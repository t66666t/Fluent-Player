import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/app_haptics.dart';
import 'package:video_player_app/services/drag_haptic_session.dart';
import 'package:video_player_app/services/settings_service.dart';

const tick = 'HapticFeedbackType.selectionClick';
const light = 'HapticFeedbackType.lightImpact';
const medium = 'HapticFeedbackType.mediumImpact';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <Object?>[];
  var elapsed = Duration.zero;
  late SettingsService settings;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  DragHapticSession session({double? step}) => step == null
      ? DragHapticSession(elapsed: () => elapsed)
      : DragHapticSession(step: step, elapsed: () => elapsed);

  void move(DragHapticSession session) => session.pointerMove(
    const PointerMoveEvent(pointer: 1, position: Offset(40, 0)),
  );

  void start(DragHapticSession session, {double value = 0.2}) {
    session.pointerDown(const PointerDownEvent(pointer: 1));
    session.begin(value);
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
    calls.clear();
    elapsed = Duration.zero;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add(call.arguments);
          }
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      '$platform: tap seeks emit once, a real drag also confirms release',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final drag = session();
        start(drag);
        drag.update(0.8); // A far-away tap is still a tap, not a long drag.
        drag.end();
        await flush();
        expect(calls, [tick]);

        calls.clear();
        start(drag);
        move(drag);
        drag.update(0.23);
        drag.end();
        await flush();
        expect(calls, [tick, light]);
      },
    );
  }

  test(
    'firmer ticks start at 2 percent and 80ms; chapter ticks share the budget',
    () async {
      final drag = session();
      start(drag);
      move(drag);
      elapsed = const Duration(milliseconds: 79);
      drag.update(0.7, checkpoint: true);
      await flush();
      expect(calls, [tick]);
      elapsed = const Duration(milliseconds: 80);
      drag.update(0.219);
      await flush();
      expect(calls, [tick]);
      drag.update(0.22, checkpoint: true);
      drag.update(0.6, checkpoint: true);
      await flush();
      expect(calls, [tick, light]);
      elapsed = const Duration(milliseconds: 160);
      drag.update(0.8, checkpoint: true);
      await flush();
      expect(calls, [tick, light, light]);
      // No timers replay the checkpoints skipped during the fast movement.
      elapsed = const Duration(seconds: 2);
      await flush();
      expect(calls, [tick, light, light]);
      drag.end();
      await flush();
      expect(calls.last, light);
    },
  );

  test(
    'cancel zone transitions pulse once, suppress ticks and never confirm cancellation',
    () async {
      final drag = session();
      start(drag);
      move(drag);
      drag.setCanceling(true);
      drag.setCanceling(true);
      elapsed = const Duration(seconds: 1);
      drag.update(0.8, checkpoint: true);
      drag.end();
      await flush();
      expect(calls, [tick, medium]);

      calls.clear();
      start(drag);
      move(drag);
      drag.setCanceling(true);
      drag.update(0.4);
      drag.setCanceling(false);
      drag.update(0.41);
      drag.end();
      await flush();
      expect(calls, [tick, medium, tick, light]);
    },
  );

  test('reset discards cancelled pointers and late callbacks', () async {
    final drag = session();
    start(drag);
    move(drag);
    drag.update(0.6);
    drag.reset();
    elapsed = const Duration(seconds: 1);
    drag.update(0.9, checkpoint: true);
    drag.setCanceling(true);
    drag.end();
    await flush();
    expect(calls, [tick]);
    start(drag);
    drag.end();
    await flush();
    expect(calls, [tick, tick]);
  });

  test(
    'switching off during a gesture silences all subsequent feedback',
    () async {
      final drag = session();
      start(drag);
      move(drag);
      await settings.saveEnableHapticFeedback(false);
      elapsed = const Duration(seconds: 1);
      drag.update(0.6, checkpoint: true);
      drag.setCanceling(true);
      drag.setCanceling(false);
      drag.end();
      await AppHaptics.sidebarOpened(settings);
      await AppHaptics.resizeBoundaryReached(settings);
      await AppHaptics.cardTap(settings);
      await flush();
      expect(calls, [tick]);
    },
  );

  test(
    'sidebar resize ticks are 12dp with a distinct hard stop; holding it does not repeat',
    () async {
      final drag = session(step: 12);
      drag.begin(300, dragging: true);
      elapsed = const Duration(milliseconds: 80);
      drag.update(311);
      await flush();
      expect(calls, [tick]);
      drag.update(312);
      drag.update(500, boundary: 1);
      elapsed = const Duration(seconds: 1);
      drag.update(500, boundary: 1);
      await flush();
      expect(calls, [tick, light, medium]);
      drag.update(460);
      drag.update(100, boundary: -1);
      drag.end();
      await flush();
      expect(calls, [tick, light, medium, light, medium]);
    },
  );

  test(
    'cancelled resize and a grab without a width change have no commit pulse',
    () async {
      final drag = session(step: 12);
      drag.begin(300, dragging: true);
      drag.update(310);
      drag.end(committed: false);
      drag.begin(300, dragging: true);
      drag.end();
      await flush();
      expect(calls, [tick, tick]);
    },
  );

  test(
    'desktop targets stay silent; platform feedback failure is non-fatal',
    () async {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        final drag = session();
        start(drag);
        move(drag);
        drag.update(0.6);
        drag.end();
        await AppHaptics.sidebarOpened(settings);
      }
      await flush();
      expect(calls, isEmpty);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (_) async {
            throw PlatformException(code: 'unsupported');
          });
      await AppHaptics.sidebarOpened(settings);
      await AppHaptics.dragTick(settings);
    },
  );
}
