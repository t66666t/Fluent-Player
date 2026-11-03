import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../models/managed_subtitle_asset.dart';
import '../../../models/video_item.dart';
import '../../../services/library_service.dart';
import '../../../services/task_subtitle_storage_service.dart';
import '../../../utils/subtitle_parser.dart';
import '../../../models/cloud_drive_source_ref.dart';
import '../models/cloud_drive_models.dart';
import '../providers/cloud_drive_provider.dart';
import 'cloud_drive_runtime.dart';

/// Scope shared by every card of one account, file and revision.
String cloudOfficialScope(CloudDriveSourceRef source) {
  final canonical = [
    source.providerId,
    source.remoteAccountId,
    source.driveId,
    source.fileId,
    source.revision ?? '',
  ].join('\u001f');
  return sha256.convert(utf8.encode(canonical)).toString().substring(0, 16);
}

/// Library asset id for one official track. The signed URL is not stored.
String cloudOfficialAssetId(CloudDriveSourceRef source, String trackId) {
  return 'cloud-official-${cloudOfficialScope(source)}-$trackId';
}

/// One row in the cloud subtitle group.
class CloudDriveListedSubtitle {
  const CloudDriveListedSubtitle({
    required this.id,
    required this.label,
    required this.isAi,
    this.language,
    this.savedPath,
    this.remote,
  });

  final String id;
  final String label;
  final String? language;
  final bool isAi;
  final String? savedPath;
  final CloudDriveSubtitleTrack? remote;

  bool get isSaved => savedPath != null;
}

/// One readable official track to apply when a cloud video has no selection.
///
/// Prefer Chinese, then supplied subtitles over AI subtitles in that language.
/// The AI marker describes the source; it is not required for automatic loading.
CloudDriveListedSubtitle? preferredCloudDriveAutoSubtitle(
  Iterable<CloudDriveListedSubtitle> tracks,
) {
  final usable = tracks
      .where((track) => track.isSaved || track.remote?.textAvailable == true)
      .toList(growable: false);
  if (usable.isEmpty) return null;

  bool isChinese(CloudDriveListedSubtitle track) {
    final language = track.language?.toLowerCase().replaceAll('_', '-') ?? '';
    return language == 'zh' ||
        language.startsWith('zh-') ||
        language == 'chi' ||
        language == 'zho';
  }

  final chinese = usable.where(isChinese).toList(growable: false);
  final preferred = chinese.isNotEmpty ? chinese : usable;
  for (final track in preferred) {
    if (!track.isAi) return track;
  }
  return preferred.first;
}

/// Lifecycle of the automatic official-subtitle selection.
///
/// The player keeps this separate from `cloudDriveSubtitleStatus` so a failure
/// is not a permanent "正在查找" and a deliberate skip is not an error.
enum CloudDriveAutoSubtitleStatus {
  idle,
  loading,
  applied,
  preserved,
  skipped,
  failed,
}

/// Why the automatic selection did nothing. Explicit, never inferred from a
/// silent return.
enum CloudDriveAutoSubtitleSkipReason {
  none,
  manual,
  disabled,
  cached,
  noTracks,
  notReady,
  superseded,
  emptyText,
  unparsable,
  network,
  loginRequired,
  restricted,
  scope,
}

/// Result of one automatic attempt for the current media.
class CloudDriveAutoSubtitleOutcome {
  const CloudDriveAutoSubtitleOutcome(
    this.status, {
    this.reason = CloudDriveAutoSubtitleSkipReason.none,
    this.trackId,
    this.detail,
  });

  const CloudDriveAutoSubtitleOutcome.idle()
    : status = CloudDriveAutoSubtitleStatus.idle,
      reason = CloudDriveAutoSubtitleSkipReason.none,
      trackId = null,
      detail = null;

  final CloudDriveAutoSubtitleStatus status;
  final CloudDriveAutoSubtitleSkipReason reason;
  final String? trackId;
  final String? detail;

  bool get applied => status == CloudDriveAutoSubtitleStatus.applied;

  /// A user choice or a restored local file already owns the subtitle slot.
  bool get preserved => status == CloudDriveAutoSubtitleStatus.preserved;

  /// The playback refresh must stop: something is already on screen.
  bool get shouldStopRefresh => applied || preserved;

  String get label {
    final track = trackId == null ? '' : ' track=$trackId';
    return '${status.name}/${reason.name}$track';
  }

  @override
  String toString() => label;
}

/// The official-subtitle list for one card, right now.
class CloudDriveSubtitleTrackList {
  const CloudDriveSubtitleTrackList({
    this.tracks = const <CloudDriveListedSubtitle>[],
    this.loading = false,
    this.failed = false,
    this.networkFailed = false,
    this.listed = false,
    this.loginRequired = false,
    this.restricted = false,
    this.unsupported = false,
  });

  final List<CloudDriveListedSubtitle> tracks;
  final bool loading;
  final bool failed;
  final bool networkFailed;
  final bool listed;
  final bool loginRequired;
  final bool restricted;
  final bool unsupported;

  String? get emptyMessage {
    if (loading || failed || loginRequired || tracks.isNotEmpty || !listed) {
      return null;
    }
    return '这个视频没有官方字幕';
  }

  String? get failureMessage {
    if (loading || !failed) return null;
    if (restricted) return '当前账号没有权限读取官方字幕，点一下重试';
    if (networkFailed) return '网络不通，官方字幕暂时拿不到，点一下重试';
    return '官方字幕列表暂时拿不到，点一下重试';
  }

  String? get loginMessage {
    if (loading || failed || !loginRequired) return null;
    return '需要重新登录当前网盘账号';
  }
}

/// Reads the official directory and one track body. No selection happens here.
abstract class CloudDriveSubtitleTrackSource {
  int get generation;
  Listenable? get loginChanges;
  Future<CloudDriveOfficialSubtitleDiscovery> fetchOfficial(VideoItem item);
  Future<String> fetchText(VideoItem item, CloudDriveSubtitleTrack track);
}

/// Where a saved official track is attached.
class CloudDriveSubtitleTrackStore {
  const CloudDriveSubtitleTrackStore({
    required this.itemOf,
    required this.cardsSharing,
    required this.allocate,
    required this.noteChanged,
    this.changes,
  });

  factory CloudDriveSubtitleTrackStore.library(
    LibraryService library, {
    VideoItem? Function(String itemId)? playbackItemOf,
  }) {
    return CloudDriveSubtitleTrackStore(
      // Direct cloud playback has no library card. Its official subtitles stay
      // attached to the playback item without importing it into the library.
      itemOf: (id) => library.getVideo(id) ?? playbackItemOf?.call(id),
      cardsSharing: library.cardsOfSameCloudFile,
      allocate: (itemId, fileName) =>
          library.allocateSubtitleFile(itemId, fileName),
      noteChanged: library.noteCardDataChanged,
      changes: library,
    );
  }

  final VideoItem? Function(String itemId) itemOf;
  final List<VideoItem> Function(String itemId) cardsSharing;
  final Future<String> Function(String itemId, String fileName) allocate;
  final Future<void> Function(String itemId) noteChanged;
  final Listenable? changes;
}

class _ListState {
  _ListState(this.generation);

  final int generation;
  bool loading = true;
  bool outdated = false;
  CloudDriveOfficialSubtitleStatus status =
      CloudDriveOfficialSubtitleStatus.failed;
  List<CloudDriveSubtitleTrack> tracks = const <CloudDriveSubtitleTrack>[];
  String? message;
  bool networkFailed = false;
}

/// Official cloud subtitles for the open player, listed like Bilibili tracks.
///
/// The directory request does not download cue text. Automatic playback or a
/// manual tap fetches one track, checks that it parses, then saves it through
/// the existing managed-subtitle folder. The player owns the selection.
class CloudDriveSubtitleTracks extends ChangeNotifier {
  CloudDriveSubtitleTracks({required this.source, required this.store}) {
    store.changes?.addListener(notifyListeners);
    source.loginChanges?.addListener(_loginChanged);
  }

  factory CloudDriveSubtitleTracks.forApp({
    required LibraryService library,
    required CloudDriveRuntime runtime,
  }) {
    final known = _app;
    if (known != null &&
        identical(known.$1, library) &&
        identical(known.$2, runtime)) {
      return known.$3;
    }
    final tracks = CloudDriveSubtitleTracks(
      source: _RuntimeSubtitleSource(runtime),
      store: CloudDriveSubtitleTrackStore.library(
        library,
        playbackItemOf: (id) {
          final current = runtime.launch.playback.currentItem;
          if (current?.id == id) return current;
          return runtime.launch.playlist.playlist
              .where((item) => item.id == id)
              .firstOrNull;
        },
      ),
    );
    _app = (library, runtime, tracks);
    return tracks;
  }

  static (LibraryService, CloudDriveRuntime, CloudDriveSubtitleTracks)? _app;

  /// Drops in-memory "already saved" futures so a deleted file is not reattached.
  static void noteStorageFilesDeleted(Iterable<String> paths) {
    final app = _app;
    if (app == null || paths.isEmpty) return;
    app.$3._loading.clear();
    app.$3._listLoads.clear();
    app.$3._failedLoads.clear();
  }

  /// Tests install a fake here. The player uses it instead of the app runtime.
  static CloudDriveSubtitleTracks? overrideForTesting;

  final CloudDriveSubtitleTrackSource source;
  final CloudDriveSubtitleTrackStore store;

  final Map<String, _ListState> _remote = <String, _ListState>{};
  final Map<String, Future<void>> _listLoads = <String, Future<void>>{};
  final Map<String, Future<String?>> _loading = <String, Future<String?>>{};
  final Set<String> _failedLoads = <String>{};
  bool _disposed = false;

  static bool covers(VideoItem? item) {
    return item?.sourceRef?.cloudDrive != null;
  }

  bool needsAsking(String itemId) {
    final item = store.itemOf(itemId);
    if (item == null || !covers(item)) return false;
    return !_remote.containsKey(_fileKey(item));
  }

  Future<void> ensureLoaded(String itemId) {
    final item = store.itemOf(itemId);
    if (item == null || !covers(item)) return Future<void>.value();
    final key = _fileKey(item);
    final running = _listLoads[key];
    if (running != null) return running;
    final known = _remote[key];
    if (known != null &&
        !known.loading &&
        known.generation == source.generation &&
        (known.status == CloudDriveOfficialSubtitleStatus.ready ||
            known.status == CloudDriveOfficialSubtitleStatus.restricted ||
            known.status == CloudDriveOfficialSubtitleStatus.unsupported)) {
      return Future<void>.value();
    }
    final entry = _ListState(source.generation);
    _remote[key] = entry;
    _notify();
    final future = _loadList(item, key, entry);
    _listLoads[key] = future;
    return future.whenComplete(() {
      if (identical(_listLoads[key], future)) _listLoads.remove(key);
    });
  }

  Future<void> reload(String itemId) {
    final item = store.itemOf(itemId);
    if (item == null) return Future<void>.value();
    final key = _fileKey(item);
    if (!(_remote[key]?.loading ?? false)) _remote.remove(key);
    return ensureLoaded(itemId);
  }

  CloudDriveSubtitleTrackList listFor(String itemId) {
    final item = store.itemOf(itemId);
    if (item == null || !covers(item)) {
      return const CloudDriveSubtitleTrackList();
    }
    final saved = _savedRows(item);
    final remote = _remote[_fileKey(item)];
    if (remote == null || remote.loading) {
      return CloudDriveSubtitleTrackList(tracks: saved, loading: true);
    }
    if (remote.status == CloudDriveOfficialSubtitleStatus.unsupported) {
      return CloudDriveSubtitleTrackList(tracks: saved, unsupported: true);
    }
    final login =
        remote.status == CloudDriveOfficialSubtitleStatus.loginRequired;
    final failed =
        remote.status == CloudDriveOfficialSubtitleStatus.failed ||
        remote.status == CloudDriveOfficialSubtitleStatus.restricted;
    if (login || failed) {
      return CloudDriveSubtitleTrackList(
        tracks: saved,
        failed: failed,
        networkFailed: remote.networkFailed,
        listed: remote.status == CloudDriveOfficialSubtitleStatus.ready,
        loginRequired: login,
        restricted:
            remote.status == CloudDriveOfficialSubtitleStatus.restricted,
      );
    }
    return CloudDriveSubtitleTrackList(
      tracks: _merge(item, remote.tracks, saved),
      listed: true,
    );
  }

  bool isLoading(String itemId, CloudDriveListedSubtitle track) =>
      _loading.containsKey(_trackKey(itemId, track.id));

  bool hasFailed(String itemId, CloudDriveListedSubtitle track) =>
      _failedLoads.contains(_trackKey(itemId, track.id));

  /// A saved official track for [itemId], read from the library only.
  ///
  /// This deliberately touches no network: a re-entry with a valid local file
  /// must not wait for, or depend on, the official directory.
  CloudDriveListedSubtitle? savedPreferred(String itemId) {
    final item = store.itemOf(itemId);
    if (item == null || !covers(item)) return null;
    final saved = _savedRows(item);
    if (saved.isEmpty) return null;
    return preferredCloudDriveAutoSubtitle(saved);
  }

  /// Downloads [track] when it is not already a file. Concurrent taps share
  /// one request. A saved file is returned without another download.
  ///
  /// [reuseSaved] is false only when the caller already parsed the local file
  /// and found it unusable. Re-fetching that one track must overwrite the bad
  /// copy instead of returning it again.
  Future<String?> load(
    String itemId,
    CloudDriveListedSubtitle track, {
    bool reuseSaved = true,
  }) {
    final saved = track.savedPath;
    if (reuseSaved && saved != null && File(saved).existsSync()) {
      return Future<String?>.value(saved);
    }
    final remote = track.remote;
    if (remote == null) return Future<String?>.value(null);
    final key = _trackKey(itemId, track.id);
    final running = _loading[key];
    if (running != null) return running;
    _failedLoads.remove(key);
    final loading = _loadTrack(itemId, remote, reuseSaved: reuseSaved);
    _loading[key] = loading;
    _notify();
    return loading
        .then((path) {
          if (path == null) _failedLoads.add(key);
          return path;
        })
        .whenComplete(() {
          _loading.remove(key);
          _notify();
        });
  }

  Future<void> _loadList(VideoItem item, String key, _ListState entry) async {
    try {
      final result = await source.fetchOfficial(item);
      final current = store.itemOf(item.id);
      final sameFile =
          current?.sourceRef?.cloudDrive?.fileId ==
          item.sourceRef?.cloudDrive?.fileId;
      if (entry.outdated ||
          entry.generation != source.generation ||
          !sameFile) {
        entry.outdated = true;
        return;
      }
      entry
        ..status = result.status
        ..tracks = result.tracks
        ..message = result.message
        ..networkFailed = false;
      developer.log(
        'Cloud official subtitles listed status=${result.status.name} '
        'tracks=${result.tracks.length}',
        name: 'cloud_drive.subtitles',
      );
    } catch (error) {
      entry
        ..status = CloudDriveOfficialSubtitleStatus.failed
        ..tracks = const <CloudDriveSubtitleTrack>[]
        ..networkFailed = _network(error)
        ..message = error is CloudDriveFailure ? error.message : null;
      developer.log(
        'Cloud official subtitle list failed',
        name: 'cloud_drive.subtitles',
        error: error.runtimeType,
      );
    } finally {
      entry.loading = false;
      if (entry.outdated && identical(_remote[key], entry)) {
        _remote.remove(key);
      }
      _notify();
    }
  }

  Future<String?> _loadTrack(
    String itemId,
    CloudDriveSubtitleTrack track, {
    bool reuseSaved = true,
  }) async {
    final started = store.itemOf(itemId);
    final sourceRef = started?.sourceRef?.cloudDrive;
    if (started == null || sourceRef == null) return null;
    final generation = source.generation;
    final assetId = cloudOfficialAssetId(sourceRef, track.id);
    // A saved copy is the user's file. Reuse it before asking the network,
    // otherwise re-entering a card downloads the same body again.
    if (reuseSaved) {
      final existing = _asset(started, assetId);
      if (existing != null && File(existing.path).existsSync()) {
        return existing.path;
      }
    }
    try {
      final text = await _readText(started, track);
      if (source.generation != generation) return null;
      final current = store.itemOf(itemId);
      if (current?.sourceRef?.cloudDrive?.fileId != sourceRef.fileId) {
        return null;
      }
      final cues = SubtitleParser.parse(text);
      if (cues.isEmpty) return null;
      if (reuseSaved) {
        final existing = _asset(current!, assetId);
        if (existing != null && File(existing.path).existsSync()) {
          return existing.path;
        }
      }
      final extension = track.format.isEmpty ? 'srt' : track.format;
      final path = await store.allocate(
        itemId,
        TaskSubtitleStorageService.readableSubtitleFileName(
          label: track.label,
          extension: '.$extension',
          uniqueId: assetId,
        ),
      );
      final committed = await _commitSubtitleFile(
        path,
        text,
        overwrite: !reuseSaved,
      );
      if (!committed) return null;
      final after = store.itemOf(itemId);
      if (source.generation != generation ||
          after?.sourceRef?.cloudDrive?.fileId != sourceRef.fileId) {
        await _deleteQuietly(path);
        return null;
      }
      await _attach(itemId, track, path, assetId);
      developer.log(
        'Cloud official subtitle saved',
        name: 'cloud_drive.subtitles',
      );
      return path;
    } on CloudDriveFailure catch (error) {
      developer.log(
        'Cloud official subtitle track failed kind=${error.kind.name}',
        name: 'cloud_drive.subtitles',
      );
      return null;
    } catch (error) {
      developer.log(
        'Cloud official subtitle track failed',
        name: 'cloud_drive.subtitles',
        error: error.runtimeType,
      );
      return null;
    }
  }

  /// One directory refresh when the signed address is stale. A login failure
  /// is not retried, and a second failure is returned as-is.
  Future<String> _readText(
    VideoItem item,
    CloudDriveSubtitleTrack track,
  ) async {
    try {
      return await source.fetchText(item, track);
    } on CloudDriveFailure catch (error) {
      if (error.kind == CloudDriveFailureKind.notLoggedIn) rethrow;
      if (error.kind != CloudDriveFailureKind.unavailable &&
          error.kind != CloudDriveFailureKind.network) {
        rethrow;
      }
    }
    final listed = await source.fetchOfficial(item);
    if (listed.status == CloudDriveOfficialSubtitleStatus.loginRequired) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '需要重新登录后才能读取字幕',
      );
    }
    CloudDriveSubtitleTrack? match;
    for (final candidate in listed.tracks) {
      if (candidate.id == track.id) {
        match = candidate;
        break;
      }
    }
    if (match == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '刷新后没有找到同一条字幕',
      );
    }
    return source.fetchText(item, match);
  }

  Future<bool> _commitSubtitleFile(
    String path,
    String text, {
    bool overwrite = false,
  }) async {
    final partial = File('$path.partial');
    try {
      await partial.parent.create(recursive: true);
      await partial.writeAsString(text, flush: true);
      final target = File(path);
      // An existing file is the user's copy, including edits. Never replace it,
      // unless the caller already proved the local copy unusable.
      if (!overwrite && await target.exists()) {
        await _deleteQuietly(partial.path);
        return true;
      }
      await partial.rename(path);
      await File('$path.stamp').writeAsString(
        sha256.convert(utf8.encode(text)).toString(),
        flush: true,
      );
      return true;
    } catch (error) {
      await _deleteQuietly(partial.path);
      developer.log(
        'Cloud official subtitle was not saved',
        name: 'cloud_drive.subtitles',
        error: error.runtimeType,
      );
      return false;
    }
  }

  Future<void> _attach(
    String itemId,
    CloudDriveSubtitleTrack track,
    String path,
    String assetId,
  ) async {
    final cards = store.cardsSharing(itemId);
    final single = store.itemOf(itemId);
    final targets = cards.isNotEmpty ? cards : <VideoItem>[?single];
    for (final card in targets) {
      _attachOne(card, track, path, assetId);
      await store.noteChanged(card.id);
    }
  }

  void _attachOne(
    VideoItem item,
    CloudDriveSubtitleTrack track,
    String path,
    String assetId,
  ) {
    final normalized = p.normalize(path);
    final subtitles = <String, String>{...?item.additionalSubtitles};
    final listed = subtitles.values.any(
      (existing) => p.equals(p.normalize(existing), normalized),
    );
    if (!listed) {
      var key = track.label;
      if (subtitles.containsKey(key)) {
        key = p.basename(path);
        var serial = 2;
        while (subtitles.containsKey(key)) {
          key =
              '${p.basenameWithoutExtension(path)} ($serial)${p.extension(path)}';
          serial++;
        }
      }
      subtitles[key] = normalized;
    }
    item
      ..additionalSubtitles = subtitles
      ..usesManagedAssociatedSubtitles = true;
    final assets = item.managedSubtitleAssets;
    final known = assets.any(
      (asset) =>
          asset.assetId == assetId ||
          p.equals(p.normalize(asset.path), normalized),
    );
    if (known) return;
    item.managedSubtitleAssets = <ManagedSubtitleAsset>[
      ...assets,
      ManagedSubtitleAsset(
        assetId: assetId,
        path: normalized,
        kind: ManagedSubtitleAssetKind.downloaded,
        displayName: track.label,
        language: track.language,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        machineGenerated: track.isAi,
      ),
    ];
  }

  List<CloudDriveListedSubtitle> _savedRows(VideoItem item) {
    final sourceRef = item.sourceRef?.cloudDrive;
    if (sourceRef == null) return const <CloudDriveListedSubtitle>[];
    final prefix = 'cloud-official-${cloudOfficialScope(sourceRef)}-';
    final rows = <CloudDriveListedSubtitle>[];
    for (final asset in item.managedSubtitleAssets) {
      if (!asset.assetId.startsWith(prefix)) continue;
      if (!File(asset.path).existsSync()) continue;
      rows.add(
        CloudDriveListedSubtitle(
          id: asset.assetId.substring(prefix.length),
          label: asset.displayName,
          language: asset.language,
          isAi: asset.machineGenerated,
          savedPath: asset.path,
        ),
      );
    }
    return rows;
  }

  List<CloudDriveListedSubtitle> _merge(
    VideoItem item,
    List<CloudDriveSubtitleTrack> remote,
    List<CloudDriveListedSubtitle> saved,
  ) {
    final sourceRef = item.sourceRef?.cloudDrive;
    final byId = <String, CloudDriveListedSubtitle>{
      for (final row in saved) row.id: row,
    };
    final rows = <CloudDriveListedSubtitle>[];
    final seen = <String>{};
    for (final track in remote) {
      if (!seen.add(track.id)) continue;
      final existing = byId.remove(track.id);
      rows.add(
        CloudDriveListedSubtitle(
          id: track.id,
          label: track.label,
          language: track.language,
          isAi: track.isAi || (existing?.isAi ?? false),
          savedPath: existing?.savedPath,
          remote: track,
        ),
      );
    }
    rows.addAll(byId.values);
    if (sourceRef == null) return rows;
    return rows;
  }

  ManagedSubtitleAsset? _asset(VideoItem item, String assetId) {
    for (final asset in item.managedSubtitleAssets) {
      if (asset.assetId == assetId) return asset;
    }
    return null;
  }

  void _loginChanged() {
    for (final entry in _remote.values) {
      entry.outdated = true;
    }
    _remote.removeWhere((_, entry) => !entry.loading);
    _notify();
  }

  static bool _network(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        (error is CloudDriveFailure &&
            error.kind == CloudDriveFailureKind.network);
  }

  static String _fileKey(VideoItem item) {
    final source = item.sourceRef?.cloudDrive;
    if (source == null) return item.id;
    return '${source.providerId}|${source.remoteAccountId}|${source.driveId}|'
        '${source.fileId}|${source.revision ?? ''}|';
  }

  /// One in-flight download per account/file/revision/track. Two cards of the
  /// same cloud file share the request; the UI state stays per card.
  String _trackKey(String itemId, String trackId) {
    final item = store.itemOf(itemId);
    final scope = item == null ? itemId : _fileKey(item);
    return '$scope|$trackId';
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.changes?.removeListener(notifyListeners);
    source.loginChanges?.removeListener(_loginChanged);
    super.dispose();
  }
}

class _RuntimeSubtitleSource implements CloudDriveSubtitleTrackSource {
  _RuntimeSubtitleSource(this.runtime);

  final CloudDriveRuntime runtime;

  @override
  int get generation => runtime.accounts.sessionGeneration;

  @override
  Listenable? get loginChanges => runtime.accounts.sessionChanges;

  @override
  Future<CloudDriveOfficialSubtitleDiscovery> fetchOfficial(
    VideoItem item,
  ) async {
    final prepared = await _prepared(item);
    if (prepared == null) {
      return const CloudDriveOfficialSubtitleDiscovery(
        status: CloudDriveOfficialSubtitleStatus.loginRequired,
        message: '需要重新登录当前网盘账号',
      );
    }
    return prepared.provider.discoverOfficialSubtitles(prepared.request);
  }

  @override
  Future<String> fetchText(
    VideoItem item,
    CloudDriveSubtitleTrack track,
  ) async {
    final prepared = await _prepared(item);
    if (prepared == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '需要重新登录后才能读取字幕',
      );
    }
    return prepared.provider.readSubtitleText(
      CloudDriveSubtitleReadRequest(
        credential: prepared.request.credential,
        accountLocalId: prepared.account.localId,
        remoteAccountId: prepared.account.remoteAccountId,
        driveId: prepared.request.driveId,
        track: track,
      ),
    );
  }

  Future<
    ({
      CloudDriveProvider provider,
      CloudDriveAccount account,
      CloudDrivePlaybackRequest request,
    })?
  >
  _prepared(VideoItem item) async {
    final cloud = item.sourceRef?.cloudDrive;
    if (cloud == null) {
      return null;
    }
    final account = runtime.accounts.findRemote(
      cloud.providerId,
      cloud.remoteAccountId,
    );
    if (account == null ||
        account.authState == CloudDriveAuthState.needsLogin) {
      return null;
    }
    final credential = await runtime.accounts.credentialFor(account);
    if (credential == null) return null;
    final provider = runtime.providers[cloud.providerId];
    if (provider == null) return null;
    return (
      provider: provider,
      account: account,
      request: CloudDrivePlaybackRequest(
        credential: credential,
        accountLocalId: account.localId,
        remoteAccountId: account.remoteAccountId,
        driveId: cloud.driveId,
        fileId: cloud.fileId,
        pathHint: cloud.pathHint,
        name: item.title,
        durationMs: item.durationMs > 0 ? item.durationMs : null,
        revision: cloud.revision,
        playbackSessionId: item.id,
      ),
    );
  }
}
