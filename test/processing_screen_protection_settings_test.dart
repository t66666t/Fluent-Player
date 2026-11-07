import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';
import 'package:video_player_app/widgets/processing_screen_protection_settings.dart';

void main() {
  final preview = Platform.environment['PROTECTION_PREVIEW'] == '1';
  late SettingsService settings;

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
  });

  Future<void> capture(WidgetTester tester, String name) async {
    if (!preview) return;
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('preview')),
      );
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('.artifacts/screen-protection/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> mount(WidgetTester tester, {bool confirm = false}) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            colorScheme: const ColorScheme.dark(
              primary: Colors.blue,
              surface: Color(0xFF121212),
            ),
            fontFamily: 'Noto Sans SC',
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  if (confirm) {
                    showProcessingScreenProtectionSettings(
                      context,
                      settings,
                      confirmDisable: true,
                    );
                  } else {
                    showMediaLibrarySettingsBottomSheet(
                      context,
                      settings,
                      showSystemMediaNotificationSetting: false,
                    );
                  }
                },
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
  }

  for (final (size, scale) in [
    (const Size(320, 568), 1.0),
    (const Size(320, 568), 2.0),
    (const Size(568, 320), 1.6),
    (const Size(768, 1024), 1.0),
    (const Size(1280, 800), 1.0),
    (const Size(1920, 1080), 1.0),
    (const Size(240, 240), 1.0),
  ]) {
    testWidgets(
      'library setting, info and custom seconds fit $size at $scale',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await mount(tester);
        final info = find.byKey(const ValueKey('processing-protection-info'));
        await tester.ensureVisible(info);
        await tester.tap(info);
        await tester.pumpAndSettle();
        expect(find.text('防烧屏有什么用？'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final understood = find.text('知道了');
        await tester.ensureVisible(understood);
        await tester.tap(understood);
        await tester.pumpAndSettle();
        final wait = find.byKey(const ValueKey('processing-protection-wait'));
        await tester.ensureVisible(wait);
        await capture(
          tester,
          '${size.width.toInt()}x${size.height.toInt()}-$scale-library',
        );
        await tester.tap(wait);
        await tester.pumpAndSettle();
        final seconds = find.byKey(
          const ValueKey('processing-protection-seconds'),
        );
        await tester.ensureVisible(seconds);
        expect(tester.widget<TextFormField>(seconds).controller!.text, '15');
        await tester.enterText(seconds, '37');
        await tester.pumpAndSettle();
        final save = find.text('保存');
        await tester.ensureVisible(save);
        await capture(
          tester,
          '${size.width.toInt()}x${size.height.toInt()}-$scale-wait',
        );
        expect(tester.takeException(), isNull);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(settings.processingScreenProtectionWaitSeconds, 37);
        expect(settings.processingScreenProtection, isTrue);
        expect(find.text('37 秒'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('confirmation stays usable with keyboard at $size and $scale', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(tester, confirm: true);
      await capture(
        tester,
        '${size.width.toInt()}x${size.height.toInt()}-$scale-confirm',
      );
      tester.view.viewInsets = FakeViewPadding(
        bottom: size.height > 400 ? 240 : 80,
      );
      await tester.pumpAndSettle();
      final seconds = find.byKey(
        const ValueKey('processing-protection-seconds'),
      );
      await tester.ensureVisible(seconds);
      await tester.enterText(seconds, '28');
      await tester.pumpAndSettle();
      final close = find.text('确认关闭');
      await tester.ensureVisible(close);
      await tester.pumpAndSettle();
      expect(close.hitTestable(), findsOneWidget);
      await capture(
        tester,
        '${size.width.toInt()}x${size.height.toInt()}-$scale-confirm-keyboard',
      );
      expect(tester.takeException(), isNull);
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(settings.processingScreenProtection, isFalse);
      expect(settings.processingScreenProtectionWaitSeconds, 28);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('invalid seconds stay editable and cancel discards the draft', (
    tester,
  ) async {
    await mount(tester, confirm: true);
    final seconds = find.byKey(const ValueKey('processing-protection-seconds'));
    for (final value in ['', '0', '86401', '999999999999999999999999']) {
      await tester.enterText(seconds, value);
      await tester.tap(find.text('确认关闭'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1–86400 之间的整数秒数'), findsOneWidget);
      expect(settings.processingScreenProtection, isTrue);
      expect(settings.processingScreenProtectionWaitSeconds, 15);
    }
    await tester.enterText(seconds, '60');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(settings.processingScreenProtectionWaitSeconds, 15);
  });
}
