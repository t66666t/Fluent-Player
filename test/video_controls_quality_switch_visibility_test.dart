import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Completer<bool> pending;

  setUp(() {
    pending = Completer<bool>();
    MediaPlaybackService().debugCloudQualitySwitchOverride = (_) =>
        pending.future;
  });

  tearDown(() {
    MediaPlaybackService().debugCloudQualitySwitchOverride = null;
    MediaPlaybackService().debugSeedCloudDriveQualities(const []);
  });

  Widget harness({
    required VideoPlayerController controller,
    required ValueChanged<bool> onVisibility,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: SettingsService()),
        ChangeNotifierProvider<MediaPlaybackService>.value(
          value: MediaPlaybackService(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: VideoControlsOverlay(
            controller: controller,
            isLocked: false,
            onTogglePlay: () {},
            onBackPressed: () {},
            onToggleLock: () {},
            onSpeedUpdate: (_) async {},
            showSubtitles: false,
            onToggleSubtitles: () {},
            onMoveSubtitles: () {},
            isLongPressing: false,
            longPressFeedbackText: '',
            onLongPressStart: () => true,
            onLongPressEnd: () {},
            subtitleEntries: const [],
            subtitleStyle: const SubtitleStyle(),
            subtitleAlignment: Alignment.bottomCenter,
            onEnterSubtitleDragMode: () {},
            initialShowControls: true,
            onControlsVisibilityIntent: onVisibility,
          ),
        ),
      ),
    );
  }

  testWidgets('progress ticks keep quality chrome and its measurement stable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    addTearDown(controller.dispose);
    final playback = MediaPlaybackService();
    const qualities = [
      CloudDriveQualityChoice(
        id: 'original',
        label: '原画',
        transcoded: false,
        complete: true,
      ),
      CloudDriveQualityChoice(
        id: '720',
        label: '720P 转码',
        transcoded: true,
        complete: true,
      ),
    ];
    playback.debugSeedCloudDriveQualities(qualities);
    controller.value = const VideoPlayerValue(
      duration: Duration(minutes: 10),
      isInitialized: true,
    );
    await tester.pumpWidget(
      harness(controller: controller, onVisibility: (_) {}),
    );
    await tester.pump();
    final pill = find.byKey(const ValueKey('video-controls-quality-button'));
    final initialChrome = tester.widget(pill);
    final initialSize = tester.getSize(pill);

    for (var frame = 1; frame <= 24; frame++) {
      controller.value = controller.value.copyWith(
        position: Duration(milliseconds: frame * 7),
      );
      await tester.pump(const Duration(milliseconds: 7));
    }
    expect(identical(tester.widget(pill), initialChrome), isTrue);
    expect(tester.getSize(pill), initialSize);

    // An unrelated service notification must not invalidate the stable child.
    playback.debugSeedCloudDriveQualities(qualities);
    await tester.pump();
    expect(identical(tester.widget(pill), initialChrome), isTrue);

    // The selector must still react to a real quality change.
    playback.debugSeedCloudDriveQualities(qualities, selectedId: '720');
    await tester.pump();
    expect(
      find.descendant(of: pill, matching: find.text('720P 转码')),
      findsOneWidget,
    );
    expect(identical(tester.widget(pill), initialChrome), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 21));
  });

  testWidgets(
    'quality controls hide while the switch is still running',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/video.mp4'),
      );
      addTearDown(controller.dispose);
      MediaPlaybackService().debugSeedCloudDriveQualities(const [
        CloudDriveQualityChoice(
          id: 'original',
          label: '原画',
          transcoded: false,
          complete: true,
        ),
        CloudDriveQualityChoice(
          id: 'M3U8_AUTO_720',
          label: '720P 转码',
          transcoded: true,
          complete: true,
        ),
      ]);
      var chromeVisible = true;

      await tester.pumpWidget(
        harness(
          controller: controller,
          onVisibility: (visible) => chromeVisible = visible,
        ),
      );
      await tester.pump();

      final pill = tester.getRect(
        find.byKey(const ValueKey('video-controls-quality-button')),
      );
      final mouse = await tester.startGesture(
        Offset(pill.left + 6, pill.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(Offset(pill.right - 6, pill.center.dy));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('画质'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(chromeVisible, isTrue);

      await tester.tap(find.text('720P 转码'));
      await tester.pumpAndSettle();
      expect(find.text('画质'), findsNothing);
      expect(pending.isCompleted, isFalse);
      expect(chromeVisible, isTrue);

      await tester.tapAt(const Offset(600, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(chromeVisible, isFalse);
      expect(pending.isCompleted, isFalse);

      pending.complete(true);
      await tester.pump();
      expect(chromeVisible, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 21));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a rung that is not selectable cannot start a switch', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    addTearDown(controller.dispose);
    MediaPlaybackService().debugSeedCloudDriveQualities(const [
      CloudDriveQualityChoice(
        id: 'original',
        label: '原画',
        transcoded: false,
        complete: true,
      ),
      CloudDriveQualityChoice(
        id: 'M3U8_AUTO_1080',
        label: '1080P 转码',
        transcoded: true,
        complete: false,
        availability: CloudDriveQualityAvailability.discovering,
        statusDetail: '正在检测',
      ),
      CloudDriveQualityChoice(
        id: 'M3U8_AUTO_720',
        label: '720P 转码',
        transcoded: true,
        complete: false,
        availability: CloudDriveQualityAvailability.unavailable,
        statusDetail: '当前账号不可用',
      ),
    ]);

    await tester.pumpWidget(
      harness(controller: controller, onVisibility: (_) {}),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('video-controls-quality-button')),
    );
    await tester.pumpAndSettle();

    final discovering = tester.widget<SimpleDialogOption>(
      find.widgetWithText(SimpleDialogOption, '1080P 转码（正在检测）'),
    );
    expect(discovering.onPressed, isNull);
    final unavailable = tester.widget<SimpleDialogOption>(
      find.widgetWithText(SimpleDialogOption, '720P 转码（当前账号不可用）'),
    );
    expect(unavailable.onPressed, isNull);
    final ready = tester.widget<SimpleDialogOption>(
      find.widgetWithText(SimpleDialogOption, '原画 · 当前'),
    );
    expect(ready.onPressed, isNotNull);

    // Tapping a disabled rung must leave the menu open and start nothing.
    await tester.tap(find.text('1080P 转码（正在检测）'));
    await tester.pumpAndSettle();
    expect(find.text('画质'), findsOneWidget);
    expect(pending.isCompleted, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 21));
  });

  testWidgets('idle hide still runs after the quality menu closes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    addTearDown(controller.dispose);
    MediaPlaybackService().debugSeedCloudDriveQualities(const [
      CloudDriveQualityChoice(
        id: 'original',
        label: '原画',
        transcoded: false,
        complete: true,
      ),
      CloudDriveQualityChoice(
        id: 'M3U8_AUTO_1080',
        label: '1080P 转码',
        transcoded: true,
        complete: true,
      ),
    ]);
    var chromeVisible = true;

    await tester.pumpWidget(
      harness(
        controller: controller,
        onVisibility: (visible) => chromeVisible = visible,
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('video-controls-quality-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('1080P 转码'));
    await tester.pumpAndSettle();
    expect(pending.isCompleted, isFalse);

    await tester.pump(const Duration(seconds: 3));
    expect(chromeVisible, isFalse);
    expect(pending.isCompleted, isFalse);

    pending.complete(false);
    await tester.pump();
    expect(chromeVisible, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 21));
  });
}
