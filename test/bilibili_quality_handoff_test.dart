import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_startup.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/network/network_models.dart';
import 'package:video_player_app/services/network/network_settings_service.dart';
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _QualityApiService extends BilibiliApiService {
  int playUrlCalls = 0;
  bool specialAudio = false;
  final dimensionsByCid = <int, Size>{};
  Future<void> Function(int cid)? beforeFetch;
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    playUrlCalls++;
    await beforeFetch?.call(cid);
    StreamItem video(int id, String label, int width, int height) => StreamItem(
      id: id,
      baseUrl: 'https://upos-test.bilivideo.com/video-$id.m4s',
      bandwidth: id * 1000,
      codecs: 'avc1.640028',
      codecid: 7,
      mimeType: 'video/mp4',
      qualityName: label,
      width: dimensionsByCid[cid]?.width.toInt() ?? width,
      height: dimensionsByCid[cid]?.height.toInt() ?? height,
      frameRate: '30',
      initializationRange: '0-999',
      indexRange: '1000-1999',
    );

    return BilibiliStreamInfo(
      durationMs: const Duration(minutes: 2).inMilliseconds,
      qualityMap: const <int, String>{80: '1080P', 64: '720P'},
      videoStreams: <StreamItem>[
        video(80, '1080P', 1920, 1080),
        video(64, '720P', 1280, 720),
      ],
      audioStreams: <StreamItem>[
        if (specialAudio)
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
          initializationRange: '0-899',
          indexRange: '900-1799',
        ),
      ],
    );
  }
}

class _DelayedQualityApiService extends _QualityApiService {
  final Map<int, Completer<void>> blockers = <int, Completer<void>>{};
  final List<int> requestedCids = <int>[];

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    requestedCids.add(cid);
    await (blockers[cid] ??= Completer<void>()).future;
    return super.fetchPlayUrl(bvid, cid);
  }
}

class _HandoffVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events =
      <int, StreamController<VideoEvent>>{};
  final Map<int, Duration> _positions = <int, Duration>{};
  final Map<int, DateTime> _positionAnchors = <int, DateTime>{};
  final Map<int, bool> _playing = <int, bool>{};
  final Map<int, double> _rates = <int, double>{};
  final Set<int> frozenPlayers = <int>{};
  void Function(int playerId, double speed)? onPlaybackSpeed;
  void Function(int playerId, Duration position)? onSeek;
  Future<Duration> Function(int playerId)? readPosition;
  final Map<int, int> seekCounts = <int, int>{};
  final Map<int, Duration> seekDelays = <int, Duration>{};
  final Map<int, Duration> seekFeedbackDelays = <int, Duration>{};
  final Map<int, DateTime> _seekFeedbackReadyAt = <int, DateTime>{};
  final Map<int, Duration> lastPausePositions = <int, Duration>{};
  final List<({int playerId, double volume})> volumeCalls =
      <({int playerId, double volume})>[];
  final List<({int playerId, double volume, Duration position})>
  volumeCallPositions = <({int playerId, double volume, Duration position})>[];
  final List<int> disposedPlayerIds = <int>[];
  int _nextPlayerId = 1;

  List<int> get playerIds => _events.keys.toList(growable: false);

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    _events[playerId] = StreamController<VideoEvent>();
    _positions[playerId] = Duration.zero;
    _positionAnchors[playerId] = DateTime.now();
    _playing[playerId] = false;
    _rates[playerId] = 1.0;
    seekCounts[playerId] = 0;
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  void initializePlayer(int playerId, {Size size = const Size(1920, 1080)}) {
    _events[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 2),
        size: size,
      ),
    );
  }

  void failPlayer(int playerId) {
    _events[playerId]!.addError(
      PlatformException(
        code: 'stream_failed',
        message: 'replacement stream failed',
      ),
    );
  }

  void setBuffering(int playerId, bool buffering) {
    _anchorPosition(playerId);
    if (buffering) {
      frozenPlayers.add(playerId);
    } else {
      frozenPlayers.remove(playerId);
    }
    _events[playerId]!.add(
      VideoEvent(
        eventType: buffering
            ? VideoEventType.bufferingStart
            : VideoEventType.bufferingEnd,
      ),
    );
  }

  @override
  Future<void> dispose(int playerId) async {
    disposedPlayerIds.add(playerId);
    _positions.remove(playerId);
    _positionAnchors.remove(playerId);
    _playing.remove(playerId);
    _rates.remove(playerId);
    seekCounts.remove(playerId);
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    _anchorPosition(playerId);
    _playing[playerId] = true;
  }

  @override
  Future<void> pause(int playerId) async {
    final position = _currentPosition(playerId);
    _positions[playerId] = position;
    _positionAnchors[playerId] = DateTime.now();
    _playing[playerId] = false;
    lastPausePositions[playerId] = position;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seekCounts[playerId] = (seekCounts[playerId] ?? 0) + 1;
    final delay = seekDelays[playerId];
    if (delay != null) await Future<void>.delayed(delay);
    _positions[playerId] = position;
    _positionAnchors[playerId] = DateTime.now();
    final feedbackDelay = seekFeedbackDelays[playerId];
    if (feedbackDelay != null) {
      _seekFeedbackReadyAt[playerId] = DateTime.now().add(feedbackDelay);
    }
    onSeek?.call(playerId, position);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    volumeCalls.add((playerId: playerId, volume: volume));
    volumeCallPositions.add((
      playerId: playerId,
      volume: volume,
      position: _currentPosition(playerId),
    ));
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    _anchorPosition(playerId);
    _rates[playerId] = speed;
    onPlaybackSpeed?.call(playerId, speed);
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    final reader = readPosition;
    if (reader != null) return reader(playerId);
    final readyAt = _seekFeedbackReadyAt[playerId];
    if (readyAt != null && DateTime.now().isBefore(readyAt)) {
      return Duration.zero;
    }
    return _currentPosition(playerId);
  }

  Duration _currentPosition(int playerId) {
    final base = _positions[playerId] ?? Duration.zero;
    if (_playing[playerId] != true || frozenPlayers.contains(playerId)) {
      return base;
    }
    final anchor = _positionAnchors[playerId] ?? DateTime.now();
    final elapsedUs = DateTime.now().difference(anchor).inMicroseconds;
    final rate = _rates[playerId] ?? 1.0;
    return base + Duration(microseconds: (elapsedUs * rate).round());
  }

  void _anchorPosition(int playerId) {
    _positions[playerId] = _currentPosition(playerId);
    _positionAnchors[playerId] = DateTime.now();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

VideoItem _streamItem({
  String id = 'quality-handoff-item',
  int cid = 456,
  int lastPositionMs = 0,
}) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1xx411c7mD?cid=$cid',
  title: 'Quality hand-off',
  durationMs: 120000,
  lastPositionMs: lastPositionMs,
  lastUpdated: 0,
  sourceRef: MediaSourceRef(
    value: 'BV1xx411c7mD',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV1xx411c7mD',
    cid: cid,
  ),
);

Future<void> _waitForPlayerCount(
  _HandoffVideoPlatform platform,
  int count,
) async {
  for (var attempt = 0; attempt < 2000; attempt++) {
    if (platform.playerIds.length == count) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(platform.playerIds, hasLength(count));
}

Future<void> _waitForPlayerId(
  _HandoffVideoPlatform platform,
  int playerId, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (platform.playerIds.contains(playerId)) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(platform.playerIds, contains(playerId));
}

Future<void> _waitForRequestedCid(
  _DelayedQualityApiService api,
  int cid,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (api.requestedCids.contains(cid)) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(api.requestedCids, contains(cid));
}

Future<
  ({
    MediaPlaybackService service,
    BilibiliStreamingService streaming,
    _HandoffVideoPlatform platform,
    _QualityApiService api,
  })
>
_startQualityFixture({
  NetworkSettingsService? network,
  bool initializePlayback = true,
  bool isolatedService = false,
  bool specialAudio = false,
}) async {
  final originalPlatform = VideoPlayerPlatform.instance;
  final platform = _HandoffVideoPlatform();
  VideoPlayerPlatform.instance = platform;
  final api = _QualityApiService()..specialAudio = specialAudio;
  final streaming = BilibiliStreamingService(api, networkSettings: network);
  final service = isolatedService
      ? MediaPlaybackService.forTesting()
      : MediaPlaybackService();
  await service.stop();
  await service.initialize(
    playlistManager: PlaylistManager(),
    progressTracker: ProgressTracker(),
    bilibiliStreamingService: streaming,
    networkSettings: network,
  );
  addTearDown(() async {
    // Finish the deferred release while this fixture's platform is installed.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await service.setPlaybackSpeed(1.0);
    await service.stop();
    await streaming.shutdown();
    VideoPlayerPlatform.instance = originalPlatform;
  });
  if (!initializePlayback) {
    return (
      service: service,
      streaming: streaming,
      platform: platform,
      api: api,
    );
  }
  final initialPlay = service.play(_streamItem());
  await _waitForPlayerId(platform, 1);
  platform.initializePlayer(1);
  await initialPlay;
  await service.setPlaybackSpeed(1.0);
  await service.seekTo(const Duration(seconds: 24));
  return (service: service, streaming: streaming, platform: platform, api: api);
}

Future<void> _primeRuntimeClock(
  MediaPlaybackService service,
  _HandoffVideoPlatform platform,
) async {
  platform.frozenPlayers.add(1);
  await service.seekTo(const Duration(seconds: 8));
  final controller = service.controller!;
  controller.value = controller.value.copyWith(
    position: const Duration(seconds: 8),
    isPlaying: true,
  );
  service.updatePlaybackStateFromController();
  // Finish the preceding user seek's independent verification before injecting
  // runtime clock faults; it must not consume the controlled reads below.
  await Future<void>.delayed(const Duration(milliseconds: 220));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));


  for (final paused in [false, true]) {
    test('audio switch retains video, timeline and pause intent: paused=$paused', () async {
      final fixture = await _startQualityFixture(specialAudio: true, isolatedService: true);
      final service = fixture.service;
      if (paused) await service.pause();
      await service.setPlaybackSpeed(1.5);
      final switching = service.switchBilibiliAudioQuality(30280);
      await _waitForPlayerId(fixture.platform, 2);
      expect(service.selectedStreamAudioQuality?.id, 30251);
      expect(service.controller?.playerId, 1);
      fixture.platform.initializePlayer(2);
      expect(await switching, isTrue);
      expect(service.selectedStreamAudioQuality?.id, 30280);
      expect(service.selectedStreamQuality?.id, 80);
      expect(service.position.inMilliseconds, closeTo(24000, 800));
      expect(service.playbackSpeed, 1.5);
      expect(service.state, paused ? PlaybackState.paused : PlaybackState.playing);
      await _waitForPlayerCount(fixture.platform, 1);

      final qualitySwitch = service.switchBilibiliStreamQuality(64);
      await _waitForPlayerId(fixture.platform, 3);
      fixture.platform.initializePlayer(3);
      expect(await qualitySwitch, isTrue);
      expect(service.selectedStreamQuality?.id, 64);
      expect(service.selectedStreamAudioQuality?.id, 30280);
      await _waitForPlayerCount(fixture.platform, 1);

      final revert = service.switchBilibiliAudioQuality(30251);
      await _waitForPlayerId(fixture.platform, 4);
      fixture.platform.initializePlayer(4);
      expect(await revert, isTrue);
      expect(service.selectedStreamAudioQuality?.isSpecial, isTrue);
      expect(service.selectedStreamQuality?.id, 64);
    });
  }

  test('failed audio switch leaves the current audio and preference untouched', () async {
    final fixture = await _startQualityFixture(specialAudio: true, isolatedService: true);
    final service = fixture.service;
    final switching = service.switchBilibiliAudioQuality(30280);
    for (final id in [2, 3]) {
      await _waitForPlayerId(fixture.platform, id);
      fixture.platform.failPlayer(id);
    }
    expect(await switching, isFalse);
    expect(service.controller?.playerId, 1);
    expect(service.selectedStreamAudioQuality?.id, 30251);
    expect(fixture.streaming.hasPreferredAudioQuality(service.currentItem!.id), isFalse);
    expect(service.isSwitchingStreamQuality, isFalse);
  });

  for (final seconds in [8, 9, 10]) {
    test(
      'a stale zero at ${seconds}s does not flush a healthy Bilibili decoder',
      () async {
        final fixture = await _startQualityFixture(isolatedService: true);
        final service = fixture.service;
        fixture.platform.frozenPlayers.add(1);
        final position = Duration(seconds: seconds);
        await service.seekTo(position);
        final controller = service.controller!;
        controller.value = controller.value.copyWith(
          position: position,
          isPlaying: true,
        );
        service.updatePlaybackStateFromController();
        final seeks = fixture.platform.seekCounts[1];
        // The video_player snapshot briefly reports zero; the platform's own
        // getPosition still reports the healthy decoder at the correct clock.
        controller.value = controller.value.copyWith(position: Duration.zero);
        service.updatePlaybackStateFromController();
        expect(
          service.position,
          position,
          reason: 'An unconfirmed zero cannot replace the live timeline',
        );
        await Future<void>.delayed(const Duration(milliseconds: 650));
        expect(
          fixture.platform.seekCounts[1],
          seeks,
          reason:
              'A cached zero must not trigger a seek and flush Android MediaCodec',
        );
        expect(service.position, position);
        expect(service.state, PlaybackState.playing);
      },
    );
  }

  test('a confirmed runtime reset still recovers exactly once', () async {
    final fixture = await _startQualityFixture(isolatedService: true);
    final service = fixture.service;
    final platform = fixture.platform;
    await _primeRuntimeClock(service, platform);
    final seeks = platform.seekCounts[1]!;
    final correction = Completer<void>();
    platform._positions[1] = Duration.zero;
    platform.onSeek = (_, position) {
      expect(position, const Duration(seconds: 8));
      if (!correction.isCompleted) correction.complete();
    };
    final controller = service.controller!;
    controller.value = controller.value.copyWith(position: Duration.zero);
    service.updatePlaybackStateFromController();
    expect(
      platform.seekCounts[1],
      seeks,
      reason: 'Never seek on the cached sample alone',
    );
    await correction.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(platform.seekCounts[1], seeks + 1);
    expect(service.position, const Duration(seconds: 8));
    expect(service.state, PlaybackState.playing);
  });

  test(
    'a single fresh zero that recovers does not trigger runtime seek',
    () async {
      final fixture = await _startQualityFixture(isolatedService: true);
      final service = fixture.service;
      final platform = fixture.platform;
      await _primeRuntimeClock(service, platform);
      final seeks = platform.seekCounts[1];
      var reads = 0;
      platform.readPosition = (_) async =>
          ++reads == 1 ? Duration.zero : const Duration(seconds: 8);
      final controller = service.controller!;
      controller.value = controller.value.copyWith(position: Duration.zero);
      service.updatePlaybackStateFromController();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      platform.readPosition = null;
      expect(reads, greaterThanOrEqualTo(2));
      expect(platform.seekCounts[1], seeks);
      expect(service.position, const Duration(seconds: 8));
    },
  );

  for (final action in ['seek-zero', 'pause', 'replace']) {
    test('late runtime zero verification cannot override $action', () async {
      final fixture = await _startQualityFixture(isolatedService: true);
      final service = fixture.service;
      final platform = fixture.platform;
      await _primeRuntimeClock(service, platform);
      final pending = Completer<Duration>();
      final requested = Completer<void>();
      var reads = 0;
      platform.readPosition = (_) {
        reads++;
        if (!requested.isCompleted) requested.complete();
        return pending.future;
      };
      final oldController = service.controller!;
      oldController.value = oldController.value.copyWith(
        position: Duration.zero,
      );
      service.updatePlaybackStateFromController();
      await requested.future.timeout(const Duration(seconds: 1));
      service.updatePlaybackStateFromController();
      service.updatePlaybackStateFromController();
      expect(reads, 1, reason: 'Concurrent zero samples share one clock check');
      platform.readPosition = null;
      if (action == 'seek-zero') {
        await service.seekTo(Duration.zero);
      } else if (action == 'pause') {
        await service.pause();
      } else {
        final next = service.play(
          _streamItem(id: 'next-zero-check', cid: 2002),
          autoPlay: false,
        );
        await _waitForPlayerId(platform, 2);
        platform.initializePlayer(2);
        await next;
      }
      final expectedPosition = service.position;
      final seeks = Map<int, int>.from(platform.seekCounts);
      pending.complete(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        platform.seekCounts,
        seeks,
        reason: 'An obsolete check cannot issue a corrective seek',
      );
      expect(service.position, expectedPosition);
      if (action != 'seek-zero') expect(service.state, PlaybackState.paused);
    });
  }

  test(
    'an unavailable fresh clock does not authorize runtime recovery',
    () async {
      final fixture = await _startQualityFixture(isolatedService: true);
      final service = fixture.service;
      final platform = fixture.platform;
      await _primeRuntimeClock(service, platform);
      final seeks = platform.seekCounts[1];
      final pending = Completer<Duration>();
      final requested = Completer<void>();
      platform.readPosition = (_) {
        if (!requested.isCompleted) {
          requested.complete();
          return pending.future;
        }
        // The video_player polling timer is independent of the service's
        // one fresh-clock request. Only that verification read should fail.
        return Future.value(const Duration(seconds: 8));
      };
      final controller = service.controller!;
      controller.value = controller.value.copyWith(position: Duration.zero);
      service.updatePlaybackStateFromController();
      await requested.future.timeout(const Duration(seconds: 1));
      platform.readPosition = null;
      pending.completeError(StateError('transport clock unavailable'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(platform.seekCounts[1], seeks);
      expect(service.position, const Duration(seconds: 8));
    },
  );

  for (final initialSize in [Size.zero, const Size(1920, 0)]) {
    test(
      'Bilibili initialization without video dimensions never inserts a square frame ($initialSize)',
      () async {
        final fixture = await _startQualityFixture(initializePlayback: false);
        fixture.api.dimensionsByCid[456] = Size.zero;
        final service = fixture.service;
        final item = _streamItem();
        final opening = service.play(item, autoPlay: false);
        await _waitForPlayerId(fixture.platform, 1);
        fixture.platform.initializePlayer(1, size: initialSize);
        await opening;
        final controller = service.controller!;
        expect(service.canMountControllerFor(item.id), isTrue);
        service.bilibiliStartup!.geometry.reportCover(1);
        expect(
          service.bilibiliVideoAspectRatioFor(item.id, controller: controller),
          isNull,
          reason: 'An audio-only/probe initialization has no video size yet',
        );
        controller.value = controller.value.copyWith(
          size: const Size(1920, 1080),
        );
        expect(
          service.bilibiliVideoAspectRatioFor(item.id, controller: controller),
          16 / 9,
        );
      },
    );
  }

  for (final warmed in [false, true]) {
    test(
      'Bilibili entry cannot adopt the previous square local controller on a repeated play (warmed=$warmed)',
      () async {
        final fixture = await _startQualityFixture(initializePlayback: false);
        final service = fixture.service;
        final root = await Directory.systemTemp.createTemp(
          'bilibili_local_ratio_',
        );
        addTearDown(() => root.delete(recursive: true));
        final file = await File('${root.path}/square.mp4').writeAsBytes([0]);
        final local = VideoItem(
          id: 'square-local-before-bilibili',
          path: file.path,
          title: 'Square local video',
          durationMs: 120000,
          lastUpdated: 0,
          portraitDisplayAspectRatio: 1,
          hasPortraitAspectPreferenceInitialized: true,
        );
        final localPlay = service.play(local, autoPlay: false);
        await _waitForPlayerId(fixture.platform, 1);
        fixture.platform.initializePlayer(1);
        await localPlay;
        final previousController = service.controller!;
        previousController.value = previousController.value.copyWith(
          size: const Size(1080, 1080),
        );

        final target = _streamItem(id: 'watch-after-square', cid: 2002)
          ..isTransient = true;
        if (warmed) await fixture.streaming.listQualities(target);
        final ratios = <double?>[];
        final previousControllerMountable = <bool>[];
        Future<void>? repeatedPlay;
        var reentered = false;
        void onChange() {
          if (service.currentItem?.id != target.id) return;
          ratios.add(
            service.bilibiliVideoAspectRatioFor(
              target.id,
              controller: previousController,
            ),
          );
          previousControllerMountable.add(
            service.canMountControllerFor(
              target.id,
              controller: previousController,
            ),
          );
          if (!reentered) {
            reentered = true;
            // Entry/page notifications can request playback again after the
            // target metadata is published but before the old player retires.
            repeatedPlay = service.play(target, autoPlay: false);
          }
        }

        service.addListener(onChange);
        addTearDown(() => service.removeListener(onChange));
        final opening = service.play(target, autoPlay: false);
        expect(reentered, isTrue);
        expect(
          ratios,
          isNot(contains(1.0)),
          reason: 'A new online item must never use the old local video size',
        );
        expect(previousControllerMountable, everyElement(isFalse));
        await _waitForPlayerId(fixture.platform, 2);
        fixture.platform.initializePlayer(2);
        await Future.wait([opening, repeatedPlay!]);
        expect(service.bilibiliVideoAspectRatioFor(target.id), 16 / 9);
        expect(service.controller, isNot(same(previousController)));
        expect(local.portraitDisplayAspectRatio, 1);
      },
    );
  }

  for (final portraitFirst in [true, false]) {
    for (final warmed in [false, true]) {
      test(
        'aspect ratio belongs to the new video: portraitFirst=$portraitFirst, warmed=$warmed',
        () async {
          final fixture = await _startQualityFixture(initializePlayback: false);
          final service = fixture.service;
          final firstSize = portraitFirst
              ? const Size(1080, 1920)
              : const Size(1920, 1080);
          final nextSize = portraitFirst
              ? const Size(1920, 1080)
              : const Size(1080, 1920);
          fixture.api.dimensionsByCid[2001] = firstSize;
          fixture.api.dimensionsByCid[2002] = nextSize;
          final firstItem = _streamItem(id: 'geometry-first', cid: 2001);
          final nextItem = _streamItem(id: 'geometry-next', cid: 2002);
          final first = service.play(firstItem, autoPlay: false);
          await _waitForPlayerId(fixture.platform, 1);
          fixture.platform.initializePlayer(1);
          await first;
          final previousController = service.controller!;
          final previousStartup = service.bilibiliStartup!;
          expect(service.streamDisplayAspectRatio, firstSize.aspectRatio);
          if (warmed) await fixture.streaming.listQualities(nextItem);
          final requested = Completer<void>();
          final address = Completer<void>();
          fixture.api.beforeFetch = (cid) async {
            if (cid == 2002) {
              requested.complete();
              await address.future;
            }
          };
          final samples = <double?>[];
          void sample() {
            if (service.currentItem?.id == nextItem.id) {
              samples.add(
                service.bilibiliVideoAspectRatioFor(
                  nextItem.id,
                  controller: previousController,
                ),
              );
            }
          }

          service.addListener(sample);
          addTearDown(() => service.removeListener(sample));
          final next = service.play(nextItem, autoPlay: false);
          expect(
            service.streamDisplayAspectRatio,
            isNull,
            reason:
                'Old DASH dimensions must be cleared before the first notification',
          );
          expect(samples, isNotEmpty);
          expect(samples.first, warmed ? nextSize.aspectRatio : isNull);
          if (!warmed) {
            await requested.future;
            service.bilibiliStartup!.geometry.reportCover(1);
            expect(
              service.bilibiliVideoAspectRatioFor(
                nextItem.id,
                controller: previousController,
              ),
              isNull,
              reason:
                  'Neither the old controller nor a square cover describes the new video',
            );
            previousStartup.geometry.reportCover(9 / 16);
            expect(
              service.bilibiliVideoAspectRatioFor(
                nextItem.id,
                controller: previousController,
              ),
              isNull,
            );
          }
          address.complete();
          await _waitForPlayerId(fixture.platform, 2);
          fixture.platform.initializePlayer(2);
          await next;
          expect(service.streamDisplayAspectRatio, nextSize.aspectRatio);
          expect(
            service.bilibiliVideoAspectRatioFor(nextItem.id),
            nextSize.aspectRatio,
          );
        },
      );
    }
  }

  for (final autoPlay in [true, false]) {
    test(
      'resume recovers a parked decoder without a user progress-bar seek (autoPlay=$autoPlay)',
      () async {
        final fixture = await _startQualityFixture(initializePlayback: false);
        final service = fixture.service;
        final owner = Object();
        service.setPlaybackPageVisible(owner, true);
        final targetFrame = Completer<void>();
        var frameChecks = 0;
        service.debugBilibiliFrameReadiness = (_, _) {
          frameChecks++;
          return targetFrame.future;
        };
        fixture.platform.onSeek = (playerId, position) {
          expect(position, const Duration(seconds: 23));
          expect(fixture.platform._playing[playerId], isFalse);
          // The first seek acknowledges its time but produces no picture. A
          // second exact seek is what used to require a click on the timeline.
          if ((fixture.platform.seekCounts[playerId] ?? 0) >= 2 &&
              !targetFrame.isCompleted) {
            targetFrame.complete();
          }
        };
        final startup = BilibiliStartupContext(
          limit: const Duration(milliseconds: 1800),
        );
        service.prepareBilibiliStartup(_streamItem().id, startup);
        addTearDown(() {
          service.debugBilibiliFrameReadiness = null;
          service.setPlaybackPageVisible(owner, false);
        });
        final opening = service.play(
          _streamItem(),
          autoPlay: autoPlay,
          startPosition: const Duration(seconds: 23),
        );
        await _waitForPlayerId(fixture.platform, 1);
        fixture.platform.initializePlayer(1);
        await opening;
        expect(
          service.state,
          autoPlay ? PlaybackState.playing : PlaybackState.paused,
          reason:
              'A usable stream must recover without a manual timeline click',
        );
        expect(startup.isReady, isTrue);
        expect(service.isCoveringUntilVisibleVideoFrame, isFalse);
        expect(fixture.platform.seekCounts[1], 2);
        expect(
          frameChecks,
          greaterThanOrEqualTo(2),
          reason: 'Recheck the target frame after the recovery seek',
        );
        expect(fixture.platform.playerIds, [1]);
        expect(fixture.api.playUrlCalls, 1);
      },
    );
  }

  test(
    'play, pause and seek during loading preserve the latest intent without early audio',
    () async {
      final fixture = await _startQualityFixture(initializePlayback: false);
      final service = fixture.service;
      final owner = Object();
      service.setPlaybackPageVisible(owner, true);
      final frame = Completer<void>();
      service.debugBilibiliFrameReadiness = (_, _) => frame.future;
      addTearDown(() {
        service.debugBilibiliFrameReadiness = null;
        service.setPlaybackPageVisible(owner, false);
      });
      final opening = service.play(
        _streamItem(),
        autoPlay: false,
        startPosition: const Duration(seconds: 23),
      );
      await service.seekTo(const Duration(seconds: 50));
      await _waitForPlayerId(fixture.platform, 1);
      fixture.platform.initializePlayer(1);
      while (service.bilibiliStartup?.phase !=
          BilibiliStartupPhase.waitingForFrame) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(service.position, const Duration(seconds: 50));
      service.controller!.value = service.controller!.value.copyWith(
        position: Duration.zero,
        duration: const Duration(seconds: 3),
      );
      await service.seekTo(const Duration(seconds: 70));
      expect(service.duration, const Duration(minutes: 2));
      await service.resume();
      expect(fixture.platform._playing[1], isFalse);
      await service.pause();
      await service.resume();
      expect(fixture.platform._playing[1], isFalse);
      expect(service.bilibiliStartup!.target, const Duration(seconds: 70));
      expect(
        service.positionForProgressChrome(Duration.zero),
        const Duration(seconds: 70),
      );
      frame.complete();
      await opening;
      expect(service.state, PlaybackState.playing);
      expect(fixture.platform._playing[1], isTrue);
      expect(service.position.inMilliseconds, inInclusiveRange(70000, 70450));
    },
  );

  test(
    'startup holds its bookmark and cover until a paused target frame arrives',
    () async {
      final fixture = await _startQualityFixture(initializePlayback: false);
      final service = fixture.service;
      final owner = Object();
      service.setPlaybackPageVisible(owner, true);
      final frame = Completer<void>();
      service.debugBilibiliFrameReadiness = (_, _) => frame.future;
      addTearDown(() {
        service.debugBilibiliFrameReadiness = null;
        service.setPlaybackPageVisible(owner, false);
      });
      final play = service.play(
        _streamItem(),
        autoPlay: false,
        startPosition: const Duration(seconds: 23),
      );
      await _waitForPlayerId(fixture.platform, 1);
      fixture.platform.initializePlayer(1);
      for (
        var i = 0;
        i < 200 &&
            service.bilibiliStartup?.phase !=
                BilibiliStartupPhase.waitingForFrame;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        service.bilibiliStartup!.phase,
        BilibiliStartupPhase.waitingForFrame,
      );
      expect(service.hasMountableController, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(service.isCoveringUntilVisibleVideoFrame, isTrue);
      expect(
        service.positionForProgressChrome(Duration.zero),
        const Duration(seconds: 23),
      );
      expect(service.position, const Duration(seconds: 23));
      expect(
        fixture.platform._playing[1],
        isFalse,
        reason: 'No audio before the target frame',
      );
      frame.complete();
      await play;
      expect(service.state, PlaybackState.paused);
      expect(service.isCoveringUntilVisibleVideoFrame, isFalse);
      expect(
        service.positionForProgressChrome(Duration.zero),
        const Duration(seconds: 23),
      );
    },
  );

  test(
    'a late frame from abandoned startup cannot uncover its replacement',
    () async {
      final fixture = await _startQualityFixture(initializePlayback: false);
      final service = fixture.service;
      final owner = Object();
      service.setPlaybackPageVisible(owner, true);
      final firstFrame = Completer<void>();
      var frames = 0;
      service.debugBilibiliFrameReadiness = (_, _) =>
          ++frames == 1 ? firstFrame.future : Future.value();
      addTearDown(() {
        service.debugBilibiliFrameReadiness = null;
        service.setPlaybackPageVisible(owner, false);
      });
      final first = service.play(
        _streamItem(),
        startPosition: const Duration(seconds: 23),
      );
      await _waitForPlayerId(fixture.platform, 1);
      fixture.platform.initializePlayer(1);
      while (frames == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final old = service.bilibiliStartup!;
      final next = _streamItem(id: 'replacement-startup', cid: 789);
      final second = service.play(
        next,
        autoPlay: false,
        startPosition: const Duration(seconds: 42),
      );
      await _waitForPlayerId(fixture.platform, 2);
      fixture.platform.initializePlayer(2);
      await Future.wait([first, second]);
      firstFrame.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(old.isCancelled, isTrue);
      expect(service.currentItem!.id, next.id);
      expect(service.position, const Duration(seconds: 42));
      expect(service.isCoveringUntilVisibleVideoFrame, isFalse);
      expect(fixture.streaming.activePlaybackSessionCount, 1);
    },
  );

  test('startup deadline retains bookmark and paused retry intent', () async {
    final fixture = await _startQualityFixture(initializePlayback: false);
    final service = fixture.service;
    final owner = Object();
    service.setPlaybackPageVisible(owner, true);
    service.debugBilibiliFrameReadiness = (_, _) => Completer<void>().future;
    final context = BilibiliStartupContext(
      limit: const Duration(milliseconds: 250),
    );
    service.prepareBilibiliStartup(_streamItem().id, context);
    addTearDown(() {
      service.debugBilibiliFrameReadiness = null;
      service.setPlaybackPageVisible(owner, false);
    });
    final play = service.play(
      _streamItem(),
      autoPlay: false,
      startPosition: const Duration(seconds: 23),
    );
    await _waitForPlayerId(fixture.platform, 1);
    fixture.platform.initializePlayer(1);
    await play;
    expect(context.hasFailed, isTrue);
    expect(service.state, PlaybackState.error);
    expect(service.position, const Duration(seconds: 23));
    expect(service.isCoveringUntilVisibleVideoFrame, isTrue);
    expect(fixture.streaming.activePlaybackSessionCount, 0);
    service.debugBilibiliFrameReadiness = (_, _) => Future.value();
    final retry = service.retryBilibiliStartup();
    await _waitForPlayerId(fixture.platform, 2);
    fixture.platform.initializePlayer(2);
    await retry;
    expect(service.state, PlaybackState.paused);
    expect(service.position, const Duration(seconds: 23));
  });

  test(
    'system notifications keep a pending Bilibili startup and its frame wait',
    () async {
      final network = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await network.ready;
      await network.setMode(NetworkScope.bilibili, NetworkMode.system);
      final fixture = await _startQualityFixture(
        network: network,
        initializePlayback: false,
      );
      final service = fixture.service;
      final owner = Object();
      service.setPlaybackPageVisible(owner, true);
      final startup = BilibiliStartupContext();
      final frame = Completer<void>();
      service.debugBilibiliFrameReadiness = (_, _) => frame.future;
      service.prepareBilibiliStartup(_streamItem().id, startup);
      addTearDown(() {
        if (!frame.isCompleted) frame.complete();
        service.debugBilibiliFrameReadiness = null;
        service.setPlaybackPageVisible(owner, false);
      });
      final opening = service.play(
        _streamItem(),
        autoPlay: false,
        startPosition: const Duration(seconds: 23),
      );
      await _waitForPlayerId(fixture.platform, 1);
      fixture.platform.initializePlayer(1);
      for (
        var i = 0;
        i < 200 && startup.phase != BilibiliStartupPhase.waitingForFrame;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(startup.phase, BilibiliStartupPhase.waitingForFrame);
      final calls = fixture.api.playUrlCalls;
      for (var i = 0; i < 100; i++) {
        network.deviceNetworkChanged();
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(service.bilibiliStartup, same(startup));
      expect(startup.isCancelled, isFalse);
      expect(fixture.platform.playerIds, [1]);
      expect(fixture.api.playUrlCalls, calls);
      frame.complete();
      await opening;
      expect(service.state, PlaybackState.paused);
      expect(service.position, const Duration(seconds: 23));
    },
  );

  test(
    'network change during frame preparation preserves the original deadline and intent',
    () async {
      final network = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await network.ready;
      final fixture = await _startQualityFixture(
        network: network,
        initializePlayback: false,
      );
      final service = fixture.service;
      final owner = Object();
      service.setPlaybackPageVisible(owner, true);
      var elapsed = Duration.zero;
      final original = BilibiliStartupContext(elapsed: () => elapsed);
      final firstFrame = Completer<void>();
      service.debugBilibiliFrameReadiness = (_, startup) =>
          identical(startup, original) ? firstFrame.future : Future.value();
      service.prepareBilibiliStartup(_streamItem().id, original);
      addTearDown(() {
        service.debugBilibiliFrameReadiness = null;
        service.setPlaybackPageVisible(owner, false);
      });
      final first = service.play(
        _streamItem(),
        autoPlay: false,
        startPosition: const Duration(seconds: 23),
      );
      await _waitForPlayerId(fixture.platform, 1);
      fixture.platform.initializePlayer(1);
      for (
        var i = 0;
        i < 200 && original.phase != BilibiliStartupPhase.waitingForFrame;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(original.phase, BilibiliStartupPhase.waitingForFrame);
      elapsed = const Duration(seconds: 20);
      await network.setMode(NetworkScope.bilibili, NetworkMode.system);
      await _waitForPlayerId(fixture.platform, 2);
      fixture.platform.initializePlayer(2);
      for (
        var i = 0;
        i < 200 && service.bilibiliStartup?.isReady != true;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await first;
      firstFrame.complete();
      expect(original.isCancelled, isTrue);
      expect(service.bilibiliStartup!.remaining, const Duration(seconds: 10));
      expect(service.bilibiliStartup!.desiredPlaying, isFalse);
      expect(service.state, PlaybackState.paused);
      expect(service.position, const Duration(seconds: 23));
      expect(service.selectedStreamQuality!.id, 80);
    },
  );

  test(
    'network switch retains a healthy paused player, position, quality and speed',
    () async {
      final network = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await network.ready;
      final fixture = await _startQualityFixture(network: network);
      await fixture.service.pause();
      await fixture.service.setPlaybackSpeed(2);
      final calls = fixture.api.playUrlCalls;
      await network.setMode(NetworkScope.bilibili, NetworkMode.system);
      expect(fixture.api.playUrlCalls, calls);
      expect(fixture.service.controller!.playerId, 1);
      expect(fixture.service.isSwitchingStreamQuality, isFalse);
      expect(fixture.service.state, PlaybackState.paused);
      expect(fixture.service.position.inMilliseconds, closeTo(24000, 500));
      expect(fixture.service.selectedStreamQuality?.id, 80);
      expect(fixture.service.playbackSpeed, 2);
    },
  );

  test(
    'rapid network changes preserve a valid quality handoff without a busy-state deadlock',
    () async {
      final network = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await network.ready;
      final fixture = await _startQualityFixture(network: network);
      await fixture.service.pause();
      final oldSwitch = fixture.service.switchBilibiliStreamQuality(64);
      await _waitForPlayerId(fixture.platform, 2);
      await network.setMode(NetworkScope.bilibili, NetworkMode.system);
      await network.setMode(NetworkScope.bilibili, NetworkMode.direct);
      fixture.platform.initializePlayer(2);
      expect(await oldSwitch, isTrue);
      await _waitForPlayerCount(fixture.platform, 1);
      expect(fixture.service.isSwitchingStreamQuality, isFalse);
      expect(fixture.service.controller!.playerId, 2);
      expect(fixture.service.state, PlaybackState.paused);
      expect(fixture.platform.disposedPlayerIds, contains(1));
      expect(fixture.platform.disposedPlayerIds, isNot(contains(2)));
      expect(fixture.service.selectedStreamQuality?.id, 64);
      expect(fixture.service.position.inMilliseconds, closeTo(24000, 500));
    },
  );

  test(
    'quality switch keeps the old player until the warm player is ready',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final streaming = BilibiliStreamingService(_QualityApiService());
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
      });

      final initialPlay = service.play(_streamItem());
      await _waitForPlayerCount(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;
      await service.seekTo(const Duration(seconds: 24));
      platform.seekDelays[2] = const Duration(milliseconds: 90);

      final qualitySwitch = service.switchBilibiliStreamQuality(64);
      await _waitForPlayerCount(platform, 2);

      expect(service.controller!.playerId, 1);
      expect(service.state, PlaybackState.playing);
      expect(service.position, const Duration(seconds: 24));
      expect(service.selectedStreamQuality?.id, 80);
      expect(platform.disposedPlayerIds, isNot(contains(1)));

      platform.initializePlayer(2);
      final switched = await qualitySwitch;

      expect(switched, isTrue);
      expect(service.controller!.playerId, 2);
      expect(service.state, PlaybackState.playing);
      expect(service.position.inMilliseconds, closeTo(24000, 500));
      expect(service.selectedStreamQuality?.id, 64);
      expect(service.isSwitchingStreamQuality, isFalse);
      expect(platform.volumeCalls, contains((playerId: 2, volume: 0.0)));
      expect(platform.volumeCalls, contains((playerId: 2, volume: 1.0)));
      expect(
        platform.seekCounts[2],
        1,
        reason: 'the replacement must not seek after its warm frame',
      );
      final oldPausePosition = platform.lastPausePositions[1]!;
      final newUnmutePosition = platform.volumeCallPositions
          .lastWhere((call) => call.playerId == 2 && call.volume == 1.0)
          .position;
      expect(
        (newUnmutePosition.inMilliseconds - oldPausePosition.inMilliseconds)
            .abs(),
        lessThanOrEqualTo(90),
      );
      await _waitForPlayerCount(platform, 1);
      expect(platform.playerIds, <int>[2]);

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt('bilibili_stream_preferred_quality'), 64);
    },
  );

  test('paused quality switch stays paused at the same position', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _HandoffVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final streaming = BilibiliStreamingService(_QualityApiService());
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
      bilibiliStreamingService: streaming,
    );

    addTearDown(() async {
      await service.stop();
      await streaming.shutdown();
      VideoPlayerPlatform.instance = originalPlatform;
    });

    final initialPlay = service.play(_streamItem());
    await _waitForPlayerCount(platform, 1);
    platform.initializePlayer(1);
    await initialPlay;
    await service.seekTo(const Duration(seconds: 41));
    await service.pause();

    final qualitySwitch = service.switchBilibiliStreamQuality(64);
    await _waitForPlayerCount(platform, 2);
    platform.initializePlayer(2);
    final switched = await qualitySwitch;

    expect(switched, isTrue);
    expect(service.controller!.playerId, 2);
    expect(service.state, PlaybackState.paused);
    expect(service.controller!.value.isPlaying, isFalse);
    expect(service.position.inMilliseconds, closeTo(41000, 500));
    expect(service.selectedStreamQuality?.id, 64);
    await _waitForPlayerCount(platform, 1);
    expect(platform.playerIds, <int>[2]);
  });

  test('a newer playback request cancels a pending quality hand-off', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _HandoffVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final streaming = BilibiliStreamingService(_QualityApiService());
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
      bilibiliStreamingService: streaming,
    );

    addTearDown(() async {
      await service.stop();
      await streaming.shutdown();
      VideoPlayerPlatform.instance = originalPlatform;
    });

    final initialPlay = service.play(_streamItem());
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await initialPlay;

    final qualitySwitch = service.switchBilibiliStreamQuality(64);
    await _waitForPlayerId(platform, 2);

    final newerItem = _streamItem(id: 'newer-stream-item');
    final newerPlay = service.play(newerItem);
    await _waitForPlayerId(platform, 3);
    platform.initializePlayer(3);
    await newerPlay;

    platform.initializePlayer(2);
    final switched = await qualitySwitch;

    expect(switched, isFalse);
    expect(service.currentItem?.id, newerItem.id);
    expect(service.controller!.playerId, 3);
    expect(service.state, PlaybackState.playing);
    expect(service.selectedStreamQuality?.id, 80);
    expect(service.isSwitchingStreamQuality, isFalse);
    expect(platform.disposedPlayerIds, contains(2));
  });

  test(
    'failed warm player preserves the active quality and playback',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final streaming = BilibiliStreamingService(_QualityApiService());
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
      });

      final initialPlay = service.play(_streamItem());
      await _waitForPlayerCount(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;

      final qualitySwitch = service.switchBilibiliStreamQuality(64);
      await _waitForPlayerCount(platform, 2);
      platform.failPlayer(2);
      await _waitForPlayerId(platform, 3);
      platform.failPlayer(3);
      final switched = await qualitySwitch;

      expect(switched, isFalse);
      expect(service.controller!.playerId, 1);
      expect(service.state, PlaybackState.playing);
      expect(service.selectedStreamQuality?.id, 80);
      expect(service.isSwitchingStreamQuality, isFalse);
      expect(platform.disposedPlayerIds, contains(2));
      expect(platform.disposedPlayerIds, contains(3));
      expect(platform.disposedPlayerIds, isNot(contains(1)));

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getInt('bilibili_stream_preferred_quality'),
        isNot(64),
      );
    },
  );

  test('quality switch waits for delayed native seek feedback', () async {
    final fixture = await _startQualityFixture();
    final service = fixture.service;
    final platform = fixture.platform;
    platform.seekFeedbackDelays[2] = const Duration(milliseconds: 300);
    final qualitySwitch = service.switchBilibiliStreamQuality(64);
    await _waitForPlayerId(platform, 2);
    platform.initializePlayer(2);

    expect(await qualitySwitch, isTrue);
    expect(service.controller!.playerId, 2);
    expect(platform.seekCounts[2], 1);
    expect(fixture.api.playUrlCalls, 1);
  });

  test(
    'quality switch retries a failed initialization with fresh URLs',
    () async {
      final fixture = await _startQualityFixture();
      final service = fixture.service;
      final platform = fixture.platform;
      final initialCalls = fixture.api.playUrlCalls;
      final qualitySwitch = service.switchBilibiliStreamQuality(64);
      await _waitForPlayerId(platform, 2);
      platform.failPlayer(2);
      await _waitForPlayerId(platform, 3);

      expect(service.controller!.playerId, 1);
      expect(service.selectedStreamQuality?.id, 80);
      expect(service.state, PlaybackState.playing);
      expect(fixture.api.playUrlCalls, initialCalls + 1);
      expect(platform.disposedPlayerIds, contains(2));
      expect(fixture.streaming.activePlaybackSessionCount, 2);

      platform.initializePlayer(3);
      expect(await qualitySwitch, isTrue);
      expect(service.controller!.playerId, 3);
      expect(service.selectedStreamQuality?.id, 64);
      await _waitForPlayerCount(platform, 1);
      expect(fixture.streaming.activePlaybackSessionCount, 1);
    },
  );

  test('quality switch retries an error after initialization', () async {
    final fixture = await _startQualityFixture();
    final service = fixture.service;
    final platform = fixture.platform;
    final qualitySwitch = service.switchBilibiliStreamQuality(64);
    await _waitForPlayerId(platform, 2);
    platform.initializePlayer(2);
    platform.setBuffering(2, true);
    while (!platform.volumeCalls.contains((playerId: 2, volume: 0.0))) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    platform.failPlayer(2);
    await _waitForPlayerId(platform, 3);
    expect(service.controller!.playerId, 1);
    platform.initializePlayer(3);

    expect(await qualitySwitch, isTrue);
    expect(service.selectedStreamQuality?.id, 64);
    expect(platform.disposedPlayerIds, contains(2));
  });

  test(
    'a silent initialization times out and retries without stopping playback',
    () async {
      final fixture = await _startQualityFixture();
      final service = fixture.service;
      final platform = fixture.platform;
      final qualitySwitch = service.switchBilibiliStreamQuality(64);
      await _waitForPlayerId(platform, 2);
      // Candidate 2 never emits initialized or error.
      await _waitForPlayerId(platform, 3, timeout: const Duration(seconds: 25));
      expect(service.controller!.playerId, 1);
      expect(service.state, PlaybackState.playing);
      expect(service.selectedStreamQuality?.id, 80);
      platform.initializePlayer(3);
      expect(await qualitySwitch, isTrue);
      expect(platform.disposedPlayerIds, contains(2));
    },
  );

  test(
    'a candidate with no decoded progress is retried instead of committed',
    () async {
      final fixture = await _startQualityFixture();
      final service = fixture.service;
      final platform = fixture.platform;
      final qualitySwitch = service.switchBilibiliStreamQuality(64);
      await _waitForPlayerId(platform, 2);
      platform.frozenPlayers.add(2);
      platform.initializePlayer(2);
      await _waitForPlayerId(platform, 3, timeout: const Duration(seconds: 12));
      expect(service.controller!.playerId, 1);
      expect(service.state, PlaybackState.playing);
      platform.initializePlayer(3);
      expect(await qualitySwitch, isTrue);
      expect(service.selectedStreamQuality?.id, 64);
    },
  );

  for (final command in ['pause', 'seek', 'speed']) {
    test('quality switch honors $command during synchronization', () async {
      final fixture = await _startQualityFixture();
      final service = fixture.service;
      final platform = fixture.platform;
      platform.seekDelays[2] = const Duration(milliseconds: 350);
      var issuedCommand = false;
      Future<void>? commandFuture;
      platform.onPlaybackSpeed = (playerId, speed) {
        if (playerId != 2 || speed <= 1 || issuedCommand) return;
        issuedCommand = true;
        commandFuture = switch (command) {
          'pause' => service.pause(),
          'seek' => service.seekTo(const Duration(seconds: 60)),
          _ => service.setPlaybackSpeed(2.0),
        };
      };
      final qualitySwitch = service.switchBilibiliStreamQuality(64);
      await _waitForPlayerId(platform, 2);
      platform.initializePlayer(2);

      expect(await qualitySwitch, isTrue);
      expect(issuedCommand, isTrue);
      await commandFuture;
      expect(service.controller!.playerId, 2);
      expect(service.selectedStreamQuality?.id, 64);
      expect(fixture.api.playUrlCalls, 1);
      if (command == 'pause') {
        expect(service.state, PlaybackState.paused);
        expect(service.controller!.value.isPlaying, isFalse);
      } else {
        expect(service.state, PlaybackState.playing);
        final actual = await platform.getPosition(2);
        if (command == 'seek') {
          expect(actual.inMilliseconds, closeTo(60000, 1600));
        } else {
          expect(service.controller!.value.playbackSpeed, 2.0);
        }
      }
    });
  }

  test(
    'background episode switches keep settings across Bilibili and local media',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final streaming = BilibiliStreamingService(_QualityApiService());
      final tempDir = await Directory.systemTemp.createTemp(
        'bilibili_mixed_episode_switch_',
      );
      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}local.mp4',
      );
      await localFile.writeAsBytes(<int>[0]);
      final items = <VideoItem>[
        _streamItem(id: 'online-1', cid: 101, lastPositionMs: 7000),
        _streamItem(id: 'online-2', cid: 102, lastPositionMs: 19000),
        VideoItem(
          id: 'local-3',
          path: localFile.path,
          title: 'Local episode',
          durationMs: 120000,
          lastPositionMs: 31000,
          lastUpdated: 0,
        ),
      ];
      final settings = SettingsService();
      final originalAutoPlay = settings.autoPlayNextVideo;
      settings.autoPlayNextVideo = false;
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager()..setPlaylist(items),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        settings.autoPlayNextVideo = originalAutoPlay;
        service.setAppForegroundState(true);
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final initialPlay = service.play(items.first, autoPlay: false);
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;
      service.setAppForegroundState(false);

      final onlineToOnline = service.playNext();
      await _waitForPlayerId(platform, 2);
      platform.initializePlayer(2);
      await onlineToOnline;
      expect(service.currentItem?.id, 'online-2');
      expect(service.position, const Duration(seconds: 19));
      expect(service.state, PlaybackState.paused);
      expect(service.desiredPlaying, isFalse);

      await service.resume();
      expect(service.state, PlaybackState.playing);
      settings.autoPlayNextVideo = true;

      final onlineToLocal = service.playNext();
      await _waitForPlayerId(platform, 3);
      platform.initializePlayer(3);
      await onlineToLocal;
      expect(service.currentItem?.id, 'local-3');
      expect(service.position, const Duration(seconds: 31));
      expect(service.state, PlaybackState.playing);
      expect(service.desiredPlaying, isTrue);

      final localToOnline = service.playPrevious();
      await _waitForPlayerId(platform, 4);
      platform.initializePlayer(4);
      await localToOnline;
      expect(service.currentItem?.id, 'online-2');
      expect(service.position, const Duration(seconds: 19));
      expect(service.state, PlaybackState.playing);
      expect(service.desiredPlaying, isTrue);
    },
  );

  test(
    'Bilibili completion resumes saved progress or restarts from zero by setting',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final streaming = BilibiliStreamingService(_QualityApiService());
      final items = <VideoItem>[
        _streamItem(id: 'completion-online-1', cid: 201),
        _streamItem(id: 'completion-online-2', cid: 202, lastPositionMs: 23000),
      ];
      final settings = SettingsService();
      final originalAutoPlay = settings.autoPlayNextVideo;
      final originalCompletion = settings.autoPlayOnCompletion;
      final originalFromStart = settings.autoPlayOnCompletionFromStart;
      final originalWrap = settings.playlistWrapToFirst;
      settings.autoPlayNextVideo = false;
      settings.autoPlayOnCompletion = true;
      settings.autoPlayOnCompletionFromStart = false;
      // The second completion returns to the first item only with list wrap.
      settings.playlistWrapToFirst = true;
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager()..setPlaylist(items),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        settings.autoPlayNextVideo = originalAutoPlay;
        settings.autoPlayOnCompletion = originalCompletion;
        settings.autoPlayOnCompletionFromStart = originalFromStart;
        settings.playlistWrapToFirst = originalWrap;
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
      });

      final initialPlay = service.play(items.first);
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;
      var controller = service.controller!;
      platform._positions[1] = const Duration(minutes: 2);
      controller.value = controller.value.copyWith(
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 2),
        isPlaying: false,
      );

      await _waitForPlayerId(platform, 2);
      platform.initializePlayer(2);
      for (
        var i = 0;
        i < 300 &&
            (service.currentItem?.id != items[1].id ||
                service.state != PlaybackState.playing ||
                service.position != const Duration(seconds: 23));
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(service.currentItem?.id, items[1].id);
      expect(service.position, const Duration(seconds: 23));
      expect(service.state, PlaybackState.playing);

      settings.autoPlayOnCompletionFromStart = true;
      controller = service.controller!;
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 23),
        duration: const Duration(minutes: 2),
        isPlaying: true,
      );
      service.updatePlaybackStateFromController(
        expectedItemId: items[1].id,
        expectedController: controller,
      );
      platform._positions[2] = const Duration(minutes: 2);
      controller.value = controller.value.copyWith(
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 2),
        isPlaying: false,
      );

      await _waitForPlayerId(platform, 3);
      platform.initializePlayer(3);
      for (
        var i = 0;
        i < 300 &&
            (service.currentItem?.id != items.first.id ||
                service.state != PlaybackState.playing);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(service.currentItem?.id, items.first.id);
      expect(service.position, Duration.zero);
      expect(service.state, PlaybackState.playing);
    },
  );

  test(
    'superseded Bilibili preparation releases its gateway session',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final api = _DelayedQualityApiService();
      final streaming = BilibiliStreamingService(api);
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        for (final blocker in api.blockers.values) {
          if (!blocker.isCompleted) blocker.complete();
        }
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
      });

      final firstItem = _streamItem(id: 'superseded-online', cid: 301);
      final secondItem = _streamItem(id: 'committed-online', cid: 302);
      final firstPlay = service.play(firstItem, autoPlay: false);
      await _waitForRequestedCid(api, 301);

      final secondPlay = service.play(secondItem, autoPlay: false);
      await _waitForRequestedCid(api, 302);
      api.blockers[302]!.complete();
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await secondPlay;

      api.blockers[301]!.complete();
      await firstPlay;
      expect(service.currentItem?.id, secondItem.id);
      expect(streaming.activePlaybackSessionCount, 1);

      await service.stop();
      expect(streaming.activePlaybackSessionCount, 0);
    },
  );

  test(
    'quality switch skips the conservative 2s cache-pause on the warm player',
    () {
      final playback = File(
        'lib/services/media_playback_service.dart',
      ).readAsStringSync();
      expect(playback, contains('fastStart: true'));
      expect(
        playback,
        contains('NativeVideoPlayerMediaKit.fastStreamStartHeader'),
      );
      // Cold first-play stays conservative unless reusable `.seg` cache exists.
      expect(playback, contains('_shouldFastStartCachedBilibiliStream(item)'));
      expect(playback, contains('fastStart: bilibiliFastStart'));

      final kit = File(
        'lib/platform/windows_video_player_media_kit.dart',
      ).readAsStringSync();
      expect(kit, contains("skipInitialPause ? 'no' : 'yes'"));
      expect(
        kit,
        contains('SubtitleHopSeekPolicy.streamingScrubCachePauseWaitSeconds'),
      );
    },
  );
}
