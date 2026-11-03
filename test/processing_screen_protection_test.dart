import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:video_player_app/widgets/processing_screen_protection.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class _Wake extends WakelockPlusWindowsPlugin {
  @override
  Future<void> toggle({required bool enable}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final original = wakelockPlusPlatformInstance;
  const reason = AppWakelockCoordinator.transcriptionReason;
  final protection = find.byKey(const ValueKey('processing-screen-protection'));
  late ProtectionNavigatorObserver observer;
  late GlobalKey<NavigatorState> navigator;
  late ValueNotifier<bool> enabled;
  var actions = 0;
  var percent = 63;
  final preview = Platform.environment['PROTECTION_PREVIEW'] == '1';

  setUpAll(() async {
    if (preview) {
      await (FontLoader(
            'Noto Sans SC',
          )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
          .load();
    }
  });
  setUp(() {
    wakelockPlusPlatformInstance = _Wake();
    observer = ProtectionNavigatorObserver();
    navigator = GlobalKey<NavigatorState>();
    enabled = ValueNotifier(true);
    actions = 0;
    percent = 63;
    AppWakelockCoordinator.setActive(
      reason,
      true,
      detail: () => '字幕转录 · $percent%',
    );
  });
  tearDown(() {
    AppWakelockCoordinator.setActive(reason, false);
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      false,
    );
    wakelockPlusPlatformInstance = original;
    enabled.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Noto Sans SC'),
          navigatorKey: navigator,
          navigatorObservers: [observer],
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, value, _) => ProcessingScreenProtection(
              enabled: value,
              observer: observer,
              child: child!,
            ),
          ),
          home: Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => actions++,
              child: const SizedBox.expand(child: Center(child: Text('任务页面'))),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(protection, findsOneWidget);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'ten second idle; first tap exits without passing through; re-entry',
    (tester) async {
      await mount(tester);
      await tester.pump(const Duration(seconds: 9));
      expect(protection, findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(protection, findsOneWidget);
      await tester.tapAt(const Offset(100, 100));
      await tester.pump();
      expect(protection, findsNothing);
      expect(actions, 0);
      await tester.tapAt(const Offset(100, 100));
      expect(actions, 1);
      await enter(tester);
      await tester.tapAt(const Offset(100, 100));
      await tester.pump();
      expect(protection, findsNothing);
      await finish(tester);
    },
  );

  testWidgets('system back consumes local history and preserves route', (
    tester,
  ) async {
    await mount(tester);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('第二页')),
      ),
    );
    await tester.pumpAndSettle();
    await enter(tester);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(protection, findsNothing);
    expect(find.text('第二页'), findsOneWidget);
    expect(navigator.currentState!.canPop(), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('任务页面'), findsOneWidget);
    await finish(tester);
  });

  for (final key in [
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.keyA,
  ]) {
    testWidgets('keyboard $key dismisses', (tester) async {
      await mount(tester);
      await enter(tester);
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(protection, findsNothing);
      await finish(tester);
    });
  }

  for (final buttons in [
    kPrimaryMouseButton,
    kSecondaryMouseButton,
    kBackMouseButton,
  ]) {
    testWidgets('mouse button $buttons exits', (tester) async {
      await mount(tester);
      await enter(tester);
      final mouse = await tester.startGesture(
        const Offset(100, 100),
        kind: PointerDeviceKind.mouse,
        buttons: buttons,
      );
      await mouse.up();
      await tester.pump();
      expect(protection, findsNothing);
      expect(actions, 0);
      await finish(tester);
    });
  }

  testWidgets(
    'switch off, playback, finish and background all remove overlay',
    (tester) async {
      await mount(tester);
      await enter(tester);
      enabled.value = false;
      await tester.pump();
      expect(protection, findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(protection, findsNothing);
      enabled.value = true;
      await tester.pump();
      await enter(tester);
      AppWakelockCoordinator.setActive(
        AppWakelockCoordinator.mediaPlaybackReason,
        true,
      );
      await tester.pump();
      expect(protection, findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(protection, findsNothing);
      AppWakelockCoordinator.setActive(
        AppWakelockCoordinator.mediaPlaybackReason,
        false,
      );
      await tester.pump();
      await enter(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Paused applications do not render frames. Verify on the first resumed
      // frame that the old overlay is gone and the idle timer starts fresh.
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(protection, findsNothing);
      await enter(tester);
      AppWakelockCoordinator.setActive(reason, false);
      await tester.pump();
      expect(protection, findsNothing);
      await finish(tester);
    },
  );

  testWidgets('navigation exits; active pointer prevents entering', (
    tester,
  ) async {
    await mount(tester);
    final touch = await tester.startGesture(const Offset(100, 100));
    await tester.pump(const Duration(seconds: 20));
    expect(protection, findsNothing);
    await touch.cancel();
    await enter(tester);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('新页面')),
      ),
    );
    await tester.pumpAndSettle();
    expect(protection, findsNothing);
    expect(find.text('新页面'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('sampled progress has stable geometry; move has dark interval', (
    tester,
  ) async {
    await mount(tester);
    percent = 9;
    await enter(tester);
    final rect = tester.getRect(find.byType(ProtectionReadout));
    percent = 100;
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('9%'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('100%'), findsOneWidget);
    expect(tester.getRect(find.byType(ProtectionReadout)), rect);
    await tester.pump(const Duration(seconds: 25));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(tester.getRect(find.byType(ProtectionReadout)), isNot(rect));
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(protection, findsNothing);
    await finish(tester);
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(568, 320),
    const Size(768, 1024),
    const Size(1280, 800),
    const Size(1920, 1080),
    const Size(240, 240),
  ]) {
    testWidgets('layout and exit at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      await enter(tester);
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(ProtectionReadout));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(size.width));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      if (preview) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('preview')),
          );
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '.artifacts/screen-protection/${size.width.toInt()}x${size.height.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tapAt(Offset(size.width - 10, size.height - 10));
      await tester.pump();
      expect(protection, findsNothing);
      await finish(tester);
    });
  }

  testWidgets(
    'exit works during fully black relocation and repeated sessions',
    (tester) async {
      await mount(tester);
      for (var cycle = 0; cycle < 4; cycle++) {
        await enter(tester);
        await tester.pump(const Duration(seconds: 30));
        await tester.pump(const Duration(milliseconds: 700));
        await tester.tapAt(const Offset(15, 15));
        await tester.pump();
        expect(protection, findsNothing);
        expect(actions, 0);
      }
      await enter(tester);
      await finish(tester);
      await tester.pump(const Duration(minutes: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'other processing owner survives; broken progress reader cannot trap exit',
    (tester) async {
      const download = AppWakelockCoordinator.bilibiliDownloadReason;
      AppWakelockCoordinator.setActive(
        download,
        true,
        detail: () => throw StateError('task removed'),
      );
      addTearDown(() => AppWakelockCoordinator.setActive(download, false));
      await mount(tester);
      await enter(tester);
      AppWakelockCoordinator.setActive(reason, false);
      await tester.pump(const Duration(seconds: 5));
      expect(protection, findsOneWidget);
      expect(find.text('B 站下载进行中'), findsOneWidget);
      await tester.tapAt(const Offset(30, 30));
      await tester.pump();
      expect(protection, findsNothing);
      expect(AppWakelockCoordinator.isReasonActive(download), isTrue);
      await finish(tester);
    },
  );

  testWidgets('large text, rotation and screen reader navigation', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(tester);
    await enter(tester);
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump(const Duration(seconds: 20));
    expect(protection, findsNothing);
    await finish(tester);
  });

  test('protection preference persists and is exported', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    expect(settings.processingScreenProtection, isTrue);
    await settings.updateSetting('processingScreenProtection', false);
    expect(settings.processingScreenProtection, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'processingScreenProtection',
      ),
      isFalse,
    );
    expect(
      settings
          .exportSettingsSnapshot()['general']['processingScreenProtection'],
      isFalse,
    );
  });
}
