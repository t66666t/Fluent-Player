import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_playback_service.dart';
import 'package:video_player_app/features/media_cache/media_cache_hooks.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/network/network_models.dart';
import 'package:video_player_app/services/network/network_settings_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

import 'baidu_auto_subtitle_test.dart' show cloudItem;
import 'cloud_drive_playback_workflow_test.dart' show CloudPlaybackFake;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

class _DelayedCloud extends CloudPlaybackFake {
  final release = Completer<void>();
  final requested = Completer<void>();
  CloudDriveCancelToken? cancel;
  CloudDrivePreparedPlayback? lateResult;
  @override
  Future<CloudDrivePreparedPlayback> open(
    VideoItem item, {
    String? qualityId,
    bool refresh = false,
    DateTime? operationDeadline,
    Object? cancelToken,
  }) async {
    cancel = cancelToken as CloudDriveCancelToken?;
    requested.complete();
    await release.future;
    return lateResult = await super.open(
      item,
      qualityId: qualityId,
      operationDeadline: operationDeadline,
      cancelToken: cancelToken,
    );
  }
}

class _Platform extends VideoPlayerPlatform {
  Future<void>? volumeBlock;
  final events = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final anchors = <int, DateTime>{};
  final playing = <int, bool>{};
  final seeks = <int, int>{};
  final frozen = <int>{};
  final disposed = <int>[];
  final sources = <int, DataSource>{};
  void Function(int)? onSeek;
  Future<Duration>? Function(int)? readPosition;
  int created = 0;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++created;
    sources[id] = options.dataSource;
    events[id] = StreamController<VideoEvent>();
    positions[id] = Duration.zero;
    anchors[id] = DateTime.now();
    playing[id] = false;
    scheduleMicrotask(
      () => events[id]?.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 2),
          size: const Size(1280, 720),
        ),
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) => events[id]!.stream;
  @override
  Future<Duration> getPosition(int id) async =>
      await readPosition?.call(id) ??
      (positions[id] ?? Duration.zero) +
          (playing[id] == true && !frozen.contains(id)
              ? DateTime.now().difference(anchors[id]!)
              : Duration.zero);
  @override
  Future<void> seekTo(int id, Duration position) async {
    seeks[id] = (seeks[id] ?? 0) + 1;
    positions[id] = position;
    anchors[id] = DateTime.now();
    onSeek?.call(id);
  }

  @override
  Future<void> play(int id) async {
    positions[id] = await getPosition(id);
    anchors[id] = DateTime.now();
    playing[id] = true;
  }

  @override
  Future<void> pause(int id) async {
    positions[id] = await getPosition(id);
    anchors[id] = DateTime.now();
    playing[id] = false;
  }

  @override
  Future<void> dispose(int id) async {
    disposed.add(id);
    await events.remove(id)?.close();
  }

  @override
  Future<void> setVolume(int id, double value) async {
    await volumeBlock;
  }

  @override
  Future<void> setPlaybackSpeed(int id, double value) async {}
  @override
  Future<void> setLooping(int id, bool value) async {}
  @override
  Future<void> setMixWithOthers(bool value) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool value) async {}
  @override
  Widget buildView(int id) => const SizedBox.shrink();
}

class _Api extends BilibiliApiService {
  bool unavailable = false;
  bool highResolutionAudio = false;
  int calls = 0;
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    calls++;
    if (unavailable) throw StateError('视频已下架');
    return BilibiliStreamInfo(
      durationMs: 120000,
      qualityMap: const {80: '1080P'},
      videoStreams: [
        StreamItem(
          id: 80,
          baseUrl: 'https://upos-test.bilivideo.com/$cid.m4s',
          bandwidth: 800000,
          codecs: 'avc1.640028',
          codecid: 7,
          mimeType: 'video/mp4',
          width: 1280,
          height: 720,
          initializationRange: '0-999',
          indexRange: '1000-1999',
        ),
      ],
      audioStreams: [
        if (highResolutionAudio)
          StreamItem(
            id: 30251,
            baseUrl: 'https://upos-test.bilivideo.com/hires.m4s',
            bandwidth: 1690000,
            codecs: 'fLaC',
            codecid: 0,
            mimeType: 'audio/mp4',
          ),
        StreamItem(
          id: 30280,
          baseUrl: 'https://upos-test.bilivideo.com/audio.m4s',
          bandwidth: 128000,
          codecs: 'mp4a.40.2',
          codecid: 0,
          mimeType: 'audio/mp4',
          initializationRange: '0-999',
          indexRange: '1000-1999',
        ),
      ],
    );
  }
}

VideoItem _item(String source, String id, int cid) {
  if (source.startsWith('cloud')) {
    return cloudItem(id: id)
      ..durationMs = 120000
      ..lastPositionMs = 23000
      ..usesManagedAssociatedSubtitles = false;
  }
  final podcast = source.startsWith('podcast');
  return VideoItem(
    id: id,
    path: podcast ? 'podcast:$id' : 'bilibili://stream/BV1xx411c7mD?cid=$cid',
    title: id,
    durationMs: 120000,
    lastPositionMs: 23000,
    lastUpdated: 0,
    type: source == 'podcast-audio' ? MediaType.audio : MediaType.video,
    sourceRef: MediaSourceRef(
      kind: podcast
          ? MediaSourceKind.podcastEpisode
          : MediaSourceKind.bilibiliStream,
      value: podcast ? 'podcast:$id' : 'BV1xx411c7mD',
      bvid: podcast ? null : 'BV1xx411c7mD',
      cid: podcast ? null : cid,
      podcast: podcast
          ? PodcastEpisodeRef(
              channelId: 'channel',
              episodeId: id,
              feedUrl: 'https://podcast.invalid/rss',
              mediaUrl: 'https://podcast.invalid/$id.mp3',
            )
          : null,
    ),
  );
}

Future<void> _until(bool Function() ready) async {
  for (var count = 0; count < 1000 && !ready(); count++) {
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Platform platform;
  late VideoPlayerPlatform previous;
  late MediaPlaybackService service;
  late PlaylistManager playlist;
  late BilibiliStreamingService streaming;
  late _Api api;
  late CloudPlaybackFake cloud;
  late NetworkSettingsService network;
  HttpOverrides? previousHttp;
  late bool oldAutoPlay, oldHeadset;
  final owner = Object();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    previousHttp = HttpOverrides.current;
    HttpOverrides.global = null;
    previous = VideoPlayerPlatform.instance;
    platform = _Platform();
    VideoPlayerPlatform.instance = platform;
    api = _Api();
    streaming = BilibiliStreamingService(api);
    playlist = PlaylistManager();
    service = MediaPlaybackService.forTesting();
    cloud = CloudPlaybackFake();
    network = NetworkSettingsService(
      store: MemoryNetworkStore(),
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await network.init();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(),
      bilibiliStreamingService: streaming,
      networkSettings: network,
    );
    service.attachCloudDrivePlayback(cloud);
    PodcastPlaybackHooks.resolve = (_) async =>
        Uri.parse('https://podcast.invalid/media.mp3');
    oldAutoPlay = SettingsService().autoPlayNextVideo;
    oldHeadset = SettingsService().enableHeadsetMediaControls;
    SettingsService().autoPlayNextVideo = true;
    SettingsService().enableHeadsetMediaControls = true;
  });
  tearDown(() async {
    NativeVideoPlayerMediaKit.debugOutputStateFor = null;
    NativeVideoPlayerMediaKit.debugAttachVideoOutput = null;
    service.debugOnlineStartupReadiness = null;
    service.debugOnlineStartupClock = null;
    MediaCacheHooks.acquire = null;
    MediaCacheHooks.discover = null;
    MediaCacheHooks.publish = null;
    MediaCacheHooks.qualities = null;
    service.setPlaybackPageVisible(owner, false);
    service.setAppForegroundState(true);
    await service.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await streaming.shutdown();
    await cloud.gatewayImpl.close();
    service.dispose();
    PodcastPlaybackHooks.resolve = null;
    SettingsService().autoPlayNextVideo = oldAutoPlay;
    SettingsService().enableHeadsetMediaControls = oldHeadset;
    VideoPlayerPlatform.instance = previous;
    HttpOverrides.global = previousHttp;
  });

  Future<VideoItem> localRecoveryItem(String id) async {
    final directory = await Directory.systemTemp.createTemp(
      'surface-recovery-',
    );
    addTearDown(() async => directory.delete(recursive: true));
    final file = await File('${directory.path}/video.mp4').writeAsBytes([0]);
    return VideoItem(
      id: id,
      path: file.path,
      title: id,
      durationMs: 120000,
      lastUpdated: 0,
    );
  }

  test(
    'a local native option that never acknowledges cannot keep opening forever',
    () async {
      final stuck = Completer<void>();
      platform.volumeBlock = stuck.future;
      service.debugRecoveryLimit = const Duration(milliseconds: 50);
      final item = await localRecoveryItem('local-open-budget');
      try {
        await service
            .play(
              item,
              autoPlay: false,
              startPosition: const Duration(seconds: 66),
            )
            .timeout(const Duration(seconds: 1));
        expect(service.state, PlaybackState.error);
        expect(service.controller, isNull);
      } finally {
        platform.volumeBlock = null;
        stuck.complete();
      }
      service.debugRecoveryLimit = const Duration(seconds: 2);
      await service.play(
        item,
        autoPlay: false,
        startPosition: const Duration(seconds: 66),
      );
      expect(service.state, PlaybackState.paused);
      expect(service.position, const Duration(seconds: 66));
      expect(platform.created, 2);
    },
  );

  test(
    'a prepared clock that never starts still consumes the open budget',
    () async {
      final stalled = Completer<void>();
      service.debugRecoveryLimit = const Duration(milliseconds: 150);
      service.debugOnlineStartupReadiness = (_, _, _) => Future.value();
      service.debugOnlineStartupClock = (_, _) => stalled.future;
      try {
        await service
            .play(_item('bilibili', 'prepared-clock-budget', 989))
            .timeout(const Duration(seconds: 2));
        expect(service.state, PlaybackState.error);
        expect(service.controller, isNull);
        expect(service.session.error, isNotNull);
      } finally {
        stalled.complete();
      }
    },
  );

  test(
    'a cloud lease reopen signal replaces the transport and keeps a pause issued during renewal',
    () async {
      final item = cloudItem();
      await service.play(item, startPosition: const Duration(seconds: 66));
      final previous = service.controller;
      final lease = cloud.lastLease!;
      final gate = Completer<void>();
      cloud.resolveGate = gate;
      lease.needsReopen = true;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await service.pause();
      gate.complete();
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while ((identical(service.controller, previous) ||
              service.state == PlaybackState.loading ||
              service.controller == null) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(service.state, PlaybackState.paused);
      expect(service.controller, isNot(same(previous)));
      expect(service.controller, isNotNull);
      expect(service.position.inSeconds, 66);
      expect(lease.released, isTrue);
      expect(cloud.lastLease, isNot(same(lease)));
      expect(platform.created, 2);
    },
  );

  test(
    'an exhausted output recovery reports failure and a subsequent tap gets a fresh attempt',
    () async {
      final outputs = <int, ValueNotifier<VideoOutputState>>{};
      NativeVideoPlayerMediaKit.debugOutputStateFor = (id) =>
          outputs.putIfAbsent(
            id,
            () => ValueNotifier(
              const VideoOutputState(generation: 1, available: true),
            ),
          );
      final stuck = Completer<bool>();
      NativeVideoPlayerMediaKit.debugAttachVideoOutput = (_) => stuck.future;
      final item = await localRecoveryItem('surface-budget');
      await service.play(
        item,
        autoPlay: false,
        startPosition: const Duration(seconds: 66),
      );
      // ignore: invalid_use_of_visible_for_testing_member
      outputs[service.controller!.playerId]!.value = const VideoOutputState(
        generation: 2,
        available: false,
      );
      service.debugRecoveryLimit = const Duration(milliseconds: 30);
      service.debugOutputAttachLimit = const Duration(seconds: 1);
      expect(
        await service
            .ensureVisibleVideoOutput(item.id)
            .timeout(const Duration(seconds: 1)),
        isFalse,
      );
      expect(service.state, PlaybackState.error);
      var automaticAttempts = 0;
      NativeVideoPlayerMediaKit.debugAttachVideoOutput = (_) async {
        automaticAttempts++;
        return false;
      };
      service.setPlaybackPageVisible(owner, true);
      // A late native invalidation must leave the explicit retry UI in place,
      // instead of giving a failed session a fresh automatic recovery budget.
      // ignore: invalid_use_of_visible_for_testing_member
      outputs[service.controller!.playerId]!.value = const VideoOutputState(
        generation: 3,
        available: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(automaticAttempts, 0);
      expect(platform.created, 1);
      expect(service.state, PlaybackState.error);
      service.debugRecoveryLimit = const Duration(seconds: 2);
      NativeVideoPlayerMediaKit.debugAttachVideoOutput = (_) async => false;
      expect(await service.ensureVisibleVideoOutput(item.id), isTrue);
      expect(platform.created, 2);
      expect(service.state, PlaybackState.paused);
      stuck.complete(true);
    },
  );

  test(
    'a foreground-created player recovers its lost output without reopen or seek',
    () async {
      final outputs = <int, ValueNotifier<VideoOutputState>>{};
      NativeVideoPlayerMediaKit.debugOutputStateFor = (id) =>
          outputs.putIfAbsent(
            id,
            () => ValueNotifier(
              const VideoOutputState(generation: 1, available: true),
            ),
          );
      final attached = Completer<bool>();
      var attempts = 0;
      NativeVideoPlayerMediaKit.debugAttachVideoOutput = (_) {
        attempts++;
        return attached.future;
      };
      final item = await localRecoveryItem('surface-rebind');
      await service.play(
        item,
        autoPlay: false,
        startPosition: const Duration(seconds: 66),
      );
      final controller = service.controller!;
      // ignore: invalid_use_of_visible_for_testing_member
      final id = controller.playerId;
      final seeks = platform.seeks[id];
      service.setPlaybackPageVisible(owner, true);
      outputs[id]!.value = const VideoOutputState(
        generation: 2,
        available: false,
      );
      expect(service.needsVisibleVideoOutputRecovery(item.id), isTrue);
      expect(service.canMountControllerFor(item.id), isTrue);
      final recovery = service.ensureVisibleVideoOutput(item.id);
      expect(service.ensureVisibleVideoOutput(item.id), same(recovery));
      outputs[id]!.value = const VideoOutputState(
        generation: 3,
        available: true,
      );
      attached.complete(true);
      expect(await recovery, isTrue);
      expect(attempts, 1);
      expect(platform.created, 1);
      expect(platform.seeks[id], seeks);
      expect(service.controller, same(controller));
      expect(service.position, const Duration(seconds: 66));
      expect(controller.value.isPlaying, isFalse);
    },
  );

  test(
    'a stuck output attachment recreates once with the bookmark and pause intent',
    () async {
      final outputs = <int, ValueNotifier<VideoOutputState>>{};
      NativeVideoPlayerMediaKit.debugOutputStateFor = (id) =>
          outputs.putIfAbsent(
            id,
            () => ValueNotifier(
              const VideoOutputState(generation: 1, available: true),
            ),
          );
      final stuck = Completer<bool>();
      NativeVideoPlayerMediaKit.debugAttachVideoOutput = (_) => stuck.future;
      service.debugOutputAttachLimit = const Duration(milliseconds: 20);
      final item = await localRecoveryItem('surface-recreate');
      await service.play(
        item,
        autoPlay: false,
        startPosition: const Duration(seconds: 66),
      );
      final original = service.controller!;
      await service.setPlaybackSpeed(1.75);
      await service.setVolume(0.3);
      // ignore: invalid_use_of_visible_for_testing_member
      outputs[original.playerId]!.value = const VideoOutputState(
        generation: 2,
        available: false,
      );
      expect(await service.ensureVisibleVideoOutput(item.id), isTrue);
      expect(platform.created, 2);
      expect(service.controller, isNot(same(original)));
      expect(service.position, const Duration(seconds: 66));
      expect(service.isPlaying, isFalse);
      expect(service.controller!.value.playbackSpeed, 1.75);
      expect(service.controller!.value.volume, 0.3);
      stuck.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(platform.created, 2);
    },
  );

  test(
    'late output work cannot restore or reopen the item after a media switch',
    () async {
      final outputs = <int, ValueNotifier<VideoOutputState>>{};
      NativeVideoPlayerMediaKit.debugOutputStateFor = (id) =>
          outputs.putIfAbsent(
            id,
            () => ValueNotifier(
              const VideoOutputState(generation: 1, available: true),
            ),
          );
      final stuck = Completer<bool>();
      NativeVideoPlayerMediaKit.debugAttachVideoOutput = (_) => stuck.future;
      final first = await localRecoveryItem('surface-old');
      final next = await localRecoveryItem('surface-new');
      await service.play(first, autoPlay: false);
      // ignore: invalid_use_of_visible_for_testing_member
      outputs[service.controller!.playerId]!.value = const VideoOutputState(
        generation: 2,
        available: false,
      );
      final oldRecovery = service.ensureVisibleVideoOutput(first.id);
      await service.play(next, autoPlay: false);
      final controller = service.controller;
      expect(await oldRecovery, isFalse);
      stuck.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(service.currentItem?.id, next.id);
      expect(service.controller, same(controller));
      expect(platform.created, 2);
      expect(await service.ensureVisibleVideoOutput(first.id), isFalse);
    },
  );

  Future<VideoItem> cachedBilibili({bool attachLibrary = true}) async {
    final root = await Directory.systemTemp.createTemp('offline-bilibili-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final file = File('${root.path}/retained.mp4');
    await file.writeAsBytes([0]);
    final item = _item('bilibili', 'retained', 301);
    item.bilibiliDownloadPath = file.path;
    MediaCacheHooks.acquire = (requested, {qualityId}) async {
      if (qualityId != null && qualityId != '80') return null;
      return MaterializedMediaLease(
        videoId: requested.id,
        retainedOffline: true,
        videoPath: file.path,
        audioPath: file.path,
        completePath: file.path,
        qualityId: 80,
        width: 1280,
        height: 720,
        onRelease: () async {},
      );
    };
    MediaCacheHooks.qualities = (_) => [CacheQuality(id: '80', label: '1080P')];
    if (attachLibrary) service.debugAttachLibrary(LibraryService());
    api.unavailable = true;
    return item;
  }

  test(
    'indexed complete playback cache does not wait for material discovery',
    () async {
      final item = await cachedBilibili();
      final discovery = Completer<List<CacheVariant>>();
      var scans = 0;
      MediaCacheHooks.discover = (_) {
        scans++;
        return discovery.future;
      };
      MaterializedMediaLease? lease;
      final acquiring = LibraryService().acquireExistingMaterializedPlayback(
        item,
      );
      try {
        lease = await acquiring.timeout(const Duration(milliseconds: 300));
        expect(lease, isNotNull);
        expect(scans, 0);
      } finally {
        discovery.complete([]);
        await (lease ?? await acquiring)?.release();
      }
    },
  );

  test(
    'playing online reentry reuses transport before slow cache discovery',
    () async {
      final item = _item('bilibili', 'live-reentry', 302);
      await service.play(item);
      final original = service.controller;
      final seeks = platform.seeks[1];
      final acquisition = Completer<MaterializedMediaLease?>();
      var cacheChecks = 0;
      service.debugAttachLibrary(LibraryService());
      MediaCacheHooks.acquire = (_, {qualityId}) {
        cacheChecks++;
        return acquisition.future;
      };
      try {
        await service.play(item).timeout(const Duration(milliseconds: 400));
        expect(service.controller, same(original));
        expect(service.state, PlaybackState.playing);
        expect(cacheChecks, 0);
        expect(platform.created, 1);
        expect(platform.seeks[1], seeks);
      } finally {
        acquisition.complete(null);
      }
    },
  );

  for (final attached in [false, true]) {
    test(
      'complete cache opens while source is removed, library attached=$attached',
      () async {
        final item = await cachedBilibili(attachLibrary: attached);
        await service.play(item).timeout(const Duration(seconds: 2));
        expect(service.state, PlaybackState.playing);
        expect(platform.sources[1]!.sourceType, DataSourceType.file);
        expect(service.selectedStreamQuality!.isLocalMaterialized, isTrue);
      },
    );
  }

  test(
    'a remembered audio choice cannot block an explicitly retained file',
    () async {
      final item = await cachedBilibili();
      await streaming.rememberAudioQuality(item.id, 30251);
      await service.play(item).timeout(const Duration(seconds: 2));
      expect(service.state, PlaybackState.playing);
      expect(platform.sources[1]!.sourceType, DataSourceType.file);
      expect(service.selectedStreamQuality!.isLocalMaterialized, isTrue);
    },
  );

  test(
    'an explicit audio-quality switch can still leave the cached file',
    () async {
      final item = await cachedBilibili();
      api.unavailable = false;
      api.highResolutionAudio = true;
      await service.play(item);
      final cached = service.controller;
      await _until(
        () => service.streamAudioQualities.any((q) => q.id == 30251),
      );
      expect(await service.switchBilibiliAudioQuality(30251), isTrue);
      expect(service.controller, isNot(same(cached)));
      expect(platform.sources[2]!.sourceType, DataSourceType.network);
      expect(service.selectedStreamAudioQuality!.id, 30251);
      expect(service.state, PlaybackState.playing);
      final selected = service.controller;
      await service.pause();
      await service.resume();
      expect(service.controller, same(selected));
      expect(service.selectedStreamAudioQuality!.id, 30251);
      expect(platform.created, 2);
    },
  );

  test(
    'network policy changes cannot restart a preparing retained local file',
    () async {
      final item = await cachedBilibili();
      final frame = Completer<void>();
      var waiting = false;
      service.debugOnlineStartupReadiness = (_, _, _) {
        waiting = true;
        return frame.future;
      };
      final opening = service.play(item, autoPlay: false);
      await _until(() => waiting);
      final original = service.controller;
      final startup = service.onlineStartup;
      await network.setMode(NetworkScope.bilibili, NetworkMode.system);
      frame.complete();
      await opening;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.controller, same(original));
      expect(service.onlineStartup, same(startup));
      expect(platform.created, 1);
      expect(service.state, PlaybackState.paused);
    },
  );

  test(
    'cache miss still discovers a sealed original before resolving online',
    () async {
      final item = await cachedBilibili();
      final acquire = MediaCacheHooks.acquire!;
      var found = false;
      MediaCacheHooks.acquire = (item, {qualityId}) =>
          found ? acquire(item, qualityId: qualityId) : Future.value(null);
      MediaCacheHooks.discover = (_) async {
        found = true;
        return [];
      };
      await service.play(item);
      expect(found, isTrue);
      expect(platform.sources[1]!.sourceType, DataSourceType.file);
      expect(service.state, PlaybackState.playing);
    },
  );

  test(
    'a cached 1080P file cannot silently replace an explicit missing quality',
    () async {
      final item = await cachedBilibili();
      await service.play(item, bilibiliQualityId: 64);
      expect(service.state, PlaybackState.error);
      expect(platform.created, 0);
    },
  );

  for (final paused in [false, true]) {
    test(
      'offline removed Bilibili keeps its picture across Android home/return: paused=$paused',
      () async {
        final item = await cachedBilibili();
        service.setPlaybackPageVisible(owner, true);
        await service.play(item, autoPlay: !paused);
        final original = service.controller;
        expect(service.isCoveringUntilVisibleVideoFrame, isFalse);
        for (var cycle = 0; cycle < 3; cycle++) {
          service.handleAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          service.handleAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(service.controller, same(original));
          expect(
            service.isCoveringUntilVisibleVideoFrame,
            isFalse,
            reason:
                'A delegated local file has no online track-policy callback',
          );
          expect(service.bilibiliStartup!.isReady, isTrue);
          expect(
            service.state,
            paused ? PlaybackState.paused : PlaybackState.playing,
          );
        }
        expect(platform.created, 1);
        expect(platform.seeks[1], 1);
      },
    );
  }

  for (final source in [
    'bilibili',
    'cloud-hls',
    'cloud-original',
    'podcast-audio',
    'podcast-video',
  ]) {
    for (final entry in [
      'page-next',
      'page-previous',
      'remote-next',
      'remote-previous',
      'remote-queue',
    ]) {
      test('$source saved-position recovery through $entry', () async {
        cloud.transport = source == 'cloud-original'
            ? CloudDriveTransport.progressive
            : CloudDriveTransport.hls;
        final items = [
          _item(source, 'first', 101),
          _item(source, 'second', 102),
        ];
        final backwards = entry.contains('previous');
        final initial = backwards ? items.last : items.first;
        final target = backwards ? items.first : items.last;
        playlist.setPlaylist(items);
        final background = entry.startsWith('remote');
        if (!background) service.setPlaybackPageVisible(owner, true);
        await service.play(initial, autoPlay: false);
        if (background) service.setAppForegroundState(false);
        final held = Completer<void>();
        var checked = 0;
        service
            .debugOnlineStartupReadiness = (controller, startup, needsVideo) {
          expect(needsVideo, !background && target.type == MediaType.video);
          if (++checked == 1) {
            // Emulate a real native open which used its positioning correction.
            expect(startup.claimPositionCorrection(), isTrue);
            return held.future;
          }
          return Future.value();
        };
        platform.onSeek = (id) {
          if (id == 2 && (platform.seeks[id] ?? 0) >= 2 && !held.isCompleted) {
            expect(platform.playing[id], isFalse);
            held.complete();
          }
        };
        final handler = createSystemMediaHandlerForTesting(
          playbackService: service,
          playlistManager: playlist,
        );
        final switching = switch (entry) {
          'page-next' => service.playNext(),
          'page-previous' => service.playPrevious(),
          'remote-next' => handler.skipToNext(),
          'remote-previous' => handler.skipToPrevious(),
          _ => handler.skipToQueueItem(1),
        };
        await _until(() => checked > 0);
        expect(
          service.positionForProgressChrome(Duration.zero),
          const Duration(seconds: 23),
        );
        if (entry == 'remote-next') {
          await handler.skipToNext(); // duplicate is acknowledged, not queued
        }
        await switching.timeout(const Duration(seconds: 5));
        expect(service.currentItem?.id, target.id);
        expect(service.state, PlaybackState.playing);
        expect(service.onlineStartupForTesting!.isReady, isTrue);
        expect(platform.created, 2);
        expect(platform.seeks[2], 2);
        expect(checked, 2);
      });
    }

    test(
      '$source clock acknowledgement alone is recovered before success',
      () async {
        final items = [_item(source, 'one', 111), _item(source, 'two', 112)];
        playlist.setPlaylist(items);
        await service.play(items.first, autoPlay: false);
        service.setAppForegroundState(false);
        platform.frozen.add(2);
        final parked = Completer<void>();
        var clockChecks = 0;
        service.debugOnlineStartupClock = (controller, startup) {
          clockChecks++;
          return (platform.seeks[2] ?? 0) >= 2 ? Future.value() : parked.future;
        };
        platform.onSeek = (id) {
          if (id == 2 && (platform.seeks[id] ?? 0) >= 2) {
            platform.frozen.remove(id);
            if (!parked.isCompleted) parked.complete();
          }
        };
        final switching = service.playNext();
        await _until(() => clockChecks > 0);
        expect(service.onlineStartupForTesting!.isPrepared, isTrue);
        expect(service.onlineStartupForTesting!.isReady, isFalse);
        await switching.timeout(const Duration(seconds: 5));
        expect(service.state, PlaybackState.playing);
        expect(
          service.onlineStartupForTesting!.marks.where(
            (mark) => mark.step == 'startup clock recovery seek',
          ),
          hasLength(1),
        );
        expect(platform.seeks[2], 2);
        expect(clockChecks, greaterThanOrEqualTo(2));
      },
    );

    test(
      '$source paused open resumes through the same verified controller',
      () async {
        final item = _item(source, 'paused', 116);
        await service.play(item, autoPlay: false);
        final controller = service.controller;
        platform.frozen.add(1);
        platform.onSeek = (id) => platform.frozen.remove(id);
        final handler = createSystemMediaHandlerForTesting(
          playbackService: service,
          playlistManager: playlist,
        );
        await handler.play().timeout(const Duration(seconds: 3));
        expect(service.controller, same(controller));
        expect(platform.created, 1);
        expect(platform.seeks[1], 2);
        expect(service.state, PlaybackState.playing);
        expect(service.onlineStartup!.isReady, isTrue);
        expect(
          service.onlineStartup!.marks.where(
            (mark) => mark.step == 'startup clock recovery seek',
          ),
          hasLength(1),
        );
      },
    );
  }

  test(
    'remote stop cancels an episode open without waiting behind the switch',
    () async {
      final items = [
        _item('bilibili', 'old', 121),
        _item('bilibili', 'new', 122),
      ];
      playlist.setPlaylist(items);
      await service.play(items.first, autoPlay: false);
      final never = Completer<void>();
      var waiting = false;
      service.debugOnlineStartupReadiness = (_, _, _) {
        waiting = true;
        return never.future;
      };
      final handler = createSystemMediaHandlerForTesting(
        playbackService: service,
        playlistManager: playlist,
      );
      final switching = handler.skipToNext();
      await _until(() => waiting);
      await handler.stop().timeout(const Duration(seconds: 1));
      await switching.timeout(const Duration(seconds: 1));
      expect(service.currentItem, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(platform.created, 2);
      expect(platform.disposed, contains(2));
    },
  );

  for (final targetIndex in [1, 2]) {
    test(
      'queue selection $targetIndex supersedes a blocked episode preparation',
      () async {
        final items = [
          for (var i = 0; i < 3; i++) _item('bilibili', 'queue-$i', 180 + i),
        ];
        playlist.setPlaylist(items);
        await service.play(items.first, autoPlay: false);
        final parked = Completer<void>();
        var checks = 0;
        service.debugOnlineStartupReadiness = (_, _, _) =>
            ++checks == 1 ? parked.future : Future.value();
        final handler = createSystemMediaHandlerForTesting(
          playbackService: service,
          playlistManager: playlist,
        );
        final old = handler.skipToNext();
        await _until(() => checks == 1);
        final oldContext = service.onlineStartup!;
        await handler
            .skipToQueueItem(targetIndex)
            .timeout(const Duration(seconds: 2));
        await old;
        expect(service.currentItem?.id, items[targetIndex].id);
        expect(service.state, PlaybackState.playing);
        expect(oldContext.isCancelled, isTrue);
        expect(platform.created, 3);
        parked.complete();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(platform.seeks[2], 1);
        expect(platform.disposed, contains(2));
      },
    );
  }

  test(
    'an abandoned initial position read cannot rewind a newer online item',
    () async {
      final items = [
        _item('bilibili', 'old-read', 201),
        _item('bilibili', 'new-read', 202)..lastPositionMs = 37000,
      ];
      playlist.setPlaylist(items);
      final late = Completer<Duration>();
      var waiting = false;
      platform.readPosition = (id) {
        if (id == 1 && service.onlineStartup?.phase.name == 'positioning') {
          waiting = true;
          return late.future;
        }
        return null;
      };
      final old = service.playPlaylistItem(items.first, autoPlay: false);
      await _until(() => waiting);
      await service
          .playPlaylistItem(items.last, autoPlay: false)
          .timeout(const Duration(seconds: 2));
      await old;
      platform.readPosition = null;
      late.complete(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(service.currentItem?.id, items.last.id);
      expect(service.position, const Duration(seconds: 37));
      expect(service.state, PlaybackState.paused);
      expect(platform.seeks[1] ?? 0, 0);
    },
  );

  test(
    'duplicate entry joins startup and preserves the last pause intent',
    () async {
      final item = _item('bilibili', 'same', 131);
      final frame = Completer<void>();
      var waiting = false;
      service.debugOnlineStartupReadiness = (_, _, _) {
        waiting = true;
        return frame.future;
      };
      final first = service.play(item);
      await _until(() => waiting);
      final context = service.onlineStartupForTesting;
      final second = service.play(item, autoPlay: false);
      frame.complete();
      await Future.wait([first, second]);
      expect(platform.created, 1);
      expect(service.onlineStartupForTesting, same(context));
      expect(service.state, PlaybackState.paused);
      expect(context!.isReady, isTrue);
    },
  );

  test(
    'synchronous route reentry joins before the first play notification',
    () async {
      final item = _item('bilibili', 'reentrant', 141);
      Future<void>? joined;
      service.addListener(() {
        if (service.currentItem?.id == item.id && joined == null) {
          // Set a sentinel before the duplicate invocation also notifies.
          joined = Future.value();
          joined = service.play(item, autoPlay: false);
        }
      });
      await service.play(item);
      await joined;
      expect(platform.created, 1);
      expect(service.state, PlaybackState.paused);
    },
  );

  for (final source in ['bilibili', 'cloud-hls', 'podcast-audio']) {
    for (final paused in [false, true]) {
      test('$source retry preserves latest pause intent: $paused', () async {
        final items = [
          _item(source, 'retry-a', 211),
          _item(source, 'retry-b', 212),
        ];
        playlist.setPlaylist(items);
        await service.play(items.first, autoPlay: false);
        var checks = 0;
        service.debugOnlineStartupReadiness = (_, _, _) => ++checks == 1
            ? Future.error(StateError('temporary stream error'))
            : Future.value();
        final switching = service.playNext();
        await _until(() => service.onlineStartup?.hasFailed == true);
        if (paused) await service.pause();
        await switching.timeout(const Duration(seconds: 3));
        expect(service.onlineStartup!.isReady, isTrue);
        expect(
          service.state,
          paused ? PlaybackState.paused : PlaybackState.playing,
        );
        expect(platform.created, 3);
        expect(platform.playing[3], !paused);
      });
    }

    test(
      '$source network changes cancel the old startup and keep its budget',
      () async {
        final item = _item(source, 'network', 149);
        final oldFrame = Completer<void>();
        var checked = 0;
        service.debugOnlineStartupReadiness = (_, _, _) {
          return ++checked == 1 ? oldFrame.future : Future.value();
        };
        final opening = service.play(item, autoPlay: false);
        await _until(() => checked == 1);
        final old = service.onlineStartup!;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final scope = source == 'bilibili'
            ? NetworkScope.bilibili
            : source.startsWith('cloud')
            ? NetworkScope.cloudDrive
            : NetworkSites.forPodcast(
                Uri.parse(item.sourceRef!.podcast!.mediaUrl),
              );
        await network.setMode(
          scope,
          network.configuration.modes[scope] == NetworkMode.direct
              ? NetworkMode.system
              : NetworkMode.direct,
        );
        await opening;
        await _until(
          () =>
              service.onlineStartup != old &&
              service.onlineStartup?.isReady == true,
        );
        final next = service.onlineStartup!;
        expect(old.isCancelled, isTrue);
        expect(
          (next.elapsed - old.elapsed).abs(),
          lessThan(const Duration(milliseconds: 10)),
        );
        expect(next.remaining, lessThan(const Duration(milliseconds: 29940)));
        expect(service.state, PlaybackState.paused);
        expect(platform.created, 2);
        oldFrame.complete();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(service.onlineStartup, same(next));
        expect(platform.seeks[2], 1);
      },
    );

    test(
      '$source notification pause wins over a pending clock check',
      () async {
        final item = _item(source, 'pause', 151);
        platform.frozen.add(1);
        final handler = createSystemMediaHandlerForTesting(
          playbackService: service,
          playlistManager: playlist,
        );
        final opening = service.play(item);
        await _until(() => platform.playing[1] == true);
        await handler.pause().timeout(const Duration(seconds: 1));
        await opening.timeout(const Duration(seconds: 1));
        expect(service.onlineStartupForTesting!.isReady, isTrue);
        expect(service.state, PlaybackState.paused);
        expect(platform.playing[1], isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(platform.seeks[1], 1);
      },
    );

    test('$source notification seek retargets a pending clock check', () async {
      final item = _item(source, 'seek', 161);
      platform.frozen.add(1);
      final handler = createSystemMediaHandlerForTesting(
        playbackService: service,
        playlistManager: playlist,
      );
      final opening = service.play(item);
      await _until(() => platform.playing[1] == true);
      platform.onSeek = (id) => platform.frozen.remove(id);
      await handler
          .seek(const Duration(seconds: 31))
          .timeout(const Duration(seconds: 1));
      await opening.timeout(const Duration(seconds: 1));
      expect(
        service.onlineStartupForTesting!.target,
        const Duration(seconds: 31),
      );
      expect(service.state, PlaybackState.playing);
      expect(platform.positions[1]!.inSeconds, 31);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(platform.seeks[1], 2);
    });
  }

  test(
    'stop cancels cloud resolution and releases a provider result arriving late',
    () async {
      await cloud.gatewayImpl.close();
      final delayed = _DelayedCloud();
      cloud = delayed;
      service.attachCloudDrivePlayback(delayed);
      final opening = service.play(_item('cloud-hls', 'late-cloud', 171));
      await delayed.requested.future;
      await service.stop().timeout(const Duration(seconds: 1));
      await opening.timeout(const Duration(seconds: 1));
      expect(delayed.cancel!.isCancelled, isTrue);
      delayed.release.complete();
      await _until(() => delayed.lateResult != null);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(
          delayed.lateResult!.lease.loopbackUri,
        )).close();
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
      expect(service.currentItem, isNull);
      expect(platform.created, 0);
    },
  );
}
