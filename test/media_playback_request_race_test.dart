import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/playback_session.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _ControlledVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _positions = <int, Duration>{};
  int _nextPlayerId = 1;
  final List<double> playbackSpeedCalls = <double>[];
  final List<Completer<void>> _playbackSpeedBlockers = <Completer<void>>[];
  final List<Completer<void>> _seekBlockers = <Completer<void>>[];
  final List<Completer<void>> _playBlockers = <Completer<void>>[];
  final List<int> playCalls = <int>[];
  final List<int> pauseCalls = <int>[];
  final List<String> transportCommands = <String>[];
  int activePlaybackSpeedCalls = 0;
  int maxConcurrentPlaybackSpeedCalls = 0;
  Duration seekApplyDelay = Duration.zero;
  final List<Duration> seekCalls = <Duration>[];

  List<int> get playerIds => _events.keys.toList(growable: false);

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextPlayerId++;
    _events[id] = StreamController<VideoEvent>();
    _positions[id] = Duration.zero;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  void initializePlayer(int playerId) {
    _events[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 1),
        size: const Size(1920, 1080),
      ),
    );
  }

  void failPlayer(int playerId) {
    // A native event channel can report a late failure for an already released
    // id. Match the adapter's disposed-id gate instead of throwing in the fake.
    _events[playerId]?.addError(
      PlatformException(code: 'initialize_failed', message: 'failed'),
    );
  }

  @override
  Future<void> dispose(int playerId) async {
    _positions.remove(playerId);
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    playCalls.add(playerId);
    transportCommands.add('play:$playerId');
    if (_playBlockers.isNotEmpty) {
      await _playBlockers.removeAt(0).future;
    }
  }

  @override
  Future<void> pause(int playerId) async {
    pauseCalls.add(playerId);
    transportCommands.add('pause:$playerId');
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seekCalls.add(position);
    transportCommands.add('seek:$playerId:${position.inMilliseconds}');
    if (_seekBlockers.isNotEmpty) {
      await _seekBlockers.removeAt(0).future;
    }
    final delay = seekApplyDelay;
    if (delay <= Duration.zero) {
      if (_positions.containsKey(playerId)) _positions[playerId] = position;
      return;
    }
    Timer(delay, () {
      if (_positions.containsKey(playerId)) _positions[playerId] = position;
    });
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    playbackSpeedCalls.add(speed);
    activePlaybackSpeedCalls++;
    if (activePlaybackSpeedCalls > maxConcurrentPlaybackSpeedCalls) {
      maxConcurrentPlaybackSpeedCalls = activePlaybackSpeedCalls;
    }
    try {
      if (_playbackSpeedBlockers.isNotEmpty) {
        await _playbackSpeedBlockers.removeAt(0).future;
      }
    } finally {
      activePlaybackSpeedCalls--;
    }
  }

  Completer<void> blockNextPlaybackSpeedCall() {
    final blocker = Completer<void>();
    _playbackSpeedBlockers.add(blocker);
    return blocker;
  }

  Completer<void> blockNextSeekCall() {
    final blocker = Completer<void>();
    _seekBlockers.add(blocker);
    return blocker;
  }

  Completer<void> blockNextPlayCall() {
    final blocker = Completer<void>();
    _playBlockers.add(blocker);
    return blocker;
  }

  void setReportedPosition(int playerId, Duration position) {
    if (_positions.containsKey(playerId)) _positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      _positions[playerId] ?? Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

Future<void> _waitForPlayers(
  _ControlledVideoPlatform platform,
  int count,
) async {
  for (var i = 0; i < 100 && platform.playerIds.length < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(platform.playerIds, hasLength(count));
}

Future<void> _waitForPlayerId(
  _ControlledVideoPlatform platform,
  int playerId,
) async {
  for (var i = 0; i < 100 && !platform.playerIds.contains(playerId); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(platform.playerIds, contains(playerId));
}

Future<void> _waitForNoPlayers(_ControlledVideoPlatform platform) async {
  for (var i = 0; i < 100 && platform.playerIds.isNotEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(platform.playerIds, isEmpty);
}

Future<void> _waitForPlaybackSpeedCalls(
  _ControlledVideoPlatform platform,
  int count,
) async {
  for (var i = 0; i < 100 && platform.playbackSpeedCalls.length < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(platform.playbackSpeedCalls, hasLength(count));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  test(
    'temporary playback speed commands are serialized and restored',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'temporary_playback_speed_test_',
      );
      final video = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
      await video.writeAsBytes(<int>[0]);

      final service = MediaPlaybackService();
      await service.cancelPendingPlay();
      addTearDown(() async {
        await service.cancelPendingPlay();
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
      );
      final play = service.play(
        VideoItem(
          id: 'temporary-speed',
          path: video.path,
          title: 'Temporary speed',
          durationMs: 0,
          lastUpdated: 0,
        ),
      );
      await _waitForPlayers(platform, 1);
      platform.initializePlayer(platform.playerIds.single);
      await play;
      platform.playbackSpeedCalls.clear();
      platform.maxConcurrentPlaybackSpeedCalls = 0;
      var temporarySpeedNotifications = 0;
      void countTemporarySpeedNotification() {
        temporarySpeedNotifications++;
      }

      service.addListener(countTemporarySpeedNotification);
      addTearDown(
        () => service.removeListener(countTemporarySpeedNotification),
      );

      final blocker = platform.blockNextPlaybackSpeedCall();
      final begin = service.beginTemporaryPlaybackSpeed(2.0);
      await _waitForPlaybackSpeedCalls(platform, 1);
      expect(service.confirmedPlaybackSpeed, 1.0);
      expect(service.isTemporaryPlaybackSpeedActive, isTrue);

      final end = service.endTemporaryPlaybackSpeed();
      await Future<void>.delayed(Duration.zero);
      expect(platform.playbackSpeedCalls, <double>[2.0]);
      expect(platform.maxConcurrentPlaybackSpeedCalls, 1);

      blocker.complete();
      await begin;
      await end;

      expect(platform.playbackSpeedCalls, <double>[2.0, 1.0]);
      expect(platform.maxConcurrentPlaybackSpeedCalls, 1);
      expect(service.confirmedPlaybackSpeed, 1.0);
      expect(service.playbackSpeed, 1.0);
      expect(service.isTemporaryPlaybackSpeedActive, isFalse);
      expect(temporarySpeedNotifications, 0);
    },
  );

  test('a released long press is coalesced before native dispatch', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'coalesced_playback_speed_test_',
    );
    final video = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
    await video.writeAsBytes(<int>[0]);

    final service = MediaPlaybackService();
    await service.cancelPendingPlay();
    addTearDown(() async {
      await service.cancelPendingPlay();
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
    );
    final play = service.play(
      VideoItem(
        id: 'coalesced-speed',
        path: video.path,
        title: 'Coalesced speed',
        durationMs: 0,
        lastUpdated: 0,
      ),
    );
    await _waitForPlayers(platform, 1);
    platform.initializePlayer(platform.playerIds.single);
    await play;
    platform.playbackSpeedCalls.clear();

    final begin = service.beginTemporaryPlaybackSpeed(2.0);
    final end = service.endTemporaryPlaybackSpeed();
    await Future.wait(<Future<void>>[begin, end]);

    expect(platform.playbackSpeedCalls, isEmpty);
    expect(service.confirmedPlaybackSpeed, 1.0);
    expect(service.playbackSpeed, 1.0);
  });

  test(
    'a playback-rate boundary never re-anchors to a stale native position',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'continuous_playback_speed_test_',
      );
      final video = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
      await video.writeAsBytes(<int>[0]);

      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
      );
      addTearDown(() async {
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final play = service.play(
        VideoItem(
          id: 'continuous-speed',
          path: video.path,
          title: 'Continuous speed',
          durationMs: 0,
          lastUpdated: 0,
        ),
        autoPlay: false,
      );
      await _waitForPlayers(platform, 1);
      final playerId = platform.playerIds.single;
      platform.initializePlayer(playerId);
      await play;
      await service.seekTo(
        const Duration(seconds: 10),
        source: 'rate-continuity-test',
      );
      final beforeRateChange = service.positionNotifier.value;

      // This models a backend whose queried position trails the already
      // presented frame during a rate transition.
      platform.setReportedPosition(playerId, const Duration(seconds: 2));
      await service.beginTemporaryPlaybackSpeed(2.0);

      expect(service.positionNotifier.value, beforeRateChange);
      await service.endTemporaryPlaybackSpeed();
      expect(service.positionNotifier.value, beforeRateChange);
    },
  );

  test(
    'foreground resume re-anchors the shared presentation position',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'foreground_position_resync_test_',
      );
      final video = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
      await video.writeAsBytes(<int>[0]);

      final service = MediaPlaybackService();
      await service.cancelPendingPlay();
      addTearDown(() async {
        service.handleAppLifecycleState(AppLifecycleState.resumed);
        await service.cancelPendingPlay();
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
      );
      final play = service.play(
        VideoItem(
          id: 'foreground-position-resync',
          path: video.path,
          title: 'Foreground position resync',
          durationMs: 0,
          lastUpdated: 0,
        ),
      );
      await _waitForPlayers(platform, 1);
      platform.initializePlayer(platform.playerIds.single);
      await play;

      service.handleAppLifecycleState(AppLifecycleState.paused);
      final controller = service.controller!;
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 20),
        isPlaying: true,
      );

      // Native/coarse playback can advance while the Flutter frame ticker is
      // suspended. The shared presentation clock must catch up immediately
      // when the app becomes visible again.
      expect(
        service.positionNotifier.value,
        isNot(const Duration(seconds: 20)),
      );
      service.handleAppLifecycleState(AppLifecycleState.resumed);

      expect(service.position, const Duration(seconds: 20));
      expect(
        service.positionNotifier.value.inMilliseconds,
        closeTo(const Duration(seconds: 20).inMilliseconds, 50),
      );
      expect(
        service.coarsePositionNotifier.value.inMilliseconds,
        closeTo(const Duration(seconds: 20).inMilliseconds, 50),
      );
    },
  );

  test(
    'a stale initialization failure cannot overwrite newer playback',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'media_playback_request_race_test_',
      );
      addTearDown(() async {
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final firstFile = File(
        '${tempDir.path}${Platform.pathSeparator}first.mp4',
      );
      final secondFile = File(
        '${tempDir.path}${Platform.pathSeparator}second.mp4',
      );
      final thirdFile = File(
        '${tempDir.path}${Platform.pathSeparator}third.mp4',
      );
      await firstFile.writeAsBytes(<int>[0]);
      await secondFile.writeAsBytes(<int>[0]);
      await thirdFile.writeAsBytes(<int>[0]);

      final service = MediaPlaybackService();
      await service.cancelPendingPlay();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
      );
      final firstItem = VideoItem(
        id: 'first',
        path: firstFile.path,
        title: 'First',
        durationMs: 0,
        lastUpdated: 0,
      );
      final secondItem = VideoItem(
        id: 'second',
        path: secondFile.path,
        title: 'Second',
        durationMs: 0,
        lastUpdated: 0,
      );

      final firstPlay = service.play(firstItem);
      await _waitForPlayers(platform, 1);
      final retiredPlayerId = platform.playerIds.single;
      final secondPlay = service.play(secondItem);
      await _waitForPlayerId(platform, 2);

      platform.initializePlayer(2);
      await secondPlay;
      expect(service.currentItem?.id, 'second');
      expect(service.state, PlaybackState.playing);

      // Cancellation releases the old candidate immediately. A late native
      // failure must be discarded instead of holding that player until retry.
      expect(platform.playerIds, isNot(contains(retiredPlayerId)));
      platform.failPlayer(retiredPlayerId);
      await firstPlay.timeout(const Duration(seconds: 1));
      expect(service.currentItem?.id, 'second');
      expect(service.state, PlaybackState.playing);

      await service.seekTo(const Duration(seconds: 37));
      expect(service.position, const Duration(seconds: 37));

      final thirdItem = VideoItem(
        id: 'third',
        path: thirdFile.path,
        title: 'Third',
        durationMs: const Duration(minutes: 2).inMilliseconds,
        lastPositionMs: 0,
        lastUpdated: 0,
      );
      final thirdPlay = service.play(thirdItem);

      // The loading notification must never combine the new item identity
      // with the previous item's timeline (the visible one-frame progress bug).
      expect(service.currentItem?.id, 'third');
      expect(service.state, PlaybackState.loading);
      expect(service.position, Duration.zero);
      expect(service.duration, const Duration(minutes: 2));

      await _waitForPlayerId(platform, 3);
      platform.initializePlayer(3);
      await thirdPlay;
    },
  );

  test('resume position is frozen while a controller initializes', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'media_resume_position_race_test_',
    );
    final video = File('${tempDir.path}${Platform.pathSeparator}audio.mp3');
    await video.writeAsBytes(<int>[0]);

    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
    );
    addTearDown(() async {
      await service.cancelPendingPlay();
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    const savedPosition = Duration(seconds: 23);
    final play = service.play(
      VideoItem(
        id: 'frozen-resume-position',
        path: video.path,
        title: 'Frozen resume position',
        durationMs: const Duration(minutes: 1).inMilliseconds,
        lastPositionMs: savedPosition.inMilliseconds,
        lastUpdated: 0,
      ),
    );

    // The request publishes its saved position before native initialization.
    expect(service.state, PlaybackState.loading);
    expect(service.position, savedPosition);
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await play;

    expect(service.position, savedPosition);
    expect(service.controller?.value.position, savedPosition);
    expect(
      platform.seekCalls.where((position) => position == savedPosition),
      hasLength(1),
      reason: 'a confirmed initial seek must not be replayed',
    );
    await service.stop();
  });

  test(
    'initialized controller is mountable before playback readiness completes',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'mountable_loading_controller_test_',
      );
      final video = File(
        '${tempDir.path}${Platform.pathSeparator}stream-video.mp4',
      );
      await video.writeAsBytes(<int>[0]);

      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
      );
      addTearDown(() async {
        await service.stop();
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final playBlocker = platform.blockNextPlayCall();
      final play = service.play(
        VideoItem(
          id: 'mountable-while-loading',
          path: video.path,
          title: 'Mountable while loading',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastUpdated: 0,
        ),
      );
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);

      for (var i = 0; i < 100 && !service.hasMountableController; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      // The native play call is deliberately blocked, so readiness cannot
      // complete. The page must nevertheless be able to mount the initialized
      // video output and break the first-frame circular wait.
      expect(service.state, PlaybackState.loading);
      expect(service.controller?.value.isInitialized, isTrue);
      expect(service.hasMountableController, isTrue);

      playBlocker.complete();
      await play;
      expect(service.state, PlaybackState.playing);
    },
  );

  test('stale route cleanup cannot mutate the replacement session', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'stale_route_cleanup_test_',
    );
    final firstFile = File(
      '${tempDir.path}${Platform.pathSeparator}online.mp4',
    );
    final secondFile = File(
      '${tempDir.path}${Platform.pathSeparator}audio.mp3',
    );
    await firstFile.writeAsBytes(<int>[0]);
    await secondFile.writeAsBytes(<int>[0]);

    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
    );
    addTearDown(() async {
      await service.cancelPendingPlay();
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final oldItem = VideoItem(
      id: 'old-online-route',
      path: firstFile.path,
      title: 'Old online route',
      durationMs: const Duration(minutes: 1).inMilliseconds,
      lastUpdated: 0,
    );
    final oldPlay = service.play(oldItem);
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await oldPlay;
    final oldController = service.controller!;

    const replacementPosition = Duration(seconds: 19);
    final replacementItem = VideoItem(
      id: 'replacement-audio',
      path: secondFile.path,
      title: 'Replacement audio',
      durationMs: const Duration(minutes: 1).inMilliseconds,
      lastUpdated: 0,
    );
    final replacementPlay = service.play(
      replacementItem,
      startPosition: replacementPosition,
    );
    await _waitForPlayerId(platform, 2);
    platform.initializePlayer(2);
    await replacementPlay;

    expect(service.currentItem?.id, replacementItem.id);
    expect(service.position, replacementPosition);
    expect(service.state, PlaybackState.playing);

    final synchronized = service.updatePlaybackStateFromController(
      expectedItemId: oldItem.id,
      expectedController: oldController,
    );
    await service.pause(
      expectedItemId: oldItem.id,
      expectedController: oldController,
    );
    await service.persistCurrentProgress(
      expectedItemId: oldItem.id,
      expectedController: oldController,
    );

    expect(synchronized, isFalse);
    expect(service.currentItem?.id, replacementItem.id);
    expect(service.position, replacementPosition);
    expect(service.state, PlaybackState.playing);
    await service.stop();
  });

  test(
    'episode navigation defaults to the persisted auto-play setting',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'episode_navigation_autoplay_test_',
      );
      final firstFile = File(
        '${tempDir.path}${Platform.pathSeparator}first.mp4',
      );
      final secondFile = File(
        '${tempDir.path}${Platform.pathSeparator}second.mp4',
      );
      await firstFile.writeAsBytes(<int>[0]);
      await secondFile.writeAsBytes(<int>[0]);

      final settings = SettingsService();
      await settings.init();
      final originalAutoPlay = settings.autoPlayNextVideo;
      final playlist = PlaylistManager();
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: playlist,
        progressTracker: ProgressTracker(),
      );
      final items = <VideoItem>[
        VideoItem(
          id: 'autoplay-first',
          path: firstFile.path,
          title: 'First',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastUpdated: 0,
        ),
        VideoItem(
          id: 'autoplay-second',
          path: secondFile.path,
          title: 'Second',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastPositionMs: const Duration(seconds: 17).inMilliseconds,
          lastUpdated: 0,
        ),
      ];
      playlist.setPlaylist(items);

      addTearDown(() async {
        await settings.saveAutoPlayNextVideo(originalAutoPlay);
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final initialPlay = service.play(items.first, autoPlay: false);
      await _waitForPlayers(platform, 1);
      platform.initializePlayer(platform.playerIds.single);
      await initialPlay;
      expect(service.state, PlaybackState.paused);

      await settings.saveAutoPlayNextVideo(true);
      final next = service.playNext();
      await _waitForPlayerId(platform, 2);
      platform.initializePlayer(2);
      await next;
      expect(service.currentItem?.id, 'autoplay-second');
      expect(service.state, PlaybackState.playing);
      expect(service.position, const Duration(seconds: 17));
      expect(platform.playCalls, contains(2));
      expect(
        platform.transportCommands.indexOf('pause:2'),
        lessThan(platform.transportCommands.indexOf('seek:2:17000')),
      );
      expect(
        platform.transportCommands.indexOf('seek:2:17000'),
        lessThan(platform.transportCommands.indexOf('play:2')),
        reason: 'resume position must be committed before playback starts',
      );

      await settings.saveAutoPlayNextVideo(false);
      final previous = service.playPrevious();
      await _waitForPlayerId(platform, 3);
      platform.initializePlayer(3);
      await previous;
      expect(service.currentItem?.id, 'autoplay-first');
      expect(service.state, PlaybackState.paused);
      expect(platform.playCalls, isNot(contains(3)));
      expect(platform.pauseCalls, contains(3));
    },
  );

  test('episode navigation skips consecutive missing local sources', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'episode_navigation_missing_source_test_',
    );
    final firstFile = File('${tempDir.path}${Platform.pathSeparator}first.mp4');
    final lastFile = File('${tempDir.path}${Platform.pathSeparator}last.mp4');
    await firstFile.writeAsBytes(<int>[0]);
    await lastFile.writeAsBytes(<int>[0]);

    final playlist = PlaylistManager();
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(),
    );
    final items = <VideoItem>[
      VideoItem(
        id: 'playable-first',
        path: firstFile.path,
        title: 'First',
        durationMs: 0,
        lastUpdated: 0,
      ),
      VideoItem(
        id: 'missing-one',
        path: '${tempDir.path}${Platform.pathSeparator}missing-one.mp4',
        title: 'Missing one',
        durationMs: 0,
        lastUpdated: 0,
      ),
      VideoItem(
        id: 'missing-two',
        path: '${tempDir.path}${Platform.pathSeparator}missing-two.mp4',
        title: 'Missing two',
        durationMs: 0,
        lastUpdated: 0,
      ),
      VideoItem(
        id: 'playable-last',
        path: lastFile.path,
        title: 'Last',
        durationMs: 0,
        lastUpdated: 0,
      ),
    ];
    playlist.setPlaylist(items);

    addTearDown(() async {
      await service.stop();
      await _waitForNoPlayers(platform);
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final initialPlay = service.play(items.first, autoPlay: false);
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await initialPlay;

    expect(service.nextPlayableItem?.id, 'playable-last');
    final next = service.playNext(autoPlay: false);
    await _waitForPlayerId(platform, 2);
    platform.initializePlayer(2);
    await next;
    expect(service.currentItem?.id, 'playable-last');
    expect(playlist.currentIndex, 1);
    expect(service.hasPlayableNext, isFalse);

    expect(service.previousPlayableItem?.id, 'playable-first');
    final previous = service.playPrevious(autoPlay: false);
    await _waitForPlayerId(platform, 3);
    platform.initializePlayer(3);
    await previous;
    expect(service.currentItem?.id, 'playable-first');
    expect(playlist.currentIndex, 0);
  });

  test(
    'episode switch retries initialization and preserves target resume point',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'episode_switch_retry_test_',
      );
      final firstFile = File(
        '${tempDir.path}${Platform.pathSeparator}first.mp4',
      );
      final secondFile = File(
        '${tempDir.path}${Platform.pathSeparator}second.mp4',
      );
      await firstFile.writeAsBytes(<int>[0]);
      await secondFile.writeAsBytes(<int>[0]);

      final playlist = PlaylistManager();
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: playlist,
        progressTracker: ProgressTracker(),
      );
      final items = <VideoItem>[
        VideoItem(
          id: 'retry-first',
          path: firstFile.path,
          title: 'First',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastUpdated: 0,
        ),
        VideoItem(
          id: 'retry-second',
          path: secondFile.path,
          title: 'Second',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastPositionMs: const Duration(seconds: 23).inMilliseconds,
          lastUpdated: 0,
        ),
      ];
      playlist.setPlaylist(items);

      addTearDown(() async {
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final initialPlay = service.play(items.first, autoPlay: false);
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;

      // The previous episode is close enough to its end to trigger the old
      // bug, but its position must never reset the next episode's own resume
      // point.
      await service.seekTo(
        const Duration(milliseconds: 59600),
        source: 'episode-switch-retry-test',
      );

      final next = service.playNext(autoPlay: true);
      await _waitForPlayerId(platform, 2);
      platform.failPlayer(2);

      // The failed native player is released before a fresh decoder is built.
      for (var i = 0; i < 200 && !platform.playerIds.contains(3); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(platform.playerIds, contains(3));
      platform.initializePlayer(3);
      await next;

      expect(service.currentItem?.id, 'retry-second');
      expect(service.state, PlaybackState.playing);
      expect(service.position, const Duration(seconds: 23));
      expect(platform.seekCalls, contains(const Duration(seconds: 23)));
    },
  );

  test('service owns and releases a page-created controller', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'transferred_controller_ownership_test_',
    );
    final mediaFile = File(
      '${tempDir.path}${Platform.pathSeparator}transferred.mp4',
    );
    await mediaFile.writeAsBytes(<int>[0]);

    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
    );
    addTearDown(() async {
      await service.stop();
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final controller = VideoPlayerController.file(mediaFile);
    final initialize = controller.initialize();
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await initialize;

    final item = VideoItem(
      id: 'transferred-controller',
      path: mediaFile.path,
      title: 'Transferred controller',
      durationMs: const Duration(minutes: 1).inMilliseconds,
      lastUpdated: 0,
    );
    await service.setController(controller);
    await service.updateMetadata(item);
    await service.stop();
    await _waitForNoPlayers(platform);
  });

  test('automatic continuation skips missing local sources', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'automatic_continuation_missing_source_test_',
    );
    final firstFile = File('${tempDir.path}${Platform.pathSeparator}first.mp4');
    final lastFile = File('${tempDir.path}${Platform.pathSeparator}last.mp4');
    await firstFile.writeAsBytes(<int>[0]);
    await lastFile.writeAsBytes(<int>[0]);

    final settings = SettingsService();
    final originalAutoPlayOnCompletion = settings.autoPlayOnCompletion;
    settings.autoPlayOnCompletion = true;
    final playlist = PlaylistManager();
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(),
    );
    final items = <VideoItem>[
      VideoItem(
        id: 'automatic-first',
        path: firstFile.path,
        title: 'First',
        durationMs: const Duration(minutes: 1).inMilliseconds,
        lastUpdated: 0,
      ),
      VideoItem(
        id: 'automatic-missing',
        path: '${tempDir.path}${Platform.pathSeparator}missing.mp4',
        title: 'Missing',
        durationMs: 0,
        lastUpdated: 0,
      ),
      VideoItem(
        id: 'automatic-last',
        path: lastFile.path,
        title: 'Last',
        durationMs: 0,
        lastUpdated: 0,
      ),
    ];
    playlist.setPlaylist(items);

    addTearDown(() async {
      settings.autoPlayOnCompletion = originalAutoPlayOnCompletion;
      await service.stop();
      await _waitForNoPlayers(platform);
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final initialPlay = service.play(items.first);
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await initialPlay;
    final controller = service.controller!;
    platform._positions[1] = const Duration(minutes: 1);
    controller.value = controller.value.copyWith(
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 1),
      isPlaying: false,
    );

    await _waitForPlayerId(platform, 2);
    platform.initializePlayer(2);
    for (
      var i = 0;
      i < 100 && service.currentItem?.id != 'automatic-last';
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(service.currentItem?.id, 'automatic-last');
    expect(playlist.currentIndex, 1);
  });

  test('completion stays on the current item when auto-play is off', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'automatic_continuation_disabled_test_',
    );
    final firstFile = File('${tempDir.path}${Platform.pathSeparator}first.mp4');
    final secondFile = File(
      '${tempDir.path}${Platform.pathSeparator}second.mp4',
    );
    await firstFile.writeAsBytes(<int>[0]);
    await secondFile.writeAsBytes(<int>[0]);

    final settings = SettingsService();
    final originalAutoPlayNextVideo = settings.autoPlayNextVideo;
    final originalAutoPlayOnCompletion = settings.autoPlayOnCompletion;
    settings.autoPlayNextVideo = true;
    settings.autoPlayOnCompletion = false;

    final playlist = PlaylistManager();
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(),
    );
    final items = <VideoItem>[
      VideoItem(
        id: 'completion-disabled-first',
        path: firstFile.path,
        title: 'First',
        durationMs: const Duration(minutes: 1).inMilliseconds,
        lastUpdated: 0,
      ),
      VideoItem(
        id: 'completion-disabled-second',
        path: secondFile.path,
        title: 'Second',
        durationMs: const Duration(minutes: 1).inMilliseconds,
        lastUpdated: 0,
      ),
    ];
    playlist.setPlaylist(items);

    addTearDown(() async {
      settings.autoPlayNextVideo = originalAutoPlayNextVideo;
      settings.autoPlayOnCompletion = originalAutoPlayOnCompletion;
      await service.stop();
      await _waitForNoPlayers(platform);
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final initialPlay = service.play(items.first);
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await initialPlay;
    final controller = service.controller!;
    platform._positions[1] = const Duration(minutes: 1);
    controller.value = controller.value.copyWith(
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 1),
      isPlaying: false,
    );

    for (var i = 0; i < 200 && service.state != PlaybackState.paused; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(service.currentItem?.id, 'completion-disabled-first');
    expect(service.state, PlaybackState.paused);
    expect(playlist.currentIndex, 0);
    expect(platform.playerIds, <int>[1]);
  });

  test(
    'automatic continuation resumes normally but restarts when configured',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'automatic_continuation_start_position_test_',
      );
      final files = <File>[
        for (var i = 0; i < 3; i++)
          File('${tempDir.path}${Platform.pathSeparator}$i.mp4'),
      ];
      for (final file in files) {
        await file.writeAsBytes(<int>[0]);
      }

      final settings = SettingsService();
      final originalAutoPlayNextVideo = settings.autoPlayNextVideo;
      final originalAutoPlayOnCompletion = settings.autoPlayOnCompletion;
      final originalFromStart = settings.autoPlayOnCompletionFromStart;
      settings.autoPlayNextVideo = false;
      settings.autoPlayOnCompletion = true;
      settings.autoPlayOnCompletionFromStart = false;

      final playlist = PlaylistManager();
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: playlist,
        progressTracker: ProgressTracker(),
      );
      final items = <VideoItem>[
        for (var i = 0; i < files.length; i++)
          VideoItem(
            id: 'automatic-start-$i',
            path: files[i].path,
            title: 'Item $i',
            durationMs: const Duration(minutes: 1).inMilliseconds,
            lastPositionMs: i == 0
                ? 0
                : const Duration(seconds: 23).inMilliseconds,
            lastUpdated: 0,
          ),
      ];
      playlist.setPlaylist(items);

      addTearDown(() async {
        settings.autoPlayNextVideo = originalAutoPlayNextVideo;
        settings.autoPlayOnCompletion = originalAutoPlayOnCompletion;
        settings.autoPlayOnCompletionFromStart = originalFromStart;
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final initialPlay = service.play(items.first);
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;

      var controller = service.controller!;
      platform._positions[1] = const Duration(minutes: 1);
      controller.value = controller.value.copyWith(
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 1),
        isPlaying: false,
      );

      await _waitForPlayerId(platform, 2);
      platform.initializePlayer(2);
      for (
        var i = 0;
        i < 300 &&
            (service.currentItem?.id != 'automatic-start-1' ||
                service.state != PlaybackState.playing ||
                service.position != const Duration(seconds: 23));
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(service.currentItem?.id, 'automatic-start-1');
      expect(service.state, PlaybackState.playing);
      expect(service.position, const Duration(seconds: 23));

      settings.autoPlayOnCompletionFromStart = true;
      controller = service.controller!;
      // Confirm the resumed native position so the bounded stale-sample guard
      // no longer treats the simulated completion as an old decoder sample.
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 23),
        duration: const Duration(minutes: 1),
        isPlaying: true,
      );
      service.updatePlaybackStateFromController(
        expectedItemId: items[1].id,
        expectedController: controller,
      );
      platform._positions[2] = const Duration(minutes: 1);
      controller.value = controller.value.copyWith(
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 1),
        isPlaying: false,
      );

      await _waitForPlayerId(platform, 3);
      platform.initializePlayer(3);
      for (
        var i = 0;
        i < 300 &&
            (service.currentItem?.id != 'automatic-start-2' ||
                service.state != PlaybackState.playing);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(service.currentItem?.id, 'automatic-start-2');
      expect(service.state, PlaybackState.playing);
      expect(service.position, Duration.zero);
    },
  );

  test('a stalled native seek cannot freeze later progress commands', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp('stalled_seek_test_');
    final service = MediaPlaybackService();
    addTearDown(() async {
      await service.stop();
      await _waitForNoPlayers(platform);
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    await service.cancelPendingPlay();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
    );
    final mediaFile = File(
      '${tempDir.path}${Platform.pathSeparator}stalled-seek.m4a',
    );
    await mediaFile.writeAsBytes(<int>[0]);
    final item = VideoItem(
      id: 'stalled-seek',
      path: mediaFile.path,
      title: 'Stalled seek',
      durationMs: const Duration(minutes: 1).inMilliseconds,
      lastUpdated: 0,
    );

    final play = service.play(item);
    await _waitForPlayers(platform, 1);
    platform.initializePlayer(platform.playerIds.single);
    await play;

    final stalledSeek = platform.blockNextSeekCall();
    final stopwatch = Stopwatch()..start();
    await service.seekTo(
      const Duration(seconds: 15),
      source: 'stalled-seek-test',
    );
    stopwatch.stop();
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));

    stalledSeek.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await service.seekTo(
      const Duration(seconds: 20),
      source: 'post-timeout-seek-test',
    );
    expect(service.position, const Duration(seconds: 20));
  });

  test('a delayed ALAC seek does not snap shared progress back', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'delayed_alac_seek_test_',
    );
    final service = MediaPlaybackService();
    addTearDown(() async {
      await service.stop();
      await _waitForNoPlayers(platform);
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    await service.cancelPendingPlay();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
    );
    final mediaFile = File(
      '${tempDir.path}${Platform.pathSeparator}album-with-cover.m4a',
    );
    await mediaFile.writeAsBytes(<int>[0]);
    final item = VideoItem(
      id: 'delayed-alac-seek',
      path: mediaFile.path,
      title: 'Delayed ALAC seek',
      durationMs: const Duration(minutes: 1).inMilliseconds,
      lastUpdated: 0,
    );

    final play = service.play(item);
    await _waitForPlayers(platform, 1);
    platform.initializePlayer(platform.playerIds.single);
    await play;
    platform.seekCalls.clear();
    platform.seekApplyDelay = const Duration(milliseconds: 500);

    await service.seekTo(
      const Duration(seconds: 35),
      source: 'delayed-alac-test',
    );
    expect(service.position, const Duration(seconds: 35));

    // The first verifier sees the old native timestamp but must keep the mini
    // player and notification at the target without duplicating the seek.
    await Future<void>.delayed(const Duration(milliseconds: 260));
    expect(service.position, const Duration(seconds: 35));
    expect(platform.seekCalls, hasLength(1));

    await Future<void>.delayed(const Duration(milliseconds: 750));
    expect(service.position, const Duration(seconds: 35));
  });

  test(
    'an erroneous active ALAC controller is rebuilt at its position',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'alac_controller_recovery_test_',
      );
      final service = MediaPlaybackService();
      addTearDown(() async {
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await service.cancelPendingPlay();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
      );
      final mediaFile = File(
        '${tempDir.path}${Platform.pathSeparator}lossless.m4a',
      );
      await mediaFile.writeAsBytes(<int>[0]);
      final item = VideoItem(
        id: 'recover-erroneous-alac',
        path: mediaFile.path,
        title: 'Recover erroneous ALAC',
        durationMs: const Duration(minutes: 1).inMilliseconds,
        lastUpdated: 0,
        type: MediaType.audio,
      );

      final initialPlay = service.play(item);
      await _waitForPlayers(platform, 1);
      final firstPlayerId = platform.playerIds.single;
      platform.initializePlayer(firstPlayerId);
      await initialPlay;
      await service.seekTo(
        const Duration(seconds: 21),
        source: 'alac-recovery-test',
      );

      platform.failPlayer(firstPlayerId);
      final replacementPlayerId = firstPlayerId + 1;
      await _waitForPlayerId(platform, replacementPlayerId);
      platform.initializePlayer(replacementPlayerId);

      for (var i = 0; i < 200; i++) {
        if (service.controller?.playerId == replacementPlayerId &&
            service.state == PlaybackState.playing) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(service.controller?.playerId, replacementPlayerId);
      expect(service.state, PlaybackState.playing);
      expect(service.position, const Duration(seconds: 21));
    },
  );

  test('subtitle hand-off repairs a primary-only service snapshot', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'subtitle_handoff_test_',
    );
    addTearDown(() async {
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final video = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
    final primary = File('${tempDir.path}${Platform.pathSeparator}primary.srt');
    final secondary = File(
      '${tempDir.path}${Platform.pathSeparator}secondary.srt',
    );
    await video.writeAsBytes(<int>[0]);
    await primary.writeAsString('1\n00:00:00,000 --> 00:00:02,000\nPrimary\n');
    await secondary.writeAsString(
      '1\n00:00:00,000 --> 00:00:02,000\nSecondary\n',
    );

    final service = MediaPlaybackService();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
    );
    final item = VideoItem(
      id: 'handoff',
      path: video.path,
      title: 'Handoff',
      durationMs: 0,
      lastUpdated: 0,
      subtitlePath: primary.path,
      secondarySubtitlePath: secondary.path,
    );
    final play = service.play(item);
    await _waitForPlayers(platform, 1);

    // Known external subtitles must not sit behind native player
    // initialization. The playback platform is still deliberately blocked.
    for (var i = 0; i < 100 && service.subtitlePaths.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(service.state, PlaybackState.loading);
    expect(service.subtitlePaths, <String>[primary.path, secondary.path]);
    expect(service.subtitles.single.text, 'Primary');
    expect(service.secondarySubtitles.single.text, 'Secondary');

    platform.initializePlayer(platform.playerIds.single);
    await play;

    await service.loadSubtitlePathsForCurrentItem(
      itemId: item.id,
      paths: <String>[primary.path],
    );
    expect(service.subtitlePaths, hasLength(1));
    expect(service.secondarySubtitles, isEmpty);

    final committed = await service.ensureSubtitlePathsForCurrentItem(
      itemId: item.id,
      paths: <String>[primary.path, secondary.path],
    );
    expect(committed, isTrue);
    expect(service.subtitlePaths, <String>[primary.path, secondary.path]);
    expect(service.subtitles.single.text, 'Primary');
    expect(service.secondarySubtitles.single.text, 'Secondary');
  });

  test('rapid episode commands are serialized and coalesced', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'episode_command_coalescing_',
    );
    final files = <File>[];
    for (var index = 0; index < 4; index++) {
      final file = File('${tempDir.path}${Platform.pathSeparator}$index.mp4');
      await file.writeAsBytes(<int>[0]);
      files.add(file);
    }
    final items = List<VideoItem>.generate(
      files.length,
      (index) => VideoItem(
        id: 'coalesced-$index',
        path: files[index].path,
        title: 'Item $index',
        durationMs: 0,
        lastUpdated: 0,
      ),
    );
    final playlist = PlaylistManager()..setPlaylist(items);
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(),
    );
    addTearDown(() async {
      await service.stop();
      await _waitForNoPlayers(platform);
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final initial = service.play(items.first, autoPlay: false);
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await initial;

    final firstNext = service.playNext(autoPlay: false);
    await _waitForPlayerId(platform, 2);
    expect(service.session.itemId, items[1].id);
    expect(
      service.session.phase,
      anyOf(
        PlaybackSessionPhase.preparingSource,
        PlaybackSessionPhase.initializingTransport,
      ),
    );

    final secondNext = service.playNext(autoPlay: false);
    final thirdNext = service.playNext(autoPlay: false);
    final previous = service.playPrevious(autoPlay: false);
    platform.initializePlayer(2);

    await _waitForPlayerId(platform, 3);
    platform.initializePlayer(3);
    await Future.wait<void>([firstNext, secondNext, thirdNext, previous]);

    expect(service.currentItem?.id, items[2].id);
    expect(playlist.currentIndex, 2);
    expect(service.session.phase, PlaybackSessionPhase.ready);
    expect(service.session.desiredPlaying, isFalse);
  });

  test('batched episode commands preserve boundary order', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'episode_command_boundary_order_',
    );
    final firstFile = File('${tempDir.path}${Platform.pathSeparator}first.mp4');
    final secondFile = File(
      '${tempDir.path}${Platform.pathSeparator}second.mp4',
    );
    await firstFile.writeAsBytes(<int>[0]);
    await secondFile.writeAsBytes(<int>[0]);
    final items = <VideoItem>[
      VideoItem(
        id: 'boundary-first',
        path: firstFile.path,
        title: 'First',
        durationMs: 0,
        lastUpdated: 0,
      ),
      VideoItem(
        id: 'boundary-second',
        path: secondFile.path,
        title: 'Second',
        durationMs: 0,
        lastUpdated: 0,
      ),
    ];
    final playlist = PlaylistManager()..setPlaylist(items);
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(),
    );
    addTearDown(() async {
      await service.stop();
      await _waitForNoPlayers(platform);
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final initial = service.play(items.first, autoPlay: false);
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await initial;

    final previous = service.playPrevious(autoPlay: false);
    final next = service.playNext(autoPlay: false);
    await _waitForPlayerId(platform, 2);
    platform.initializePlayer(2);
    await Future.wait<void>([previous, next]);

    expect(service.currentItem?.id, items[1].id);
    expect(playlist.currentIndex, 1);
  });

  test(
    'pause intent during loading is committed to the same session',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'loading_pause_intent_',
      );
      final file = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
      await file.writeAsBytes(<int>[0]);
      final item = VideoItem(
        id: 'loading-pause',
        path: file.path,
        title: 'Loading pause',
        durationMs: 0,
        lastUpdated: 0,
      );
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager()..setPlaylist(<VideoItem>[item]),
        progressTracker: ProgressTracker(),
      );
      addTearDown(() async {
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final play = service.play(item);
      await _waitForPlayerId(platform, 1);
      expect(service.state, PlaybackState.loading);
      expect(service.desiredPlaying, isTrue);

      await service.pause();
      expect(service.desiredPlaying, isFalse);
      platform.initializePlayer(1);
      await play;

      expect(service.currentItem?.id, item.id);
      expect(service.state, PlaybackState.paused);
      expect(service.session.phase, PlaybackSessionPhase.ready);
      expect(service.canMountControllerFor(item.id), isTrue);
    },
  );

  test(
    'notification-style skip does not retry after a loading pause',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'notification_skip_pause_',
      );
      final firstFile = File(
        '${tempDir.path}${Platform.pathSeparator}first.mp4',
      );
      final secondFile = File(
        '${tempDir.path}${Platform.pathSeparator}second.mp4',
      );
      await firstFile.writeAsBytes(<int>[0]);
      await secondFile.writeAsBytes(<int>[0]);
      final items = <VideoItem>[
        VideoItem(
          id: 'notification-first',
          path: firstFile.path,
          title: 'First',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastUpdated: 0,
        ),
        VideoItem(
          id: 'notification-second',
          path: secondFile.path,
          title: 'Second',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastPositionMs: const Duration(seconds: 17).inMilliseconds,
          lastUpdated: 0,
        ),
      ];
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager()..setPlaylist(items),
        progressTracker: ProgressTracker(),
      );
      addTearDown(() async {
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final initial = service.play(items.first, autoPlay: false);
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await initial;

      final settings = SettingsService();
      final originalAutoPlay = settings.autoPlayNextVideo;
      settings.autoPlayNextVideo = true;
      addTearDown(() => settings.autoPlayNextVideo = originalAutoPlay);

      final playBlocker = platform.blockNextPlayCall();
      final next = service.playNext();
      await _waitForPlayerId(platform, 2);
      platform.initializePlayer(2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await service.pause();
      playBlocker.complete();
      await next;

      expect(service.currentItem?.id, items[1].id);
      expect(service.position, const Duration(seconds: 17));
      expect(service.state, PlaybackState.paused);
      expect(
        platform._nextPlayerId,
        3,
        reason: 'the target source must be opened once instead of retried',
      );
    },
  );

  test(
    'persisted pause-on-switch intent stays controllable during background load',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'paused_background_switch_transport_',
      );
      final firstFile = File(
        '${tempDir.path}${Platform.pathSeparator}first.mp4',
      );
      final secondFile = File(
        '${tempDir.path}${Platform.pathSeparator}second.mp4',
      );
      await firstFile.writeAsBytes(<int>[0]);
      await secondFile.writeAsBytes(<int>[0]);
      final items = <VideoItem>[
        VideoItem(
          id: 'paused-switch-first',
          path: firstFile.path,
          title: 'First',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastPositionMs: const Duration(seconds: 9).inMilliseconds,
          lastUpdated: 0,
        ),
        VideoItem(
          id: 'paused-switch-second',
          path: secondFile.path,
          title: 'Second',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastPositionMs: const Duration(seconds: 17).inMilliseconds,
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
      );
      addTearDown(() async {
        settings.autoPlayNextVideo = originalAutoPlay;
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final initial = service.play(items.first, autoPlay: false);
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await initial;

      final next = service.playNext();
      await _waitForPlayerId(platform, 2);
      expect(service.currentItem?.id, items[1].id);
      expect(service.desiredPlaying, isFalse);

      // This is the notification play button arriving while skipToNext is
      // still awaiting native initialization. It must affect the target
      // session immediately instead of waiting behind the skip Future.
      await service.resume();
      expect(service.desiredPlaying, isTrue);
      platform.initializePlayer(2);
      await next;

      expect(service.currentItem?.id, items[1].id);
      expect(service.position, const Duration(seconds: 17));
      expect(service.state, PlaybackState.playing);

      await service.pause();
      expect(service.desiredPlaying, isFalse);
      expect(service.state, PlaybackState.paused);
      await service.resume();
      expect(service.desiredPlaying, isTrue);
      expect(service.state, PlaybackState.playing);
    },
  );

  test(
    'a failed notification switch does not block the next notification switch',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'notification_switch_recovery_',
      );
      final files = List<File>.generate(
        3,
        (index) =>
            File('${tempDir.path}${Platform.pathSeparator}episode-$index.mp4'),
      );
      for (final file in files) {
        await file.writeAsBytes(<int>[0]);
      }
      final items = List<VideoItem>.generate(
        3,
        (index) => VideoItem(
          id: 'notification-recovery-$index',
          path: files[index].path,
          title: 'Episode $index',
          durationMs: const Duration(minutes: 1).inMilliseconds,
          lastPositionMs: index == 2
              ? const Duration(seconds: 29).inMilliseconds
              : 0,
          lastUpdated: 0,
        ),
      );
      final settings = SettingsService();
      final originalAutoPlay = settings.autoPlayNextVideo;
      settings.autoPlayNextVideo = false;
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager()..setPlaylist(items),
        progressTracker: ProgressTracker(),
      );
      addTearDown(() async {
        settings.autoPlayNextVideo = originalAutoPlay;
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final initial = service.play(items.first, autoPlay: false);
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await initial;

      final failedSwitch = service.playNext();
      await _waitForPlayerId(platform, 2);
      platform.failPlayer(2);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await _waitForPlayerId(platform, 3);
      platform.failPlayer(3);
      await failedSwitch;
      expect(service.currentItem?.id, items[1].id);
      expect(service.state, PlaybackState.error);

      final recoveredSwitch = service.playNext();
      await _waitForPlayerId(platform, 4);
      platform.initializePlayer(4);
      await recoveredSwitch;

      expect(service.currentItem?.id, items[2].id);
      expect(service.position, const Duration(seconds: 29));
      expect(service.state, PlaybackState.paused);
      expect(
        platform._nextPlayerId,
        5,
        reason: 'the next command must run after bounded recovery is exhausted',
      );
    },
  );

  test(
    'resume intent during loading is committed to the same session',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'loading_resume_intent_',
      );
      final file = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
      await file.writeAsBytes(<int>[0]);
      final item = VideoItem(
        id: 'loading-resume',
        path: file.path,
        title: 'Loading resume',
        durationMs: 0,
        lastUpdated: 0,
      );
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager()..setPlaylist(<VideoItem>[item]),
        progressTracker: ProgressTracker(),
      );
      addTearDown(() async {
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final play = service.play(item, autoPlay: false);
      await _waitForPlayerId(platform, 1);
      expect(service.state, PlaybackState.loading);
      expect(service.desiredPlaying, isFalse);

      await service.resume();
      expect(service.desiredPlaying, isTrue);
      platform.initializePlayer(1);
      await play;

      expect(service.currentItem?.id, item.id);
      expect(service.state, PlaybackState.playing);
      expect(service.session.phase, PlaybackSessionPhase.ready);
    },
  );
}
