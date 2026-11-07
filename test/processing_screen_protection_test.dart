import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:video_player_app/widgets/processing_screen_protection.dart';
import 'package:video_player_app/widgets/processing_screen_protection_settings.dart';
import 'package:video_player_app/platform/app_video_player_controller.dart';
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
  late ValueNotifier<bool> playbackActive;
  late SettingsService settings;
  var actions = 0;
  var percent = 63;
  final preview = Platform.environment['PROTECTION_PREVIEW'] == '1';

  setUpAll(() async {
    if (preview) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await (FontLoader(
            'Noto Sans SC',
          )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
          .load();
    }
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
    wakelockPlusPlatformInstance = _Wake();
    observer = ProtectionNavigatorObserver();
    navigator = GlobalKey<NavigatorState>();
    enabled = ValueNotifier(true);
    playbackActive = ValueNotifier(false);
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
    playbackActive.dispose();
  });

  Future<void> mount(WidgetTester tester, {Widget? home}) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Noto Sans SC'),
          navigatorKey: navigator,
          navigatorObservers: [observer],
          builder: (context, child) => ListenableBuilder(
            listenable: Listenable.merge([enabled, playbackActive, settings]),
            builder: (context, _) => ProcessingScreenProtection(
              enabled: enabled.value && settings.processingScreenProtection,
              playbackActive: playbackActive.value,
              idleDelay: Duration(
                seconds: settings.processingScreenProtectionWaitSeconds,
              ),
              onDisableRequested: (context) =>
                  showProcessingScreenProtectionSettings(
                    context,
                    settings,
                    confirmDisable: true,
                  ),
              observer: observer,
              child: child!,
            ),
          ),
          home:
              home ??
              Scaffold(
                body: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => actions++,
                  child: const SizedBox.expand(
                    child: Center(child: Text('任务页面')),
                  ),
                ),
              ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.pump(
      Duration(seconds: settings.processingScreenProtectionWaitSeconds),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 650));
    expect(protection, findsOneWidget);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'fifteen second idle; first tap exits without passing through; re-entry',
    (tester) async {
      await mount(tester);
      await tester.pump(const Duration(seconds: 14));
      expect(protection, findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(protection, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 650));
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
      final icon = tester.getRect(
        find.byKey(const ValueKey('processing-protection-disable-icon')),
      );
      final label = tester.getRect(
        find.byKey(const ValueKey('processing-protection-disable-label')),
      );
      expect(
        icon.expandToInclude(label).center.dx,
        closeTo(rect.center.dx, .1),
      );
      expect(icon.center.dy, closeTo(label.center.dy, .1));
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

  testWidgets('entry fades and slides in; reduced motion enters immediately', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    final transition = find.byKey(
      const ValueKey('processing-protection-entrance'),
    );
    double opacity() => tester.widget<FadeTransition>(transition).opacity.value;
    expect(opacity(), 0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(opacity(), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 350));
    expect(opacity(), 1);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(opacity(), 1);
    await finish(tester);
  });

  testWidgets(
    'OCR with native preview playback or buffering never covers media',
    (tester) async {
      AppWakelockCoordinator.setActive(reason, false);
      AppWakelockCoordinator.setActive(
        AppWakelockCoordinator.ocrProcessingReason,
        true,
      );
      addTearDown(
        () => AppWakelockCoordinator.setActive(
          AppWakelockCoordinator.ocrProcessingReason,
          false,
        ),
      );
      final controller = AppVideoPlayerController.file(File('preview.mp4'));
      controller.value = const VideoPlayerValue(
        duration: Duration(minutes: 2),
        isInitialized: true,
        isPlaying: true,
      );
      await mount(tester);
      await tester.pump(const Duration(minutes: 2));
      expect(protection, findsNothing);
      controller.value = controller.value.copyWith(
        isPlaying: false,
        isBuffering: true,
      );
      await tester.pump(const Duration(minutes: 2));
      expect(protection, findsNothing);
      controller.value = controller.value.copyWith(isBuffering: false);
      await tester.pump(const Duration(seconds: 14));
      expect(protection, findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(protection, findsOneWidget);
      controller.value = controller.value.copyWith(isPlaying: true);
      await tester.pump();
      expect(protection, findsNothing);
      await controller.dispose();
      await finish(tester);
    },
  );

  testWidgets(
    'transport loading and a changed delay restart the complete wait',
    (tester) async {
      await mount(tester);
      await tester.pump(const Duration(seconds: 14));
      playbackActive.value = true;
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      expect(protection, findsNothing);
      playbackActive.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 14));
      expect(protection, findsNothing);
      await settings.updateSetting('processingScreenProtectionWaitSeconds', 25);
      await tester.pump();
      await tester.pump(const Duration(seconds: 24));
      expect(protection, findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(protection, findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets('focused desktop input and popup routes suspend protection', (
    tester,
  ) async {
    final focus = FocusNode();
    await mount(
      tester,
      home: Scaffold(body: TextField(focusNode: focus)),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(protection, findsNothing);
    focus.unfocus();
    await tester.pump();
    await tester.pump(const Duration(seconds: 14));
    expect(protection, findsNothing);
    final dialog = showDialog<void>(
      context: navigator.currentState!.overlay!.context,
      builder: (context) => const AlertDialog(title: Text('保持弹窗')),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 1));
    expect(protection, findsNothing);
    navigator.currentState!.pop();
    await dialog;
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 14));
    expect(protection, findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(protection, findsOneWidget);
    await finish(tester);
    focus.dispose();
  });

  testWidgets('programmatic scrolling finishes before a fresh idle period', (
    tester,
  ) async {
    final scroll = ScrollController();
    await mount(
      tester,
      home: Scaffold(
        body: ListView.builder(
          controller: scroll,
          itemExtent: 50,
          itemCount: 100,
          itemBuilder: (_, index) => Text('条目 $index'),
        ),
      ),
    );
    scroll.animateTo(
      2000,
      duration: const Duration(seconds: 30),
      curve: Curves.linear,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(protection, findsNothing);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 14));
    expect(protection, findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(protection, findsOneWidget);
    await finish(tester);
    scroll.dispose();
  });

  testWidgets(
    'checkbox exits before confirmation; cancel and save preserve protection',
    (tester) async {
      await mount(tester);
      await enter(tester);
      final checkbox = find.byKey(
        const ValueKey('processing-protection-disable'),
      );
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(protection, findsNothing);
      expect(find.text('关闭防烧屏？'), findsOneWidget);
      expect(actions, 0);
      expect(settings.processingScreenProtection, isTrue);
      await tester.pump(const Duration(minutes: 1));
      expect(protection, findsNothing);
      final seconds = find.byKey(
        const ValueKey('processing-protection-seconds'),
      );
      await tester.enterText(seconds, '22');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(settings.processingScreenProtectionWaitSeconds, 15);
      await enter(tester);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      await tester.enterText(seconds, '22');
      await tester.tap(find.text('保存等待时间'));
      await tester.pumpAndSettle();
      expect(settings.processingScreenProtection, isTrue);
      expect(settings.processingScreenProtectionWaitSeconds, 22);
      await tester.pump(const Duration(seconds: 21));
      expect(protection, findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 650));
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      await tester.enterText(seconds, '35');
      await tester.tap(find.text('确认关闭'));
      await tester.pumpAndSettle();
      expect(settings.processingScreenProtection, isFalse);
      expect(settings.processingScreenProtectionWaitSeconds, 35);
      expect(AppWakelockCoordinator.isReasonActive(reason), isTrue);
      await tester.pump(const Duration(minutes: 2));
      expect(protection, findsNothing);
      await finish(tester);
    },
  );

  test('protection preference persists and is exported', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    expect(settings.processingScreenProtection, isTrue);
    expect(settings.processingScreenProtectionWaitSeconds, 15);
    await settings.updateSetting('processingScreenProtectionWaitSeconds', 47);
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
    settings.resetForTest();
    await settings.init();
    expect(settings.processingScreenProtection, isFalse);
    expect(settings.processingScreenProtectionWaitSeconds, 47);
    expect(
      settings
          .exportSettingsSnapshot()['general']['processingScreenProtectionWaitSeconds'],
      47,
    );
  });

  test(
    'invalid persisted delay is normalized without resetting other preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'processingScreenProtection': false,
        'processingScreenProtectionWaitSeconds': 0,
      });
      settings.resetForTest();
      await settings.init();
      expect(settings.processingScreenProtection, isFalse);
      expect(settings.processingScreenProtectionWaitSeconds, 1);
      await settings.updateSetting(
        'processingScreenProtectionWaitSeconds',
        100000000,
      );
      expect(settings.processingScreenProtectionWaitSeconds, 86400);
    },
  );
}
