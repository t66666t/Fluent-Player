import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

class _Platform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final playing = <int, bool>{};
  final commands = <String>[];
  int nextId = 0;
  Completer<void>? nextPlayGate;
  Completer<void>? nextPlayEntered;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++nextId;
    events[id] = StreamController<VideoEvent>();
    positions[id] = Duration.zero;
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
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  @override
  Future<void> play(int playerId) async {
    commands.add('play');
    final gate = nextPlayGate;
    nextPlayGate = null;
    nextPlayEntered?.complete();
    nextPlayEntered = null;
    await gate?.future;
    if (events.containsKey(playerId)) playing[playerId] = true;
  }

  @override
  Future<void> pause(int playerId) async {
    commands.add('pause');
    if (events.containsKey(playerId)) playing[playerId] = false;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;
  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      positions[playerId] = position;
  @override
  Future<void> dispose(int playerId) async {
    await events.remove(playerId)?.close();
    playing.remove(playerId);
    positions.remove(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  late VideoPlayerPlatform previousPlatform;
  late _Platform native;
  late Directory directory;
  late VideoItem item;
  late MediaPlaybackService playback;
  late SystemMediaSessionService session;
  late bool oldConcurrent, oldHeadset, oldBackgroundPause, oldNotification;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    oldConcurrent = settings.allowConcurrentPlayback;
    oldHeadset = settings.enableHeadsetMediaControls;
    oldBackgroundPause = settings.pausePlaybackWhenAppBackgrounded;
    oldNotification = settings.showSystemMediaNotification;
    settings.allowConcurrentPlayback = false;
    settings.enableHeadsetMediaControls = true;
    settings.pausePlaybackWhenAppBackgrounded = false;
    previousPlatform = VideoPlayerPlatform.instance;
    native = _Platform();
    VideoPlayerPlatform.instance = native;
    directory = await Directory.systemTemp.createTemp(
      'background-autoplay-test-',
    );
    final file = await File('${directory.path}/test.mp4').writeAsBytes([0]);
    item = VideoItem(
      id: 'test',
      path: file.path,
      title: 'test',
      lastUpdated: 0,
      durationMs: 120000,
    );
    playback = MediaPlaybackService.forTesting();
    await playback.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(
        playbackStateStore: PlaybackStateStore(
          directoryProvider: () async => directory,
        ),
      ),
    );
    session = SystemMediaSessionService.forTesting(playbackService: playback);
  });

  tearDown(() async {
    native.nextPlayGate?.complete();
    await playback.stop();
    playback.dispose();
    VideoPlayerPlatform.instance = previousPlatform;
    settings.allowConcurrentPlayback = oldConcurrent;
    settings.enableHeadsetMediaControls = oldHeadset;
    settings.pausePlaybackWhenAppBackgrounded = oldBackgroundPause;
    settings.showSystemMediaNotification = oldNotification;
    // Verify the resolved generated path before recursive cleanup.
    final tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
    final testRoot = await directory.resolveSymbolicLinks();
    if (!p.isWithin(tempRoot, testRoot) ||
        !p.basename(testRoot).startsWith('background-autoplay-test-')) {
      throw StateError('Refusing cleanup outside the generated test directory');
    }
    await directory.delete(recursive: true);
  });

  Future<void> interruption(
    bool begin, [
    AudioInterruptionType type = AudioInterruptionType.pause,
  ]) => session.handleAudioInterruptionForTesting(
    AudioInterruptionEvent(begin, type),
  );
  Future<void> open({bool playing = true}) => playback.play(
    item,
    autoPlay: playing,
    startPosition: const Duration(seconds: 17),
  );

  void expectPaused() {
    expect(playback.desiredPlaying, isFalse);
    expect(playback.state, PlaybackState.paused);
  }

  test(
    'an unpaired focus gain cannot resume manually paused background media',
    () async {
      await open();
      await playback.pause();
      playback.setAppForegroundState(false);
      native.commands.clear();
      await interruption(false);
      expectPaused();
      expect(native.commands, isNot(contains('play')));
    },
  );

  test(
    'a begin and end received while already manually paused cannot resume',
    () async {
      await open(playing: false);
      native.commands.clear();
      await interruption(true);
      await interruption(false);
      expectPaused();
      expect(native.commands, isNot(contains('play')));
    },
  );

  test(
    'a manual pause during a temporary interruption cancels auto resume',
    () async {
      await open();
      await interruption(true);
      expectPaused();
      await playback.pause();
      native.commands.clear();
      await interruption(false);
      expectPaused();
      expect(native.commands, isNot(contains('play')));
    },
  );

  test(
    'a genuine temporary interruption resumes the same playing item once',
    () async {
      await open();
      final controller = playback.controller;
      await interruption(true);
      expectPaused();
      await interruption(false);
      expect(playback.desiredPlaying, isTrue);
      expect(playback.controller, same(controller));
      expect(playback.position, const Duration(seconds: 17));
      await playback.pause();
      await interruption(false);
      expectPaused();
    },
  );

  test(
    'Android hidden headset session retains focus through an owned interruption',
    () async {
      settings.showSystemMediaNotification = false;
      final calls = <bool>[];
      session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        setAudioSessionActive: (active) async {
          calls.add(active);
          return true;
        },
      );
      await open();
      playback.setAppForegroundState(false);
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      await interruption(true);
      await session.syncAudioFocusForTesting(desiredPlaying: false);
      expectPaused();
      expect(calls, [true]);

      await interruption(false);
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      expect(playback.desiredPlaying, isTrue);
      // The gain belongs to the retained request; background continuation
      // must not make a fresh Android 15 focus request with no visible FGS.
      expect(calls, [true]);
    },
  );

  test(
    'Android manual pause during interruption releases retained focus',
    () async {
      final calls = <bool>[];
      session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        setAudioSessionActive: (active) async {
          calls.add(active);
          return true;
        },
      );
      await open();
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      await interruption(true);
      await session.syncAudioFocusForTesting(desiredPlaying: false);
      await playback.pause();
      await session.syncAudioFocusForTesting(desiredPlaying: false);
      await interruption(false);
      await session.flushAudioFocusForTesting();
      expectPaused();
      expect(calls, [true, false]);
    },
  );

  test(
    'Android rapid focus intent retains self-focus grace for the same session',
    () async {
      final grant = Completer<void>();
      final entered = Completer<void>();
      var calls = 0;
      session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        setAudioSessionActive: (active) async {
          if (++calls == 1) {
            entered.complete();
            await grant.future;
          }
          return true;
        },
      );
      await open();
      final first = session.syncAudioFocusForTesting(desiredPlaying: true);
      await entered.future;
      final pausing = session.syncAudioFocusForTesting(desiredPlaying: false);
      final playing = session.syncAudioFocusForTesting(desiredPlaying: true);
      grant.complete();
      await Future.wait([first, pausing, playing]);
      // A coalesced pause/play did not replace the actual playing session. An
      // OEM self-loss directly after its grant still uses the existing grace.
      await interruption(true, AudioInterruptionType.unknown);
      await session.flushAudioFocusForTesting();
      expect(playback.desiredPlaying, isTrue);
    },
  );

  test(
    'iOS interruption deactivates then reactivates its audio session',
    () async {
      final calls = <bool>[];
      session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: true,
        setAudioSessionActive: (active) async {
          calls.add(active);
          return true;
        },
      );
      await open();
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      await interruption(true, AudioInterruptionType.unknown);
      await session.syncAudioFocusForTesting(desiredPlaying: false);
      expectPaused();
      expect(calls, [true, false]);
      await interruption(false);
      await session.syncAudioFocusForTesting(desiredPlaying: true);
      expect(playback.desiredPlaying, isTrue);
      expect(calls, [true, false, true]);
    },
  );

  test(
    'duplicate begin events preserve one temporary pause ownership',
    () async {
      await open();
      await interruption(true);
      await interruption(true);
      await interruption(false);
      expect(playback.desiredPlaying, isTrue);
    },
  );

  test('duck events alone cannot resume manually paused media', () async {
    await open(playing: false);
    await interruption(true, AudioInterruptionType.duck);
    await interruption(false, AudioInterruptionType.duck);
    expectPaused();
  });

  test(
    'Android duck-tagged gain can finish an owned temporary pause',
    () async {
      await open();
      await interruption(true);
      await interruption(true, AudioInterruptionType.duck);
      expectPaused();
      await interruption(false, AudioInterruptionType.duck);
      expect(playback.desiredPlaying, isTrue);
      await playback.pause();
      await interruption(false);
      expectPaused();
    },
  );

  test(
    'a late interruption end cannot resume a replacement paused session',
    () async {
      await open();
      await interruption(true);
      await playback.play(
        item,
        autoPlay: false,
        forceRecreate: true,
        startPosition: const Duration(seconds: 38),
      );
      await interruption(false);
      expectPaused();
      expect(playback.position, const Duration(seconds: 38));
    },
  );

  test('a permanent loss cancels temporary resume ownership', () async {
    await open();
    await interruption(true);
    await interruption(true, AudioInterruptionType.unknown);
    await interruption(false);
    expectPaused();
  });

  test(
    'headphone removal while interrupted cannot later play on speakers',
    () async {
      await open();
      await interruption(true);
      session.handleBecomingNoisyForTesting();
      await interruption(false);
      expectPaused();
    },
  );

  test(
    'mix mode does not arm an automatic resume for later focus events',
    () async {
      await open();
      settings.allowConcurrentPlayback = true;
      await interruption(true);
      await playback.pause();
      settings.allowConcurrentPlayback = false;
      await interruption(false);
      expectPaused();
    },
  );

  test(
    'a sleep deadline elapsed while interrupted wins over focus gain',
    () async {
      await open();
      await interruption(true);
      await playback.sleepTimer.scheduleAfter(const Duration(milliseconds: 80));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await interruption(false);
      expectPaused();
      expect(playback.sleepTimer.isActive, isFalse);
    },
  );

  test('a stop during interruption cannot be undone by focus gain', () async {
    await open();
    await interruption(true);
    await playback.stop();
    await interruption(false);
    expect(playback.desiredPlaying, isFalse);
    expect(playback.controller, isNull);
    expect(playback.currentItem, isNull);
  });

  test(
    'iOS unknown begin and should-resume end retain normal continuation',
    () async {
      session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: true,
        exclusiveFocusGrantedAt: DateTime.now(),
      );
      await open();
      await interruption(true, AudioInterruptionType.unknown);
      expectPaused();
      await interruption(false);
      expect(playback.desiredPlaying, isTrue);
    },
  );

  test('iOS end without should-resume does not authorize playback', () async {
    session = SystemMediaSessionService.forTesting(
      playbackService: playback,
      isIOS: true,
    );
    await open();
    await interruption(true, AudioInterruptionType.unknown);
    await interruption(false, AudioInterruptionType.unknown);
    expectPaused();
    await interruption(false);
    expectPaused();
  });

  test(
    'iOS interruption continuation cannot override a manual pause',
    () async {
      session = SystemMediaSessionService.forTesting(
        playbackService: playback,
        isIOS: true,
      );
      await open();
      await interruption(true, AudioInterruptionType.unknown);
      await playback.pause();
      await interruption(false);
      expectPaused();
    },
  );

  test(
    'a notification pause is honored during the self focus grace window',
    () async {
      await open();
      final graceSession = SystemMediaSessionService.forTesting(
        playbackService: playback,
        exclusiveFocusGrantedAt: DateTime.now(),
      );
      final controls = createSystemMediaHandlerForTesting(
        playbackService: playback,
        playlistManager: PlaylistManager(),
        session: graceSession,
      );
      await controls.pause();
      expectPaused();
      await controls.play();
      expect(playback.desiredPlaying, isTrue);
    },
  );

  test(
    'a late foreground native play cannot override a newer manual pause',
    () async {
      await open();
      final controller = playback.controller!;
      controller.value = controller.value.copyWith(isPlaying: false);
      // The platform paused the transport while Dart retained play intent.
      native.playing.updateAll((_, _) => false);
      final blocked = Completer<void>();
      final entered = Completer<void>();
      native.nextPlayGate = blocked;
      native.nextPlayEntered = entered;
      playback.handleAppLifecycleState(AppLifecycleState.resumed);
      await entered.future.timeout(const Duration(seconds: 1));
      final pausing = playback.pause();
      expect(playback.desiredPlaying, isFalse);
      try {
        // Explicit pause must be sent even if the old foreground play never
        // acknowledges. Its late completion must also be corrected below.
        await pausing.timeout(const Duration(seconds: 1));
        expect(native.commands.last, 'pause');
      } finally {
        blocked.complete();
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expectPaused();
      expect(native.playing.values, everyElement(isFalse));
    },
  );
}
