import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili_download_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/app_text_input_focus.dart';
import 'tooltip_finders.dart';

class _SettingsDownloadService extends BilibiliDownloadService {
  // The dialog needs a display path; no filesystem migration is needed here.
  @override
  Future<Directory> resolveDefaultImportDirectory() async =>
      Directory('${Directory.systemTemp.path}/focus-test-downloads');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({BilibiliDownloadService service, SettingsService settings})>
  pumpDownloadScreen(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settings = SettingsService()..resetForTest();
    await settings.init();
    final BilibiliDownloadService service = _SettingsDownloadService();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: service),
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: LibraryService()),
        ],
        child: MaterialApp(
          builder: (context, child) => AppTextInputFocus(child: child!),
          navigatorKey: AppToast.navigatorKey,
          home: const BilibiliDownloadScreen(),
        ),
      ),
    );
    await tester.pump();
    return (service: service, settings: settings);
  }

  testWidgets(
    'mobile link editing controls preserve input focus and selection',
    (tester) async {
      await pumpDownloadScreen(tester);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      await tester.enterText(input, 'abcd');
      await tester.pump();
      final controller = tester.widget<TextField>(input).controller!;
      final focus = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode;
      controller.selection = const TextSelection.collapsed(offset: 2);
      final gesture = await tester.startGesture(
        tester.getCenter(findTooltipLabeled('换行')),
      );
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(controller.selection.baseOffset, 2);
      await gesture.up();
      await tester.pump();
      expect(controller.text, 'ab\ncd');
      expect(focus.hasFocus, isTrue);

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': 'pasted link'} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(findTooltipLabeled('粘贴'));
      await tester.pumpAndSettle();
      expect(controller.text, 'ab\ncd\npasted link');
      expect(focus.hasFocus, isTrue);
      await tester.tap(findTooltipLabeled('清空'));
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(focus.hasFocus, isTrue);

      tester.testTextInput.hide();
      await tester.tap(find.text('请输入链接并解析'));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('cancelling download settings discards the danmaku draft', (
    tester,
  ) async {
    final host = await pumpDownloadScreen(tester);
    expect(host.service.downloadDanmaku, isTrue);

    await tester.tap(findTooltipLabeled('下载设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载弹幕'));
    await tester.pump();

    expect(host.service.downloadDanmaku, isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(host.service.downloadDanmaku, isTrue);
  });

  testWidgets('using the default directory clears the custom-path override', (
    tester,
  ) async {
    final host = await pumpDownloadScreen(tester);
    host.service.customDownloadPath = r'D:\custom-downloads';

    await tester.tap(findTooltipLabeled('下载设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用默认'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(host.service.customDownloadPath, isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('bilibili_custom_download_path'), isFalse);
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets('audio preference draft can be cancelled or saved at width $width', (tester) async {
      final host = await pumpDownloadScreen(tester);
      await tester.binding.setSurfaceSize(Size(width, 844));
      await tester.pumpAndSettle();
      final picker = find.byKey(const ValueKey('bilibili-download-audio-preference'));
      for (final save in [false, true]) {
        await tester.tap(findTooltipLabeled('下载设置'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(picker);
        await tester.tap(picker);
        await tester.pumpAndSettle();
        await tester.tap(find.text('杜比全景声优先').last);
        await tester.pumpAndSettle();
        expect(host.service.preferredAudioQuality, BilibiliAudioPreference.bestAvailable);
        await tester.tap(find.text(save ? '保存' : '取消'));
        await tester.pumpAndSettle();
        expect(host.service.preferredAudioQuality, save
            ? BilibiliAudioPreference.dolby : BilibiliAudioPreference.bestAvailable);
        expect(tester.takeException(), isNull);
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bilibili_preferred_audio_quality'), 'dolby');
    });
  }
}
