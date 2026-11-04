import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../debug/developer_log.dart' as developer;
import '../../models/bilibili_models.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import '../library_service.dart';
import '../playlist_manager.dart';
import 'bilibili_cover_cache.dart';
import 'bilibili_download_service.dart';
import 'bilibili_history_service.dart';
import 'bilibili_stream_card.dart';
import 'bilibili_watch_cards.dart';

/// One video of the temporary Bilibili playlist: no files, just what it
/// takes to list it and to make its entry again without a request.
class BilibiliWatchPlaylistEntry {
  BilibiliWatchPlaylistEntry({
    required this.bvid,
    required this.page,
    required this.info,
  });

  final String bvid;

  /// The part last opened or played.
  int page;

  /// Title, cover and parts.
  BilibiliVideoInfo info;

  String get title => info.title;
  String get coverUrl => info.pic;

  BilibiliPage? get part {
    for (final candidate in info.pages) {
      if (candidate.page == page) return candidate;
    }
    return info.pages.isEmpty ? null : info.pages.first;
  }
}

/// The temporary playlist of the videos opened from the Bilibili pages, in
/// the order they were opened. Separate from the media library's queues.
/// Closing the playback page keeps it. [BilibiliWatchPlaylistSession] writes
/// it down so the mini player can show it again after a restart.
///
/// A video is in it once, with all its parts: opening it again goes back to
/// it. At most [capacity] videos; beyond that the oldest one leaves, or the
/// one after it when the oldest is playing.
class BilibiliWatchPlaylist extends ChangeNotifier {
  static const int capacity = 50;

  /// The list of this app run.
  static final BilibiliWatchPlaylist instance = BilibiliWatchPlaylist();

  final List<BilibiliWatchPlaylistEntry> _entries =
      <BilibiliWatchPlaylistEntry>[];
  String? _currentBvid;

  List<BilibiliWatchPlaylistEntry> get entries =>
      List<BilibiliWatchPlaylistEntry>.unmodifiable(_entries);

  /// The video that plays from the list.
  String? get currentBvid => _currentBvid;

  BilibiliWatchPlaylistEntry? entryOf(String bvid) {
    for (final entry in _entries) {
      if (entry.bvid == bvid) return entry;
    }
    return null;
  }

  /// [bvid] opened at part [page]: added at the end, or, when listed
  /// already, gone back to. [playingBvid] is the video playing until now,
  /// which is not dropped to make room.
  void open({
    required String bvid,
    required int page,
    required BilibiliVideoInfo info,
    String? playingBvid,
  }) {
    final listed = entryOf(bvid);
    if (listed != null) {
      listed
        ..page = page
        ..info = info;
    } else {
      _entries.add(
        BilibiliWatchPlaylistEntry(bvid: bvid, page: page, info: info),
      );
      while (_entries.length > capacity) {
        final index = _entries.indexWhere(
          (entry) => entry.bvid != bvid && entry.bvid != playingBvid,
        );
        if (index < 0) break;
        _entries.removeAt(index);
      }
    }
    _currentBvid = bvid;
    notifyListeners();
  }

  /// The list moved on to part [page] of [bvid] (next, previous, a pick in
  /// the list). False when [bvid] is not listed.
  bool select(String bvid, int page) {
    final entry = entryOf(bvid);
    if (entry == null) return false;
    if (entry.page == page && _currentBvid == bvid) return true;
    entry.page = page;
    _currentBvid = bvid;
    notifyListeners();
    return true;
  }

  bool remove(String bvid) {
    if (entryOf(bvid) == null) return false;
    _entries.removeWhere((entry) => entry.bvid == bvid);
    if (_currentBvid == bvid) _currentBvid = null;
    notifyListeners();
    return true;
  }

  /// Empties the list except for the video that plays ([keepBvid]).
  /// Returns what the list held before, for [restore].
  List<BilibiliWatchPlaylistEntry> clear({String? keepBvid}) {
    final before = <BilibiliWatchPlaylistEntry>[
      for (final entry in _entries)
        BilibiliWatchPlaylistEntry(
          bvid: entry.bvid,
          page: entry.page,
          info: entry.info,
        ),
    ];
    _entries.removeWhere((entry) => entry.bvid != keepBvid);
    if (_entries.isEmpty) _currentBvid = null;
    notifyListeners();
    return before;
  }

  /// Puts back the videos a [clear] took away, in their order. Videos
  /// opened since stay (after them, unless they were listed before); the
  /// playing one is untouched.
  void restore(List<BilibiliWatchPlaylistEntry> before) {
    final now = <String, BilibiliWatchPlaylistEntry>{
      for (final entry in _entries) entry.bvid: entry,
    };
    final merged = <BilibiliWatchPlaylistEntry>[
      for (final entry in before) now[entry.bvid] ?? entry,
    ];
    final listed = <String>{for (final entry in before) entry.bvid};
    merged.addAll(_entries.where((entry) => !listed.contains(entry.bvid)));
    while (merged.length > capacity) {
      final index = merged.indexWhere((entry) => entry.bvid != _currentBvid);
      if (index < 0) break;
      merged.removeAt(index);
    }
    _entries
      ..clear()
      ..addAll(merged);
    notifyListeners();
  }

  /// Replaces the list. Used when a saved list is read back at startup.
  void replaceAll(
    List<BilibiliWatchPlaylistEntry> entries, {
    String? currentBvid,
  }) {
    _entries
      ..clear()
      ..addAll(entries);
    _currentBvid = currentBvid;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _currentBvid = null;
    notifyListeners();
  }
}

/// Plays the [BilibiliWatchPlaylist] through the regular playback queue
/// ([PlaylistManager]): every listed video is one queue entry (its card, or
/// a lightweight entry without files), the playing one with all its parts so
/// the episode list switches parts; previous, next and auto-continue follow
/// the list. Only a watch that really opens a playback page is added
/// ([opened]). The queue is the list's only while nothing else (a library
/// folder, another queue) replaced it; other playback is never touched.
class BilibiliWatchPlaylistSession {
  BilibiliWatchPlaylistSession({
    required this.list,
    required this.service,
    required this.library,
    required this.queue,
    required this.playbackChanges,
    required this.currentItem,
    BilibiliHistoryService? history,
    this.undoWindow = defaultUndoWindow,
    this.persistenceFile,
    this.warmCovers = false,
  }) : history = history ?? BilibiliHistoryService.instance {
    _loadPersistence();
    playbackChanges.addListener(_onPlayback);
    library.addListener(_onLibrary);
    list.addListener(_onListChanged);
    queue.addListener(_onQueueChanged);
  }

  final BilibiliWatchPlaylist list;
  final BilibiliDownloadService service;
  final LibraryService library;
  final PlaylistManager queue;
  final Listenable playbackChanges;
  final VideoItem? Function() currentItem;
  final BilibiliHistoryService history;

  /// Where the list is written. Null keeps it in memory only (tests).
  final File? persistenceFile;

  /// Downloads missing covers into the shared cache. Off in tests so opening
  /// a video does not touch the image CDN.
  final bool warmCovers;

  static BilibiliWatchPlaylistSession? _instance;

  /// Bumps when a shared cover finishes downloading, so open lists can show
  /// it without waiting for the next playback tick.
  static final BilibiliCoverUpdates coverUpdates = BilibiliCoverUpdates();

  /// The app's session; null where none was installed (most tests).
  static BilibiliWatchPlaylistSession? get instance => _instance;

  static void install(BilibiliWatchPlaylistSession? session) {
    if (identical(_instance, session)) return;
    _instance?.dispose();
    _instance = session;
  }

  List<String>? _queueIds;
  final Set<String> _removedParts = {};
  List<String> _orderedParts = [];
  int _generation = 0;
  String? _lastCurrentId;
  bool _repairScheduled = false;
  bool _persistedActive = false;
  String? _persistedCurrentItemId;
  bool _loadingPersistence = false;
  Timer? _persistTimer;
  // A disposed session can still be saving when its replacement starts.
  // Serialize snapshots by file, so an older write cannot finish last.
  static final Map<String, Future<void>> _persistenceWrites = {};

  /// Whether the playback queue is this list right now.
  bool get isActive {
    final ids = _queueIds;
    if (ids == null) return false;
    return listEquals(ids, <String>[
      for (final item in queue.playlist) item.id,
    ]);
  }

  /// The title the playlist panels show for [item]: a listed video other
  /// than the playing one stands for the whole video (all its parts), so it
  /// shows the video's title rather than that of its first part. Anything
  /// else keeps its own title.
  static String titleOf(VideoItem item) {
    final session = _instance;
    if (session == null || !session.isActive) return item.title;
    if (!session._queueIds!.contains(item.id)) return item.title;
    final bvid = _bvidOf(item);
    if (bvid == null || bvid == session.list.currentBvid) return item.title;
    final title = session.list.entryOf(bvid)?.title.trim() ?? '';
    return title.isEmpty ? item.title : title;
  }

  /// Every entry of the list's queue while it is the playback queue.
  Iterable<String> queuedItemIds() {
    if (!isActive) return const <String>[];
    return List<String>.of(_queueIds!);
  }

  /// Entries of the list's queue that have no files yet; they stay while
  /// the list plays on (the mini player's previous / next use them).
  Iterable<String> placeholderIds() {
    if (!isActive) return const <String>[];
    return _queueIds!.where(service.isWatchPlaceholder);
  }

  /// The playback page of [plan] opened: its video joins the list (or the
  /// list goes back to it) and the queue becomes the list.
  void opened(BilibiliWatchPlan plan) {
    final item = plan.item;
    final ref = item.sourceRef;
    final info = plan.videoInfo;
    final bvid = _bvidOf(item) ?? info.bvid;
    if (bvid.isEmpty) return;
    // Explicitly opening the video again starts a fresh queue for its parts.
    _removedParts.removeWhere((key) => key.startsWith('$bvid:'));
    list.open(
      bvid: bvid,
      page: ref?.page ?? 1,
      info: info,
      playingBvid: list.currentBvid,
    );
    _lastCurrentId = item.id;
    // The part list is there at once; the other videos join a moment later.
    _apply(plan.queue ?? <VideoItem>[item], item.id);
    unawaited(_project(item, currentParts: plan.queue));
  }

  /// Builds the list's queue again (cards made or removed meanwhile).
  void refresh() {
    final anchored = queue.currentItem;
    if (isActive && anchored != null) unawaited(_project(anchored));
  }

  /// Removes one displayed row, retaining other parts and the live controller.
  /// Use source identities because cleaned-up cards may be rebuilt with new ids.
  bool removeFromQueue(String itemId) {
    if (!isActive) return false;
    final index = queue.indexOfItem(itemId);
    if (index < 0) return false;
    final item = queue.playlist[index];
    final bvid = _bvidOf(item);
    final key = _partKey(item);
    if (key != null) _removedParts.add(key);
    _orderedParts.remove(key);
    if (bvid != null &&
        !queue.playlist.any(
          (entry) => entry.id != itemId && _bvidOf(entry) == bvid,
        )) {
      list.remove(bvid);
    }
    // A projection already in flight must not put the removed row back.
    _generation++;
    queue.removeFromQueue(itemId);
    _queueIds = [for (final entry in queue.playlist) entry.id];
    _schedulePersist(immediate: true);
    return true;
  }

  bool reorderQueue(List<String> itemIds) {
    if (!isActive || !queue.reorderQueue(itemIds)) return false;
    _orderedParts = [for (final item in queue.playlist) ?_partKey(item)];
    _queueOrderEdited();
    return true;
  }

  bool resetQueueOrder() {
    if (!isActive || !queue.resetQueueOrder()) return false;
    _orderedParts = [];
    _queueOrderEdited();
    return true;
  }

  void _queueOrderEdited() {
    _generation++;
    _queueIds = [for (final item in queue.playlist) item.id];
    _schedulePersist(immediate: true);
  }

  /// Expands the current video's parts without moving the cursor before
  /// playback commits. Other videos retain their places in this session.
  bool preparePartSwitch(List<VideoItem> items, String currentItemId) {
    if (!isActive || queue.currentItem?.id != currentItemId) return false;
    _generation++;
    _apply(items, currentItemId);
    return true;
  }

  /// How long the 「撤销」 of a clear is offered.
  static const Duration defaultUndoWindow = Duration(seconds: 5);

  final Duration undoWindow;

  /// The playlist header listens so 「撤销」 can sit in the page instead of a toast.
  final ValueNotifier<bool> undoOffered = ValueNotifier<bool>(false);

  List<BilibiliWatchPlaylistEntry>? _undoSnapshot;
  Timer? _undoTimer;

  /// Whether the last clear can still be undone.
  bool get canUndoClear => _undoSnapshot != null;

  /// The list's "clear": every video goes except the playing one. The
  /// playing card and its place in the queue stay, so playback is neither
  /// stopped nor restarted. For [undoWindow] [undoClear] puts it back.
  Future<void> clear() async {
    final current = currentItem();
    final keep = current == null ? null : _bvidOf(current);
    _undoTimer?.cancel();
    _undoSnapshot = list.clear(keepBvid: keep);
    undoOffered.value = _undoSnapshot != null;
    _undoTimer = Timer(undoWindow, () {
      _undoSnapshot = null;
      _undoTimer = null;
      undoOffered.value = false;
    });
    final anchored = queue.currentItem;
    if (anchored != null && isActive) await _project(anchored);
    BilibiliWatchCards.instance?.janitor.scheduleSweep();
  }

  /// Undoes the last [clear] within [undoWindow]: the videos come back in
  /// their order, as lightweight entries where their cards were cleaned up
  /// meanwhile. False when it is too late.
  Future<bool> undoClear() async {
    final snapshot = _undoSnapshot;
    if (snapshot == null) return false;
    _undoSnapshot = null;
    _undoTimer?.cancel();
    _undoTimer = null;
    undoOffered.value = false;
    list.restore(snapshot);
    final anchored = queue.currentItem;
    if (anchored != null && isActive) await _project(anchored);
    return true;
  }

  void _onPlayback() {
    final current = currentItem();
    if (current == null || current.id == _lastCurrentId) return;
    _lastCurrentId = current.id;
    if (!isActive || !_queueIds!.contains(current.id)) return;
    final bvid = _bvidOf(current);
    if (bvid == null) return;
    final page = current.sourceRef?.page ?? 1;
    final sameVideo = bvid == list.currentBvid;
    if (!list.select(bvid, page)) return;
    if (sameVideo) return;
    // Another video of the list: it is watched now, and its parts show.
    final entry = list.entryOf(bvid)!;
    unawaited(_noteWatched(entry, current));
    unawaited(_project(current));
  }

  /// A listed card was cleaned up (its page closed): its place gets a
  /// lightweight entry again.
  void _onLibrary() {
    if (_repairScheduled || !isActive) return;
    final ids = _queueIds!;
    if (ids.every((id) => library.getVideo(id) != null)) return;
    _repairScheduled = true;
    scheduleMicrotask(() {
      _repairScheduled = false;
      final anchored = queue.currentItem;
      if (isActive && anchored != null) unawaited(_project(anchored));
    });
  }

  Future<void> _noteWatched(
    BilibiliWatchPlaylistEntry entry,
    VideoItem item,
  ) async {
    try {
      await history.recordWatch(
        bilibiliWatchHistoryEntry(
          info: entry.info,
          bvid: entry.bvid,
          page: entry.page,
          positionMs: item.lastPositionMs,
        ),
      );
    } catch (error) {
      developer.log('Watch history not recorded', error: error);
    }
  }

  /// Builds the queue of the list around [current] and makes it the
  /// playback queue, unless something else took over meanwhile.
  Future<void> _project(
    VideoItem current, {
    List<VideoItem>? currentParts,
  }) async {
    final generation = ++_generation;
    final List<VideoItem> items;
    try {
      items = await _queueAround(current, currentParts: currentParts);
    } catch (error, stack) {
      developer.log(
        'Bilibili playlist not built',
        error: error,
        stackTrace: stack,
      );
      return;
    }
    if (generation != _generation || !isActive) return;
    final anchored = queue.currentItem;
    if (anchored == null) return;
    if (anchored.id != current.id) {
      // Moved on meanwhile (a part picked in the list): build around that.
      unawaited(_project(anchored));
      return;
    }
    _apply(items, current.id);
  }

  void _apply(List<VideoItem> items, String currentId) {
    items = items
        .where((item) => !_removedParts.contains(_partKey(item)))
        .toList();
    List<String>? orderedIds;
    if (_orderedParts.isNotEmpty) {
      final rank = {
        for (var i = 0; i < _orderedParts.length; i++) _orderedParts[i]: i,
      };
      final positions = {for (var i = 0; i < items.length; i++) items[i].id: i};
      final ordered = [...items]
        ..sort(
          (a, b) =>
              (rank[_partKey(a)] ?? _orderedParts.length + positions[a.id]!)
                  .compareTo(
                    rank[_partKey(b)] ??
                        _orderedParts.length + positions[b.id]!,
                  ),
        );
      orderedIds = ordered.map((item) => item.id).toList();
    }
    queue.setPlaylist(
      items,
      currentItemId: currentId,
      owner: this,
      orderedItemIds: orderedIds,
    );
    _queueIds = <String>[for (final item in queue.playlist) item.id];
    final cards = BilibiliWatchCards.instance;
    for (final item in items) {
      if (item.isTransient) cards?.track(item);
    }
    if (warmCovers) unawaited(_warmMissingCovers());
    _schedulePersist(immediate: true);
  }

  /// The card's own cover file, or the shared cover kept after that card was
  /// cleaned up. Null when neither is on disk. Safe to call from a widget
  /// when the path or the item changed, not on every playback tick.
  static String? thumbnailFileFor(VideoItem item) {
    final own = item.thumbnailPath?.trim();
    if (own != null && own.isNotEmpty && File(own).existsSync()) return own;
    final bvid = _bvidOf(item);
    if (bvid == null) return null;
    // The startup Mini card precedes source integrations. Its existing shared
    // cover must not wait for the watch-playlist session to be installed.
    final root = (_instance?.library ?? LibraryService()).dataRootDirOrNull;
    if (root == null) return null;
    return BilibiliCoverCache(root).existingPath(bvid);
  }

  /// Whether startup should put this list back as the playback queue.
  ///
  /// A watch-only card has no folder, so the list is its queue whenever the
  /// video is still listed. A library card only comes back to the list when
  /// that list was the queue at exit; otherwise its folder stays in charge.
  bool shouldRestoreWatchQueue(VideoItem item) {
    final bvid = _bvidOf(item);
    if (bvid == null || list.entryOf(bvid) == null) return false;
    if (item.isTransient) return true;
    return _persistedActive;
  }

  /// Rebuilds the playback queue from the saved list around [item]. No
  /// network: the video info was saved with the list, and covers come from
  /// the shared cache.
  Future<bool> restoreWatchQueue(VideoItem item) async {
    if (!shouldRestoreWatchQueue(item)) return false;
    final bvid = _bvidOf(item);
    if (bvid == null) return false;
    final page = item.sourceRef?.page ?? list.entryOf(bvid)?.page ?? 1;
    list.select(bvid, page);
    try {
      final items = await _queueAround(item);
      if (items.isEmpty || !items.any((entry) => entry.id == item.id)) {
        return false;
      }
      _lastCurrentId = item.id;
      _apply(items, item.id);
      return isActive && queue.currentItem?.id == item.id;
    } catch (error, stack) {
      developer.log(
        'Bilibili playlist not restored',
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }

  void _onListChanged() {
    if (_loadingPersistence || persistenceFile == null) return;
    _schedulePersist();
  }

  void _onQueueChanged() {
    // Before this session has applied the list, queue updates belong to
    // whatever else is playing. Don't record those as "the list is gone".
    if (_loadingPersistence || persistenceFile == null || _queueIds == null) {
      return;
    }
    _schedulePersist();
  }

  void _schedulePersist({bool immediate = false}) {
    if (persistenceFile == null || _loadingPersistence || _disposed) return;
    _persistTimer?.cancel();
    _persistTimer = null;
    if (immediate) {
      unawaited(_writePersistence());
      return;
    }
    _persistTimer = Timer(const Duration(milliseconds: 200), () {
      _persistTimer = null;
      unawaited(_writePersistence());
    });
  }

  @visibleForTesting
  Future<void> flushPersistenceForTesting() => _writePersistence();

  Future<void> _writePersistence() {
    final file = persistenceFile;
    if (file == null) return Future<void>.value();
    final active = _queueIds != null && isActive;
    if (active) _persistedActive = true;
    final payload = <String, dynamic>{
      'active': active,
      'currentItemId': currentItem()?.id ?? _persistedCurrentItemId,
      'currentBvid': list.currentBvid,
      'removedParts': _removedParts.toList(),
      'orderedParts': List<String>.of(_orderedParts),
      'entries': <Map<String, dynamic>>[
        for (final entry in list.entries)
          <String, dynamic>{
            'bvid': entry.bvid,
            'page': entry.page,
            'info': entry.info.toJson(),
          },
      ],
    };
    final key = file.absolute.path;
    final previous = _persistenceWrites[key] ?? Future<void>.value();
    late final Future<void> writing;
    writing = previous
        .then((_) async {
          try {
            await file.parent.create(recursive: true);
            await file.writeAsString(jsonEncode(payload), flush: true);
          } catch (error) {
            developer.log('Bilibili playlist not saved', error: error);
          }
        })
        .whenComplete(() {
          if (identical(_persistenceWrites[key], writing)) {
            _persistenceWrites.remove(key);
          }
        });
    _persistenceWrites[key] = writing;
    return writing;
  }

  void _loadPersistence() {
    final file = persistenceFile;
    if (file == null || !file.existsSync()) return;
    _loadingPersistence = true;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return;
      final removed = decoded['removedParts'];
      if (removed is List) _removedParts.addAll(removed.whereType<String>());
      final ordered = decoded['orderedParts'];
      if (ordered is List) _orderedParts = ordered.whereType<String>().toList();
      _persistedActive = decoded['active'] == true;
      final currentId = decoded['currentItemId'];
      _persistedCurrentItemId = currentId is String && currentId.isNotEmpty
          ? currentId
          : null;
      final rawEntries = decoded['entries'];
      if (rawEntries is! List) return;
      final restored = <BilibiliWatchPlaylistEntry>[];
      for (final raw in rawEntries) {
        if (raw is! Map) continue;
        final bvid = raw['bvid']?.toString().trim() ?? '';
        final infoRaw = raw['info'];
        if (bvid.isEmpty || infoRaw is! Map) continue;
        final info = BilibiliVideoInfo.fromJson(
          Map<String, dynamic>.from(infoRaw),
        );
        if (info.bvid.isEmpty && info.pages.isEmpty) continue;
        final page = raw['page'] is num
            ? (raw['page'] as num).toInt()
            : int.tryParse('${raw['page']}') ?? 1;
        restored.add(
          BilibiliWatchPlaylistEntry(bvid: bvid, page: page, info: info),
        );
      }
      final savedBvid = decoded['currentBvid']?.toString();
      list.replaceAll(
        restored,
        currentBvid: savedBvid == null || savedBvid.isEmpty ? null : savedBvid,
      );
    } catch (error, stack) {
      developer.log(
        'Bilibili playlist not restored',
        error: error,
        stackTrace: stack,
      );
    } finally {
      _loadingPersistence = false;
    }
  }

  Future<void> _warmMissingCovers() async {
    if (!warmCovers || _disposed) return;
    final root = library.dataRootDirOrNull;
    if (root == null) return;
    final cache = BilibiliCoverCache(root);
    final pending = <String, String>{};
    for (final entry in list.entries) {
      final url = entry.coverUrl.trim();
      if (url.isEmpty || cache.existingPath(entry.bvid) != null) continue;
      pending[entry.bvid] = url;
    }
    final entries = pending.entries.toList(growable: false);
    const width = 4;
    for (var i = 0; i < entries.length && !_disposed && isActive; i += width) {
      final slice = entries.skip(i).take(width);
      await Future.wait(
        slice.map((entry) => cache.download(entry.key, entry.value)),
      );
    }
    if (_disposed || !isActive) return;
    var changed = false;
    for (final item in queue.playlist) {
      final own = item.thumbnailPath;
      if (own != null && own.isNotEmpty && File(own).existsSync()) continue;
      final bvid = _bvidOf(item);
      if (bvid == null) continue;
      final path = cache.existingPath(bvid);
      if (path == null) continue;
      item.thumbnailPath = path;
      changed = true;
    }
    if (changed) {
      queue.revalidatePlaylist();
      coverUpdates.ping();
    }
  }

  Future<List<VideoItem>> _queueAround(
    VideoItem current, {
    List<VideoItem>? currentParts,
  }) async {
    final currentBvid = list.currentBvid;
    final slots = <VideoItem?>[];
    final missing = <(BilibiliVideoInfo, BilibiliPage)>[];
    final missingSlots = <int>[];
    for (final entry in list.entries) {
      if (entry.bvid == currentBvid) {
        slots.addAll(
          currentParts ??
              await bilibiliWatchPartsQueue(
                service: service,
                library: library,
                info: entry.info,
                bvid: entry.bvid,
                current: current,
                currentPage: entry.page,
              ),
        );
        continue;
      }
      final part = entry.part;
      if (part == null) continue;
      final existing =
          service.findStreamCard(library, bvid: entry.bvid, page: part) ??
          findBilibiliStreamCard(
            library.transientVideos,
            bvid: entry.bvid,
            page: part.page,
            cid: part.cid,
            collectionOf: library.getCollection,
          );
      if (existing != null) {
        slots.add(existing);
      } else {
        missingSlots.add(slots.length);
        missing.add((entry.info, part));
        slots.add(null);
      }
    }
    if (missing.isNotEmpty) {
      final made = await service.addWatchEntries(library, missing);
      // Parts without a BV or cid are skipped by addWatchEntries.
      var next = 0;
      for (var i = 0; i < missingSlots.length && next < made.length; i++) {
        final (info, part) = missing[i];
        final candidate = made[next];
        if (candidate.sourceRef?.cid != part.cid) continue;
        next++;
        _resumeFromHistory(candidate, info);
        slots[missingSlots[i]] = candidate;
      }
    }
    return <VideoItem>[for (final slot in slots) ?slot];
  }

  /// A new entry starts where the history says the video was left, when
  /// that was this part.
  void _resumeFromHistory(VideoItem item, BilibiliVideoInfo info) {
    final bvid = _bvidOf(item) ?? info.bvid;
    final saved = history.watchEntryOf(bvid);
    if (saved != null && saved.page == item.sourceRef?.page) {
      item.lastPositionMs = saved.positionMs;
    }
  }

  static String? _bvidOf(VideoItem item) {
    final ref = item.sourceRef;
    if (ref == null || ref.kind != MediaSourceKind.bilibiliStream) {
      return null;
    }
    final bvid = (ref.bvid ?? ref.value).trim();
    return bvid.isEmpty ? null : bvid;
  }

  static String? _partKey(VideoItem item) {
    final bvid = _bvidOf(item);
    if (bvid == null) return null;
    return '$bvid:${item.sourceRef?.cid ?? 'p${item.sourceRef?.page ?? 1}'}';
  }

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _undoTimer?.cancel();
    _persistTimer?.cancel();
    _persistTimer = null;
    playbackChanges.removeListener(_onPlayback);
    library.removeListener(_onLibrary);
    list.removeListener(_onListChanged);
    queue.removeListener(_onQueueChanged);
    if (persistenceFile != null) unawaited(_writePersistence());
  }
}

/// Tells open playlist rows that a shared Bilibili cover is now on disk.
class BilibiliCoverUpdates extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// The 「清空」 of the playlist panels (episode panel, mini player list):
/// clears the temporary Bilibili playlist except the playing video, without
/// asking, and offers 「撤销」 for a few seconds.
Future<void> clearBilibiliWatchPlaylist(
  BilibiliWatchPlaylistSession session,
) async {
  await session.clear();
}
