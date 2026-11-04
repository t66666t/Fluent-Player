import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:video_player/video_player.dart';
import 'package:video_player_app/platform/app_video_player_controller.dart';
import 'package:video_player_app/platform/video_display_geometry.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Platform extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>();
  Size initialSize = Size.zero;

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => 1;
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 2),
        size: initialSize,
      ),
    );
    return events.stream;
  }

  @override
  Future<void> dispose(int playerId) async => events.close();
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool allow) async {}
  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.blue);
}

class _Controller extends AppVideoPlayerController {
  _Controller(this.dimensions)
    : super.networkUrl(Uri.parse('https://example.test/video'));
  final ValueNotifier<Size?> dimensions;
  @override
  ValueListenable<Size?> get nativeDisplaySize => dimensions;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('slow motion video cannot become audio-only when the timeout fires', () {
    const tracks = mk.Tracks(
      audio: [mk.AudioTrack('1', null, null)],
      video: [mk.VideoTrack('2', null, null)],
    );
    expect(
      VideoDisplayGeometry.canInitializeWithoutVideo(
        knownAudioOnly: false,
        videoIntentionallyDisabled: false,
        tracks: tracks,
      ),
      isFalse,
    );
    expect(
      VideoDisplayGeometry.canInitializeWithoutVideo(
        knownAudioOnly: false,
        videoIntentionallyDisabled: true,
        tracks: tracks,
      ),
      isTrue,
      reason: 'Mini/background audio may deliberately defer video',
    );
    expect(
      VideoDisplayGeometry.canInitializeWithoutVideo(
        knownAudioOnly: false,
        videoIntentionallyDisabled: false,
        tracks: const mk.Tracks(),
      ),
      isFalse,
      reason: 'An empty track list is still loading',
    );
  });

  test('audio and album art still initialize without a motion frame', () {
    for (final video in <List<mk.VideoTrack>>[
      [],
      [const mk.VideoTrack('2', null, null, albumart: true)],
      [const mk.VideoTrack('2', null, null, image: true)],
    ]) {
      expect(
        VideoDisplayGeometry.canInitializeWithoutVideo(
          knownAudioOnly: false,
          videoIntentionallyDisabled: false,
          tracks: mk.Tracks(
            audio: [const mk.AudioTrack('1', null, null)],
            video: video,
          ),
        ),
        isTrue,
      );
    }
  });

  test('presentation dimensions include pixel aspect and rotation', () {
    for (final angle in [0, 90, 180, 270, -90]) {
      expect(
        VideoDisplayGeometry.fromVideoParams(
          mk.VideoParams(w: 720, h: 576, dw: 1024, dh: 576, rotate: angle),
        ),
        angle % 180 == 0 ? const Size(1024, 576) : const Size(576, 1024),
      );
    }
    expect(
      VideoDisplayGeometry.fromVideoParams(
        const mk.VideoParams(dw: 0, dh: 1080),
      ),
      isNull,
    );
    expect(
      VideoDisplayGeometry.fromVideoParams(const mk.VideoParams()),
      isNull,
    );
    expect(
      VideoDisplayGeometry.fromVideoParams(
        const mk.VideoParams(dw: 1920, dh: 1080),
      ),
      const Size(1920, 1080),
    );
  });

  test(
    'paused HLS initializes from coded dimensions before decoded dw/dh arrive',
    () {
      expect(
        VideoDisplayGeometry.fromVideoParams(
          const mk.VideoParams(w: 1280, h: 720),
        ),
        const Size(1280, 720),
      );
      expect(
        VideoDisplayGeometry.fromVideoParams(
          const mk.VideoParams(w: 720, h: 576, par: 64 / 45, rotate: 90),
        ),
        const Size(576, 1024),
      );
      expect(
        VideoDisplayGeometry.fromVideoParams(
          const mk.VideoParams(w: 720, h: 576, aspect: 16 / 9),
        ),
        const Size(1024, 576),
      );
      for (final params in [
        const mk.VideoParams(w: 1280),
        const mk.VideoParams(w: 0, h: 720),
        const mk.VideoParams(w: -1, h: 720),
      ]) {
        expect(VideoDisplayGeometry.fromVideoParams(params), isNull);
      }
      // Decoded display dimensions retain priority over the demuxer fallback.
      expect(
        VideoDisplayGeometry.fromVideoParams(
          const mk.VideoParams(w: 720, h: 576, dw: 1024, dh: 576, par: 1),
        ),
        const Size(1024, 576),
      );
    },
  );

  late VideoPlayerPlatform original;
  late _Platform platform;
  setUp(() {
    original = VideoPlayerPlatform.instance;
    platform = _Platform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() => VideoPlayerPlatform.instance = original);

  test(
    'late dimensions repair initialized controller without reopening or losing playback',
    () async {
      final dimensions = ValueNotifier<Size?>(null);
      final controller = _Controller(dimensions);
      await controller.initialize();
      expect(controller.value.size, Size.zero);
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 23),
        playbackSpeed: 1.5,
        isPlaying: true,
      );
      dimensions.value = const Size(1920, 1080);
      expect(controller.value.size, const Size(1920, 1080));
      expect(controller.value.position, const Duration(seconds: 23));
      expect(controller.value.playbackSpeed, 1.5);
      expect(controller.value.isPlaying, isTrue);
      dimensions.value = const Size(1080, 1920);
      expect(controller.value.aspectRatio, 1080 / 1920);
      dimensions.value = null;
      dimensions.value = Size.zero;
      expect(
        controller.value.size,
        const Size(1080, 1920),
        reason: 'Transient unload must retain the last usable geometry',
      );
      await controller.dispose();
      // ignore: invalid_use_of_protected_member
      expect(dimensions.hasListeners, isFalse);
      dimensions.value = const Size(640, 480);
      dimensions.dispose();
    },
  );

  test(
    'dimensions already received during initialization are reconciled',
    () async {
      final dimensions = ValueNotifier<Size?>(const Size(2560, 1080));
      final controller = _Controller(dimensions);
      await controller.initialize();
      expect(controller.value.aspectRatio, 2560 / 1080);
      await controller.dispose();
      dimensions.dispose();
    },
  );

  testWidgets(
    'late video preserves black bars through sidebar resize and fullscreen',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dimensions = ValueNotifier<Size?>(null);
      final controller = _Controller(dimensions);
      await tester.runAsync(controller.initialize);
      Widget host(double sidebar) => MaterialApp(
        home: Row(
          children: [
            Expanded(
              child: Center(
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: controller,
                  builder: (context, value, child) =>
                      AspectRatio(aspectRatio: value.aspectRatio, child: child),
                  child: SizedBox(
                    key: const ValueKey('picture'),
                    child: VideoPlayer(controller),
                  ),
                ),
              ),
            ),
            SizedBox(width: sidebar),
          ],
        ),
      );
      await tester.pumpWidget(host(400));
      await tester.pump(const Duration(seconds: 2));
      dimensions.value = const Size(1920, 1080);
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const ValueKey('picture'))),
        const Size(800, 450),
      );
      for (final sidebar in [500.0, 0.0, 400.0]) {
        await tester.pumpWidget(host(sidebar));
        final size = tester.getSize(find.byKey(const ValueKey('picture')));
        expect(size.aspectRatio, closeTo(16 / 9, 0.000001));
        expect(size.height, lessThan(800));
      }
      dimensions.value = const Size(1080, 1920);
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const ValueKey('picture'))),
        const Size(450, 800),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
      dimensions.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
