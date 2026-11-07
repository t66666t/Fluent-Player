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

const _railKey = ValueKey('swipe-seek-progress-slider');
const _timeKey = ValueKey('video-controls-time-display');

typedef _Configuration = ({bool locked, bool blocked, String itemId});

class _Player {
  final controller = VideoPlayerController.file(File('swipe-seek-test.mp4'));
  final playback = MediaPlaybackService.forTesting();
  final key = GlobalKey<VideoControlsOverlayState>();
  final seeks = <Duration>[];
  final configuration = ValueNotifier<_Configuration>((
    locked: false,
    blocked: false,
    itemId: 'first',
  ));

  Slider getSlider(WidgetTester tester) => tester.widget<Slider>(
    find.byWidgetPredicate(
      (widget) => widget is Slider && widget.key != _railKey,
    ),
  );

  double progress(WidgetTester tester) => getSlider(tester).value;

  void tick(Duration position) {
    controller.value = controller.value.copyWith(position: position);
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(800, 400),
    bool visible = false,
    Duration position = const Duration(minutes: 5),
    Duration duration = const Duration(minutes: 10),
    bool disableAnimations = false,
    TextDirection direction = TextDirection.ltr,
    EdgeInsets viewPadding = EdgeInsets.zero,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    controller.value = VideoPlayerValue(
      duration: duration,
      position: position,
      isInitialized: true,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
      await controller.dispose();
      playback.dispose();
      configuration.dispose();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              disableAnimations: disableAnimations,
              viewPadding: viewPadding,
            ),
            child: Directionality(
              textDirection: direction,
              child: Scaffold(
                body: ValueListenableBuilder<_Configuration>(
                  valueListenable: configuration,
                  builder: (context, value, _) => VideoControlsOverlay(
                    key: key,
                    controller: controller,
                    mediaItemId: value.itemId,
                    initialShowControls: visible,
                    enableSeekThumbnailPreview: false,
                    isLocked: value.locked,
                    suppressPrimaryGestures: value.blocked,
                    onTogglePlay: () {},
                    onBackPressed: () {},
                    onSeekTo: seeks.add,
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
        ),
      ),
    );
    await tester.pump();
  }

  Future<TestGesture> swipe(
    WidgetTester tester, {
    Offset? start,
    double dx = 80,
  }) async {
    final rect = tester.getRect(find.byType(VideoControlsOverlay));
    final gesture = await tester.startGesture(start ?? rect.center);
    // The first move crosses the existing drag threshold and chooses its
    // origin; sensitivity remains one second per ten logical pixels.
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(dx, 0));
    await tester.pump();
    return gesture;
  }
}

void main() {
  for (final size in [
    const Size(400, 800),
    const Size(800, 400),
    const Size(1280, 800),
    const Size(800, 1280),
  ]) {
    for (final duration in [
      const Duration(minutes: 10),
      const Duration(hours: 2),
    ]) {
      testWidgets(
        'progress drag has consistent haptic spacing at $size over $duration',
        (tester) async {
          final calls = <Object?>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'HapticFeedback.vibrate') {
                calls.add(call.arguments);
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          final player = _Player();
          await player.pump(
            tester,
            size: size,
            visible: true,
            duration: duration,
            position: duration ~/ 2,
          );
          final rect = tester.getRect(find.byWidget(player.getSlider(tester)));
          final gesture = await tester.startGesture(rect.center);
          await gesture.moveBy(const Offset(24, 0));
          await tester.pump();
          calls.clear();
          for (var i = 0; i < 3; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 60)),
            );
            await gesture.moveBy(const Offset(12, 0));
            await tester.pump();
          }
          expect(calls, List.filled(3, 'HapticFeedbackType.lightImpact'));
          player.tick(
            player.controller.value.position + const Duration(seconds: 1),
          );
          await tester.pump();
          expect(calls, hasLength(3));
          await SettingsService().saveEnableHapticFeedback(false);
          calls.clear();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await gesture.moveBy(const Offset(30, 0));
          await gesture.up();
          await tester.pump();
          expect(calls, isEmpty);
          expect(player.seeks, hasLength(1));
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.iOS,
        }),
      );
    }
  }

  for (final size in [const Size(800, 400), const Size(400, 800)]) {
    testWidgets(
      'swipe haptics follow movement and cancel-zone transitions at $size',
      (tester) async {
        final calls = <Object?>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              calls.add(call.arguments);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final player = _Player();
        await player.pump(tester, size: size);
        calls.clear();
        final gesture = await player.swipe(tester, dx: 0);
        expect(calls, ['HapticFeedbackType.selectionClick']);

        Future<void> move(Offset delta) async {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await gesture.moveBy(delta);
          await tester.pump();
        }

        await move(const Offset(12, 0));
        expect(calls.last, 'HapticFeedbackType.lightImpact');
        final count = calls.length;
        player.tick(const Duration(seconds: 301));
        await move(Offset.zero);
        expect(calls, hasLength(count));
        await move(const Offset(-12, 0));
        expect(calls, hasLength(count + 1));
        await gesture.moveTo(Offset(size.width / 2 + 30, size.height * 0.1));
        await tester.pump();
        expect(calls, hasLength(count + 2));
        expect(calls.last, 'HapticFeedbackType.lightImpact');
        await move(const Offset(20, 0));
        expect(calls, hasLength(count + 2));
        await gesture.moveTo(Offset(size.width / 2 + 50, size.height / 2));
        await tester.pump();
        expect(calls.last, 'HapticFeedbackType.selectionClick');
        await gesture.up();
        await tester.pump();
        expect(calls.last, 'HapticFeedbackType.lightImpact');
        expect(player.seeks, hasLength(1));
        calls.clear();
        await tester.pump(const Duration(seconds: 4));
        expect(calls, isEmpty);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets(
    'the vibration switch silences start, movement, cancel and release immediately',
    (tester) async {
      final calls = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final player = _Player();
      await player.pump(tester);
      final settings = SettingsService();
      await settings.saveEnableHapticFeedback(false);
      calls.clear();
      final gesture = await player.swipe(tester);
      await gesture.moveTo(const Offset(510, 30));
      await tester.pump();
      expect(calls, isEmpty);
      await settings.saveEnableHapticFeedback(true);
      await gesture.moveTo(const Offset(510, 200));
      await tester.pump();
      expect(calls, ['HapticFeedbackType.selectionClick']);
      await settings.saveEnableHapticFeedback(false);
      calls.clear();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await gesture.moveBy(const Offset(30, 0));
      await gesture.moveTo(const Offset(540, 30));
      await gesture.up();
      await tester.pump(const Duration(seconds: 4));
      expect(calls, isEmpty);
      expect(player.seeks, isEmpty);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final size in [const Size(800, 400), const Size(400, 800)]) {
    for (final visible in [false, true]) {
      testWidgets(
        '$size visible=$visible follows the finger and holds until native landing',
        (tester) async {
          final player = _Player();
          await player.pump(tester, size: size, visible: visible);
          final gesture = await player.swipe(tester);
          expect(player.progress(tester), 308000);
          expect(player.seeks, isEmpty);
          expect(player.controller.value.position, const Duration(minutes: 5));
          expect(player.key.currentState!.controlsVisible, visible);

          if (!visible) {
            expect(tester.widget<Slider>(find.byKey(_railKey)).value, 308000);
            // Both tracks share a baseline, side insets and text direction.
            expect(
              tester.getCenter(find.byKey(_railKey)).dy,
              closeTo(
                tester.getCenter(find.byWidget(player.getSlider(tester))).dy,
                0.01,
              ),
            );
            expect(
              tester.getRect(find.byKey(_railKey)).left,
              tester.getRect(find.byWidget(player.getSlider(tester))).left,
            );
          } else {
            expect(find.byKey(_railKey), findsNothing);
          }
          expect(
            tester.widget<Text>(find.byKey(_timeKey)).data,
            '05:08 / 10:00',
          );

          player.tick(const Duration(seconds: 301));
          await tester.pump();
          expect(player.progress(tester), 308000);
          await gesture.moveBy(const Offset(10, 0));
          await tester.pump();
          expect(player.progress(tester), 309000);
          await gesture.up();
          await tester.pump();
          expect(player.seeks, [const Duration(seconds: 309)]);
          expect(player.progress(tester), 309000);

          // Old native events arriving after release must not flash backward.
          player.tick(const Duration(seconds: 302));
          await tester.pump(const Duration(milliseconds: 60));
          expect(player.progress(tester), 309000);
          player.tick(const Duration(milliseconds: 308900));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 90));
          expect(player.progress(tester), inInclusiveRange(308900, 309000));
          await tester.pump(const Duration(milliseconds: 200));
          expect(player.progress(tester), 308900);
          expect(find.byKey(_railKey), findsNothing);
          expect(player.key.currentState!.controlsVisible, visible);
          expect(tester.takeException(), isNull);
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.windows,
        }),
      );
    }
  }

  for (final pointerCancel in [false, true]) {
    testWidgets('cancel ($pointerCancel) returns smoothly without seeking', (
      tester,
    ) async {
      final player = _Player();
      await player.pump(tester, visible: true);
      final gesture = await player.swipe(tester, dx: 200);
      expect(player.progress(tester), 320000);
      if (pointerCancel) {
        await gesture.cancel();
      } else {
        await gesture.moveTo(const Offset(630, 30));
        await tester.pump();
        expect(find.text('松手取消跳转'), findsOneWidget);
        await gesture.up();
      }
      await tester.pump();
      final released = player.progress(tester);
      expect(released, greaterThan(300000));
      await tester.pump(const Duration(milliseconds: 90));
      expect(player.progress(tester), greaterThan(300000));
      expect(player.progress(tester), lessThan(released));
      player.tick(const Duration(seconds: 301));
      await tester.pump(const Duration(milliseconds: 200));
      expect(player.progress(tester), 301000);
      expect(player.seeks, isEmpty);
    });
  }

  testWidgets('leaving the cancel zone restores the original commit behavior', (
    tester,
  ) async {
    final player = _Player();
    await player.pump(tester);
    final gesture = await player.swipe(tester);
    await gesture.moveTo(const Offset(510, 30));
    await tester.pump();
    expect(find.text('松手取消跳转'), findsOneWidget);
    await gesture.moveTo(const Offset(510, 200));
    await tester.pump();
    final target = player.progress(tester);
    await gesture.up();
    await tester.pump();
    expect(player.seeks.single.inMilliseconds, target);
    expect(player.key.currentState!.controlsVisible, isFalse);
  });

  testWidgets(
    'a new swipe owns an unfinished cancel animation and landing timeout',
    (tester) async {
      final player = _Player();
      await player.pump(tester, visible: true);
      final first = await player.swipe(tester, dx: 200);
      await first.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final before = player.progress(tester);
      final next = await tester.startGesture(const Offset(300, 200));
      await next.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(player.progress(tester), before);
      await next.moveBy(const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 250));
      expect(player.progress(tester), before + 8000);
      await next.up();
      await tester.pump();
      expect(player.seeks.single.inMilliseconds, before + 8000);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 200));
      expect(player.progress(tester), 300000);
    },
  );

  testWidgets('fractional movement stays smooth at the existing sensitivity', (
    tester,
  ) async {
    final player = _Player();
    await player.pump(tester);
    final gesture = await player.swipe(tester, dx: 80.5);
    expect(player.progress(tester), 308050);
    await gesture.moveBy(const Offset(0.75, 0));
    await tester.pump();
    expect(player.progress(tester), 308125);
    expect(tester.widget<Slider>(find.byKey(_railKey)).value, 308125);
    await tester.pump(const Duration(milliseconds: 180));
    await gesture.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(
      tester.widget<Slider>(find.byKey(_railKey)).value,
      inExclusiveRange(300000, 308125),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(_railKey), findsNothing);
    expect(player.seeks, isEmpty);
  });

  testWidgets('a second committed swipe replaces the first landing hold', (
    tester,
  ) async {
    final player = _Player();
    await player.pump(tester, visible: true);
    final first = await player.swipe(tester);
    await first.up();
    await tester.pump(const Duration(seconds: 2));
    final second = await player.swipe(tester);
    player.tick(const Duration(seconds: 308));
    await second.up();
    await tester.pump();
    expect(player.seeks, [
      const Duration(seconds: 308),
      const Duration(seconds: 316),
    ]);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(player.progress(tester), 316000);
    player.tick(const Duration(seconds: 316));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(player.progress(tester), 316000);
  });

  testWidgets('a sub-second seek ignores its unchanged native position', (
    tester,
  ) async {
    final player = _Player();
    await player.pump(tester, visible: true);
    final gesture = await player.swipe(tester, dx: 3);
    await gesture.up();
    await tester.pump();
    player.tick(const Duration(milliseconds: 300050));
    await tester.pump(const Duration(milliseconds: 250));
    expect(player.progress(tester), 300300);
    player.tick(const Duration(milliseconds: 300300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(player.progress(tester), 300300);
    expect(player.seeks, [const Duration(milliseconds: 300300)]);
  });

  testWidgets('a changed duration bounds both the preview and committed seek', (
    tester,
  ) async {
    final player = _Player();
    await player.pump(tester, visible: true);
    final gesture = await player.swipe(tester);
    player.controller.value = player.controller.value.copyWith(
      duration: const Duration(seconds: 305),
    );
    await tester.pump();
    expect(player.progress(tester), 305000);
    await gesture.up();
    await tester.pump();
    expect(player.seeks, [const Duration(seconds: 305)]);
  });

  testWidgets('backgrounding cancels the gesture before a late release', (
    tester,
  ) async {
    final player = _Player();
    await player.pump(tester, visible: true);
    final gesture = await player.swipe(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.seeks, isEmpty);
    expect(player.progress(tester), 300000);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('RTL and safe-area insets preserve the shared track geometry', (
    tester,
  ) async {
    final player = _Player();
    await player.pump(
      tester,
      direction: TextDirection.rtl,
      viewPadding: const EdgeInsets.only(left: 44, right: 32, bottom: 24),
    );
    final gesture = await player.swipe(tester);
    final railRect = tester.getRect(find.byKey(_railKey));
    final normalRect = tester.getRect(find.byWidget(player.getSlider(tester)));
    expect(railRect.left, normalRect.left);
    expect(railRect.right, normalRect.right);
    expect(railRect.center.dy, closeTo(normalRect.center.dy, 0.01));
    expect(player.progress(tester), 308000);
    await gesture.cancel();
  });

  for (final (position, dx, expected) in [
    (const Duration(seconds: 2), -100.0, Duration.zero),
    (const Duration(seconds: 599), 100.0, const Duration(minutes: 10)),
  ]) {
    testWidgets('clamps the swipe at $expected', (tester) async {
      final player = _Player();
      await player.pump(tester, position: position);
      final gesture = await player.swipe(tester, dx: dx);
      expect(player.progress(tester), expected.inMilliseconds);
      expect(
        tester.widget<Slider>(find.byKey(_railKey)).value,
        expected.inMilliseconds,
      );
      await gesture.up();
      await tester.pump();
      expect(player.seeks, [expected]);
    });
  }

  for (final configuration in <_Configuration>[
    (locked: true, blocked: false, itemId: 'first'),
    (locked: false, blocked: true, itemId: 'first'),
    (locked: false, blocked: false, itemId: 'second'),
  ]) {
    testWidgets(
      'invalidates an old swipe when configuration becomes $configuration',
      (tester) async {
        final player = _Player();
        await player.pump(tester, visible: true);
        final gesture = await player.swipe(tester);
        player.configuration.value = configuration;
        await tester.pump();
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 300));
        expect(player.seeks, isEmpty);
        expect(player.progress(tester), 300000);
        expect(find.byKey(_railKey), findsNothing);
        player.configuration.value = (
          locked: false,
          blocked: false,
          itemId: 'second',
        );
        await tester.pump();
        final next = await player.swipe(tester);
        await next.up();
        await tester.pump();
        expect(player.seeks, hasLength(1));
      },
    );
  }

  testWidgets(
    'reduced motion cancels immediately and zero duration cannot seek',
    (tester) async {
      final player = _Player();
      await player.pump(tester, visible: true, disableAnimations: true);
      final gesture = await player.swipe(tester);
      await gesture.cancel();
      await tester.pump();
      expect(player.progress(tester), 300000);
      player.controller.value = player.controller.value.copyWith(
        duration: Duration.zero,
      );
      final invalid = await player.swipe(tester);
      await invalid.up();
      await tester.pump();
      expect(player.seeks, isEmpty);
      expect(player.progress(tester), 0);
      expect(tester.takeException(), isNull);
    },
  );
}
