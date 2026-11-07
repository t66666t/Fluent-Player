import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
  });

  Future<MediaPlaybackService> pumpPlayer(
    WidgetTester tester, {
    Size size = const Size(800, 400),
    double pixelRatio = 1,
    FakeViewPadding viewPadding = FakeViewPadding.zero,
    FakeViewPadding gestureInsets = FakeViewPadding.zero,
    EdgeInsets playerPadding = EdgeInsets.zero,
    ValueChanged<Duration>? onSeekTo,
  }) async {
    tester.view.devicePixelRatio = pixelRatio;
    tester.view.physicalSize = size * pixelRatio;
    tester.view.viewPadding = viewPadding;
    tester.view.systemGestureInsets = gestureInsets;
    addTearDown(tester.view.reset);

    final controller = VideoPlayerController.file(File('gesture-test.mp4'));
    controller.value = const VideoPlayerValue(
      duration: Duration(minutes: 10),
      position: Duration(minutes: 5),
      isInitialized: true,
      volume: 0.5,
    );
    final playback = MediaPlaybackService.forTesting();
    await playback.setVolume(0.5);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
      await controller.dispose();
      playback.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: playerPadding,
              child: VideoControlsOverlay(
                controller: controller,
                initialShowControls: false,
                enableSeekThumbnailPreview: false,
                isLocked: false,
                onTogglePlay: () {},
                onBackPressed: () {},
                onSeekTo: onSeekTo ?? (_) {},
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
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return playback;
  }

  // These tests exercise the actual overlay and arena. Platform overrides
  // select mobile input rules; native brightness/volume calls are not tested.
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final size in [const Size(400, 800), const Size(800, 400)]) {
      testWidgets(
        '$platform $size: edge-origin swipes remain ignored',
        (tester) async {
          final seeks = <Duration>[];
          await pumpPlayer(tester, size: size, onSeekTo: seeks.add);

          for (final x in [size.width * 0.1, size.width * 0.9]) {
            for (final y in [size.height * 0.05, size.height * 0.95]) {
              final gesture = await tester.startGesture(Offset(x, y));
              await gesture.moveTo(Offset(x, size.height * 0.5));
              await tester.pump();
              expect(seeks, isEmpty);
              expect(find.byType(LinearProgressIndicator), findsNothing);
              await gesture.up();
              await tester.pump();
              expect(seeks, isEmpty);
            }
          }
        },
        variant: TargetPlatformVariant.only(platform),
      );

      testWidgets(
        '$platform $size: valid swipes keep working in edge zones',
        (tester) async {
          await pumpPlayer(tester, size: size);

          for (final x in [size.width * 0.1, size.width * 0.9]) {
            final gesture = await tester.startGesture(
              Offset(x, size.height * 0.85),
            );
            await gesture.moveTo(Offset(x, size.height * 0.95));
            await tester.pump();
            expect(find.byType(LinearProgressIndicator), findsOneWidget);
            final value = tester
                .widget<LinearProgressIndicator>(
                  find.byType(LinearProgressIndicator),
                )
                .value!;
            await gesture.moveBy(Offset(0, size.height * 0.03));
            await tester.pump();
            expect(
              tester
                  .widget<LinearProgressIndicator>(
                    find.byType(LinearProgressIndicator),
                  )
                  .value!,
              lessThan(value),
            );
            await gesture.up();
            await tester.pump();
            expect(find.byType(LinearProgressIndicator), findsNothing);
          }
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }

  testWidgets(
    'safe areas larger than ten percent win at device pixel ratio 2',
    (tester) async {
      await pumpPlayer(
        tester,
        pixelRatio: 2,
        viewPadding: const FakeViewPadding(top: 160, left: 120),
        gestureInsets: const FakeViewPadding(bottom: 160, right: 120),
      );

      for (final position in [
        const Offset(100, 60),
        const Offset(700, 340),
        const Offset(30, 200),
        const Offset(770, 200),
      ]) {
        final gesture = await tester.startGesture(position);
        await gesture.moveBy(Offset(0, position.dy > 200 ? -100 : 100));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await gesture.up();
        await tester.pump();
      }

      final valid = await tester.startGesture(const Offset(700, 200));
      await valid.moveBy(const Offset(0, 50));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await valid.up();
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'an inset player uses its own height without doubling safe areas',
    (tester) async {
      await pumpPlayer(
        tester,
        size: const Size(400, 800),
        viewPadding: const FakeViewPadding(top: 160, bottom: 240),
        playerPadding: const EdgeInsets.only(top: 160, bottom: 240),
      );

      // The 400-high player occupies window y=160..560. Its first/last 40px
      // are excluded, even though the window's safe area is already outside it.
      final blocked = await tester.startGesture(const Offset(360, 180));
      await blocked.moveTo(const Offset(360, 300));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await blocked.up();

      final valid = await tester.startGesture(const Offset(360, 220));
      await valid.moveBy(const Offset(0, 50));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await valid.up();
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'the initial contact chooses brightness or volume',
    (tester) async {
      await pumpPlayer(tester);

      for (final (startX, driftX, icon) in [
        (152.0, 24.0, Icons.brightness_6),
        (648.0, -24.0, Icons.volume_up),
      ]) {
        final gesture = await tester.startGesture(Offset(startX, 180));
        await gesture.moveBy(Offset(driftX, 80));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        final feedback = find
            .ancestor(
              of: find.byType(LinearProgressIndicator),
              matching: find.byType(Column),
            )
            .first;
        expect(
          find.descendant(of: feedback, matching: find.byIcon(icon)),
          findsOneWidget,
        );
        await gesture.cancel();
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsNothing);
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'edge swipes cannot reuse an existing keyboard volume adjustment',
    (tester) async {
      final playback = await pumpPlayer(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(playback.volume, closeTo(0.45, 1e-9));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      final gesture = await tester.startGesture(const Offset(720, 20));
      await gesture.moveBy(const Offset(24, 160));
      await tester.pump();
      expect(playback.volume, closeTo(0.45, 1e-9));
      await gesture.up();
      await tester.pump();
      expect(playback.volume, closeTo(0.45, 1e-9));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'horizontal seeking still works without triggering vertical adjustment',
    (tester) async {
      final seeks = <Duration>[];
      await pumpPlayer(tester, onSeekTo: seeks.add);
      final gesture = await tester.startGesture(const Offset(320, 200));
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await gesture.up();
      await tester.pump();
      expect(seeks, hasLength(1));
      expect(seeks.single, greaterThan(const Duration(minutes: 5)));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'desktop vertical adjustment still starts near the top edge',
    (tester) async {
      await pumpPlayer(tester);

      final gesture = await tester.startGesture(const Offset(720, 10));
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await gesture.up();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
