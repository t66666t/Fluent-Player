import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/experimental_layout.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';
import 'package:video_player_app/widgets/categorized_settings_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ExperimentalLayout.instance.value = false;
    SettingsService().resetForTest();
  });
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(1440, 900),
  ]) {
    testWidgets('all settings remain reachable at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = SettingsService();
      await settings.init();
      ExperimentalLayout.instance.value = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showMediaLibrarySettingsBottomSheet(context, settings),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      for (final label in ['卡片与列表样式', '显示迷你播放卡片', '隐私与联网说明']) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text(label).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('打开设置'), findsOneWidget);
    });
  }
  testWidgets('flat settings stay default while layout preference changes', (
    tester,
  ) async {
    final settings = SettingsService();
    await settings.init();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showMediaLibrarySettingsBottomSheet(context, settings),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.byType(CategorizedSettingsPage), findsOneWidget);
    await tester.tap(find.byTooltip('首页布局实验室'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('体验新布局'));
    await tester.pumpAndSettle();
    expect(ExperimentalLayout.instance.value, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        ExperimentalLayout.preferenceKey,
      ),
      isTrue,
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.byType(CategorizedSettingsPage), findsOneWidget);
    await tester.tap(find.byTooltip('首页布局实验室'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复原布局'));
    await tester.pumpAndSettle();
    expect(ExperimentalLayout.instance.value, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        ExperimentalLayout.preferenceKey,
      ),
      isFalse,
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.text('媒体库设置'), findsOneWidget);
    expect(find.byType(CategorizedSettingsPage), findsOneWidget);
  });
}
