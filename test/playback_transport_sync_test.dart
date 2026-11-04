import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';

class _NativeOperation {
  final entered = Completer<void>.sync();
  final release = Completer<void>.sync();
}

class _DelayedTransportPlatform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final playing = <int, bool>{};
  final commands = <String>[];
  final blockers = <String, List<_NativeOperation>>{};
  final operations = <_NativeOperation>[];
  int activeCommands = 0;
  int maxConcurrentCommands = 0;
  int _nextId = 1;
  bool failNextPlay = false;
  bool failNextSeek = false;
  _NativeOperation block(String operation) {
    final blocker = _NativeOperation();
    operations.add(blocker);
    blockers.putIfAbsent(operation, () => []).add(blocker);
    return blocker;
  }

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    events[id] = StreamController<VideoEvent>();
    positions[id] = Duration.zero;
    playing[id] = false;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  Future<void> _apply(int playerId, bool play) async {
    final name = play ? 'play' : 'pause';
    commands.add(name);
    activeCommands++;
    if (activeCommands > maxConcurrentCommands) {
      maxConcurrentCommands = activeCommands;
    }
    try {
      final pending = blockers[name];
      if (pending != null && pending.isNotEmpty) {
        final blocker = pending.removeAt(0);
        blocker.entered.complete();
        await blocker.release.future;
      }
      if (play && failNextPlay) {
        failNextPlay = false;
        throw StateError('native play failed');
      }
      if (events.containsKey(playerId)) {
        playing[playerId] = play;
        events[playerId]!.add(
          VideoEvent(
            eventType: VideoEventType.isPlayingStateUpdate,
            isPlaying: play,
          ),
        );
      }
    } finally {
      activeCommands--;
    }
  }

  @override
  Future<void> play(int playerId) => _apply(playerId, true);
  @override
  Future<void> pause(int playerId) => _apply(playerId, false);
  @override
  Future<Duration> getPosition(int playerId) async {
    final value = positions[playerId] ?? Duration.zero;
    final pending = blockers['position'];
    if (pending != null && pending.isNotEmpty) {
      final blocker = pending.removeAt(0);
      blocker.entered.complete();
      await blocker.release.future;
    }
    return value;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    commands.add('seek');
    final pending = blockers['seek'];
    if (pending != null && pending.isNotEmpty) {
      final blocker = pending.removeAt(0);
      blocker.entered.complete();
      await blocker.release.future;
    }
    if (failNextSeek) {
      failNextSeek = false;
      throw StateError('native seek failed');
    }
    positions[playerId] = position;
  }

  @override
  Future<void> dispose(int playerId) async {
    await events.remove(playerId)?.close();
    positions.remove(playerId);
    playing.remove(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool value) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool value) async {}
  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  Future<(_DelayedTransportPlatform, MediaPlaybackService, int)> load(
    WidgetTester tester, {
    bool visible = true,
    bool bilibili = false,
    int Function()? nowMicroseconds,
  }) async {
    final original = VideoPlayerPlatform.instance;
    final platform = _DelayedTransportPlatform();
    VideoPlayerPlatform.instance = platform;
    final service = MediaPlaybackService.forTesting(
      nowMicroseconds: nowMicroseconds,
    );
    final streaming = bilibili
        ? await tester.runAsync(
            () async => BilibiliStreamingService(BilibiliApiService()),
          )
        : null;
    late Directory directory;
    await tester.runAsync(() async {
      await service.cancelPendingPlay();
      directory = await Directory.systemTemp.createTemp('transport_sync_');
      final file = File('${directory.path}/audio.mp3');
      await file.writeAsBytes([0]);
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );
      final loading = service.play(
        VideoItem(
          id: directory.path,
          path: file.path,
          title: 'Transport sync',
          type: MediaType.audio,
          durationMs: 60000,
          lastUpdated: 0,
        ),
        autoPlay: false,
        startPosition: const Duration(seconds: 10),
      );
      for (var i = 0; i < 200 && platform.events.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(platform.events, isNotEmpty);
      platform.events.values.single.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 1),
          size: const Size(640, 360),
        ),
      );
      await loading;
    });
    // These regressions model an open subtitle/lyric surface. A direct read
    // alone must not keep the app rendering frames after the surface leaves.
    void visiblePositionListener() {}
    if (visible) service.positionNotifier.addListener(visiblePositionListener);
    addTearDown(() async {
      if (visible) {
        service.positionNotifier.removeListener(visiblePositionListener);
      }
      await tester.runAsync(() async {
        for (final operation in platform.operations) {
          if (!operation.release.isCompleted) operation.release.complete();
        }
        final controller = service.controller;
        if (controller?.value.isInitialized == true) await controller!.pause();
        await service.stop();
        await controller?.dispose();
        service.dispose();
        await streaming?.shutdown();
        // stop() intentionally releases ordinary native sessions off the UI
        // path. Keep the fake platform installed until that release finishes.
        for (var i = 0; i < 100 && platform.events.isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(platform.events, isEmpty);
        VideoPlayerPlatform.instance = original;
        // Delete only the absolute directory returned by createTemp above.
        if (await directory.exists()) await directory.delete(recursive: true);
      });
    });
    platform.commands.clear();
    platform.maxConcurrentCommands = 0;
    return (platform, service, platform.events.keys.single);
  }

  testWidgets('off-page playback does not request presentation frames', (
    tester,
  ) async {
    var nowUs = 0;
    final (_, service, _) = await load(
      tester,
      visible: false,
      nowMicroseconds: () => nowUs,
    );
    await tester.runAsync(service.resume);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);

    nowUs += const Duration(seconds: 3).inMicroseconds;
    // Production retains its existing low-frequency progress timer. Let that
    // timer run in its real async zone, without synthesizing display frames.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    expect(service.positionNotifier.value, const Duration(seconds: 13));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'subscribing during build waits for the next presentation frame',
    (tester) async {
      var nowUs = 0;
      final (_, service, _) = await load(
        tester,
        visible: false,
        nowMicroseconds: () => nowUs,
      );
      await tester.runAsync(service.resume);
      nowUs = const Duration(seconds: 2).inMicroseconds;
      var notifications = 0;
      void listener() => notifications++;
      await tester.pumpWidget(
        Builder(
          builder: (_) {
            service.positionNotifier.addListener(listener);
            expect(notifications, 0);
            return const SizedBox.shrink();
          },
        ),
      );
      expect(notifications, 0);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 8));
      expect(service.positionNotifier.value, const Duration(seconds: 12));
      expect(notifications, 1);
      final shown = service.positionNotifier.value;
      await tester.pump(const Duration(milliseconds: 8));
      expect(
        service.positionNotifier.value - shown,
        const Duration(milliseconds: 8),
      );
      service.positionNotifier.removeListener(listener);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'a danmaku-only subscriber keeps frames until the last consumer leaves',
    (tester) async {
      var nowUs = 0;
      final (_, service, _) = await load(
        tester,
        visible: false,
        nowMicroseconds: () => nowUs,
      );
      await tester.runAsync(service.resume);
      var notifications = 0;
      void danmaku() => notifications++;
      void progress() {}
      service.danmakuPosition.addListener(danmaku);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(notifications, greaterThan(0));
      service.positionNotifier.addListener(progress);
      service.danmakuPosition.removeListener(danmaku);
      expect(tester.binding.transientCallbackCount, 1);
      service.positionNotifier.removeListener(progress);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'off-page rate and buffering changes survive presentation reentry',
    (tester) async {
      var nowUs = 0;
      final (_, service, _) = await load(
        tester,
        visible: false,
        nowMicroseconds: () => nowUs,
      );
      await tester.runAsync(service.resume);
      nowUs += const Duration(seconds: 1).inMicroseconds;
      await tester.runAsync(() => service.setPlaybackSpeed(2));
      nowUs += const Duration(seconds: 1).inMicroseconds;
      final controller = service.controller!;
      controller.value = controller.value.copyWith(isBuffering: true);
      nowUs += const Duration(seconds: 10).inMicroseconds;
      controller.value = controller.value.copyWith(isBuffering: false);
      nowUs += const Duration(milliseconds: 500).inMicroseconds;
      void listener() {}
      service.positionNotifier.addListener(listener);
      await tester.pump();
      expect(service.positionNotifier.value, const Duration(seconds: 14));
      service.positionNotifier.removeListener(listener);
      await tester.runAsync(service.pause);
      nowUs += const Duration(seconds: 10).inMicroseconds;
      service.positionNotifier.addListener(listener);
      expect(tester.binding.transientCallbackCount, 0);
      service.positionNotifier.removeListener(listener);
    },
  );

  testWidgets('background listeners cannot restart a presentation ticker', (
    tester,
  ) async {
    var nowUs = 0;
    final (_, service, _) = await load(
      tester,
      visible: false,
      nowMicroseconds: () => nowUs,
    );
    await tester.runAsync(service.resume);
    service.setAppForegroundState(false);
    void listener() {}
    service.positionNotifier.addListener(listener);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    service.positionNotifier.removeListener(listener);
    await tester.runAsync(service.pause);
    service.setAppForegroundState(true);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'off-page seek resumes at its acknowledgement before the next poll',
    (tester) async {
      var nowUs = 0;
      final (platform, service, id) = await load(
        tester,
        visible: false,
        nowMicroseconds: () => nowUs,
      );
      await tester.runAsync(service.resume);
      final acknowledgement = platform.block('seek');
      late Future<void> seeking;
      await tester.runAsync(() async {
        seeking = service.seekTo(
          const Duration(seconds: 20),
          source: 'music-player',
        );
        await acknowledgement.entered.future;
      });
      nowUs = const Duration(seconds: 2).inMicroseconds;
      expect(service.positionNotifier.value, const Duration(seconds: 20));
      await tester.runAsync(() async {
        acknowledgement.release.complete();
        await seeking;
      });
      // No UI frame has run since acknowledgement. The next low-frequency
      // sample must include all audio played since then, rather than starting
      // the clock late at this polling boundary.
      nowUs += const Duration(milliseconds: 250).inMicroseconds;
      platform.positions[id] = const Duration(milliseconds: 20250);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)),
      );
      expect(
        service.positionNotifier.value,
        const Duration(milliseconds: 20250),
      );
      expect(tester.binding.transientCallbackCount, 0);
      nowUs += const Duration(milliseconds: 100).inMicroseconds;
      platform.positions[id] = const Duration(milliseconds: 20350);
      void listener() {}
      service.positionNotifier.addListener(listener);
      await tester.pump();
      expect(
        service.positionNotifier.value,
        const Duration(milliseconds: 20350),
      );
      service.positionNotifier.removeListener(listener);
    },
  );

  for (final buffering in [false, true]) {
    testWidgets(
      'off-page seek acknowledgement respects ${buffering ? 'buffering' : 'pause'}',
      (tester) async {
        var nowUs = 0;
        final (_, service, _) = await load(
          tester,
          visible: false,
          nowMicroseconds: () => nowUs,
        );
        if (buffering) {
          await tester.runAsync(service.resume);
          final controller = service.controller!;
          controller.value = controller.value.copyWith(isBuffering: true);
        }
        await tester.runAsync(
          () => service.seekTo(
            const Duration(seconds: 20),
            source: 'music-player',
          ),
        );
        nowUs += const Duration(seconds: 5).inMicroseconds;
        void listener() {}
        service.positionNotifier.addListener(listener);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(service.positionNotifier.value, const Duration(seconds: 20));
        service.positionNotifier.removeListener(listener);
      },
    );
  }

  for (final paused in [false, true]) {
    testWidgets(
      'off-page Bilibili native seek-hold release respects ${paused ? 'pause' : 'playback'}',
      (tester) async {
        var nowUs = 0;
        final (platform, service, id) = await load(
          tester,
          visible: false,
          bilibili: true,
          nowMicroseconds: () => nowUs,
        );
        if (!paused) await tester.runAsync(service.resume);
        // Keep the real controller/session and switch only the source policy
        // under test. This exercises split-stream seek-hold without fetching
        // a Bilibili play URL or substituting private hold methods.
        service.currentItem!.sourceRef = const MediaSourceRef(
          value: 'https://www.bilibili.com/video/BV1test',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1test',
          cid: 1,
        );
        await tester.runAsync(
          () => service.seekTo(const Duration(seconds: 20), source: 'ui'),
        );
        expect(service.positionNotifier.value, const Duration(seconds: 20));
        // The seek target has landed; an 80 ms advancing native sample clears
        // the hold before its 350 ms visual-delay timer has shown any overlay.
        nowUs += const Duration(milliseconds: 80).inMicroseconds;
        platform.positions[id] = const Duration(milliseconds: 20080);
        final controller = service.controller!;
        controller.value = controller.value.copyWith(
          position: const Duration(milliseconds: 20080),
        );
        nowUs += const Duration(milliseconds: 250).inMicroseconds;
        void listener() {}
        service.positionNotifier.addListener(listener);
        await tester.pump();
        expect(
          service.positionNotifier.value,
          paused
              ? const Duration(seconds: 20)
              : const Duration(milliseconds: 20250),
        );
        service.positionNotifier.removeListener(listener);
      },
    );
  }

  testWidgets(
    'off-page timed-out seek keeps verification and resumes its released clock',
    (tester) async {
      var nowUs = 0;
      final (platform, service, id) = await load(
        tester,
        visible: false,
        nowMicroseconds: () => nowUs,
      );
      await tester.runAsync(service.resume);
      final lateAcknowledgement = platform.block('seek');
      late Future<void> seeking;
      await tester.runAsync(() async {
        seeking = service.seekTo(
          const Duration(seconds: 20),
          source: 'music-player',
        );
        await lateAcknowledgement.entered.future;
      });
      nowUs = const Duration(seconds: 2).inMicroseconds;
      expect(service.positionNotifier.value, const Duration(seconds: 20));
      await tester.runAsync(() async {
        // Exercise the real bounded native-seek timeout. A timeout releases the
        // pending gate but retains the target guard and the direct verifier.
        await seeking;
        lateAcknowledgement.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      nowUs += const Duration(milliseconds: 250).inMicroseconds;
      platform.positions[id] = const Duration(milliseconds: 20250);
      await tester.runAsync(() async {
        // Await the native verifier under concurrent test load. Its real-time
        // timer must acknowledge the same exact clock asserted below.
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (service.positionNotifier.value !=
                const Duration(milliseconds: 20250) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(
        service.positionNotifier.value,
        const Duration(milliseconds: 20250),
      );
      expect(platform.commands.where((command) => command == 'seek').length, 1);
      void listener() {}
      service.positionNotifier.addListener(listener);
      await tester.pump();
      expect(
        service.positionNotifier.value,
        const Duration(milliseconds: 20250),
      );
      service.positionNotifier.removeListener(listener);
    },
  );

  for (final rate in [0.5, 1.0, 2.0, 8.0]) {
    testWidgets(
      'subtitle lookup shares the presented lyric frame at ${rate}x',
      (tester) async {
        final (_, service, _) = await load(tester);
        await tester.runAsync(() async {
          await service.setPlaybackSpeed(rate);
          await service.resume();
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        final native = service.controller!.value.position;
        await tester.pump(const Duration(milliseconds: 64));
        expect(service.controller!.value.position, native);
        expect(service.positionNotifier.value, greaterThan(native));
        expect(
          service.positionForSubtitleOverlay(native),
          service.positionNotifier.value,
        );
        await tester.runAsync(service.pause);
        final paused = service.positionForSubtitleOverlay(
          service.controller!.value.position,
        );
        await tester.pump(const Duration(seconds: 1));
        expect(
          service.positionForSubtitleOverlay(
            service.controller!.value.position,
          ),
          paused,
        );
      },
    );
  }

  testWidgets('buffering freezes subtitles on the last presented lyric frame', (
    tester,
  ) async {
    final (_, service, _) = await load(tester);
    await tester.runAsync(service.resume);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final controller = service.controller!;
    final frozen = service.positionNotifier.value;
    controller.value = controller.value.copyWith(isBuffering: true);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(service.positionNotifier.value, frozen);
    expect(
      service.positionForSubtitleOverlay(controller.value.position),
      frozen,
    );
    controller.value = controller.value.copyWith(isBuffering: false);
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(service.positionNotifier.value, greaterThan(frozen));
    expect(
      service.positionForSubtitleOverlay(controller.value.position),
      service.positionNotifier.value,
    );
    await tester.runAsync(service.pause);
  });

  testWidgets(
    'a new presentation subscriber cannot start frames during buffering',
    (tester) async {
      final (_, service, _) = await load(tester, visible: false);
      await tester.runAsync(service.resume);
      final controller = service.controller!;
      controller.value = controller.value.copyWith(isBuffering: true);
      void listener() {}
      service.positionNotifier.addListener(listener);
      try {
        await tester.pump();
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.binding.hasScheduledFrame, isFalse);
        controller.value = controller.value.copyWith(isBuffering: false);
        expect(tester.binding.transientCallbackCount, 1);
        await tester.pump();
        final before = service.positionNotifier.value;
        await tester.pump(const Duration(milliseconds: 16));
        expect(service.positionNotifier.value, greaterThan(before));
      } finally {
        service.positionNotifier.removeListener(listener);
      }
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  for (final showOverlay in [false, true]) {
    testWidgets(
      'visible Bilibili seek-hold restarts frames after native progress (overlay=$showOverlay)',
      (tester) async {
        final (platform, service, id) = await load(tester, bilibili: true);
        await tester.runAsync(service.resume);
        await tester.pump();
        service.currentItem!.sourceRef = const MediaSourceRef(
          value: 'https://www.bilibili.com/video/BV1test',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1test',
          cid: 1,
        );
        await tester.runAsync(
          () => service.seekTo(const Duration(seconds: 20)),
        );
        if (showOverlay) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 400)),
          );
          await tester.pump();
        }
        expect(tester.binding.transientCallbackCount, 0);
        platform.positions[id] = const Duration(milliseconds: 20080);
        final controller = service.controller!;
        controller.value = controller.value.copyWith(
          position: const Duration(milliseconds: 20080),
        );
        expect(tester.binding.transientCallbackCount, 1);
        await tester.pump();
        final before = service.positionNotifier.value;
        await tester.pump(const Duration(milliseconds: 16));
        expect(service.positionNotifier.value, greaterThan(before));
        await tester.runAsync(service.stop);
      },
    );
  }

  for (final fails in [false, true]) {
    testWidgets(
      'visible seek ${fails ? 'failure' : 'timeout'} restores suspended frames',
      (tester) async {
        final (platform, service, _) = await load(tester);
        await tester.runAsync(service.resume);
        await tester.pump();
        final blocker = platform.block('seek');
        platform.failNextSeek = fails;
        late Future<void> seeking;
        await tester.runAsync(() async {
          seeking = service.seekTo(const Duration(seconds: 20));
          await blocker.entered.future;
        });
        expect(tester.binding.transientCallbackCount, 0);
        await tester.runAsync(() async {
          if (fails) blocker.release.complete();
          await seeking;
          if (!fails) blocker.release.complete();
        });
        expect(tester.binding.transientCallbackCount, 1);
        await tester.pump();
        final before = service.positionNotifier.value;
        await tester.pump(const Duration(milliseconds: 16));
        expect(service.positionNotifier.value, greaterThan(before));
        await tester.runAsync(service.stop);
      },
    );
  }

  testWidgets('native playing resumes after a seek acknowledged while paused', (
    tester,
  ) async {
    final (platform, service, _) = await load(tester);
    await tester.runAsync(service.resume);
    await tester.pump();
    final blocker = platform.block('seek');
    late Future<void> seeking;
    await tester.runAsync(() async {
      seeking = service.seekTo(const Duration(seconds: 20));
      await blocker.entered.future;
    });
    final controller = service.controller!;
    controller.value = controller.value.copyWith(isPlaying: false);
    await tester.runAsync(() async {
      blocker.release.complete();
      await seeking;
    });
    expect(service.isPlaying, isTrue, reason: 'seek retains the play intent');
    expect(tester.binding.transientCallbackCount, 0);
    controller.value = controller.value.copyWith(isPlaying: true);
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pump();
    final before = service.positionNotifier.value;
    await tester.pump(const Duration(milliseconds: 16));
    expect(service.positionNotifier.value, greaterThan(before));
    await tester.runAsync(service.stop);
  });

  testWidgets(
    'page sync during a native pause cannot accumulate unplayed wall time',
    (tester) async {
      var nowUs = 0;
      final (_, service, _) = await load(tester, nowMicroseconds: () => nowUs);
      await tester.runAsync(service.resume);
      await tester.pump();
      final controller = service.controller!;
      await tester.runAsync(() async {
        controller.value = controller.value.copyWith(isPlaying: false);
        expect(service.desiredPlaying, isTrue);
        // Playback pages explicitly synchronize the same controller while the
        // service retains its play intent through a transient native pause.
        expect(service.updatePlaybackStateFromController(), isTrue);
      });
      final held = service.positionNotifier.value;
      expect(tester.binding.transientCallbackCount, 0);
      nowUs += const Duration(seconds: 5).inMicroseconds;
      await tester.pump(const Duration(seconds: 5));
      expect(service.positionNotifier.value, held);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.runAsync(() async {
        controller.value = controller.value.copyWith(isPlaying: true);
      });
      expect(service.positionNotifier.value, held);
      expect(tester.binding.transientCallbackCount, 1);
      await tester.pump();
      expect(service.positionNotifier.value, held);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        service.positionNotifier.value - held,
        const Duration(milliseconds: 16),
      );
      await tester.runAsync(service.stop);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'authoritative seek correction remains frozen until buffering ends',
    (tester) async {
      var nowUs = 0;
      final (platform, service, id) = await load(
        tester,
        nowMicroseconds: () => nowUs,
      );
      await tester.runAsync(service.resume);
      await tester.pump();
      const target = Duration(seconds: 20);
      const actual = Duration(seconds: 45);
      final controller = service.controller!;
      // Keep native verification and snapshot IO in the real async zone;
      // injected media time remains fixed through both authoritative reads.
      await tester.runAsync(() async {
        await service.seekTo(target, source: 'music-player');
        platform.positions[id] = actual;
        controller.value = controller.value.copyWith(isBuffering: true);
        await Future<void>.delayed(const Duration(milliseconds: 220));
        expect(service.positionNotifier.value, target);
        await Future<void>.delayed(const Duration(milliseconds: 700));
      });
      expect(service.positionNotifier.value, actual);
      expect(service.position, actual);
      expect(tester.binding.transientCallbackCount, 0);
      nowUs += const Duration(seconds: 5).inMicroseconds;
      await tester.pump(const Duration(seconds: 5));
      expect(service.positionNotifier.value, actual);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.runAsync(() async {
        controller.value = controller.value.copyWith(isBuffering: false);
      });
      expect(service.positionNotifier.value, actual);
      expect(tester.binding.transientCallbackCount, 1);
      await tester.pump();
      expect(service.positionNotifier.value, actual);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        service.positionNotifier.value - actual,
        const Duration(milliseconds: 16),
      );
      await tester.runAsync(service.stop);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'adopting a running controller does not drop the next media frame',
    (tester) async {
      final (_, service, _) = await load(tester);
      await tester.runAsync(service.resume);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 64));
      for (var adoption = 0; adoption < 3; adoption++) {
        final before = service.positionNotifier.value;
        service.updatePlaybackStateFromController();
        await tester.pump(const Duration(milliseconds: 8));
        expect(
          (service.positionNotifier.value - before).inMicroseconds,
          closeTo(8000, 10),
        );
      }
      await tester.runAsync(service.pause);
    },
  );

  testWidgets(
    'rapid toggles serialize native commands, keep the clock frozen until ack and finish at fresh position',
    (tester) async {
      final (platform, service, id) = await load(tester);
      await tester.runAsync(service.resume);
      await tester.pump();
      final pauseBlock = platform.block('pause');
      final playBlock = platform.block('play');
      platform.commands.clear();
      late Future<void> pause;
      await tester.runAsync(() async {
        pause = service.pause();
        await pauseBlock.entered.future.timeout(const Duration(seconds: 3));
      });
      expect(pauseBlock.entered.isCompleted, isTrue);
      late Future<void> resume, pauseAgain, finalResume;
      await tester.runAsync(() async {
        resume = service.resume();
        pauseAgain = service.pause();
        finalResume = service.resume();
      });
      final frozen = service.positionNotifier.value;
      await tester.pump(const Duration(milliseconds: 400));
      expect(platform.commands, ['pause']);
      expect(tester.binding.transientCallbackCount, 0);
      expect(service.positionNotifier.value, frozen);
      expect(platform.maxConcurrentCommands, 1);
      platform.positions[id] = const Duration(milliseconds: 11250);
      await tester.runAsync(() async {
        pauseBlock.release.complete();
        await playBlock.entered.future.timeout(const Duration(seconds: 3));
      });
      expect(playBlock.entered.isCompleted, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      expect(platform.playing[id], isFalse);
      expect(service.positionNotifier.value, frozen);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.runAsync(() async {
        playBlock.release.complete();
        await Future.wait([pause, resume, pauseAgain, finalResume]);
      });
      expect(platform.commands, ['pause', 'play']);
      expect(platform.maxConcurrentCommands, 1);
      expect(platform.playing[id], isTrue);
      expect(service.desiredPlaying, isTrue);
      expect(
        service.positionNotifier.value.inMilliseconds,
        inInclusiveRange(11250, 11255),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        service.positionNotifier.value.inMilliseconds,
        inInclusiveRange(11250, 11283),
      );
      await tester.runAsync(service.pause);
      await tester.pump();
    },
  );

  testWidgets(
    'delayed resume followed by pause leaves both backend and lyrics paused',
    (tester) async {
      final (platform, service, id) = await load(tester);
      final blocker = platform.block('play');
      late Future<void> resume;
      await tester.runAsync(() async {
        resume = service.resume();
        await blocker.entered.future.timeout(const Duration(seconds: 3));
      });
      expect(blocker.entered.isCompleted, isTrue);
      late Future<void> pause;
      await tester.runAsync(() async {
        pause = service.pause();
      });
      expect(platform.commands, ['play']);
      platform.positions[id] = const Duration(milliseconds: 10480);
      await tester.runAsync(() async {
        blocker.release.complete();
        await Future.wait([resume, pause]);
      });
      expect(platform.commands, ['play', 'pause']);
      expect(platform.maxConcurrentCommands, 1);
      expect(platform.playing[id], isFalse);
      expect(service.isPlaying, isFalse);
      expect(
        service.positionNotifier.value,
        const Duration(milliseconds: 10480),
      );
      final paused = service.positionNotifier.value;
      await tester.pump(const Duration(seconds: 2));
      expect(service.positionNotifier.value, paused);
    },
  );

  testWidgets(
    'repeated pause acknowledgements do not accumulate the native pause latency',
    (tester) async {
      final (platform, service, id) = await load(tester);
      for (var cycle = 0; cycle < 12; cycle++) {
        await tester.runAsync(service.resume);
        await tester.pump();
        // Native audio advances while a pause request is travelling to it.
        platform.positions[id] = Duration(
          milliseconds: 10000 + (cycle + 1) * 130,
        );
        await tester.runAsync(service.pause);
        expect(service.positionNotifier.value, platform.positions[id]);
        expect(service.position, platform.positions[id]);
        expect(platform.playing[id], isFalse);
      }
      expect(platform.maxConcurrentCommands, 1);
    },
  );

  testWidgets('a late pause-position reply cannot overwrite a newer seek', (
    tester,
  ) async {
    final (platform, service, id) = await load(tester);
    await tester.runAsync(service.resume);
    final read = platform.block('position');
    platform.positions[id] = const Duration(milliseconds: 10350);
    late Future<void> pause;
    await tester.runAsync(() async {
      pause = service.pause();
      await read.entered.future.timeout(const Duration(seconds: 3));
      await service.seekTo(const Duration(seconds: 20));
      read.release.complete();
      await pause;
    });
    expect(service.positionNotifier.value, const Duration(seconds: 20));
    expect(service.position, const Duration(seconds: 20));
    expect(platform.playing[id], isFalse);
    await tester.pump();
  });

  for (final offsetMs in [-250, 250]) {
    for (final rate in [.5, 1.0, 2.0, 8.0]) {
      testWidgets(
        'danmaku freezes across ${offsetMs}ms native pause calibration at ${rate}x',
        (tester) async {
          // VSync advances through pump below. Keep the pre-frame monotonic
          // clock deterministic too: real host scheduling multiplied by 8x
          // can exceed the sub-millisecond calibration assertion.
          final (platform, service, id) = await load(
            tester,
            nowMicroseconds: () => 0,
          );
          void overlayListener() {}
          service.danmakuPosition.addListener(overlayListener);
          addTearDown(
            () => service.danmakuPosition.removeListener(overlayListener),
          );
          await tester.runAsync(() async {
            await service.setPlaybackSpeed(rate);
            await service.resume();
          });
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 32));
          final frozen = service.danmakuPosition.value;
          final stopped =
              service.positionNotifier.value + Duration(milliseconds: offsetMs);
          platform.positions[id] = stopped;
          await tester.runAsync(service.pause);
          expect(service.position, stopped);
          expect(service.positionNotifier.value, stopped);
          expect(service.danmakuPosition.value, frozen);
          await tester.pump(const Duration(seconds: 2));
          expect(service.danmakuPosition.value, frozen);
          await tester.runAsync(service.resume);
          expect(
            (service.danmakuPosition.value - frozen).inMicroseconds.abs(),
            lessThan(1000),
          );
          await tester.pump();
          expect(
            (service.danmakuPosition.value - frozen).inMicroseconds.abs(),
            lessThan(1000),
            reason: 'the first resumed VSync must keep the pause calibration',
          );
          final beforeFrame = service.danmakuPosition.value;
          await tester.pump(const Duration(milliseconds: 16));
          final deltaUs =
              (service.danmakuPosition.value - beforeFrame).inMicroseconds;
          expect(
            deltaUs,
            inInclusiveRange(16000 * rate * .89, 16000 * rate * 1.11),
          );
          await tester.runAsync(service.pause);
        },
      );
    }
  }

  testWidgets('a seek during pause calibration updates danmaku immediately', (
    tester,
  ) async {
    final (platform, service, id) = await load(tester);
    void overlayListener() {}
    service.danmakuPosition.addListener(overlayListener);
    addTearDown(() => service.danmakuPosition.removeListener(overlayListener));
    await tester.runAsync(service.resume);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final read = platform.block('position');
    platform.positions[id] = const Duration(milliseconds: 10400);
    await tester.runAsync(() async {
      final pausing = service.pause();
      await read.entered.future.timeout(const Duration(seconds: 3));
      await service.seekTo(const Duration(seconds: 20));
      expect(service.danmakuPosition.value, const Duration(seconds: 20));
      read.release.complete();
      await pausing;
    });
    expect(service.danmakuPosition.value, const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
    expect(service.danmakuPosition.value, const Duration(seconds: 20));
  });

  for (final target in [
    const Duration(seconds: 5),
    const Duration(seconds: 20),
  ]) {
    testWidgets('subtitle hop to $target keeps the shared frame clock', (
      tester,
    ) async {
      final (platform, service, _) = await load(tester);
      await tester.runAsync(service.resume);
      final blocker = platform.block('seek');
      await tester.runAsync(() async {
        await service.seekTo(target, source: 'subtitle_hop');
        await blocker.entered.future.timeout(const Duration(seconds: 3));
      });
      try {
        await tester.pump(const Duration(milliseconds: 80));
        expect(service.positionNotifier.value, target);
        expect(
          service.positionForSubtitleOverlay(
            service.controller!.value.position,
          ),
          target,
        );
      } finally {
        await tester.runAsync(() async {
          blocker.release.complete();
          await Future<void>.delayed(const Duration(milliseconds: 40));
        });
      }
      // Normal playback can move more than the hop-settle tolerance while
      // the hop protection window is still open. Keep using the current frame,
      // rather than reverting to the coarse service position for that window.
      final presented = target + const Duration(milliseconds: 640);
      service.positionNotifier.value = presented;
      expect(
        service.positionForSubtitleOverlay(
          target + const Duration(milliseconds: 600),
        ),
        presented,
      );
      await tester.runAsync(service.stop);
    });

    testWidgets('lyric seek to $target waits for native acknowledgement', (
      tester,
    ) async {
      final (platform, service, _) = await load(tester);
      await tester.runAsync(service.resume);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final blocker = platform.block('seek');
      late Future<void> seek;
      await tester.runAsync(() async {
        seek = service.seekTo(target, source: 'music-player');
        await blocker.entered.future.timeout(const Duration(seconds: 3));
      });
      try {
        expect(service.positionNotifier.value, target);
        expect(tester.binding.transientCallbackCount, 0);
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.binding.transientCallbackCount, 0);
          expect(tester.binding.hasScheduledFrame, isFalse);
          expect(
            service.positionNotifier.value,
            target,
            reason: 'word highlighting must not run ahead of a pending seek',
          );
          expect(
            service.positionForSubtitleOverlay(
              service.controller!.value.position,
            ),
            target,
            reason: 'floating subtitles must also hold the pending seek target',
          );
        }
      } finally {
        await tester.runAsync(() async {
          blocker.release.complete();
          await seek;
        });
      }
      await tester.pump(const Duration(milliseconds: 16));
      var previous = service.positionNotifier.value;
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(service.positionNotifier.value, greaterThanOrEqualTo(previous));
        previous = service.positionNotifier.value;
      }
      expect(previous, greaterThan(target));
      expect(platform.commands.where((command) => command == 'seek'), ['seek']);
      await tester.runAsync(service.stop);
    });
  }

  for (final playing in [false, true]) {
    for (final offsetMs in [-40, 40]) {
      testWidgets(
        'lyric seek verification preserves ${playing ? 'running' : 'paused'} clock with ${offsetMs}ms native offset',
        (tester) async {
          final (platform, service, id) = await load(tester);
          if (playing) await tester.runAsync(service.resume);
          await tester.pump();
          const target = Duration(seconds: 20);
          try {
            // Start in the test clock's zone, so its verification timer runs
            // between the same VSync frames that drive word highlighting.
            await service.seekTo(target, source: 'music-player');
            final actual = target + Duration(milliseconds: offsetMs);
            platform.positions[id] = actual;
            await tester.pump();
            var previous = service.positionNotifier.value;
            for (var frame = 0; frame < 15; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              final current = service.positionNotifier.value;
              if (playing) {
                expect(
                  current,
                  greaterThanOrEqualTo(previous),
                  reason:
                      'a successful native verification must not restart the lyric',
                );
              }
              previous = current;
            }
            if (playing) {
              expect(previous, greaterThan(target));
            } else {
              expect(previous, actual);
            }
          } finally {
            await tester.runAsync(service.stop);
          }
        },
      );
    }
  }

  testWidgets('a rejected lyric seek still corrects to the native position', (
    tester,
  ) async {
    final (platform, service, id) = await load(tester);
    try {
      const target = Duration(seconds: 20);
      const actual = Duration(seconds: 45);
      await tester.runAsync(() async {
        await service.seekTo(target, source: 'music-player');
        platform.positions[id] = actual;
        await Future<void>.delayed(const Duration(milliseconds: 220));
        expect(service.positionNotifier.value, target);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(service.positionNotifier.value, actual);
        expect(service.position, actual);
      });
    } finally {
      await tester.runAsync(service.stop);
    }
  });

  testWidgets(
    'failed native play leaves a frozen clock and the next request can recover',
    (tester) async {
      final (platform, service, id) = await load(tester);
      platform.failNextPlay = true;
      await tester.runAsync(service.resume);
      expect(service.isPlaying, isFalse);
      final frozen = service.positionNotifier.value;
      await tester.pump(const Duration(milliseconds: 500));
      expect(service.positionNotifier.value, frozen);
      await tester.runAsync(service.resume);
      expect(service.isPlaying, isTrue);
      expect(platform.playing[id], isTrue);
      expect(platform.maxConcurrentCommands, 1);
      await tester.runAsync(service.pause);
      await tester.pump();
    },
  );
}
