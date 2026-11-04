import '../community_media_input.dart';
import 'package:video_player_app/services/network/network_http.dart';
import '../network/resumable_media_download.dart';
import '../network/network_recovery.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/bilibili_models.dart';
import '../../models/bilibili_audio_quality.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import '../settings_service.dart';
import 'bilibili_api_service.dart';
import 'bilibili_audio_selection.dart';
import 'bilibili_startup.dart';
import 'bilibili_video_shot_service.dart';
import '../../features/media_cache/media_cache_reads.dart';
import 'media_connection_pool.dart';
import 'package:dio/dio.dart' show CancelToken;

export '../../models/bilibili_audio_quality.dart';

class BilibiliStreamQuality {
  static const int localMaterializedId = -1;

  final int id;
  final String label;
  final bool cached;

  const BilibiliStreamQuality({
    required this.id,
    required this.label,
    this.cached = false,
  });

  bool get isLocalMaterialized => id == localMaterializedId || cached;

  @override
  bool operator ==(Object other) =>
      other is BilibiliStreamQuality &&
      other.id == id &&
      other.label == label &&
      other.cached == cached;

  @override
  int get hashCode => Object.hash(id, label, cached);
}

class BilibiliPreparedPlayback {
  /// A video-only fragmented MP4 exposed through the local media gateway.
  final Uri videoUri;

  /// The matching audio-only fragmented MP4. Native playback attaches this as
  /// an external audio track, so playback does not depend on DASH/MPD support
  /// in the platform backend.
  final Uri audioUri;

  /// Kept as a standards-based fallback and for diagnostics. Native clients
  /// should prefer [videoUri] + [audioUri].
  final Uri manifestUri;
  final List<BilibiliStreamQuality> qualities;
  final BilibiliStreamQuality selectedQuality;
  final List<BilibiliAudioQuality> audioQualities;
  final BilibiliAudioQuality? selectedAudioQuality;

  /// Stable display ratio derived from the video's best available DASH track.
  /// It deliberately does not follow the selected quality: some lower-quality
  /// representations have padded/rounded coded dimensions, which must not make
  /// the Flutter viewport shrink when quality changes.
  final double? displayAspectRatio;

  const BilibiliPreparedPlayback({
    required this.videoUri,
    required this.audioUri,
    required this.manifestUri,
    required this.qualities,
    required this.selectedQuality,
    required this.displayAspectRatio,
    this.audioQualities = const [],
    this.selectedAudioQuality,
  });
}

class BilibiliStreamCacheReport {
  final int bytes;
  final int fileCount;

  const BilibiliStreamCacheReport({this.bytes = 0, this.fileCount = 0});
}

/// Per-card cache breakdown distinguishing materialized assets (tracks and
/// playable files downloaded by compose/OCR/transcription) from the playback
/// gateway cache files written while streaming online.
class BilibiliItemCacheBreakdown {
  final int totalBytes;
  final int gatewayBytes;
  final int gatewayFileCount;
  final int materializedBytes;
  final int materializedFileCount;

  const BilibiliItemCacheBreakdown({
    this.totalBytes = 0,
    this.gatewayBytes = 0,
    this.gatewayFileCount = 0,
    this.materializedBytes = 0,
    this.materializedFileCount = 0,
  });

  bool get isEmpty => totalBytes <= 0;
}

bool _isMaterializedCacheFileName(String name) {
  return name == 'materialization.json' ||
      name == 'materialization.json.backup' ||
      name == 'materialization.json.partial' ||
      name == 'materialization.pending_delete' ||
      name.startsWith('materialized_video_') ||
      name.startsWith('materialized_playback_') ||
      name.startsWith('transcription_audio');
}

/// Rolling throughput estimate for one gateway item while bytes stream through
/// the loopback proxy.
class _GatewayTransferMeter {
  final List<({DateTime at, int bytes})> _samples =
      <({DateTime at, int bytes})>[];

  void record(int bytes) {
    if (bytes <= 0) return;
    final now = DateTime.now();
    _samples.add((at: now, bytes: bytes));
    final cutoff = now.subtract(const Duration(seconds: 1));
    while (_samples.isNotEmpty && _samples.first.at.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  double get bytesPerSecond {
    return measureGatewayBytesPerSecond(_samples, now: DateTime.now());
  }

  void reset() {
    _samples.clear();
  }
}

/// Bytes in the last [window], divided by the full window — not by the time
/// since the first burst. A 2 MB chunk in 50 ms is 2 MB/s over 1 s, not 40.
@visibleForTesting
double measureGatewayBytesPerSecond(
  Iterable<({DateTime at, int bytes})> samples, {
  required DateTime now,
  Duration window = const Duration(seconds: 1),
}) {
  final windowMs = window.inMilliseconds;
  if (windowMs <= 0) return 0;
  final cutoff = now.subtract(window);
  var totalBytes = 0;
  for (final sample in samples) {
    if (sample.at.isBefore(cutoff)) continue;
    totalBytes += sample.bytes;
  }
  if (totalBytes <= 0) return 0;
  return totalBytes * 1000.0 / windowMs;
}

/// Persisted byte-interval map for one DASH track. libmpv does not replay the
/// same Range boundaries after a process restart, so slices must merge.
class _TrackCacheIndex {
  int? totalBytes;
  List<({int start, int endExclusive})> ranges;
  bool dirty = false;

  _TrackCacheIndex({
    this.totalBytes,
    List<({int start, int endExclusive})>? ranges,
  }) : ranges = _mergeCachedRanges(ranges ?? const []);

  bool get isComplete {
    final total = totalBytes;
    return total != null && total > 0 && covers(0, total);
  }

  bool covers(int start, int endExclusive) {
    if (endExclusive <= start) return false;
    for (final range in ranges) {
      if (range.start <= start && endExclusive <= range.endExclusive) {
        return true;
      }
    }
    return false;
  }

  int? contiguousEndExclusive(int start) {
    for (final range in ranges) {
      if (range.start <= start && start < range.endExclusive) {
        return range.endExclusive;
      }
    }
    return null;
  }

  void addRange(int start, int endExclusive, {int? totalBytes}) {
    if (endExclusive <= start) return;
    ranges = _mergeCachedRanges([
      ...ranges,
      (start: start, endExclusive: endExclusive),
    ]);
    if (totalBytes != null && totalBytes > 0) this.totalBytes = totalBytes;
    dirty = true;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'totalBytes': totalBytes,
    'ranges': [
      for (final range in ranges) [range.start, range.endExclusive],
    ],
  };

  factory _TrackCacheIndex.fromJson(Map<String, dynamic> json) {
    final rawRanges = json['ranges'];
    final ranges = <({int start, int endExclusive})>[];
    if (rawRanges is List) {
      for (final entry in rawRanges) {
        if (entry is! List || entry.length < 2) continue;
        final start = (entry[0] as num?)?.toInt();
        final endExclusive = (entry[1] as num?)?.toInt();
        if (start == null || endExclusive == null || endExclusive <= start) {
          continue;
        }
        ranges.add((start: start, endExclusive: endExclusive));
      }
    }
    return _TrackCacheIndex(
      totalBytes: (json['totalBytes'] as num?)?.toInt(),
      ranges: ranges,
    );
  }
}

List<({int start, int endExclusive})> _mergeCachedRanges(
  List<({int start, int endExclusive})> input,
) {
  if (input.isEmpty) return const [];
  final sorted = [...input]..sort((a, b) => a.start.compareTo(b.start));
  final merged = <({int start, int endExclusive})>[sorted.first];
  for (var i = 1; i < sorted.length; i++) {
    final current = sorted[i];
    final last = merged.last;
    if (current.start <= last.endExclusive) {
      merged[merged.length - 1] = (
        start: last.start,
        endExclusive: current.endExclusive > last.endExclusive
            ? current.endExclusive
            : last.endExclusive,
      );
    } else {
      merged.add(current);
    }
  }
  return merged;
}

class BilibiliAudioDownloadProgress {
  final int receivedBytes;
  final int? totalBytes;
  final double bytesPerSecond;

  const BilibiliAudioDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
  });

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

/// Resolves stable Bilibili identities at playback time and exposes a loopback
/// media gateway. CDN URLs remain inside short-lived in-memory sessions and
/// are never persisted into the media library.
class BilibiliStreamingService extends ChangeNotifier {
  static const _preferredQualityPreferenceKey =
      'bilibili_stream_preferred_quality';
  static const preferredAudioPreferenceKey = 'bilibili_stream_preferred_audio';
  static const _refreshAge = Duration(minutes: 90);

  /// Refresh before the CDN signature actually expires. Players keep requesting
  /// byte ranges long after the manifest was served, and Bilibili closes those
  /// sockets once `deadline` has passed.
  static const _deadlineRefreshMargin = Duration(minutes: 2);
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const _referer = 'https://www.bilibili.com/';

  final BilibiliApiService apiService;
  final bool Function(Uri uri)? _mediaUriValidator;
  final Duration _upstreamOpenTimeout;
  final Duration _upstreamIdleTimeout;
  final Duration _cdnHedgeDelay;
  final DateTime Function() _clock;
  static final Object _startupZone = Object();
  final _tracedStartups = Expando<bool>();
  final _sessions = <String, _GatewaySession>{};
  final _preferredQualityByItem = <String, int>{};
  final _preferredAudioByItem = <String, int>{};
  final _localAudioOverrides = <String>{};
  int? _preferredAudioQualityId;
  bool _preferredAudioLoaded = false;
  Future<void>? _preferredAudioLoad;
  Future<void> _audioPreferenceWrites = Future<void>.value();
  final _activeCacheFiles = <String>{};
  final _cachePolicyByItem = <String, bool>{};
  final _videoShotLoads = <String, Future<void>>{};
  final _videoShotUnavailableByItem = <String>{};
  final Map<String, Future<String>> _transcriptionAudioDownloads = {};
  final Map<String, HttpClient> _transcriptionAudioClients = {};
  final Set<String> _cancelledTranscriptionAudioItems = {};
  final _uuid = const Uuid();
  final _playUrlCache =
      <String, ({BilibiliStreamInfo info, DateTime obtainedAt})>{};
  final _playUrlLoads = <String, Future<BilibiliStreamInfo>>{};
  final _playUrlLoadOwners = <String, BilibiliStartupContext?>{};

  /// Next/previous episodes pre-built so a notification skip does not wait on
  /// playurl. Spotify/YouTube/Bilibili all warm the adjacent item this way.
  final _warmPlaybacks = <String, BilibiliPreparedPlayback>{};
  final _warmPrepareFutures = <String, Future<BilibiliPreparedPlayback>>{};

  /// Shared CDN client so episode switches reuse TLS instead of handshaking
  /// bilivideo.com again. Per-session clients made every skip look like a
  /// cold download even on gigabit LAN.
  HttpClient? _sharedMediaClient;
  StreamSubscription<NetworkSettingsChange>? _networkSubscription;
  int _networkGeneration = 0;
  final _successfulCdnOrigins = <bool, String>{};
  BilibiliStartupContext? _priorityStartup;
  final Set<void Function()> _warmCdnAborts = {};
  final _gatewayTransferMeters = <String, _GatewayTransferMeter>{};
  DateTime? _lastGatewayTransferNotifyAt;
  final _cacheIoLocks = <String, Future<void>>{};
  HttpServer? _server;
  Future<HttpServer>? _serverFuture;
  Directory? _cacheDirectory;
  int _cachePolicyRevision = 0;
  int? _preferredQualityId;
  bool _preferredQualityLoaded = false;
  Future<void>? _preferredQualityLoadFuture;

  /// Called after a cache file is closed so LibraryService can invalidate its
  /// filesystem-size cache while the recycle-bin screen is open.
  void Function(String itemId)? onCacheChanged;

  /// Persists lazily backfilled sprite metadata for pre-existing online cards.
  Future<void> Function(VideoItem item)? onVideoShotChanged;

  final List<Duration> networkRetryDelays;

  BilibiliStreamingService(
    this.apiService, {
    @visibleForTesting bool Function(Uri uri)? mediaUriValidator,
    NetworkSettingsService? networkSettings,
    @visibleForTesting Directory? cacheDirectory,
    @visibleForTesting this.networkRetryDelays = NetworkRecovery.retryDelays,
    @visibleForTesting
    Duration upstreamOpenTimeout = const Duration(seconds: 4),
    @visibleForTesting
    Duration upstreamIdleTimeout = const Duration(seconds: 8),
    @visibleForTesting
    Duration cdnHedgeDelay = const Duration(milliseconds: 750),
    @visibleForTesting DateTime Function()? clock,
  }) : _mediaUriValidator = mediaUriValidator,
       _upstreamOpenTimeout = upstreamOpenTimeout,
       _upstreamIdleTimeout = upstreamIdleTimeout,
       _cdnHedgeDelay = cdnHedgeDelay,
       _clock = clock ?? DateTime.now,
       _cacheDirectory = cacheDirectory {
    _networkSubscription = (networkSettings ?? NetworkSettingsService.instance)
        .changes
        .listen((change) {
          if (!change.deviceChanged &&
              change.scopes.contains(NetworkScope.bilibili)) {
            invalidateNetwork();
          }
        });
  }

  /// Keep verified disk ranges, but never reuse an address signed for an old
  /// network exit. Existing gateway URLs remain local and can recover in place.
  void invalidateNetwork() {
    _networkGeneration++;
    _successfulCdnOrigins.clear();
    _playUrlCache.clear();
    _playUrlLoads.clear();
    _playUrlLoadOwners.clear();
    final warm = _warmPlaybacks.values.toList(growable: false);
    _warmPlaybacks.clear();
    _warmPrepareFutures.clear();
    final oldClient = _sharedMediaClient;
    _sharedMediaClient = null;
    oldClient?.close(force: false);
    for (final session in _sessions.values) {
      session.mediaClient = _sharedMediaClientForSessions();
      session.urlsMarkedStale = true;
      session.refreshFuture = null;
      session.preferredCdnUrls.clear();
      session.failedCdnUrls.clear();
    }
    for (final playback in warm) {
      unawaited(releasePlayback(playback));
    }
  }

  @visibleForTesting
  int get activePlaybackSessionCount => _sessions.length;

  /// Cards whose cache is in use right now (a playback session or a running
  /// transcription audio download); size trimming must leave them alone.
  Set<String> get cacheItemIdsInUse => <String>{
    for (final session in _sessions.values) session.itemId,
    ..._transcriptionAudioDownloads.keys,
  };

  /// The cache root this service writes to.
  Future<Directory> resolveCacheDirectory() => _resolveCacheDirectory();

  /// Folder name a card's cache lives under inside the cache root.
  static String cacheEntryName(String itemId) => _safeNameStatic(itemId);

  /// Bytes copied from a CDN body to a player. Tests use this to see that a
  /// disconnected player stops the read, not merely that the kernel buffer
  /// stopped accepting writes.
  @visibleForTesting
  int relayedBodyBytes = 0;

  /// Rolling download speed for the active gateway session of [itemId].
  double gatewayBytesPerSecondFor(String? itemId) {
    if (itemId == null || itemId.isEmpty) return 0;
    return _gatewayTransferMeters[itemId]?.bytesPerSecond ?? 0;
  }

  void _recordGatewayTransfer(String itemId, int bytes) {
    if (bytes <= 0 || itemId.isEmpty) return;
    relayedBodyBytes += bytes;
    final meter = _gatewayTransferMeters.putIfAbsent(
      itemId,
      () => _GatewayTransferMeter(),
    );
    meter.record(bytes);
    final now = DateTime.now();
    final lastNotify = _lastGatewayTransferNotifyAt;
    if (lastNotify != null &&
        now.difference(lastNotify) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastGatewayTransferNotifyAt = now;
    notifyListeners();
  }

  void _resetGatewayTransferMeter(String itemId) {
    _gatewayTransferMeters.remove(itemId)?.reset();
  }

  /// Warms playurl + a gateway session + the CDN TCP/TLS session for [item]
  /// without opening a native player. Notification/Mini skip then only has to
  /// point libmpv at an already-live loopback URL.
  Future<void> prefetch(VideoItem item) async {
    requireCommunityOfficialBilibili();
    if (_priorityStartup?.isPending == true) return;
    final source = item.sourceRef;
    if (source?.kind != MediaSourceKind.bilibiliStream ||
        source?.cid == null ||
        (source?.bvid?.isEmpty ?? true)) {
      return;
    }
    try {
      await _warmPrepare(item);
    } catch (error) {
      debugPrint('Bilibili neighbor prefetch failed: $error');
    }
  }

  /// Drop warm sessions that are no longer the next/previous queue neighbors.
  void retainWarmPlaybacks(Set<String> itemIds) {
    final staleIds = _warmPlaybacks.keys
        .where((id) => !itemIds.contains(id))
        .toList(growable: false);
    for (final id in staleIds) {
      final playback = _warmPlaybacks.remove(id);
      if (playback != null) unawaited(releasePlayback(playback));
    }
  }

  Future<BilibiliPreparedPlayback> _warmPrepare(VideoItem item) {
    final existing = _warmPlaybacks[item.id];
    if (existing != null) {
      return Future<BilibiliPreparedPlayback>.value(existing);
    }
    final inFlight = _warmPrepareFutures[item.id];
    if (inFlight != null) return inFlight;
    final generation = _networkGeneration;
    late final Future<BilibiliPreparedPlayback> future;
    future = () async {
      try {
        final playback = await prepare(item, allowWarmReuse: false);
        if (generation != _networkGeneration) {
          await releasePlayback(playback);
          throw StateError('网络设置已更新，请重新加载视频');
        }
        _warmPlaybacks[item.id] = playback;
        unawaited(_warmCdnConnections(playback));
        return playback;
      } finally {
        if (identical(_warmPrepareFutures[item.id], future)) {
          _warmPrepareFutures.remove(item.id);
        }
      }
    }();
    _warmPrepareFutures[item.id] = future;
    return future;
  }

  Future<BilibiliPreparedPlayback> prepareForStartup(
    VideoItem item, {
    BilibiliStartupContext? startup,
    int? qualityId,
  }) async {
    requireCommunityOfficialBilibili();
    if (startup == null) return prepare(item, qualityId: qualityId);
    startup.qualityId = qualityId ?? startup.qualityId;
    _priorityStartup = startup;
    // Stop speculative byte reads before the real player asks for its ranges.
    // Keep a matching warm session's signed addresses and healthy cache.
    for (final abort in _warmCdnAborts.toList()) {
      abort();
    }
    retainWarmPlaybacks({item.id});
    _traceStartup(startup);
    startup.mark(BilibiliStartupPhase.connecting);
    try {
      return await startup.run(
        runZoned(
          () => prepare(item, qualityId: startup.qualityId),
          zoneValues: {_startupZone: startup},
        ),
      );
    } catch (error) {
      startup.fail(error);
      rethrow;
    }
  }

  void _traceStartup(BilibiliStartupContext startup) {
    if (!startup.isPending || _tracedStartups[startup] == true) return;
    _tracedStartups[startup] = true;
    final subscription = NetworkHttp.instance.bridge.connectionTimings.listen((
      event,
    ) {
      if (event.scope == NetworkScope.bilibili && startup.isPending) {
        startup.record(
          'network #${event.connectionId} ${event.host} '
          '${event.phase} ${event.elapsedMilliseconds}ms',
        );
      }
    });
    void finish() {
      if (startup.isPending) return;
      unawaited(subscription.cancel());
      startup.removeListener(finish);
    }

    startup.addListener(finish);
  }

  Future<BilibiliPreparedPlayback> prepare(
    VideoItem item, {
    int? qualityId,
    int? audioQualityId,
    bool allowWarmReuse = true,
    bool forceRefresh = false,
  }) async {
    requireCommunityOfficialBilibili();
    final startup = Zone.current[_startupZone] as BilibiliStartupContext?;
    startup?.check();
    final networkGeneration = _networkGeneration;
    await _ensurePreferredAudioLoaded();
    startup?.check();
    final requestedAudio =
        audioQualityId ??
        (_localAudioOverrides.contains(item.id)
            ? null
            : _preferredAudioQualityId) ??
        _preferredAudioByItem[item.id];
    if (allowWarmReuse && !forceRefresh) {
      final warm = _takeWarmPlayback(
        item.id,
        qualityId: qualityId,
        audioQualityId: requestedAudio,
      );
      if (warm != null) {
        _bindCachePolicy(warm, item.id);
        _bindStartup(warm, startup);
        return warm;
      }
      final inFlight = _warmPrepareFutures[item.id];
      if (inFlight != null) {
        final warmed = await (startup?.run(inFlight) ?? inFlight);
        if ((qualityId == null || warmed.selectedQuality.id == qualityId) &&
            _matchesAudioPreference(warmed, requestedAudio)) {
          _warmPlaybacks.remove(item.id);
          _bindCachePolicy(warmed, item.id);
          _bindStartup(warmed, startup);
          return warmed;
        }
      }
    }
    final source = item.sourceRef;
    if (source == null ||
        source.kind != MediaSourceKind.bilibiliStream ||
        source.cid == null ||
        (source.bvid?.isEmpty ?? true)) {
      throw const FormatException('媒体库条目缺少 Bilibili 播放身份信息');
    }
    final preferredFuture = _ensurePreferredQualityLoaded();
    // Seek-preview sprites are optional metadata. Do not put their download
    // on the critical media-notification -> playback path.
    unawaited(_ensureVideoShot(item));
    final serverFuture = _ensureServer();
    final playUrlFuture = _playUrlFor(
      source.bvid!,
      source.cid!,
      forceRefresh: forceRefresh,
      startup: startup,
      courseEpisodeId: source.bilibiliCourseEpisodeId,
    );
    await preferredFuture;
    final requested =
        qualityId ?? _preferredQualityId ?? _preferredQualityByItem[item.id];
    final streamInfo = await (startup?.run(playUrlFuture) ?? playUrlFuture);
    startup?.check();
    final session = await _createSession(
      itemId: item.id,
      source: source,
      fallbackDurationMs: item.durationMs,
      requestedQualityId: requested,
      requestedAudioQualityId: requestedAudio,
      streamInfo: streamInfo,
    );
    final server = await serverFuture;
    if (networkGeneration != _networkGeneration ||
        startup?.isCancelled == true ||
        startup?.hasFailed == true) {
      session.close();
      throw StateError('网络方式已更新，请重新获取播放地址');
    }
    // Direct service callers (including low-level gateway clients) retain the
    // historical cache-enabled behavior until a playback context explicitly
    // supplies a policy. MediaPlaybackService always supplies that policy
    // before calling prepare(), so the app still obeys its visibility rules.
    session.setCachingEnabled(_cachePolicyByItem[item.id] ?? true);
    _sessions[session.token] = session;
    session.startup = startup;
    session.unbindStartupAbort = startup?.bindAbort(session.close);
    _preferredQualityByItem[item.id] = session.selectedVideo.id;
    if (audioQualityId == null && requestedAudio != null) {
      _preferredAudioByItem[item.id] = session.selectedAudio.id;
    }
    _pruneSessions();
    final qualities = _qualitiesFor(session.streamInfo);
    final selected = qualities.firstWhere(
      (quality) => quality.id == session.selectedVideo.id,
      orElse: () => qualities.first,
    );
    if (startup != null) startup.qualityId = selected.id;
    return BilibiliPreparedPlayback(
      videoUri: Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/session/${session.token}/video',
      ),
      audioUri: Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/session/${session.token}/audio',
      ),
      manifestUri: Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/session/${session.token}/manifest.mpd',
      ),
      qualities: qualities,
      selectedQuality: selected,
      audioQualities: _audioQualitiesFor(session.streamInfo),
      selectedAudioQuality: BilibiliAudioQuality.fromStream(
        session.selectedAudio,
      ),
      displayAspectRatio: _displayAspectRatioFor(session.streamInfo),
    );
  }

  /// Resolves the currently available online qualities without creating a
  /// gateway playback session. This keeps a materialized local file as the
  /// active source while still allowing the quality menu to offer online
  /// alternatives.
  Future<List<BilibiliStreamQuality>> listQualities(VideoItem item) async {
    requireCommunityOfficialBilibili();
    final source = item.sourceRef;
    if (source?.bvid?.isNotEmpty != true || source?.cid == null) {
      throw const FormatException('媒体库条目缺少 Bilibili 播放身份信息');
    }
    final info = await _playUrlFor(
      source!.bvid!,
      source.cid!,
      courseEpisodeId: source.bilibiliCourseEpisodeId,
    );
    return List<BilibiliStreamQuality>.unmodifiable(_qualitiesFor(info));
  }

  String _playUrlCacheKey(String bvid, int cid) => '$bvid:$cid';

  BilibiliPreparedPlayback? _takeWarmPlayback(
    String itemId, {
    int? qualityId,
    int? audioQualityId,
  }) {
    final warm = _warmPlaybacks[itemId];
    if (warm == null) return null;
    final session = _sessionForPlayback(warm);
    if (session == null || session.isClosed) {
      _warmPlaybacks.remove(itemId);
      return null;
    }
    if (qualityId != null && warm.selectedQuality.id != qualityId) {
      return null;
    }
    if (!_matchesAudioPreference(warm, audioQualityId)) {
      return null;
    }
    _warmPlaybacks.remove(itemId);
    return warm;
  }

  bool _matchesAudioPreference(BilibiliPreparedPlayback playback, int? id) {
    if (id == null || playback.selectedAudioQuality?.id == id) return true;
    final session = _sessionForPlayback(playback);
    return session != null &&
        _selectCompatibleAudio(session.streamInfo, requestedId: id).id ==
            playback.selectedAudioQuality?.id;
  }

  void _bindCachePolicy(BilibiliPreparedPlayback playback, String itemId) {
    final session = _sessionForPlayback(playback);
    session?.setCachingEnabled(_cachePolicyByItem[itemId] ?? true);
  }

  void _bindStartup(
    BilibiliPreparedPlayback playback,
    BilibiliStartupContext? startup,
  ) {
    startup?.check();
    final session = _sessionForPlayback(playback);
    if (session == null || startup == null) return;
    startup.qualityId = playback.selectedQuality.id;
    startup.geometry.reportVideo(playback.displayAspectRatio);
    session.unbindStartupAbort?.call();
    session.startup = startup;
    session.unbindStartupAbort = startup.bindAbort(session.close);
  }

  _GatewaySession? _sessionForPlayback(BilibiliPreparedPlayback playback) {
    final segments = playback.videoUri.pathSegments;
    if (segments.length < 3 || segments.first != 'session') return null;
    return _sessions[segments[1]];
  }

  /// Starts the CDN handshake for a playback that is about to be opened.
  ///
  /// Safe to call more than once. The body is only the init+index range and
  /// is discarded, so it never writes the track cache. A short cached prefix
  /// would make the player's open-ended Range return a truncated 206 and end
  /// the audio or video track.
  void primeCdnConnections(BilibiliPreparedPlayback playback) {
    unawaited(_warmCdnConnections(playback));
  }

  /// Pull the DASH init+sidx bytes so the next skip's first Range is a
  /// connection reuse, not a TLS handshake to bilivideo.com.
  Future<void> _warmCdnConnections(BilibiliPreparedPlayback playback) async {
    if (_priorityStartup?.isPending == true) return;
    final session = _sessionForPlayback(playback);
    if (session == null || session.isClosed || session.cdnWarmStarted) return;
    session.cdnWarmStarted = true;
    await _refreshSessionIfUrlsStale(session);
    if (session.isClosed) return;
    await Future.wait<void>([
      _warmCdnTrack(session, session.selectedAudio),
      if (session.videoEnabled)
        _warmCdnTrack(session, session.selectedVideo, video: true),
    ]);
  }

  Future<void> _warmCdnTrack(
    _GatewaySession session,
    StreamItem track, {
    bool video = false,
  }) async {
    final uri = () {
      for (final candidate in <String>[track.baseUrl, ...track.backupUrls]) {
        final parsed = Uri.tryParse(candidate);
        if (parsed != null && _isAllowedMediaUri(parsed)) return parsed;
      }
      return null;
    }();
    if (uri == null) return;
    HttpClientRequest? request;
    void Function()? unbindAbort;
    var cancelled = false;
    void cancelWarm() {
      cancelled = true;
      request?.abort();
    }

    _warmCdnAborts.add(cancelWarm);
    try {
      if (session.isClosed) return;
      request = await session.mediaClient.getUrl(uri);
      if (cancelled || session.isClosed) {
        request.abort();
        return;
      }
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.refererHeader, _referer);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=0-${_warmRangeEnd(track)}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final done = Completer<void>();
      late final StreamSubscription<List<int>> subscription;
      var finished = false;
      void abort() {
        if (cancelled) return;
        cancelled = true;
        // A finished body already returned its socket to the keep-alive pool.
        // Cancelling again would destroy that pooled connection.
        if (!finished) unawaited(subscription.cancel());
        if (!done.isCompleted) done.complete();
      }

      subscription = response.listen(
        (_) {},
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          finished = true;
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      unbindAbort = session.bindTransferAbort(abort, video: video);
      try {
        await done.future.timeout(const Duration(seconds: 4));
      } catch (_) {
        // Leave the keep-alive connection alone when the small range
        // finished. Only tear it down if it is still running.
        abort();
      }
    } catch (_) {
      request?.abort();
    } finally {
      _warmCdnAborts.remove(cancelWarm);
      unbindAbort?.call();
    }
  }

  int _warmRangeEnd(StreamItem track) {
    final match = RegExp(r'-(\d+)\s*$').firstMatch(track.indexRange);
    if (match != null) {
      final end = int.tryParse(match.group(1)!);
      if (end != null && end > 0) return end;
    }
    return 4095;
  }

  /// Reusing a fresh playurl avoids a blocking API round-trip when re-opening
  /// the same card. A cached document is stale once its CDN `deadline` is
  /// inside [_deadlineRefreshMargin], even if it is younger than [_refreshAge].
  Future<BilibiliStreamInfo> _playUrlFor(
    String bvid,
    int cid, {
    bool forceRefresh = false,
    BilibiliStartupContext? startup,
    int? courseEpisodeId,
  }) async {
    final key = _playUrlCacheKey(bvid, cid);
    final networkGeneration = _networkGeneration;
    if (!forceRefresh) {
      final cached = _playUrlCache[key];
      if (cached != null &&
          DateTime.now().difference(cached.obtainedAt) < _refreshAge &&
          !_playUrlExpiresSoon(cached.info)) {
        startup?.record('cached play address');
        return cached.info;
      }
    }
    final pending = _playUrlLoads[key];
    final owner = _playUrlLoadOwners[key];
    if (pending != null &&
        owner?.isCancelled != true &&
        owner?.hasFailed != true &&
        (owner == null || owner.remaining > Duration.zero)) {
      startup?.record('joining play address');
      return startup?.run(pending) ?? pending;
    }
    late final Future<BilibiliStreamInfo> loading;
    loading =
        () async {
          final info = startup == null
              ? await apiService.fetchMediaPlayUrl(
                  bvid,
                  cid,
                  courseEpisodeId: courseEpisodeId,
                )
              : await apiService.fetchStartupPlayUrl(
                  bvid,
                  cid,
                  startup,
                  courseEpisodeId: courseEpisodeId,
                );
          if (networkGeneration != _networkGeneration) {
            throw StateError('播放地址属于此前的网络方式');
          }
          startup?.check();
          _playUrlCache[key] = (info: info, obtainedAt: DateTime.now());
          return info;
        }().whenComplete(() {
          if (identical(_playUrlLoads[key], loading)) {
            _playUrlLoads.remove(key);
            _playUrlLoadOwners.remove(key);
          }
        });
    _playUrlLoads[key] = loading;
    _playUrlLoadOwners[key] = startup;
    return loading;
  }

  /// Installs a playurl another feature just fetched (AI subtitles, OCR,
  /// compose) into any live playback session for [itemId]. In-flight range
  /// requests keep the socket they already opened; the next range uses this
  /// document instead of a signature that is about to expire.
  void noteFreshPlayUrl(String itemId, BilibiliStreamInfo info) {
    if (itemId.isEmpty) return;
    for (final session in _sessions.values.toList(growable: false)) {
      if (session.isClosed || session.itemId != itemId) continue;
      final bvid = session.source.bvid;
      final cid = session.source.cid;
      if (bvid != null && bvid.isNotEmpty && cid != null) {
        _playUrlCache[_playUrlCacheKey(bvid, cid)] = (
          info: info,
          obtainedAt: DateTime.now(),
        );
      }
      try {
        _replaceSessionTracks(session, info);
      } catch (error) {
        debugPrint('Bilibili playback ignored a refreshed playurl: $error');
      }
    }
  }

  void _replaceSessionTracks(_GatewaySession session, BilibiliStreamInfo info) {
    final video = _selectVideo(info, session.selectedVideo.id);
    final audio = _selectCompatibleAudio(
      info,
      requestedId: session.selectedAudio.id,
      requireExact: true,
    );
    session
      ..obtainedAt = DateTime.now()
      ..streamInfo = info
      ..selectedVideo = video
      ..selectedAudio = audio
      ..durationMs = info.durationMs > 0 ? info.durationMs : session.durationMs
      ..urlsMarkedStale = false
      ..skipStaleRefreshUntil = null;
  }

  /// Metadata already resolved for this exact BV/part; never starts a request.
  double? cachedDisplayAspectRatioFor(VideoItem item) {
    final source = item.sourceRef;
    if (source?.bvid == null || source?.cid == null) return null;
    final cached = _playUrlCache[_playUrlCacheKey(source!.bvid!, source.cid!)];
    return cached == null ? null : _displayAspectRatioFor(cached.info);
  }

  double? _displayAspectRatioFor(BilibiliStreamInfo info) {
    final tracks = info.videoStreams.where(_isUsableTrack).toList()
      ..sort(StreamItem.compareVideoQuality);
    for (final track in tracks) {
      if (track.width <= 0 || track.height <= 0) continue;
      final ratio = track.width / track.height;
      if (ratio.isFinite && ratio > 0) return ratio;
    }
    return null;
  }

  void rememberQuality(String itemId, int qualityId) {
    _preferredQualityByItem[itemId] = qualityId;
    _preferredQualityId = qualityId;
    _preferredQualityLoaded = true;
    unawaited(_persistPreferredQuality(qualityId));
  }

  /// Commit only after the replacement player has successfully warmed up.
  /// A failed selection must not change reconnects or later quality switches.
  Future<void> rememberAudioQuality(String itemId, int audioQualityId) {
    _preferredAudioByItem[itemId] = audioQualityId;
    _localAudioOverrides.remove(itemId);
    _preferredAudioQualityId = audioQualityId;
    _preferredAudioLoaded = true;
    final write = _audioPreferenceWrites
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt(preferredAudioPreferenceKey, audioQualityId);
        })
        .catchError((Object error) {
          debugPrint('Failed to save Bilibili audio preference: $error');
        });
    _audioPreferenceWrites = write;
    return write;
  }

  Future<void> _ensurePreferredAudioLoaded() {
    if (_preferredAudioLoaded) return Future<void>.value();
    return _preferredAudioLoad ??= () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getInt(preferredAudioPreferenceKey);
        if (!_preferredAudioLoaded && saved != null && saved > 0) {
          _preferredAudioQualityId = saved;
        }
      } catch (error) {
        debugPrint('Failed to load Bilibili audio preference: $error');
      } finally {
        _preferredAudioLoaded = true;
      }
    }();
  }

  bool hasPreferredAudioQuality(String itemId) =>
      _preferredAudioByItem.containsKey(itemId);

  void clearAudioQualityPreference(String itemId) {
    _preferredAudioByItem.remove(itemId);
    _localAudioOverrides.add(itemId);
  }

  Future<List<BilibiliAudioQuality>> listAudioQualities(VideoItem item) async {
    requireCommunityOfficialBilibili();
    final source = item.sourceRef;
    if (source?.bvid?.isNotEmpty != true || source?.cid == null) {
      return const [];
    }
    final info = await _playUrlFor(
      source!.bvid!,
      source.cid!,
      courseEpisodeId: source.bilibiliCourseEpisodeId,
    );
    return _audioQualitiesFor(info);
  }

  Future<void> _ensurePreferredQualityLoaded() {
    if (_preferredQualityLoaded) return Future.value();
    return _preferredQualityLoadFuture ??= () async {
      try {
        final preferences = await SharedPreferences.getInstance();
        _preferredQualityId ??= preferences.getInt(
          _preferredQualityPreferenceKey,
        );
      } catch (error) {
        debugPrint('Failed to load Bilibili stream quality preference: $error');
      } finally {
        _preferredQualityLoaded = true;
      }
    }();
  }

  Future<void> _persistPreferredQuality(int qualityId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_preferredQualityPreferenceKey, qualityId);
    } catch (error) {
      debugPrint('Failed to save Bilibili stream quality preference: $error');
    }
  }

  Future<void> ensureVideoShot(VideoItem item) => _ensureVideoShot(item);

  Future<void> _ensureVideoShot(VideoItem item) {
    if (item.bilibiliVideoShot?.hasLocalSprites == true ||
        _videoShotUnavailableByItem.contains(item.id)) {
      return Future.value();
    }
    return _videoShotLoads[item.id] ??=
        () async {
          final source = item.sourceRef;
          if (source?.bvid?.isNotEmpty != true || source?.cid == null) {
            _videoShotUnavailableByItem.add(item.id);
            return;
          }
          final videoShot = await BilibiliVideoShotService.instance
              .downloadForCard(
                apiService: apiService,
                videoId: item.id,
                bvid: source!.bvid!,
                cid: source.cid!,
              );
          if (videoShot == null) {
            _videoShotUnavailableByItem.add(item.id);
            return;
          }
          item.bilibiliVideoShot = videoShot;
          try {
            await onVideoShotChanged?.call(item);
          } catch (error) {
            debugPrint(
              'Failed to persist Bilibili video-shot metadata: $error',
            );
          }
        }().whenComplete(() {
          _videoShotLoads.remove(item.id);
        });
  }

  Future<BilibiliStreamCacheReport> inspectCache({bool strict = false}) async {
    final dir = await _resolveCacheDirectory();
    return _inspectCacheDirectory(dir, strict: strict);
  }

  /// Downloads and atomically caches the complete audio track used by ASR.
  /// The file lives under this card's cache directory, so recycle-bin size
  /// accounting and permanent deletion include it automatically.
  Future<String> downloadAudioForTranscription(
    VideoItem item, {
    void Function(BilibiliAudioDownloadProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) {
    requireCommunityOfficialBilibili();
    final source = item.sourceRef;
    if (source == null ||
        source.kind != MediaSourceKind.bilibiliStream ||
        source.bvid?.isNotEmpty != true ||
        source.cid == null) {
      throw const FormatException('媒体库条目缺少有效的 Bilibili 音频身份信息');
    }

    final existing = _transcriptionAudioDownloads[item.id];
    if (existing != null) return existing;
    _cancelledTranscriptionAudioItems.remove(item.id);
    final operation = _downloadAudioForTranscription(
      item,
      onProgress: onProgress,
      cancelSignal: cancelSignal,
    );
    _transcriptionAudioDownloads[item.id] = operation;
    operation.whenComplete(() {
      if (identical(_transcriptionAudioDownloads[item.id], operation)) {
        _transcriptionAudioDownloads.remove(item.id);
      }
    }).ignore();
    return operation;
  }

  Future<String> _downloadAudioForTranscription(
    VideoItem item, {
    void Function(BilibiliAudioDownloadProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    final root = await _resolveCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeName(item.id)));
    if (!await itemDir.exists()) await itemDir.create(recursive: true);
    final finalFile = File(p.join(itemDir.path, 'transcription_audio.m4a'));
    final partialFile = File('${finalFile.path}.part');
    await _deleteFileBestEffort(partialFile);
    if (await finalFile.exists()) {
      final length = await finalFile.length();
      if (length > 0) {
        onProgress?.call(
          BilibiliAudioDownloadProgress(
            receivedBytes: length,
            totalBytes: length,
            bytesPerSecond: 0,
          ),
        );
        return finalFile.path;
      }
      await _deleteFileBestEffort(finalFile);
    }

    var cancelled = false;
    cancelSignal?.then((_) {
      cancelled = true;
      _transcriptionAudioClients[item.id]?.close(force: true);
    });
    void checkCancelled() {
      if (cancelled || _cancelledTranscriptionAudioItems.contains(item.id)) {
        throw StateError('Bilibili 音频下载已取消');
      }
    }

    try {
      final source = item.sourceRef!;
      final info = await apiService.fetchMediaPlayUrl(
        source.bvid!,
        source.cid!,
        courseEpisodeId: source.bilibiliCourseEpisodeId,
      );
      noteFreshPlayUrl(item.id, info);
      final compatibleAudio =
          info.audioStreams.where(_hasAllowedMediaUri).toList()..sort((a, b) {
            int codecRank(StreamItem track) {
              final codec = track.codecs.toLowerCase();
              if (codec.startsWith('mp4a')) return 0;
              if (codec.contains('opus')) return 1;
              if (codec.contains('ec-3') || codec.contains('eac3')) return 2;
              if (codec.contains('flac')) return 3;
              return 4;
            }

            final codec = codecRank(a).compareTo(codecRank(b));
            return codec != 0 ? codec : b.bandwidth.compareTo(a.bandwidth);
          });
      if (compatibleAudio.isEmpty) {
        throw StateError('Bilibili 未返回可下载的音轨');
      }
      final audio = compatibleAudio.first;
      final candidates = <String>[
        audio.baseUrl,
        ...audio.backupUrls,
      ].map(Uri.tryParse).whereType<Uri>().where(_isAllowedMediaUri);

      var lastReceived = 0;
      var sampleBytes = 0;
      var sampleStarted = DateTime.now();
      await ResumableMediaDownload(
        createClient: _createMediaClient,
        retryDelays: networkRetryDelays,
      ).download(
        urls: candidates.toList(),
        partial: partialFile,
        headers: {
          HttpHeaders.userAgentHeader: _userAgent,
          HttpHeaders.refererHeader: _referer,
        },
        checkCancelled: checkCancelled,
        onClient: (client) => _transcriptionAudioClients[item.id] = client,
        onClientClosed: (client) {
          if (identical(_transcriptionAudioClients[item.id], client)) {
            _transcriptionAudioClients.remove(item.id);
          }
        },
        onBytes: (received, expected) {
          sampleBytes += received >= lastReceived
              ? received - lastReceived
              : received;
          lastReceived = received;
          final now = DateTime.now();
          final elapsed = now.difference(sampleStarted);
          if (elapsed < const Duration(milliseconds: 250) &&
              received != expected) {
            return;
          }
          final seconds = elapsed.inMicroseconds / 1000000;
          onProgress?.call(
            BilibiliAudioDownloadProgress(
              receivedBytes: received,
              totalBytes: expected,
              bytesPerSecond: seconds > 0 ? sampleBytes / seconds : 0,
            ),
          );
          sampleBytes = 0;
          sampleStarted = now;
        },
      );
      await partialFile.rename(finalFile.path);
      final received = await finalFile.length();
      onProgress?.call(
        BilibiliAudioDownloadProgress(
          receivedBytes: received,
          totalBytes: received,
          bytesPerSecond: 0,
        ),
      );
      _notifyCacheChanged(item.id);
      return finalFile.path;
    } catch (error) {
      checkCancelled();
      throw StateError('Bilibili 音频下载失败: $error');
    } finally {
      _transcriptionAudioClients.remove(item.id)?.close(force: true);
      _cancelledTranscriptionAudioItems.remove(item.id);
      await _deleteFileBestEffort(partialFile);
    }
  }

  Future<void> _deleteFileBestEffort(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _cancelTranscriptionAudioDownloads([String? itemId]) async {
    final entries = _transcriptionAudioDownloads.entries
        .where((entry) => itemId == null || entry.key == itemId)
        .toList(growable: false);
    for (final entry in entries) {
      _cancelledTranscriptionAudioItems.add(entry.key);
      _transcriptionAudioClients[entry.key]?.close(force: true);
    }
    for (final entry in entries) {
      try {
        await entry.value;
      } catch (_) {}
    }
  }

  /// True when this card already has readable track bytes that the loopback
  /// gateway can serve after a process restart without hitting the CDN.
  Future<bool> hasReusableTrackCache(String itemId) async {
    final dir = await _resolveCacheDirectory();
    final itemDir = Directory(p.join(dir.path, _safeName(itemId)));
    if (!await itemDir.exists()) return false;
    await for (final entity in itemDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.track') || name.endsWith('.seg')) return true;
    }
    return false;
  }

  /// Returns only the cache owned by one library card.
  ///
  /// The item id is the ownership boundary. The Bilibili URL, title and
  /// source identity may be shared by multiple cards, but their cache folders
  /// must never be shared.
  Future<BilibiliStreamCacheReport> inspectItemCache(
    String itemId, {
    bool strict = false,
  }) async {
    final dir = await _resolveCacheDirectory();
    return inspectCacheForItem(itemId, cacheDirectory: dir, strict: strict);
  }

  /// Filesystem-only variant used by LibraryService when the service instance
  /// is not available (for example during startup or in a unit test).
  static Future<BilibiliStreamCacheReport> inspectCacheForItem(
    String itemId, {
    Directory? cacheDirectory,
    bool strict = false,
  }) async {
    if (itemId.trim().isEmpty) return const BilibiliStreamCacheReport();
    final root = cacheDirectory ?? await _resolveDefaultCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeNameStatic(itemId)));
    return _inspectCacheDirectoryStatic(itemDir, strict: strict);
  }

  /// Filesystem-only breakdown of one card's cache into materialized assets
  /// and playback gateway cache files.
  static Future<BilibiliItemCacheBreakdown> inspectItemCacheBreakdown(
    String itemId, {
    Directory? cacheDirectory,
    bool strict = false,
  }) async {
    if (itemId.trim().isEmpty) return const BilibiliItemCacheBreakdown();
    final root = cacheDirectory ?? await _resolveDefaultCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeNameStatic(itemId)));
    if (!await itemDir.exists()) return const BilibiliItemCacheBreakdown();
    var gatewayBytes = 0;
    var gatewayFiles = 0;
    var materializedBytes = 0;
    var materializedFiles = 0;
    await for (final entity in itemDir.list(followLinks: false)) {
      if (entity is! File) continue;
      int size;
      try {
        size = await entity.length();
      } catch (_) {
        if (strict &&
            await FileSystemEntity.type(entity.path, followLinks: false) !=
                FileSystemEntityType.notFound) {
          rethrow;
        }
        continue;
      }
      if (_isMaterializedCacheFileName(p.basename(entity.path))) {
        materializedBytes += size;
        materializedFiles++;
      } else {
        gatewayBytes += size;
        gatewayFiles++;
      }
    }
    return BilibiliItemCacheBreakdown(
      totalBytes: gatewayBytes + materializedBytes,
      gatewayBytes: gatewayBytes,
      gatewayFileCount: gatewayFiles,
      materializedBytes: materializedBytes,
      materializedFileCount: materializedFiles,
    );
  }

  /// Permanently removes every cache file owned by [itemId].
  ///
  /// This deliberately deletes the whole card directory rather than trying to
  /// infer ownership from CDN URLs or ranges. That keeps repeated imports of
  /// the same Bilibili link independent.
  static Future<void> clearCacheForItemOnDisk(
    String itemId, {
    Directory? cacheDirectory,
  }) async {
    if (itemId.trim().isEmpty) return;
    final root = cacheDirectory ?? await _resolveDefaultCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeNameStatic(itemId)));
    if (!await itemDir.exists()) return;
    try {
      await itemDir.delete(recursive: true);
    } catch (_) {
      // A platform decoder may briefly keep a file handle open. Make a best
      // effort to remove individual files as well; the next size inspection
      // will report only files that genuinely survived the deletion attempt.
      try {
        await for (final entity in itemDir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      } catch (_) {}
      try {
        if (await itemDir.exists()) await itemDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<BilibiliStreamCacheReport> _inspectCacheDirectory(
    Directory dir, {
    bool strict = false,
  }) async {
    return _inspectCacheDirectoryStatic(dir, strict: strict);
  }

  static Future<BilibiliStreamCacheReport> _inspectCacheDirectoryStatic(
    Directory dir, {
    bool strict = false,
  }) async {
    if (!await dir.exists()) return const BilibiliStreamCacheReport();
    var bytes = 0;
    var files = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        bytes += await entity.length();
        files++;
      } catch (_) {
        if (strict &&
            await FileSystemEntity.type(entity.path, followLinks: false) !=
                FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
    return BilibiliStreamCacheReport(bytes: bytes, fileCount: files);
  }

  static Future<Directory> _resolveDefaultCacheDirectory() async {
    final root = await SettingsService().resolveLargeDataRootDir();
    final dir = Directory(p.join(root.path, 'bilibili_stream_cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> clearCache() async {
    await _cancelTranscriptionAudioDownloads();
    // Clearing disk cache must not end the global media session. Disable every
    // current session's cache writers first; the loopback proxy and native
    // player remain usable by the mini player and system media controls.
    await Future.wait<void>([
      for (final session in _sessions.values.toList(growable: false))
        session.disableCaching(),
    ]);
    final dir = await _resolveCacheDirectory();
    if (await dir.exists()) {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File &&
            !_activeCacheFiles.contains(p.normalize(entity.path))) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    onCacheChanged?.call('');
    notifyListeners();
  }

  /// Disables active writers, closes the card's gateway sessions and then
  /// removes every file belonging to that card.
  Future<void> clearCacheForItem(String itemId) async {
    if (itemId.trim().isEmpty) return;
    await _cancelTranscriptionAudioDownloads(itemId);
    _cachePolicyByItem[itemId] = false;
    ++_cachePolicyRevision;
    final sessions = _sessions.values
        .where((session) => session.itemId == itemId)
        .toList(growable: false);
    await Future.wait<void>([
      for (final session in sessions) session.disableCaching(),
    ]);
    await _releaseSessions(sessions);
    final dir = await _resolveCacheDirectory();
    await clearCacheForItemOnDisk(itemId, cacheDirectory: dir);
    _preferredQualityByItem.remove(itemId);
    _notifyCacheChanged(itemId);
  }

  /// Applies the single cache policy for the currently visible playback
  /// context. A page may cache while paused; a mini card/phone notification may
  /// cache only while actively playing.
  void updateCachePolicy({
    required String? itemId,
    required bool isOnlineItem,
    required bool isPlaying,
    required bool playbackPageVisible,
    required bool miniPlaybackCardVisible,
    required bool mediaNotificationVisible,
  }) {
    final allowed =
        itemId != null &&
        isOnlineItem &&
        (playbackPageVisible ||
            ((miniPlaybackCardVisible || mediaNotificationVisible) &&
                isPlaying));
    final revision = ++_cachePolicyRevision;

    for (final id in _cachePolicyByItem.keys.toList(growable: false)) {
      if (id != itemId) _cachePolicyByItem[id] = false;
    }
    if (itemId != null) _cachePolicyByItem[itemId] = allowed;

    for (final session in _sessions.values.toList(growable: false)) {
      if (session.itemId == itemId && allowed) {
        session.setCachingEnabled(true);
      } else {
        unawaited(
          session.disableCaching().whenComplete(() {
            // A newer policy may have enabled this same session while the
            // writer was closing. Re-apply it after the close completes.
            if (revision != _cachePolicyRevision) return;
            if (session.itemId == itemId && allowed) {
              session.setCachingEnabled(true);
            }
          }),
        );
      }
    }
  }

  /// Stops every gateway transfer for [itemId] and invalidates its temporary
  /// CDN sessions. Call this after the native controller has been disposed.
  Future<void> releaseItem(String itemId) async {
    final sessions = _sessions.values
        .where((session) => session.itemId == itemId)
        .toList(growable: false);
    await _releaseSessions(sessions);
  }

  /// Releases only the temporary gateway session represented by [playback].
  ///
  /// Quality hand-off briefly keeps two sessions for the same card alive. In
  /// that window [releaseItem] would also close the newly committed stream, so
  /// the player needs a session-scoped release operation.
  /// Only this playback lease's video reads stop. Audio, retained cache and
  /// independent download sessions keep their own sockets and ownership.
  void setPlaybackVideoEnabled(
    BilibiliPreparedPlayback playback,
    bool enabled,
  ) {
    _sessionForPlayback(playback)?.setVideoEnabled(enabled);
  }

  Future<void> releasePlayback(BilibiliPreparedPlayback playback) async {
    final segments = playback.videoUri.pathSegments;
    if (segments.length < 3 || segments.first != 'session') return;
    final session = _sessions[segments[1]];
    if (session == null) return;
    await _releaseSessions(<_GatewaySession>[session]);
  }

  Future<void> _releaseSessions(List<_GatewaySession> sessions) async {
    if (sessions.isEmpty) return;
    for (final session in sessions) {
      _sessions.remove(session.token);
      _resetGatewayTransferMeter(session.itemId);
      session.close();
    }
    await Future.wait<void>([
      for (final session in sessions)
        session.waitUntilIdle().timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        ),
    ]);
  }

  Future<void> shutdown() async {
    await _networkSubscription?.cancel();
    _networkSubscription = null;
    await _cancelTranscriptionAudioDownloads();
    final server = _server;
    _server = null;
    _serverFuture = null;
    await _releaseSessions(_sessions.values.toList(growable: false));
    _warmPlaybacks.clear();
    _warmPrepareFutures.clear();
    final sharedClient = _sharedMediaClient;
    _sharedMediaClient = null;
    sharedClient?.close(force: true);
    if (server != null) await server.close(force: true);
    await _audioPreferenceWrites;
  }

  Future<HttpServer> _ensureServer() {
    final existing = _server;
    if (existing != null) return Future.value(existing);
    return _serverFuture ??= () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      unawaited(_serve(server));
      return server;
    }();
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handleRequest(request));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length != 3 || segments.first != 'session') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final session = _sessions[segments[1]];
      if (session == null) {
        request.response.statusCode = HttpStatus.gone;
        await request.response.close();
        return;
      }
      switch (segments[2]) {
        case 'manifest.mpd':
          await _serveManifest(request, session);
          return;
        case 'video':
          await _proxyTrack(request, session, video: true);
          return;
        case 'audio':
          await _proxyTrack(request, session, video: false);
          return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (error) {
      debugPrint(
        'Bilibili media gateway request failed '
        '(${request.method} ${request.uri.path}): $error',
      );
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<_GatewaySession> _createSession({
    required String itemId,
    required MediaSourceRef source,
    required int fallbackDurationMs,
    int? requestedQualityId,
    int? requestedAudioQualityId,
    bool requireExactAudio = false,
    HttpClient? mediaClient,
    BilibiliStreamInfo? streamInfo,
    bool forcePlayUrlRefresh = false,
    BilibiliStartupContext? startup,
  }) async {
    final resolvedStreamInfo =
        streamInfo ??
        await _playUrlFor(
          source.bvid!,
          source.cid!,
          forceRefresh: forcePlayUrlRefresh,
          startup: startup,
          courseEpisodeId: source.bilibiliCourseEpisodeId,
        );
    if (resolvedStreamInfo.videoStreams.isEmpty ||
        resolvedStreamInfo.audioStreams.isEmpty) {
      throw StateError('当前账号没有可播放的 Bilibili 音视频轨道');
    }
    final video = _selectVideo(resolvedStreamInfo, requestedQualityId);
    final audio = _selectCompatibleAudio(
      resolvedStreamInfo,
      requestedId: requestedAudioQualityId,
      requireExact: requireExactAudio,
    );
    return _GatewaySession(
      token: _uuid.v4().replaceAll('-', ''),
      itemId: itemId,
      source: source,
      obtainedAt: _clock(),
      streamInfo: resolvedStreamInfo,
      selectedVideo: video,
      selectedAudio: audio,
      mediaClient: mediaClient ?? _sharedMediaClientForSessions(),
      durationMs: resolvedStreamInfo.durationMs > 0
          ? resolvedStreamInfo.durationMs
          : fallbackDurationMs,
    );
  }

  List<BilibiliAudioQuality> _audioQualitiesFor(BilibiliStreamInfo info) {
    return List.unmodifiable(
      bilibiliAudioMenuTracks(
        info.audioStreams.where(_hasAllowedMediaUri),
      ).map(BilibiliAudioQuality.fromStream),
    );
  }

  StreamItem _selectCompatibleAudio(
    BilibiliStreamInfo info, {
    int? requestedId,
    bool requireExact = false,
  }) {
    if (requestedId != null) {
      for (final track in info.audioStreams) {
        if (track.id == requestedId && _hasAllowedMediaUri(track)) return track;
      }
      // Never splice a different codec into an already-open byte stream.
      if (requireExact) throw StateError('所选 Bilibili 音轨已不可用，请重新选择音质');
    }
    // Automatic choices stay automatic: only a committed manual selection is
    // remembered. Without one, prefer the best audio this account can obtain.
    final audio = selectBilibiliAudioTrack(
      info.audioStreams.where(_hasAllowedMediaUri),
      preference: const [30280, 30232, 30216].contains(requestedId)
          ? BilibiliAudioPreference.standard
          : BilibiliAudioPreference.bestAvailable,
    );
    if (audio == null) throw StateError('Bilibili 未返回可用音轨');
    return audio;
  }

  StreamItem _selectVideo(BilibiliStreamInfo info, int? requestedQualityId) {
    final valid = info.videoStreams.where(_isUsableTrack).toList()
      ..sort(StreamItem.compareVideoQuality);
    if (valid.isEmpty) throw StateError('Bilibili 未返回可用视频轨道');
    final ids = valid.map((track) => track.id).toSet().toList()
      ..sort((a, b) {
        final aa = valid.firstWhere((track) => track.id == a).qualitySortScore;
        final bb = valid.firstWhere((track) => track.id == b).qualitySortScore;
        return bb.compareTo(aa);
      });
    var chosenId = ids.first;
    if (requestedQualityId != null) {
      final exact = ids.contains(requestedQualityId);
      if (exact) {
        chosenId = requestedQualityId;
      } else {
        final requestedScore = StreamItem(
          id: requestedQualityId,
          baseUrl: '',
          bandwidth: 0,
          codecs: '',
          codecid: 0,
        ).qualitySortScore;
        chosenId = ids.firstWhere(
          (id) =>
              valid.firstWhere((track) => track.id == id).qualitySortScore <=
              requestedScore,
          orElse: () => ids.last,
        );
      }
    }
    final sameQuality = valid.where((track) => track.id == chosenId).toList();
    // AVC is the safe baseline. HEVC and AV1 are only fallbacks until explicit
    // runtime decoder capability probing is available.
    sameQuality.sort((a, b) {
      int rank(StreamItem item) => switch (item.codecid) {
        7 => 0,
        12 => 1,
        13 => 2,
        _ => 3,
      };
      final codec = rank(a).compareTo(rank(b));
      return codec != 0 ? codec : b.bandwidth.compareTo(a.bandwidth);
    });
    return sameQuality.first;
  }

  bool _isUsableTrack(StreamItem track) {
    return _hasAllowedMediaUri(track) &&
        track.initializationRange.isNotEmpty &&
        track.indexRange.isNotEmpty;
  }

  bool _hasAllowedMediaUri(StreamItem track) {
    return <String>[
      track.baseUrl,
      ...track.backupUrls,
    ].map(Uri.tryParse).whereType<Uri>().any(_isAllowedMediaUri);
  }

  List<BilibiliStreamQuality> _qualitiesFor(BilibiliStreamInfo info) {
    final tracks = info.videoStreams.where(_isUsableTrack).toList()
      ..sort(StreamItem.compareVideoQuality);
    final seen = <int>{};
    return [
      for (final track in tracks)
        if (seen.add(track.id))
          BilibiliStreamQuality(
            id: track.id,
            label:
                track.qualityName ?? info.qualityMap[track.id] ?? '${track.id}',
          ),
    ];
  }

  Future<void> _serveManifest(
    HttpRequest request,
    _GatewaySession session,
  ) async {
    await _refreshSessionIfUrlsStale(session);
    final origin = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _server!.port,
      path: '/session/${session.token}/',
    );
    final video = session.selectedVideo;
    final audio = session.selectedAudio;
    final seconds = (session.durationMs.clamp(1, 1 << 31) / 1000)
        .toStringAsFixed(3);
    final xml =
        '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT${seconds}S" minBufferTime="PT1.5S">
  <Period start="PT0S">
    <AdaptationSet mimeType="${_xml(video.mimeType ?? 'video/mp4')}" segmentAlignment="true">
      <Representation id="video-${video.id}" bandwidth="${video.bandwidth}" codecs="${_xml(video.codecs)}" width="${video.width}" height="${video.height}"${video.frameRate.isEmpty ? '' : ' frameRate="${_xml(video.frameRate)}"'}>
        <BaseURL>${_xml(origin.resolve('video').toString())}</BaseURL>
        <SegmentBase indexRange="${_xml(video.indexRange)}"><Initialization range="${_xml(video.initializationRange)}"/></SegmentBase>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="${_xml(audio.mimeType ?? 'audio/mp4')}" segmentAlignment="true">
      <Representation id="audio-${audio.id}" bandwidth="${audio.bandwidth}" codecs="${_xml(audio.codecs)}">
        <BaseURL>${_xml(origin.resolve('audio').toString())}</BaseURL>
        <SegmentBase indexRange="${_xml(audio.indexRange)}"><Initialization range="${_xml(audio.initializationRange)}"/></SegmentBase>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';
    request.response.headers.contentType = ContentType(
      'application',
      'dash+xml',
      charset: 'utf-8',
    );
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.write(xml);
    await request.response.close();
  }

  Future<void> _proxyTrack(
    HttpRequest downstream,
    _GatewaySession session, {
    required bool video,
  }) async {
    if (video && !session.videoEnabled) {
      downstream.response.statusCode = HttpStatus.gone;
      await downstream.response.close();
      return;
    }
    session.beginTransfer();
    var cancelled = false;
    final unbind = session.bindTransferAbort(
      () => cancelled = true,
      video: video,
    );
    try {
      await _proxyActiveTrack(
        downstream,
        session,
        video: video,
        transferCancelled: () => cancelled,
      );
    } catch (_) {
      if (!session.isClosed &&
          !cancelled &&
          !(video && !session.videoEnabled)) {
        rethrow;
      }
      try {
        downstream.response.statusCode = HttpStatus.gone;
      } catch (_) {
        // Already-streaming responses have committed their headers.
      }
      try {
        await downstream.response.close();
      } catch (_) {}
    } finally {
      unbind();
      session.endTransfer();
    }
  }

  Future<void> _proxyActiveTrack(
    HttpRequest downstream,
    _GatewaySession session, {
    required bool video,
    required bool Function() transferCancelled,
  }) async {
    final cacheRead = MediaCacheReadHooks.bilibili;
    final originalTrack = video ? session.selectedVideo : session.selectedAudio;
    var cachedPrefix = downstream.method == 'HEAD'
        ? null
        : await cacheRead?.call(
            session.source,
            originalTrack,
            video,
            downstream.headers.value(HttpHeaders.rangeHeader),
          );
    if (cachedPrefix != null &&
        cachedPrefix.completeRequest &&
        await MediaCacheReadHooks.serve(
          downstream,
          Future.value(cachedPrefix),
        )) {
      return;
    }
    if (await _tryServeCachedTrack(downstream, session, video: video)) {
      return;
    }

    if (!transferCancelled()) await _refreshSessionIfUrlsStale(session);
    if (session.isClosed || transferCancelled()) {
      try {
        downstream.response.statusCode = HttpStatus.gone;
        await downstream.response.close();
      } catch (_) {}
      return;
    }

    var track = video ? session.selectedVideo : session.selectedAudio;
    if (track.id != originalTrack.id || track.codecs != originalTrack.codecs) {
      cachedPrefix = null;
    }
    final suffixRange = cachedPrefix == null
        ? null
        : 'bytes=${cachedPrefix.start + cachedPrefix.bytes.length}-${cachedPrefix.requestEnd}';
    HttpClientResponse? upstream;
    _UpstreamTap? tap;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (session.isClosed ||
          transferCancelled() ||
          video && !session.videoEnabled) {
        break;
      }
      await _discardTap(tap);
      tap = null;
      upstream = null;
      Object? failure;
      try {
        final opened = await _openUpstreamWithRecovery(
          downstream,
          track,
          session,
          video: video,
          rangeOverride: suffixRange,
          expectedTotalBytes: cachedPrefix?.total,
          transferCancelled: transferCancelled,
        );
        upstream = opened.response;
        tap = opened.tap;
      } catch (error) {
        failure = error;
        upstream = null;
      }
      if (upstream != null) break;
      if (attempt == 0 &&
          !session.didRefreshAfterFailure &&
          !session.isClosed &&
          !transferCancelled() &&
          (!video || session.videoEnabled)) {
        session.didRefreshAfterFailure = true;
        final current = video ? session.selectedVideo : session.selectedAudio;
        // AI subtitle (or another feature) may already have installed a new
        // playurl. Retry that URL before asking Bilibili for yet another one.
        if (current.baseUrl == track.baseUrl) {
          await _refreshSession(session);
        }
        track = video ? session.selectedVideo : session.selectedAudio;
        continue;
      }
      if (failure != null) throw failure;
      break;
    }
    if (session.isClosed || transferCancelled()) {
      await _discardTap(tap);
      try {
        downstream.response.statusCode = HttpStatus.gone;
        await downstream.response.close();
      } catch (_) {}
      return;
    }
    if (upstream == null) {
      await _discardTap(tap);
      throw StateError('无法连接 Bilibili 媒体源');
    }
    if (upstream.statusCode >= 200 && upstream.statusCode < 400) {
      // Allow a future CDN expiry to perform its own single bounded refresh.
      session.didRefreshAfterFailure = false;
    }
    downstream.response.statusCode = upstream.statusCode;
    for (final name in const [
      HttpHeaders.contentRangeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.contentTypeHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
    ]) {
      final value = upstream.headers.value(name);
      if (value != null) downstream.response.headers.set(name, value);
    }
    if (cachedPrefix != null) {
      downstream.response.statusCode = cachedPrefix.partial
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      downstream.response.contentLength =
          cachedPrefix.requestEnd - cachedPrefix.start + 1;
      if (cachedPrefix.partial) {
        downstream.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${cachedPrefix.start}-${cachedPrefix.requestEnd}/${cachedPrefix.total}',
        );
      } else {
        downstream.response.headers.removeAll(HttpHeaders.contentRangeHeader);
      }
      downstream.response.add(cachedPrefix.bytes);
    }
    if (downstream.method == 'HEAD') {
      await upstream.drain<void>();
      await downstream.response.close();
      return;
    }
    File? cacheFile;
    IOSink? sink;
    var cacheDisabled = false;
    Future<void>? closeCacheFuture;
    final cachedRange = _byteRangeFromContentRange(
      upstream.headers.value(HttpHeaders.contentRangeHeader),
      fallbackStart: upstream.statusCode == HttpStatus.partialContent
          ? _parseByteRange(
              downstream.headers.value(HttpHeaders.rangeHeader),
            )?.start
          : null,
      contentLength: upstream.headers.contentLength,
    );

    Future<void> closeCache({required bool delete}) {
      cacheDisabled = true;
      return closeCacheFuture ??= () async {
        final activeSink = sink;
        sink = null;
        try {
          await activeSink?.flush();
        } catch (_) {}
        try {
          await activeSink?.close();
        } catch (_) {}
        final file = cacheFile;
        if (file == null) return;
        _activeCacheFiles.remove(p.normalize(file.path));
        if (delete) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
          return;
        }
        final range = cachedRange;
        if (range == null) return;
        try {
          await _commitTrackCacheSegment(
            session,
            video: video,
            start: range.start,
            endExclusive: range.endExclusive,
            totalBytes: range.totalBytes,
            tempFile: file,
          );
        } catch (_) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }();
    }

    Future<void> disableCacheWriter() => closeCache(delete: true);

    if (session.isCachingEnabled &&
        (upstream.statusCode == HttpStatus.ok ||
            upstream.statusCode == HttpStatus.partialContent) &&
        cachedRange != null) {
      try {
        cacheFile = await _allocateTrackCacheTempFile(
          session,
          video: video,
          start: cachedRange.start,
          endExclusive: cachedRange.endExclusive,
        );
        sink = cacheFile.openWrite();
        _activeCacheFiles.add(p.normalize(cacheFile.path));
        if (!session.registerCacheWriter(disableCacheWriter)) {
          await disableCacheWriter();
        }
      } catch (_) {}
    }
    final bodyTap = tap;
    if (bodyTap == null) {
      throw StateError('Bilibili 媒体源没有可转发的响应体');
    }
    try {
      if (transferCancelled()) {
        await _discardTap(tap);
        await downstream.response.close();
        return;
      }
      await _relayUpstreamBody(
        downstream: downstream,
        tap: bodyTap,
        session: session,
        track: track,
        video: video,
        range: cachedRange,
        onBytes: (bytes) {
          if (!cacheDisabled) sink?.add(bytes);
          _recordGatewayTransfer(session.itemId, bytes.length);
        },
      );
    } finally {
      session.unregisterCacheWriter(disableCacheWriter);
      await closeCache(delete: false);
      try {
        await downstream.response.close();
      } catch (_) {}
      _notifyCacheChanged(session.itemId);
    }
  }

  /// Forwards CDN bytes only as fast as libmpv reads them, and stops the CDN
  /// socket when the player disconnects or the session is released.
  ///
  /// Interrupted ranges continue on another CDN at the exact next byte. A
  /// cancelled body still drops its incomplete cache segment.
  Future<void> _relayUpstreamBody({
    required HttpRequest downstream,
    required _UpstreamTap tap,
    required _GatewaySession session,
    required StreamItem track,
    required bool video,
    required ({int start, int endExclusive, int? totalBytes})? range,
    required void Function(List<int> bytes) onBytes,
  }) async {
    Object? upstreamError = tap.firstError;
    var cancelled = false;
    var delivered = false;
    var deliveredBytes = 0;
    Timer? idleTimer;
    Future<void>? recovering;
    var activeTap = tap;
    final failedUris = <Uri>{};
    late final StreamController<List<int>> controller;
    var subscription = tap.subscription;

    Future<void> cancelUpstream() {
      if (cancelled) return Future<void>.value();
      cancelled = true;
      idleTimer?.cancel();
      activeTap.permit?.release();
      return subscription?.cancel() ?? Future<void>.value();
    }

    void fail(Object error, StackTrace stack) {
      upstreamError ??= error;
      if (!controller.isClosed) {
        controller.addError(error, stack);
        controller.close();
      }
      unawaited(cancelUpstream());
    }

    late final void Function(_UpstreamTap) bindBody;
    late final void Function() watchForBytes;
    late final void Function(Object, StackTrace) recover;

    void receive(List<int> bytes) {
      if (cancelled || controller.isClosed) return;
      onBytes(bytes);
      delivered = true;
      deliveredBytes += bytes.length;
      controller.add(bytes);
      watchForBytes();
    }

    recover = (Object error, StackTrace stack) {
      if (cancelled || controller.isClosed || recovering != null) return;
      idleTimer?.cancel();
      final uri = activeTap.uri;
      if (uri != null) {
        failedUris.add(uri);
        session.failedCdnUrls[uri] = DateTime.now();
      }
      final slice = range;
      if (slice == null ||
          deliveredBytes >= slice.endExclusive - slice.start ||
          session.isClosed) {
        fail(error, stack);
        return;
      }
      recovering = () async {
        _UpstreamTap? replacement;
        try {
          activeTap.permit?.release();
          await subscription?.cancel();
          if (cancelled || session.isClosed) return;
          final start = slice.start + deliveredBytes;
          final opened = await _openUpstreamWithRecovery(
            downstream,
            track,
            session,
            video: video,
            rangeOverride: 'bytes=$start-${slice.endExclusive - 1}',
            expectedTotalBytes: slice.totalBytes,
            excludedUris: failedUris,
            transferCancelled: () => cancelled,
          );
          replacement = opened.tap;
          if (cancelled || session.isClosed) {
            await _discardTap(replacement);
            return;
          }
          final resumedRange = _byteRangeFromContentRange(
            opened.response.headers.value(HttpHeaders.contentRangeHeader),
          );
          // Never splice a whole-file response or a different byte window
          // into an already published response; doing so corrupts the media.
          if (opened.response.statusCode != HttpStatus.partialContent ||
              replacement == null ||
              resumedRange == null ||
              resumedRange.start != start ||
              resumedRange.endExclusive != slice.endExclusive ||
              opened.response.contentLength != slice.endExclusive - start ||
              (slice.totalBytes != null &&
                  resumedRange.totalBytes != slice.totalBytes)) {
            throw StateError('备用媒体线路返回了不匹配的数据范围');
          }
          activeTap = replacement;
          subscription = replacement.subscription;
          bindBody(replacement);
          final firstChunk = replacement.firstChunk;
          if (firstChunk != null) receive(firstChunk);
          if (!controller.isPaused) subscription?.resume();
          watchForBytes();
        } catch (recoveryError, recoveryStack) {
          await _discardTap(replacement);
          if (!cancelled && !session.isClosed) {
            fail(recoveryError, recoveryStack);
          }
        } finally {
          recovering = null;
          watchForBytes();
        }
      }();
    };

    watchForBytes = () {
      idleTimer?.cancel();
      if (cancelled ||
          controller.isClosed ||
          controller.isPaused ||
          recovering != null) {
        return;
      }
      idleTimer = Timer(_upstreamIdleTimeout, () {
        recover(TimeoutException('媒体线路停止传输数据'), StackTrace.current);
      });
    };

    bindBody = (_UpstreamTap body) {
      body.onData = receive;
      body.onError = recover;
      body.onDone = () {
        idleTimer?.cancel();
        final slice = range;
        if (slice != null &&
            deliveredBytes < slice.endExclusive - slice.start) {
          recover(StateError('媒体线路提前结束传输'), StackTrace.current);
        } else if (!controller.isClosed) {
          controller.close();
        }
      };
    };

    void abort() {
      unawaited(cancelUpstream());
      if (!controller.isClosed) controller.close();
    }

    controller = StreamController<List<int>>(
      onPause: () {
        idleTimer?.cancel();
        subscription?.pause();
      },
      onResume: () {
        subscription?.resume();
        watchForBytes();
      },
      onCancel: cancelUpstream,
    );
    bindBody(tap);
    final unbindAbort = session.bindTransferAbort(abort, video: video);
    try {
      final relayed = downstream.response.addStream(controller.stream);
      final firstChunk = tap.firstChunk;
      if (firstChunk != null) {
        receive(firstChunk);
      }
      if (tap.done) {
        if (!controller.isClosed) controller.close();
      } else {
        subscription?.resume();
        watchForBytes();
      }
      await relayed;
    } catch (error) {
      // Player seek/switch closes the loopback socket. That is not a CDN
      // failure; the replacement Range is a new request. A CDN socket that
      // exhausts the remaining routes cannot finish this response. Refresh
      // the playurl for the player's next Range after that bounded recovery.
      if (upstreamError != null && !session.isClosed) {
        final uri = activeTap.uri;
        if (uri != null) session.failedCdnUrls[uri] = DateTime.now();
        if (delivered) _schedulePlayUrlRefresh(session);
        rethrow;
      }
    } finally {
      unbindAbort();
      await cancelUpstream();
      if (!controller.isClosed) await controller.close();
    }
  }

  Future<({HttpClientResponse response, _UpstreamTap? tap})>
  _openUpstreamWithRecovery(
    HttpRequest downstream,
    StreamItem track,
    _GatewaySession session, {
    required bool video,
    String? rangeOverride,
    int? expectedTotalBytes,
    Set<Uri> excludedUris = const {},
    bool Function()? transferCancelled,
  }) async {
    void check() {
      if (session.startup?.isPending == true) session.startup!.check();
      if (session.isClosed ||
          video && !session.videoEnabled ||
          transferCancelled?.call() == true) {
        throw StateError('媒体播放会话已关闭');
      }
    }

    for (var attempt = 0; ; attempt++) {
      check();
      try {
        return await _openUpstream(
          downstream,
          track,
          session,
          video: video,
          rangeOverride: rangeOverride,
          expectedTotalBytes: expectedTotalBytes,
          excludedUris: excludedUris,
          transferCancelled: transferCancelled,
        );
      } catch (error) {
        check();
        if ((session.startup?.isPending == true && attempt >= 1) ||
            attempt >= networkRetryDelays.length ||
            !NetworkRecovery.isTransient(error)) {
          rethrow;
        }
        final waiting = NetworkRecovery.wait(
          networkRetryDelays[attempt],
          checkCancelled: check,
          cancelSignal: session.startup?.cancelled,
        );
        await (session.startup?.isPending == true
            ? session.startup!.run(waiting)
            : waiting);
      }
    }
  }

  /// Validates the first body bytes before exposing a CDN response to the
  /// player. Connection, headers and first bytes share one bounded deadline.
  Future<({HttpClientResponse response, _UpstreamTap? tap})> _raceStartupCdn(
    HttpRequest downstream,
    StreamItem track,
    _GatewaySession session,
    List<Uri> candidates, {
    required bool video,
    String? rangeOverride,
    int? expectedTotalBytes,
    bool Function()? transferCancelled,
  }) async {
    final result =
        Completer<({HttpClientResponse response, _UpstreamTap? tap})>();
    final active = <_CdnOpenAttempt>{};
    var next = 0;
    Object? lastError;
    Timer? hedge;

    void launch() {
      if (transferCancelled?.call() == true) {
        if (!result.isCompleted) {
          result.completeError(StateError('Media read cancelled'));
        }
        return;
      }
      if (result.isCompleted || next >= candidates.length || session.isClosed) {
        return;
      }
      final uri = candidates[next++];
      final attempt = _CdnOpenAttempt();
      active.add(attempt);
      _openUpstream(
        downstream,
        track,
        session,
        video: video,
        rangeOverride: rangeOverride,
        expectedTotalBytes: expectedTotalBytes,
        candidateUri: uri,
        openAttempt: attempt,
        transferCancelled: transferCancelled,
      ).then(
        (opened) {
          active.remove(attempt);
          if (result.isCompleted || attempt.isCancelled) {
            attempt.cancel();
            if (opened.tap == null) {
              unawaited(opened.response.listen((_) {}).cancel());
            } else {
              unawaited(_discardTap(opened.tap));
            }
            return;
          }
          session.preferredCdnUrls[video] = uri;
          session.startup?.record(
            video ? 'video first bytes' : 'audio first bytes',
          );
          result.complete(opened);
          hedge?.cancel();
          for (final loser in active.toList()) {
            loser.cancel();
          }
        },
        onError: (Object error, StackTrace stack) {
          active.remove(attempt);
          lastError = error;
          if (result.isCompleted) return;
          if (next < candidates.length && !session.isClosed) {
            launch();
          } else if (active.isEmpty) {
            result.completeError(lastError!, stack);
          }
        },
      );
    }

    launch();
    hedge = Timer(_cdnHedgeDelay, () {
      if (active.length < 2) launch();
    });
    try {
      return await session.startup!.run(result.future);
    } finally {
      hedge.cancel();
      for (final attempt in active.toList()) {
        attempt.cancel();
      }
    }
  }

  Future<({HttpClientResponse response, _UpstreamTap? tap})> _openUpstream(
    HttpRequest downstream,
    StreamItem track,
    _GatewaySession session, {
    required bool video,
    String? rangeOverride,
    int? expectedTotalBytes,
    Set<Uri> excludedUris = const {},
    Uri? candidateUri,
    _CdnOpenAttempt? openAttempt,
    bool Function()? transferCancelled,
  }) async {
    final networkGeneration = _networkGeneration;
    final candidates = <String>{track.baseUrl, ...track.backupUrls}
        .map(Uri.tryParse)
        .whereType<Uri>()
        .where(
          (uri) =>
              _isAllowedMediaUri(uri) &&
              !excludedUris.contains(uri) &&
              (candidateUri == null || candidateUri == uri),
        )
        .toList();
    session.failedCdnUrls.removeWhere(
      (_, at) => DateTime.now().difference(at) >= const Duration(seconds: 30),
    );
    final preferred = session.preferredCdnUrls[video];
    final successfulOrigin = _successfulCdnOrigins[video];
    int priority(Uri uri) => session.failedCdnUrls.containsKey(uri)
        ? 2
        : uri == preferred || uri.origin == successfulOrigin
        ? 0
        : 1;
    final ordered = <Uri>[
      for (var rank = 0; rank <= 2; rank++)
        ...candidates.where((uri) => priority(uri) == rank),
    ];
    if (candidateUri == null &&
        session.startup?.isPending == true &&
        ordered.length > 1) {
      return _raceStartupCdn(
        downstream,
        track,
        session,
        ordered,
        video: video,
        rangeOverride: rangeOverride,
        expectedTotalBytes: expectedTotalBytes,
        transferCancelled: transferCancelled,
      );
    }
    Object? lastError;
    for (final uri in ordered) {
      if (session.isClosed || transferCancelled?.call() == true) break;
      HttpClientRequest? request;
      _UpstreamTap? tap;
      BilibiliMediaConnectionPermit? permit;
      final connectionCancel = CancelToken();
      var abandoned = false;
      final cancelled =
          Completer<({HttpClientResponse response, _UpstreamTap? tap})>();
      void abortOpen() {
        abandoned = true;
        connectionCancel.cancel();
        request?.abort();
        if (!cancelled.isCompleted) {
          cancelled.completeError(StateError('媒体播放会话已关闭'));
        }
      }

      final unbindAbort = session.bindTransferAbort(abortOpen, video: video);
      openAttempt?.bind(abortOpen);
      try {
        final opening = () async {
          permit = await BilibiliMediaConnectionPool.shared.acquire(
            cancelToken: connectionCancel,
            playback: true,
          );
          if (abandoned ||
              session.isClosed ||
              transferCancelled?.call() == true) {
            permit?.release();
            throw StateError('媒体播放请求已取消');
          }
          final acquired = downstream.method == 'HEAD'
              ? await session.mediaClient.headUrl(uri)
              : await session.mediaClient.getUrl(uri);
          request = acquired;
          if (abandoned ||
              session.isClosed ||
              transferCancelled?.call() == true) {
            acquired.abort();
            throw StateError('媒体播放请求已取消');
          }
          acquired.headers.set(HttpHeaders.userAgentHeader, _userAgent);
          acquired.headers.set(HttpHeaders.refererHeader, _referer);
          acquired.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          final range =
              rangeOverride ??
              downstream.headers.value(HttpHeaders.rangeHeader);
          if (range != null) {
            acquired.headers.set(HttpHeaders.rangeHeader, range);
          }
          final response = await acquired.close();
          if (abandoned ||
              session.isClosed ||
              transferCancelled?.call() == true) {
            await response.listen((_) {}).cancel();
            throw StateError('媒体播放请求已取消');
          }
          if (session.startup?.isPending == true) {
            session.startup!.record(
              video ? 'video response headers' : 'audio response headers',
            );
          }
          if (response.statusCode >= 500 ||
              const {
                HttpStatus.unauthorized,
                HttpStatus.forbidden,
                HttpStatus.notFound,
                HttpStatus.tooManyRequests,
              }.contains(response.statusCode)) {
            // An error body may itself stall; cancelling frees the socket
            // without waiting for HTML that the player cannot use.
            await response.listen((_) {}).cancel();
            throw HttpException('CDN returned ${response.statusCode}');
          }
          if (rangeOverride != null) {
            final requested = _parseByteRange(rangeOverride)!;
            final actual = _byteRangeFromContentRange(
              response.headers.value(HttpHeaders.contentRangeHeader),
            );
            final end = requested.endInclusive! + 1;
            if (response.statusCode != HttpStatus.partialContent ||
                actual == null ||
                actual.start != requested.start ||
                actual.endExclusive != end ||
                response.contentLength != end - requested.start ||
                (expectedTotalBytes != null &&
                    actual.totalBytes != expectedTotalBytes)) {
              await response.listen((_) {}).cancel();
              throw StateError('备用媒体线路返回了不匹配的数据范围');
            }
          } else {
            final requested = _parseByteRange(range);
            if (requested != null &&
                (response.statusCode == HttpStatus.ok ||
                    response.statusCode == HttpStatus.partialContent)) {
              final actual = _byteRangeFromContentRange(
                response.headers.value(HttpHeaders.contentRangeHeader),
              );
              // A reconnect is also an ordinary player request. Never feed
              // the beginning of a track into a later byte position, even
              // when the CDN labels that response as partial content.
              final wholeFile =
                  response.statusCode == HttpStatus.ok &&
                  response.headers.value(HttpHeaders.contentRangeHeader) ==
                      null;
              final valid = wholeFile
                  ? requested.start == 0
                  : actual != null &&
                        actual.start == requested.start &&
                        (actual.totalBytes == null ||
                            actual.endExclusive <= actual.totalBytes!) &&
                        (requested.endInclusive == null ||
                            actual.endExclusive <=
                                requested.endInclusive! + 1) &&
                        (response.contentLength < 0 ||
                            response.contentLength ==
                                actual.endExclusive - actual.start);
              if (!valid) {
                await response.listen((_) {}).cancel();
                throw StateError('媒体线路返回了不匹配的数据范围');
              }
            }
          }
          if (downstream.method != 'HEAD') {
            final body = _UpstreamTap()
              ..uri = uri
              ..permit = permit;
            tap = body;
            await _tapFirstUpstreamEvent(response, session, body, video: video);
            if (abandoned || body.aborted || session.isClosed) {
              throw StateError('媒体播放请求已取消');
            }
            final successful =
                response.statusCode >= 200 && response.statusCode < 300;
            if (body.firstError != null || (successful && !body.sawData)) {
              throw body.firstError ?? StateError('媒体线路没有返回音视频数据');
            }
          }
          return (response: response, tap: tap);
        }();
        final opened = await Future.any([opening, cancelled.future]).timeout(
          session.startup?.isPending == true
              ? session.startup!.bounded(_upstreamOpenTimeout)
              : _upstreamOpenTimeout,
        );
        if (abandoned) {
          await _discardTap(opened.tap);
          throw const BilibiliStartupCancelled();
        }
        if (opened.response.statusCode >= 200 &&
            opened.response.statusCode < 300) {
          if (candidateUri == null && session.startup?.isPending == true) {
            session.startup!.record(
              video ? 'video first bytes' : 'audio first bytes',
            );
          }
          session.preferredCdnUrls[video] = uri;
          if (networkGeneration == _networkGeneration) {
            _successfulCdnOrigins[video] = uri.origin;
          }
          session.failedCdnUrls.remove(uri);
        }
        if (downstream.method == 'HEAD') permit?.release();
        return opened;
      } catch (error) {
        permit?.release();
        connectionCancel.cancel();
        abandoned = true;
        request?.abort();
        await _discardTap(tap);
        lastError = error;
        if (!session.isClosed &&
            transferCancelled?.call() != true &&
            (!video || session.videoEnabled)) {
          session.failedCdnUrls[uri] = DateTime.now();
        }
      } finally {
        unbindAbort();
        openAttempt?.unbind();
      }
    }
    if (lastError != null && NetworkRecovery.isTransient(lastError)) {
      throw HttpException('媒体网络暂时中断（${lastError.runtimeType}）');
    }
    throw StateError('Bilibili 媒体 CDN 不可用: ${lastError.runtimeType}');
  }

  Future<void> _refreshSession(_GatewaySession session) {
    if (session.startup?.isPending == true) session.startup!.check();
    if (session.isClosed) return Future<void>.value();
    final existing = session.refreshFuture;
    if (existing != null) return existing;
    if (session.startup?.isPending == true &&
        !session.startup!.claimAddressRefresh()) {
      return Future.error(StateError('播放地址刷新后仍不可用，请重试'));
    }
    late final Future<void> refresh;
    final activeStartup = session.startup?.isPending == true
        ? session.startup
        : null;
    final budget =
        activeStartup ??
        BilibiliStartupContext(limit: const Duration(seconds: 8));
    session.refreshBudget = budget;
    refresh = budget
        .run(_refreshSessionUnlocked(session, budget))
        .then<void>(
          (_) {
            if (activeStartup == null) budget.ready();
          },
          onError: (Object error, StackTrace stack) {
            budget.fail(error);
            Error.throwWithStackTrace(error, stack);
          },
        )
        .whenComplete(() {
          if (identical(session.refreshBudget, budget)) {
            session.refreshBudget = null;
          }
          if (identical(session.refreshFuture, refresh)) {
            session.refreshFuture = null;
          }
        });
    session.refreshFuture = refresh;
    return refresh;
  }

  Future<void> _refreshSessionUnlocked(
    _GatewaySession session,
    BilibiliStartupContext budget,
  ) async {
    final networkGeneration = _networkGeneration;
    final startedAt = DateTime.now();
    final refreshed = await _createSession(
      itemId: session.itemId,
      source: session.source,
      fallbackDurationMs: session.durationMs,
      requestedQualityId: session.selectedVideo.id,
      requestedAudioQualityId: session.selectedAudio.id,
      requireExactAudio: true,
      mediaClient: session.mediaClient,
      forcePlayUrlRefresh: true,
      startup: budget,
    );
    if (networkGeneration != _networkGeneration ||
        session.isClosed ||
        !budget.isPending ||
        session.obtainedAt.isAfter(startedAt)) {
      return;
    }
    session
      ..obtainedAt = refreshed.obtainedAt
      ..streamInfo = refreshed.streamInfo
      ..selectedVideo = refreshed.selectedVideo
      ..selectedAudio = refreshed.selectedAudio
      ..durationMs = refreshed.durationMs
      ..urlsMarkedStale = false;
  }

  Future<void> _refreshSessionIfUrlsStale(_GatewaySession session) async {
    final pending = session.refreshFuture;
    if (pending != null) await pending;
    if (session.isClosed || !_shouldRefreshUrls(session)) return;
    try {
      await _refreshSession(session);
    } catch (error) {
      debugPrint('Bilibili playurl refresh failed: $error');
      session.skipStaleRefreshUntil = DateTime.now().add(
        const Duration(seconds: 20),
      );
      return;
    }
    session.urlsMarkedStale = false;
    if (_trackExpiresSoon(session.selectedVideo) ||
        _trackExpiresSoon(session.selectedAudio)) {
      session.skipStaleRefreshUntil = DateTime.now().add(
        const Duration(minutes: 2),
      );
    } else {
      session.skipStaleRefreshUntil = null;
    }
  }

  void _schedulePlayUrlRefresh(_GatewaySession session) {
    if (session.isClosed) return;
    session.urlsMarkedStale = true;
    unawaited(
      _refreshSessionIfUrlsStale(session).catchError((Object error) {
        debugPrint('Bilibili playurl refresh failed: $error');
      }),
    );
  }

  bool _shouldRefreshUrls(_GatewaySession session) {
    final skipUntil = session.skipStaleRefreshUntil;
    if (skipUntil != null && DateTime.now().isBefore(skipUntil)) return false;
    if (session.urlsMarkedStale) return true;
    if (_trackExpiresSoon(session.selectedVideo) ||
        _trackExpiresSoon(session.selectedAudio)) {
      return true;
    }
    if (_trackHasDeadline(session.selectedVideo) ||
        _trackHasDeadline(session.selectedAudio)) {
      return false;
    }
    return DateTime.now().difference(session.obtainedAt) >= _refreshAge;
  }

  bool _playUrlExpiresSoon(BilibiliStreamInfo info) {
    final videos = info.videoStreams.where(_hasAllowedMediaUri);
    final audios = info.audioStreams.where(_hasAllowedMediaUri);
    final videosSoon = videos.isNotEmpty && videos.every(_trackExpiresSoon);
    final audiosSoon = audios.isNotEmpty && audios.every(_trackExpiresSoon);
    return videosSoon || audiosSoon;
  }

  bool _trackHasDeadline(StreamItem track) =>
      _deadlineOf(Uri.tryParse(track.baseUrl)) != null;

  bool _trackExpiresSoon(StreamItem track) {
    final deadline = _deadlineOf(Uri.tryParse(track.baseUrl));
    if (deadline == null) return false;
    return !deadline.isAfter(
      DateTime.now().toUtc().add(_deadlineRefreshMargin),
    );
  }

  DateTime? _deadlineOf(Uri? uri) {
    if (uri == null) return null;
    final raw = uri.queryParameters['deadline'];
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw);
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  Future<void> _tapFirstUpstreamEvent(
    HttpClientResponse upstream,
    _GatewaySession session,
    _UpstreamTap tap, {
    required bool video,
  }) async {
    final first = Completer<void>();
    void finish() {
      if (!first.isCompleted) first.complete();
    }

    tap.finishFirstWait = finish;

    tap.subscription = upstream.listen(
      (bytes) {
        if (bytes.isEmpty) return;
        if (!tap.sawData) {
          tap.sawData = true;
          tap.firstChunk = bytes;
          tap.subscription?.pause();
          finish();
          return;
        }
        tap.onData?.call(bytes);
      },
      onError: (Object error, StackTrace stack) {
        tap.permit?.release();
        if (!tap.sawData && !first.isCompleted) {
          tap.firstError = error;
          finish();
          return;
        }
        tap.onError?.call(error, stack);
      },
      onDone: () {
        tap.permit?.release();
        tap.done = true;
        finish();
        tap.onDone?.call();
      },
      cancelOnError: false,
    );
    final unbind = session.bindTransferAbort(() {
      tap.aborted = true;
      tap.permit?.release();
      finish();
      final subscription = tap.subscription;
      if (subscription != null) unawaited(subscription.cancel());
    }, video: video);
    try {
      await first.future;
    } finally {
      unbind();
      tap.finishFirstWait = null;
    }
  }

  Future<void> _discardTap(_UpstreamTap? tap) async {
    tap?.permit?.release();
    tap?.finishFirstWait?.call();
    final subscription = tap?.subscription;
    if (subscription == null) return;
    try {
      await subscription.cancel();
    } catch (_) {}
  }

  bool _isAllowedMediaUri(Uri? uri) {
    if (uri != null && _mediaUriValidator?.call(uri) == true) return true;
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    final host = uri.host.toLowerCase();
    return host == 'bilivideo.com' ||
        host.endsWith('.bilivideo.com') ||
        host == 'bilivideo.cn' ||
        host.endsWith('.bilivideo.cn') ||
        host == 'hdslb.com' ||
        host.endsWith('.hdslb.com') ||
        host.endsWith('.akamaized.net');
  }

  Future<Directory> _resolveCacheDirectory() async {
    final cached = _cacheDirectory;
    if (cached != null) return cached;
    final root = await SettingsService().resolveLargeDataRootDir();
    final dir = Directory(p.join(root.path, 'bilibili_stream_cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDirectory = dir;
    return dir;
  }

  Future<File> _allocateTrackCacheTempFile(
    _GatewaySession session, {
    required bool video,
    required int start,
    required int endExclusive,
  }) async {
    final itemDir = await _itemCacheDirectory(session.itemId);
    return File(
      p.join(
        itemDir.path,
        '${_trackCachePrefix(session, video: video)}_$start-$endExclusive.seg.tmp',
      ),
    );
  }

  Future<Directory> _itemCacheDirectory(String itemId) async {
    final root = await _resolveCacheDirectory();
    final itemDir = Directory(p.join(root.path, _safeName(itemId)));
    if (!await itemDir.exists()) await itemDir.create(recursive: true);
    return itemDir;
  }

  String _trackCachePrefix(_GatewaySession session, {required bool video}) {
    final track = video ? session.selectedVideo : session.selectedAudio;
    return '${video ? 'video' : 'audio'}_${track.id}';
  }

  Future<void> _commitTrackCacheSegment(
    _GatewaySession session, {
    required bool video,
    required int start,
    required int endExclusive,
    int? totalBytes,
    required File tempFile,
  }) async {
    final prefix = _trackCachePrefix(session, video: video);
    await _runCacheOp('${session.itemId}:$prefix', () async {
      if (!await tempFile.exists()) return;
      final length = await tempFile.length();
      if (length <= 0 || length != endExclusive - start) {
        await tempFile.delete();
        return;
      }
      final itemDir = await _itemCacheDirectory(session.itemId);
      final store = await _openTrackCacheStore(itemDir, prefix);
      await _writeBytesIntoTrackFile(
        store.file,
        start: start,
        source: tempFile,
      );
      await tempFile.delete();
      store.index.addRange(start, endExclusive, totalBytes: totalBytes);
      await _persistTrackCacheIndex(store);
    });
  }

  /// Serves a Range from the sparse track file when the merged interval map
  /// covers it. Exact filename matches are not required, so a restarted
  /// libmpv that asks for a different window can still hit disk.
  ///
  /// The cache IO lock only covers index lookup. Holding it while copying the
  /// HTTP body serialized the next seek behind whatever readahead Range was
  /// already streaming — even a fully cached timestamp then waited seconds.
  Future<bool> _tryServeCachedTrack(
    HttpRequest downstream,
    _GatewaySession session, {
    required bool video,
  }) async {
    final requested = _parseByteRange(
      downstream.headers.value(HttpHeaders.rangeHeader),
    );
    final prefix = _trackCachePrefix(session, video: video);
    final plan = await _runCacheOp('${session.itemId}:$prefix', () async {
      final itemDir = await _itemCacheDirectory(session.itemId);
      final store = await _openTrackCacheStore(itemDir, prefix);
      if (store.index.dirty) await _persistTrackCacheIndex(store);
      if (!await store.file.exists()) return null;

      int sliceStart;
      int sliceEndInclusive;
      var status = HttpStatus.partialContent;
      if (requested == null) {
        if (!store.index.isComplete || store.index.totalBytes == null) {
          return null;
        }
        sliceStart = 0;
        sliceEndInclusive = store.index.totalBytes! - 1;
        status = HttpStatus.ok;
      } else {
        sliceStart = requested.start;
        final total = store.index.totalBytes;
        if (requested.endInclusive == null) {
          if (total == null) return null;
          sliceEndInclusive = total - 1;
        } else {
          sliceEndInclusive = requested.endInclusive!;
          if (total != null && sliceEndInclusive >= total) {
            sliceEndInclusive = total - 1;
          }
        }
        // A cached prefix is not a complete response to bytes=S-E / S-.
        // Ending there makes FFmpeg report premature EOF and reconnect when
        // readahead reaches that boundary (often around 12 seconds). Fetch
        // the requested window upstream unless disk covers it completely.
        if (!store.index.covers(sliceStart, sliceEndInclusive + 1)) return null;
      }
      if (sliceStart < 0 || sliceStart > sliceEndInclusive) return null;
      final sliceLength = sliceEndInclusive - sliceStart + 1;
      final fileLength = await store.file.length();
      if (fileLength < sliceStart + sliceLength) return null;
      return _CachedTrackServePlan(
        file: store.file,
        sliceStart: sliceStart,
        sliceLength: sliceLength,
        status: status,
        video: video,
        totalBytes: store.index.totalBytes,
      );
    });
    if (plan == null) return false;

    final sliceEndInclusive = plan.sliceEndInclusive;
    downstream.response.statusCode = plan.status;
    downstream.response.headers.contentType = ContentType(
      plan.video ? 'video' : 'audio',
      'mp4',
    );
    downstream.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final total = plan.totalBytes;
    if (plan.status == HttpStatus.partialContent) {
      downstream.response.headers.set(
        HttpHeaders.contentRangeHeader,
        total != null && total > sliceEndInclusive
            ? 'bytes ${plan.sliceStart}-$sliceEndInclusive/$total'
            : 'bytes ${plan.sliceStart}-$sliceEndInclusive/*',
      );
    }
    downstream.response.contentLength = plan.sliceLength;
    if (downstream.method == 'HEAD') {
      await downstream.response.close();
      return true;
    }
    final raf = await plan.file.open();
    var stop = false;
    final unbindAbort = session.bindTransferAbort(
      () => stop = true,
      video: video,
    );
    try {
      await raf.setPosition(plan.sliceStart);
      var remaining = plan.sliceLength;
      await downstream.response.addStream(() async* {
        while (remaining > 0 && !stop) {
          final chunkSize = remaining < 64 * 1024 ? remaining : 64 * 1024;
          final chunk = await raf.read(chunkSize);
          if (chunk.isEmpty || stop) break;
          remaining -= chunk.length;
          yield chunk;
        }
      }());
    } catch (_) {
      // The player closed the socket. Leave the on-disk range intact.
    } finally {
      unbindAbort();
      await raf.close();
      try {
        await downstream.response.close();
      } catch (_) {}
    }
    return true;
  }

  /// Parses `Range: bytes=start-end` / `bytes=start-`. Open-ended ranges leave
  /// [endInclusive] null so any covering segment that contains [start] matches.
  ({int start, int? endInclusive})? _parseByteRange(String? header) {
    if (header == null || header.isEmpty) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final start = int.parse(match.group(1)!);
    final endText = match.group(2)!;
    return (
      start: start,
      endInclusive: endText.isEmpty ? null : int.parse(endText),
    );
  }

  /// Maps a CDN 206 Content-Range, or a 200 with known length, onto a cache
  /// slice `[start, endExclusive)`. Incomplete headers are not cached.
  ({int start, int endExclusive, int? totalBytes})? _byteRangeFromContentRange(
    String? contentRange, {
    int? fallbackStart,
    int contentLength = -1,
  }) {
    if (contentRange != null && contentRange.isNotEmpty) {
      final match = RegExp(
        r'bytes\s+(\d+)-(\d+)/(\d+|\*)',
      ).firstMatch(contentRange);
      if (match != null) {
        final start = int.parse(match.group(1)!);
        final endInclusive = int.parse(match.group(2)!);
        if (endInclusive < start) return null;
        final totalText = match.group(3)!;
        return (
          start: start,
          endExclusive: endInclusive + 1,
          totalBytes: totalText == '*' ? null : int.parse(totalText),
        );
      }
    }
    if (contentLength > 0) {
      final start = fallbackStart ?? 0;
      return (
        start: start,
        endExclusive: start + contentLength,
        totalBytes: fallbackStart == null ? contentLength : null,
      );
    }
    return null;
  }

  Future<({File file, File indexFile, _TrackCacheIndex index})>
  _openTrackCacheStore(Directory itemDir, String prefix) async {
    await _ingestLegacySegFiles(itemDir, prefix);
    final file = File(p.join(itemDir.path, '$prefix.track'));
    final indexFile = File(p.join(itemDir.path, '$prefix.track.json'));
    return (
      file: file,
      indexFile: indexFile,
      index: await _readTrackCacheIndex(indexFile),
    );
  }

  Future<_TrackCacheIndex> _readTrackCacheIndex(File indexFile) async {
    if (!await indexFile.exists()) return _TrackCacheIndex();
    try {
      final decoded = jsonDecode(await indexFile.readAsString());
      if (decoded is Map<String, dynamic>) {
        return _TrackCacheIndex.fromJson(decoded);
      }
      if (decoded is Map) {
        return _TrackCacheIndex.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return _TrackCacheIndex();
  }

  Future<void> _persistTrackCacheIndex(
    ({File file, File indexFile, _TrackCacheIndex index}) store,
  ) async {
    if (!store.index.dirty) return;
    await store.indexFile.writeAsString(
      jsonEncode(store.index.toJson()),
      flush: true,
    );
    store.index.dirty = false;
  }

  /// Fold leftover per-Range `.seg` dumps into the sparse track file so a
  /// later, differently aligned libmpv Range can still be served.
  Future<void> _ingestLegacySegFiles(Directory itemDir, String prefix) async {
    if (!await itemDir.exists()) return;
    final indexFile = File(p.join(itemDir.path, '$prefix.track.json'));
    final trackFile = File(p.join(itemDir.path, '$prefix.track'));
    var index = await _readTrackCacheIndex(indexFile);
    var changed = false;
    await for (final entity in itemDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final match = RegExp(
        '^${RegExp.escape(prefix)}_(\\d+)-(\\d+)\\.seg\$',
      ).firstMatch(name);
      if (match == null) continue;
      final start = int.parse(match.group(1)!);
      final endExclusive = int.parse(match.group(2)!);
      if (!index.covers(start, endExclusive)) {
        await _writeBytesIntoTrackFile(trackFile, start: start, source: entity);
        index.addRange(start, endExclusive);
      }
      try {
        await entity.delete();
      } catch (_) {}
      changed = true;
    }
    if (changed) {
      index.dirty = true;
      await indexFile.writeAsString(jsonEncode(index.toJson()), flush: true);
    }
  }

  Future<void> _writeBytesIntoTrackFile(
    File trackFile, {
    required int start,
    required File source,
  }) async {
    final length = await source.length();
    if (length <= 0) return;
    final endExclusive = start + length;
    final raf = await trackFile.open(mode: FileMode.append);
    try {
      if (await raf.length() < endExclusive) {
        await raf.truncate(endExclusive);
      }
      await raf.setPosition(start);
      final src = await source.open();
      try {
        var remaining = length;
        while (remaining > 0) {
          final chunkSize = remaining < 64 * 1024 ? remaining : 64 * 1024;
          final chunk = await src.read(chunkSize);
          if (chunk.isEmpty) break;
          await raf.writeFrom(chunk);
          remaining -= chunk.length;
        }
      } finally {
        await src.close();
      }
    } finally {
      await raf.close();
    }
  }

  Future<T> _runCacheOp<T>(String key, Future<T> Function() op) {
    final previous = _cacheIoLocks[key] ?? Future<void>.value();
    final run = previous.catchError((_) {}).then((_) => op());
    _cacheIoLocks[key] = run.then((_) {}, onError: (_) {});
    return run;
  }

  void _pruneSessions() {
    final cutoff = _clock().subtract(const Duration(hours: 3));
    final warmTokens = {
      for (final playback in _warmPlaybacks.values)
        playback.videoUri.pathSegments[1],
    };
    final expired = _sessions.values
        .where(
          (session) =>
              session.isClosed ||
              warmTokens.contains(session.token) &&
                  session._activeTransfers == 0 &&
                  session.obtainedAt.isBefore(cutoff),
        )
        .toList(growable: false);
    for (final session in expired) {
      _sessions.remove(session.token);
      session.close();
    }
    _warmPlaybacks.removeWhere(
      (_, playback) => _sessionForPlayback(playback) == null,
    );
  }

  HttpClient _sharedMediaClientForSessions() {
    return _sharedMediaClient ??= _createMediaClient();
  }

  HttpClient _createMediaClient() =>
      NetworkHttp.instance.createClient(scope: NetworkScope.bilibili)
        ..connectionTimeout = const Duration(seconds: 8)
        ..idleTimeout = const Duration(seconds: 60)
        ..maxConnectionsPerHost = 8;

  String _safeName(String input) => _safeNameStatic(input);

  static String _safeNameStatic(String input) {
    final safe = input.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    // Never let a malformed card id resolve to the cache root itself.
    if (safe.isEmpty || safe == '.' || safe == '..') return '_';
    return safe;
  }

  void _notifyCacheChanged(String itemId) {
    onCacheChanged?.call(itemId);
    notifyListeners();
  }

  String _xml(String input) => const HtmlEscape(
    HtmlEscapeMode.element,
  ).convert(input).replaceAll('"', '&quot;');
}

/// First CDN body event, captured before the gateway commits a player
/// response so a signature failure can refresh the playurl and retry.
class _CdnOpenAttempt {
  VoidCallback? _abort;
  bool isCancelled = false;

  void bind(VoidCallback abort) {
    _abort = abort;
    if (isCancelled) abort();
  }

  void unbind() => _abort = null;

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    _abort?.call();
  }
}

class _UpstreamTap {
  BilibiliMediaConnectionPermit? permit;
  Uri? uri;
  void Function()? finishFirstWait;
  StreamSubscription<List<int>>? subscription;
  List<int>? firstChunk;
  Object? firstError;
  bool sawData = false;
  bool done = false;
  bool aborted = false;
  void Function(List<int> bytes)? onData;
  void Function(Object error, StackTrace stack)? onError;
  void Function()? onDone;
}

/// Disk slice to copy to a gateway client. Built under the cache IO lock,
/// then streamed without holding that lock.
class _CachedTrackServePlan {
  const _CachedTrackServePlan({
    required this.file,
    required this.sliceStart,
    required this.sliceLength,
    required this.status,
    required this.video,
    this.totalBytes,
  });

  final File file;
  final int sliceStart;
  final int sliceLength;
  final int status;
  final bool video;
  final int? totalBytes;

  int get sliceEndInclusive => sliceStart + sliceLength - 1;
}

class _GatewaySession {
  BilibiliStartupContext? startup;
  VoidCallback? unbindStartupAbort;
  final String token;
  final String itemId;
  final MediaSourceRef source;
  DateTime obtainedAt;
  BilibiliStreamInfo streamInfo;
  StreamItem selectedVideo;
  StreamItem selectedAudio;
  HttpClient mediaClient;
  int durationMs;
  bool didRefreshAfterFailure = false;
  bool urlsMarkedStale = false;
  DateTime? skipStaleRefreshUntil;
  Future<void>? refreshFuture;
  BilibiliStartupContext? refreshBudget;
  bool _closed = false;
  bool _cachingEnabled = false;
  bool cdnWarmStarted = false;
  int _activeTransfers = 0;
  Completer<void>? _idleCompleter;
  final Set<Future<void> Function()> _cacheWriters = {};
  final Map<void Function(), bool> _transferAborts = {};
  bool videoEnabled = true;
  final Map<bool, Uri> preferredCdnUrls = {};
  final Map<Uri, DateTime> failedCdnUrls = {};

  bool get isClosed => _closed;
  bool get isCachingEnabled => _cachingEnabled;

  _GatewaySession({
    required this.token,
    required this.itemId,
    required this.source,
    required this.obtainedAt,
    required this.streamInfo,
    required this.selectedVideo,
    required this.selectedAudio,
    required this.mediaClient,
    required this.durationMs,
  });

  void beginTransfer() {
    if (_closed) throw StateError('Bilibili streaming session is closed');
    _activeTransfers++;
    _idleCompleter ??= Completer<void>();
  }

  void endTransfer() {
    if (_activeTransfers > 0) _activeTransfers--;
    if (_activeTransfers == 0) {
      final completer = _idleCompleter;
      _idleCompleter = null;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
  }

  Future<void> waitUntilIdle() {
    if (_activeTransfers == 0) return Future<void>.value();
    return (_idleCompleter ??= Completer<void>()).future;
  }

  bool registerCacheWriter(Future<void> Function() disable) {
    if (!_cachingEnabled || _closed) return false;
    _cacheWriters.add(disable);
    return true;
  }

  void setCachingEnabled(bool enabled) {
    if (_closed) return;
    _cachingEnabled = enabled;
  }

  void unregisterCacheWriter(Future<void> Function() disable) {
    _cacheWriters.remove(disable);
  }

  Future<void> disableCaching() async {
    if (!_cachingEnabled && _cacheWriters.isEmpty) return;
    _cachingEnabled = false;
    final writers = _cacheWriters.toList(growable: false);
    await Future.wait<void>([for (final disable in writers) disable()]);
  }

  /// Runs [abort] when the session is released. If it is already closed, runs
  /// it immediately so a late transfer cannot keep the CDN socket.
  void Function() bindTransferAbort(
    void Function() abort, {
    bool video = false,
  }) {
    if (_closed || video && !videoEnabled) {
      abort();
      return () {};
    }
    _transferAborts[abort] = video;
    return () {
      _transferAborts.remove(abort);
    };
  }

  void setVideoEnabled(bool enabled) {
    if (_closed || videoEnabled == enabled) return;
    videoEnabled = enabled;
    if (enabled) return;
    final aborts = _transferAborts.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toList();
    for (final abort in aborts) {
      _transferAborts.remove(abort);
      try {
        abort();
      } catch (_) {}
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    refreshBudget?.cancel();
    unbindStartupAbort?.call();
    unbindStartupAbort = null;
    if (startup?.isPending == true) startup!.cancel();
    // The shared CDN client outlives a single episode so the next skip can
    // reuse TLS. Stop this session's sockets now; otherwise a disconnected
    // player keeps downloading until the Range ends and the next episode
    // waits for a free connection.
    final aborts = List<void Function()>.of(_transferAborts.keys);
    _transferAborts.clear();
    for (final abort in aborts) {
      try {
        abort();
      } catch (_) {}
    }
  }
}
