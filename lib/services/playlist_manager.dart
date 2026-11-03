import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/playback_mode.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import 'library_service.dart';
import 'playback_queue_order.dart';
import 'playback_queue_policy.dart';
import 'playback_queue_identity.dart';
import 'playback_state_store.dart';

class PlaybackQueueNavigation {
  PlaybackQueueNavigation._(
    this.item,
    this._order,
    this._key,
    this._modeVersion,
  );

  final VideoItem item;
  final PlaybackQueueOrder _order;
  final String? _key;
  final int _modeVersion;
}

class _QueuePosition {
  const _QueuePosition(this.id, this.source);

  factory _QueuePosition.of(VideoItem item) {
    final ref = item.sourceRef;
    final source = ref?.kind == MediaSourceKind.bilibiliStream
        ? 'bilibili:${ref?.bvid ?? ref?.value}:${ref?.cid ?? 'p${ref?.page ?? 1}'}'
        : item.id;
    return _QueuePosition(item.id, source);
  }

  final String id;
  final String source;

  Map<String, String> toJson() => {'id': id, 'source': source};
}

/// Owns the one canonical, source-validated playback queue.
///
/// Library visibility and direct-open eligibility deliberately remain outside
/// this class. A missing local item can be opened, but its id will be detached
/// from [snapshot] and previous/next navigation will be unavailable.
class PlaylistManager extends ChangeNotifier {
  PlaylistManager({
    PlaybackQueuePolicy? queuePolicy,
    PlaybackStateStore? modeStore,
  }) : _queuePolicy = queuePolicy ?? PlaybackQueuePolicy(),
       _modeStore =
           modeStore ??
           PlaybackStateStore(
             storageFileName: 'playback_queue_modes.json',
             preferenceKey: 'playback_queue_modes',
           ),
       _snapshot = PlaybackQueueSnapshot(
         revision: 0,
         entries: const <VideoItem>[],
         currentItemId: null,
         folderId: null,
       );

  final PlaybackQueuePolicy _queuePolicy;
  final PlaybackStateStore _modeStore;
  final Map<String, Map<String, dynamic>> _savedModes = {};
  PlaybackQueueOrder _order = PlaybackQueueOrder();
  List<_QueuePosition> _customOrder = [];
  List<VideoItem> _playbackQueue = const [];
  int _playbackIndex = -1;
  final Map<(bool, bool, bool), VideoItem?> _relativeCache = {};
  String? _queueKey;
  int _modeVersion = 0;
  int _modeSelectionRevision = 0;
  bool _modesInitialized = false;
  Future<void>? _initializingModes;
  Future<void> _modeWrite = Future.value();
  PlaybackQueueNavigation? _pendingNavigation;
  LibraryService? _libraryService;
  PlaybackQueueSnapshot _snapshot;
  List<VideoItem> _sourceItems = const <VideoItem>[];
  final Set<String> _removedItemIds = {};
  String? _currentFolderId;
  String? _anchoredItemId;
  bool _isFolderPlaylist = false;

  /// True only while the active queue was opened from one recycle-bin page.
  /// Library folder queues keep this false so recycled cards stay out.
  bool _includeRecycledItems = false;
  bool _manualQueue = false;
  bool _savedManualQueue = false;
  int _queueEpoch = 0;
  final List<List<VideoItem>> _additionUndo = [];
  int get queueEpoch => _queueEpoch;
  bool get hasManualQueue => _manualQueue;

  PlaybackQueueSnapshot get snapshot => _snapshot;
  List<VideoItem> get playlist => _snapshot.entries;
  List<VideoItem> get playbackQueue => _playbackQueue;
  PlaybackMode get playbackMode => _order.mode;
  int get playbackIndex => _playbackIndex;
  int get currentIndex => _snapshot.currentIndex;
  bool get hasCustomOrder => _customOrder.isNotEmpty;
  Object? queueOwner;

  Future<void> initializePlaybackModes() =>
      _initializingModes ??= _loadPlaybackModes();

  Future<void> _loadPlaybackModes() async {
    final version = _modeSelectionRevision;
    var restoredManual = false;
    try {
      final stored = await _modeStore.read();
      final manual = stored?['activeManualQueue'];
      _savedManualQueue = _savedManualQueue || manual is Map;
      if (_queueKey == null && _sourceItems.isEmpty && manual is Map) {
        final restored = <VideoItem>[];
        for (final raw
            in manual['items'] is List ? manual['items'] as List : const []) {
          try {
            if (raw is! Map) continue;
            final saved = VideoItem.fromJson(Map<String, dynamic>.from(raw));
            restored.add(_libraryService?.getVideo(saved.id) ?? saved);
          } catch (_) {
            /* A damaged entry must not discard the remaining queue. */
          }
        }
        if (restored.isNotEmpty) {
          _queueKey = manual['key'] as String? ?? 'manual:restored';
          _sourceItems = restored;
          _manualQueue = true;
          restoredManual = true;
          _anchoredItemId = manual['currentId'] as String?;
          if (_libraryService?.dataRootDirOrNull != null) {
            await _libraryService!.addTransientVideos(
              restored.where(
                (item) =>
                    item.isTransient &&
                    _libraryService!.getVideo(item.id) == null,
              ),
            );
          }
        }
      }
      final queues = stored?['queues'];
      if (queues is Map) {
        for (final entry in queues.entries) {
          if (entry.key is String && entry.value is Map) {
            _savedModes.putIfAbsent(
              entry.key as String,
              () => Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
      if (version == _modeSelectionRevision && _queueKey != null) {
        final saved = _savedModes[_queueKey];
        if (saved != null) {
          _order = PlaybackQueueOrder.fromJson(saved);
          _restoreCustomOrder(saved);
          _replaceSnapshot(
            restoredManual ? _sourceItems : playlist,
            currentItemId: _anchoredItemId,
            folderId: _currentFolderId,
            revalidate: restoredManual,
          );
        }
      }
      if (restoredManual && _snapshot.entries.isEmpty && _manualQueue) {
        _replaceSnapshot(
          _sourceItems,
          currentItemId: _anchoredItemId,
          folderId: null,
        );
      }
    } catch (error) {
      debugPrint('Playback queue mode restore failed: $error');
    }
    _modesInitialized = true;
    _rememberMode();
  }

  void setPlaybackMode(PlaybackMode mode) {
    if (mode == playbackMode) return;
    _order.setMode(mode);
    _modeVersion++;
    _modeSelectionRevision++;
    _pendingNavigation = null;
    _replaceSnapshot(
      playlist,
      currentItemId: _anchoredItemId,
      folderId: _currentFolderId,
      revalidate: false,
    );
  }

  void cyclePlaybackMode() => setPlaybackMode(playbackMode.next);

  void _activateQueue(String key) {
    if (_queueKey == key) return;
    _rememberMode();
    _queueEpoch++;
    _manualQueue = false;
    _additionUndo.clear();
    _queueKey = key;
    _modeVersion++;
    _pendingNavigation = null;
    final saved = _savedModes[key];
    try {
      _order = saved == null
          ? PlaybackQueueOrder()
          : PlaybackQueueOrder.fromJson(saved);
      _restoreCustomOrder(saved);
    } catch (_) {
      _order = PlaybackQueueOrder();
      _customOrder = [];
    }
  }

  void _restoreCustomOrder(Map<String, dynamic>? saved) {
    final raw = saved?['customOrder'];
    _customOrder = [
      if (raw is List)
        for (final entry in raw)
          if (entry is Map && entry['id'] is String)
            _QueuePosition(
              entry['id'] as String,
              entry['source'] is String
                  ? entry['source'] as String
                  : entry['id'] as String,
            ),
    ];
  }

  List<VideoItem> _orderedEntries(Iterable<VideoItem> source) {
    final items = source.toList();
    if (!hasCustomOrder) return List.unmodifiable(items);
    final byId = {for (final item in items) item.id: item};
    final bySource = <String, List<VideoItem>>{};
    for (final item in items) {
      bySource.putIfAbsent(_QueuePosition.of(item).source, () => []).add(item);
    }
    final used = <String>{};
    final ordered = <VideoItem>[];
    for (final position in _customOrder) {
      final item =
          byId[position.id] ??
          bySource[position.source]
              ?.where((item) => !used.contains(item.id))
              .firstOrNull;
      if (item != null && used.add(item.id)) ordered.add(item);
    }
    for (final item in items) {
      if (used.add(item.id)) ordered.add(item);
    }
    return List.unmodifiable(ordered);
  }

  String _explicitQueueKey(
    List<VideoItem> items,
    Object? owner,
    String? selectedId,
  ) {
    final ids = items.map((item) => item.id).toSet();
    final oldSourceIds = _sourceItems.map((item) => item.id).toSet();
    if ((!_manualQueue || (owner == null && setEquals(ids, oldSourceIds))) &&
        !_isFolderPlaylist &&
        !_includeRecycledItems &&
        _queueKey != null &&
        ((owner != null && identical(owner, queueOwner)) ||
            setEquals(ids, oldSourceIds) ||
            (selectedId == _anchoredItemId &&
                oldSourceIds.any(ids.contains)))) {
      return _queueKey!;
    }
    final orderedIds = ids.toList()..sort();
    final key = 'items:${sha256.convert(utf8.encode(jsonEncode(orderedIds)))}';
    if (_savedModes.containsKey(key)) return key;
    // Match an edited queue after restart without inheriting another
    // playlist's mode just because it contains some of the same media.
    for (final entry in _savedModes.entries.toList().reversed) {
      if (!entry.key.startsWith('items:')) continue;
      final oldIds =
          (entry.value['source'] is List
                  ? entry.value['source'] as List
                  : const [])
              .whereType<String>()
              .toSet();
      if (ids.isNotEmpty && setEquals(ids, oldIds)) {
        return entry.key;
      }
    }
    return key;
  }

  void _rememberMode() {
    final key = _queueKey;
    if (key == null) return;
    final saveMode =
        _manualQueue ||
        playbackMode != PlaybackMode.sequential ||
        hasCustomOrder ||
        _savedModes.containsKey(key);
    if (!saveMode && !_savedManualQueue) return;
    if (saveMode) {
      _savedModes.remove(key);
      _savedModes[key] = {
        ..._order.toJson(),
        if (hasCustomOrder)
          'customOrder': [
            for (final position in _customOrder) position.toJson(),
          ],
      };
    }
    while (_savedModes.length > 48) {
      _savedModes.remove(_savedModes.keys.first);
    }
    if (!_modesInitialized) return;
    _savedManualQueue = _manualQueue;
    _modeWrite = _modeStore
        .write({
          'version': 1,
          'queues': Map.of(_savedModes),
          if (_manualQueue)
            'activeManualQueue': {
              'key': key,
              'currentId': _anchoredItemId,
              'items': [
                for (final item in _sourceItems) _persistedQueueItem(item),
              ],
            },
        })
        .catchError((Object error) {
          debugPrint('Playback queue mode save failed: $error');
        });
  }

  Future<void> flushPlaybackModes() => _modeWrite;

  Map<String, dynamic> _persistedQueueItem(VideoItem item) {
    final value = item.toJson();
    final source = item.sourceRef;
    if (source?.cloudDrive != null ||
        source?.podcast != null ||
        source?.kind == MediaSourceKind.bilibiliStream) {
      value['playbackPath'] = null;
    }
    return value;
  }

  /// Library loading and queue metadata loading run independently at startup.
  /// Reconnect retained queue cards once the catalog is ready, without importing.
  Future<void> ensureManualQueueLibraryEntries() async {
    final library = _libraryService;
    if (!_manualQueue || library?.dataRootDirOrNull == null) return;
    final epoch = _queueEpoch;
    _sourceItems = [
      for (final item in _sourceItems) library!.getVideo(item.id) ?? item,
    ];
    final missing = _sourceItems
        .where((item) => item.isTransient && library!.getVideo(item.id) == null)
        .toList();
    if (missing.isNotEmpty) await library!.addTransientVideos(missing);
    if (epoch == _queueEpoch && _manualQueue) {
      _replaceSnapshot(
        _sourceItems,
        currentItemId: _anchoredItemId,
        folderId: null,
      );
    }
  }

  /// The displayed order becomes the actual skip/continuation order. Playback
  /// stays on the same item; random mode yields to the user's explicit order.
  bool reorderQueue(List<String> itemIds) {
    final currentIds = playbackQueue.map((item) => item.id).toList();
    if (itemIds.length < 2 ||
        itemIds.length != currentIds.length ||
        itemIds.toSet().length != itemIds.length ||
        !setEquals(itemIds.toSet(), currentIds.toSet()) ||
        listEquals(itemIds, currentIds)) {
      return false;
    }
    final byId = {for (final item in playlist) item.id: item};
    _customOrder = [for (final id in itemIds) _QueuePosition.of(byId[id]!)];
    if (playbackMode == PlaybackMode.shuffle) {
      _order.setMode(PlaybackMode.sequential);
    }
    _publishOrderEdit();
    return true;
  }

  bool reverseQueue() =>
      reorderQueue(playbackQueue.reversed.map((item) => item.id).toList());

  bool resetQueueOrder() {
    if (!hasCustomOrder) return false;
    _customOrder = [];
    if (playbackMode == PlaybackMode.shuffle) {
      _order.setMode(PlaybackMode.sequential);
    }
    _publishOrderEdit();
    return true;
  }

  void _publishOrderEdit() {
    _modeVersion++;
    _modeSelectionRevision++;
    _pendingNavigation = null;
    _replaceSnapshot(
      _sourceItems,
      currentItemId: _anchoredItemId,
      folderId: _currentFolderId,
    );
  }

  PlaybackQueueNavigation? planNavigation(
    Iterable<int> deltas, {
    bool wrap = false,
    bool includeCurrentAfterWrap = false,
  }) {
    final order = _order.copy();
    var moved = false;
    for (final delta in deltas) {
      if (order.move(
            delta,
            wrap: wrap,
            includeCurrentAfterWrap: includeCurrentAfterWrap,
          ) !=
          null) {
        moved = true;
      }
    }
    if (!moved ||
        (order.currentId == _anchoredItemId && !includeCurrentAfterWrap)) {
      return null;
    }
    final index = indexOfItem(order.currentId ?? '');
    if (index < 0) return null;
    order.keepCommittedHistory(_order);
    return PlaybackQueueNavigation._(
      playlist[index],
      order,
      _queueKey,
      _modeVersion,
    );
  }

  VideoItem? relativeItem({
    required bool next,
    bool wrap = false,
    bool includeCurrentAfterWrap = false,
  }) => _relativeCache.putIfAbsent(
    (next, wrap, includeCurrentAfterWrap),
    () => planNavigation(
      [next ? 1 : -1],
      wrap: wrap,
      includeCurrentAfterWrap: includeCurrentAfterWrap,
    )?.item,
  );

  void prepareNavigation(PlaybackQueueNavigation navigation) {
    if (navigation._key == _queueKey &&
        navigation._modeVersion == _modeVersion) {
      _pendingNavigation = navigation;
    }
  }

  void cancelPreparedNavigation() => _pendingNavigation = null;

  int get revision => _snapshot.revision;
  VideoItem? get currentItem => _snapshot.currentItem;
  String? get anchoredItemId => _anchoredItemId;
  bool get isCurrentItemDetached =>
      _anchoredItemId != null && _snapshot.currentIndex < 0;
  bool isQueueEligible(VideoItem item) {
    final allowRecycled =
        _includeRecycledItems &&
        _sourceItems.any((candidate) => candidate.id == item.id);
    return _queuePolicy.isEligible(item, allowRecycled: allowRecycled);
  }

  void initialize({required LibraryService libraryService}) {
    _libraryService = libraryService;
  }

  /// Replaces the queue with a validated projection.
  ///
  /// [startIndex] addresses the unfiltered input so a missing selected item
  /// becomes detached instead of silently selecting a different playable item.
  void setPlaylist(
    List<VideoItem> items, {
    int startIndex = 0,
    String? currentItemId,
    Object? owner,
    List<String>? orderedItemIds,
  }) {
    // A cloud directory can finish loading after a user edits its queue.
    // Only that same owner may update the projection without resetting edits.
    if (owner == null || !identical(owner, queueOwner)) {
      _removedItemIds.clear();
    }
    final requestedId =
        currentItemId ??
        (items.isNotEmpty && startIndex >= 0 && startIndex < items.length
            ? items[startIndex].id
            : null);
    _activateQueue(_explicitQueueKey(items, owner, requestedId));
    if (orderedItemIds != null) {
      final byId = {for (final item in items) item.id: item};
      _customOrder = [
        for (final id in orderedItemIds)
          if (byId[id] != null) _QueuePosition.of(byId[id]!),
      ];
      _modeSelectionRevision++;
    }
    queueOwner = owner;
    _sourceItems = items
        .where((item) => !_removedItemIds.contains(item.id))
        .toList();
    _isFolderPlaylist = false;
    _includeRecycledItems = false;
    _currentFolderId = null;
    _replaceSnapshot(_sourceItems, currentItemId: requestedId, folderId: null);
  }

  /// Queue for the recycle-bin page the user is previewing.
  ///
  /// [items] are the videos on that page only: the bin root, or one recycled
  /// folder. Nested folders stay separate queues. This is not a library folder
  /// queue, so a later reload must not swap these cards for the visible
  /// library siblings. The recycled cards stay eligible for previous/next and
  /// the playlist card until a library queue replaces this one.
  void setRecycleBinPlaylist(
    List<VideoItem> items, {
    required String currentItemId,
    String? folderId,
  }) {
    _removedItemIds.clear();
    _activateQueue('recycle:${folderId ?? 'root'}');
    _sourceItems = List<VideoItem>.from(items);
    _isFolderPlaylist = false;
    queueOwner = null;
    _includeRecycledItems = true;
    _currentFolderId = folderId;
    _replaceSnapshot(
      _sourceItems,
      currentItemId: currentItemId,
      folderId: folderId,
    );
  }

  bool matchesFolderPlaylist(String? folderId, String currentItemId) {
    return _isFolderPlaylist &&
        _currentFolderId == folderId &&
        _anchoredItemId == currentItemId &&
        _snapshot.indexOf(currentItemId) >= 0;
  }

  void appendPlaylistItems(List<VideoItem> items) {
    if (items.isEmpty || _isFolderPlaylist) return;
    final known = _sourceItems.map((item) => item.id).toSet();
    for (final item in items) {
      if (!_removedItemIds.contains(item.id) && known.add(item.id)) {
        _sourceItems.add(item);
      }
    }
    _replaceSnapshot(
      _sourceItems,
      currentItemId: _anchoredItemId,
      folderId: _currentFolderId,
    );
  }

  /// User additions retain the active order object, cursor and shuffle history.
  /// Freezing a source listing stops its asynchronous page loader replacing a
  /// mixed queue later. Duplicate resources keep their original card/position.
  ({List<String> added, int duplicates, List<String> failed})
  addToPlaybackQueue(Iterable<VideoItem> items) {
    final known = {
      for (final item in _sourceItems) playbackQueueIdentity(item),
    };
    final knownIds = _sourceItems.map((item) => item.id).toSet();
    final added = <VideoItem>[];
    final failed = <String>[];
    var duplicates = 0;
    for (final item in items) {
      if (!_queuePolicy.isEligible(item)) {
        failed.add(item.id);
      } else if (knownIds.contains(item.id) ||
          !known.add(playbackQueueIdentity(item))) {
        duplicates++;
      } else {
        knownIds.add(item.id);
        added.add(item);
      }
    }
    if (added.isNotEmpty) {
      if (!_manualQueue) {
        _rememberMode();
        _queueKey = 'manual:${DateTime.now().microsecondsSinceEpoch}';
      }
      _manualQueue = true;
      _isFolderPlaylist = false;
      _includeRecycledItems = false;
      _currentFolderId = null;
      queueOwner = null;
      _removedItemIds.removeAll(added.map((item) => item.id));
      _sourceItems = [..._sourceItems, ...added];
      _additionUndo.add(added);
      if (_additionUndo.length > 12) _additionUndo.removeAt(0);
      _modeVersion++;
      _modeSelectionRevision++;
      _pendingNavigation = null;
      _replaceSnapshot(
        _sourceItems,
        currentItemId: _anchoredItemId,
        folderId: null,
      );
    } else if (duplicates > 0) {
      // A restored file can become eligible again without moving its queue row.
      refreshQueueEligibility();
    }
    return (
      added: added.map((item) => item.id).toList(),
      duplicates: duplicates,
      failed: failed,
    );
  }

  bool get canUndoQueueAddition {
    final byId = {for (final item in _sourceItems) item.id: item};
    return _additionUndo.any(
      (batch) => batch.any(
        (item) => item.id != _anchoredItemId && identical(byId[item.id], item),
      ),
    );
  }

  /// Undo only this insertion, never a stale snapshot of the whole queue.
  /// A playing item stays in place, as do later replacements of removed cards.
  bool undoLastQueueAddition() {
    final byId = {for (final item in _sourceItems) item.id: item};
    while (_additionUndo.isNotEmpty) {
      final batch = _additionUndo.removeLast();
      final ids = batch
          .where(
            (item) =>
                item.id != _anchoredItemId && identical(byId[item.id], item),
          )
          .map((item) => item.id)
          .toSet();
      if (ids.isEmpty) continue;
      _removedItemIds.addAll(ids);
      _sourceItems = _sourceItems
          .where((item) => !ids.contains(item.id))
          .toList();
      _customOrder.removeWhere((position) => ids.contains(position.id));
      _modeVersion++;
      _pendingNavigation = null;
      _replaceSnapshot(
        _sourceItems,
        currentItemId: _anchoredItemId,
        folderId: _currentFolderId,
      );
      return true;
    }
    return false;
  }

  /// Edits this queue without touching library entries or the live player.
  /// A folder queue becomes a custom snapshot so refresh cannot reinsert an
  /// entry the user removed. Explicitly opening a folder starts its queue again.
  bool removeFromQueue(String itemId) {
    if (indexOfItem(itemId) < 0) return false;
    _removedItemIds.add(itemId);
    _customOrder.removeWhere((position) => position.id == itemId);
    _sourceItems = _sourceItems.where((item) => item.id != itemId).toList();
    _isFolderPlaylist = false;
    _modeVersion++;
    _pendingNavigation = null;
    _replaceSnapshot(
      _sourceItems,
      currentItemId: _anchoredItemId,
      folderId: _currentFolderId,
    );
    return true;
  }

  /// Opens an imported card without loading its folder or activating another
  /// queue. Preserve playback mode, shuffle history and prior order. Adding
  /// an outside item freezes a folder or paginated queue into a custom list.
  bool prepareImportedPlayback(VideoItem item) {
    if (!_queuePolicy.isEligible(item)) return false;
    _removedItemIds.remove(item.id);
    final existing = indexOfItem(item.id);
    if (existing >= 0) {
      cancelPreparedNavigation();
      final sourceIndex = _sourceItems.indexWhere(
        (entry) => entry.id == item.id,
      );
      if (sourceIndex >= 0 && !identical(_sourceItems[sourceIndex], item)) {
        _sourceItems = List.of(_sourceItems)..[sourceIndex] = item;
        _replaceSnapshot(
          _sourceItems,
          currentItemId: item.id,
          folderId: _currentFolderId,
        );
      } else {
        setCurrentIndex(existing);
      }
      return true;
    }

    _rememberMode();
    final items = List<VideoItem>.from(_sourceItems);
    final oldIndex = items.indexWhere((candidate) => candidate.id == item.id);
    if (oldIndex >= 0) {
      items[oldIndex] = item;
    } else {
      items.add(item);
    }
    // Keep the active order object rather than setPlaylist(), which may load
    // a different persisted mode and discard committed shuffle history.
    if (!_manualQueue) _queueKey = _explicitQueueKey(items, null, item.id);
    // Pending cloud-directory loads must not replace this mixed queue with
    // their original listing after the imported card was appended.
    queueOwner = null;
    _modeVersion++;
    _modeSelectionRevision++;
    _pendingNavigation = null;
    _sourceItems = items;
    _isFolderPlaylist = false;
    _currentFolderId = null;
    _replaceSnapshot(items, currentItemId: item.id, folderId: null);
    return true;
  }

  void loadFolderPlaylist(String? folderId, String currentItemId) {
    final library = _libraryService;
    if (library == null) {
      debugPrint('PlaylistManager: LibraryService not initialized');
      return;
    }
    if (matchesFolderPlaylist(folderId, currentItemId)) return;

    _removedItemIds.clear();
    _activateQueue('folder:${folderId ?? 'root'}');
    queueOwner = null;
    _isFolderPlaylist = true;
    _includeRecycledItems = false;
    _currentFolderId = folderId;
    _sourceItems = library.getVideosInFolder(folderId);
    _replaceSnapshot(
      _sourceItems,
      currentItemId: currentItemId,
      folderId: folderId,
    );
  }

  /// Opens a library item into a playback queue.
  ///
  /// By default search result pages are locators only, so previous/next follow
  /// [item]'s original parent folder. [useSearchResultsAsQueue] restores the
  /// optional behavior of treating the current search listing as the queue.
  void prepareLibraryPlayback(
    VideoItem item, {
    List<VideoItem>? searchItems,
    bool useSearchResultsAsQueue = false,
  }) {
    if (useSearchResultsAsQueue && searchItems != null) {
      final startIndex = searchItems.indexWhere(
        (candidate) => candidate.id == item.id,
      );
      setPlaylist(searchItems, startIndex: startIndex < 0 ? 0 : startIndex);
      return;
    }
    if (_manualQueue && indexOfItem(item.id) >= 0) {
      anchorCurrentItem(item);
      return;
    }
    loadFolderPlaylist(item.parentId, item.id);
  }

  /// Revalidates source existence and publishes a new queue revision.
  void reloadPlaylist() {
    final library = _libraryService;
    if (!_isFolderPlaylist || library == null) return;
    _sourceItems = library.getVideosInFolder(_currentFolderId);
    _replaceSnapshot(
      _sourceItems,
      currentItemId: _anchoredItemId,
      folderId: _currentFolderId,
    );
  }

  /// Revalidates an explicitly supplied queue without changing its scope.
  void revalidatePlaylist() {
    if (_isFolderPlaylist) {
      reloadPlaylist();
      return;
    }
    _replaceSnapshot(
      _sourceItems,
      currentItemId: _anchoredItemId,
      folderId: _currentFolderId,
    );
  }

  /// Cheap source revalidation used immediately before publishing an OS queue.
  /// It notifies only when membership or the anchored index actually changes,
  /// avoiding a media-session listener loop.
  void refreshQueueEligibility() {
    if (_isFolderPlaylist && _libraryService != null) {
      _sourceItems = _libraryService!.getVideosInFolder(_currentFolderId);
    }
    final filtered = _orderedEntries(
      _queuePolicy.filter(_sourceItems, allowRecycled: _includeRecycledItems),
    );
    final oldIds = _snapshot.entries.map((item) => item.id).toList();
    final newIds = filtered.map((item) => item.id).toList();
    if (listEquals(oldIds, newIds) &&
        _snapshot.currentItemId == _anchoredItemId) {
      return;
    }
    _replaceSnapshot(
      filtered,
      currentItemId: _anchoredItemId,
      folderId: _currentFolderId,
      revalidate: false,
    );
  }

  VideoItem? getNext() => relativeItem(next: true);
  VideoItem? getFirst() => playlist.isEmpty ? null : playlist.first;
  VideoItem? getPrevious() => relativeItem(next: false);
  bool get hasNext => getNext() != null;
  bool get hasPrevious => getPrevious() != null;

  void setCurrentIndex(int index) {
    if (index < 0 || index >= playlist.length) return;
    final id = playlist[index].id;
    // Repeating the same cursor must not rewrite the snapshot or notify.
    if (id == _anchoredItemId && _snapshot.currentIndex == index) return;
    _replaceSnapshot(
      _sourceItems,
      currentItemId: id,
      folderId: _currentFolderId,
    );
  }

  /// Keeps a direct-open item associated with its folder while explicitly
  /// detaching it when it does not satisfy queue eligibility.
  ///
  /// A podcast or hand-built queue stays in place when the current item is
  /// removed. Falling through to the item's library folder would discard that
  /// order.
  void anchorCurrentItem(VideoItem item) {
    final index = indexOfItem(item.id);
    if (index >= 0) {
      setCurrentIndex(index);
      return;
    }
    if (!_isFolderPlaylist &&
        (_sourceItems.isNotEmpty || _removedItemIds.isNotEmpty)) {
      _replaceSnapshot(
        _sourceItems,
        currentItemId: item.id,
        folderId: _currentFolderId,
      );
      return;
    }
    if (_libraryService != null) {
      loadFolderPlaylist(item.parentId, item.id);
      return;
    }
    _replaceSnapshot(
      _sourceItems,
      currentItemId: item.id,
      folderId: _currentFolderId,
    );
  }

  int indexOfItem(String itemId) => _snapshot.indexOf(itemId);

  void _replaceSnapshot(
    Iterable<VideoItem> items, {
    required String? currentItemId,
    required String? folderId,
    bool revalidate = true,
  }) {
    final entries = _orderedEntries(
      revalidate
          ? _queuePolicy.filter(items, allowRecycled: _includeRecycledItems)
          : items,
    );
    _anchoredItemId = currentItemId;
    _snapshot = PlaybackQueueSnapshot(
      revision: _snapshot.revision + 1,
      entries: entries,
      currentItemId: currentItemId,
      folderId: folderId,
    );
    final pending = _pendingNavigation;
    if (pending != null &&
        pending.item.id == currentItemId &&
        pending._key == _queueKey &&
        pending._modeVersion == _modeVersion) {
      _order = pending._order.copy();
      _pendingNavigation = null;
    }
    _order.synchronize(entries.map((item) => item.id), currentItemId);
    final byId = {for (final item in entries) item.id: item};
    _playbackQueue = List.unmodifiable([
      for (final id in _order.queueIds)
        if (byId[id] != null) byId[id]!,
    ]);
    _playbackIndex = _playbackQueue.indexWhere(
      (item) => item.id == currentItemId,
    );
    _relativeCache.clear();
    _rememberMode();
    notifyListeners();
  }
}
