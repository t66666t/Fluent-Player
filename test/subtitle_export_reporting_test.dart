import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';

const _name = 'subtitle.ocr.zh-Hans.r1.20261101_012738.srt';
const _contents =
    '1\n00:00:00,000 --> 00:00:02,000\n字幕识别速度测试\n\n'
    '2\n00:00:02,000 --> 00:00:04,000\n保持原来的时间轴\n\n'
    '3\n00:00:04,000 --> 00:00:08,000\n模型下载完成后离线使用\n\n'
    '4\n00:00:10,000 --> 00:00:12,000\n最后一条字幕\n\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory downloads;
  late File source;
  late File output;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('subtitle_export_reporting_');
    downloads = Directory(p.join(root.path, 'downloads'))..createSync();
    final input = Directory(p.join(root.path, 'input'))..createSync();
    source = File(p.join(input.path, _name))..writeAsStringSync(_contents);
    output = File(p.join(downloads.path, _name));
    SharedPreferences.setMockInitialValues({
      'subtitle_download_path': downloads.path,
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();
    settings.largeDataRootPath = root.path;
  });

  tearDown(() async {
    SettingsService().resetForTest();
    await AppToast.dismiss(immediate: true);
    // Every file belongs to this freshly created fixture directory.
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpSheet(
    WidgetTester tester,
    Future<bool> Function(String) reveal,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1500);
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await AppToast.dismiss(immediate: true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ChangeNotifierProvider<EmbeddedSubtitleService>(
          create: (_) => EmbeddedSubtitleService(),
          child: MaterialApp(
            navigatorKey: AppToast.navigatorKey,
            home: Scaffold(
              body: SubtitleManagementSheet(
                videoPath: p.join(root.path, 'fixture.mp4'),
                localSubtitles: {'OCR': source.path},
                showEmbeddedSubtitles: false,
                revealSavedSubtitle: reveal,
                onSubtitleChanged: () {},
                onOpenAi: () {},
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    expect(find.byTooltip('导出字幕'), findsOneWidget);
  }

  Future<void> exportExpecting(WidgetTester tester, [String? message]) async {
    final button = find.byTooltip('导出字幕');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.runAsync(() => tester.tap(button));
    for (
      var i = 0;
      i < 100 &&
          (message == null
              ? !output.existsSync()
              : find.text(message).evaluate().isEmpty);
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (message != null) expect(find.text(message), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  }

  testWidgets('missing opener preserves full export and reports saved file', (
    tester,
  ) async {
    final opened = <String>[];
    List<int>? bytesAtOpen;
    await pumpSheet(tester, (path) async {
      opened.add(path);
      bytesAtOpen = File(path).readAsBytesSync();
      throw MissingPluginException(
        'No implementation found for method open_file on channel open_file',
      );
    });

    await exportExpecting(tester, '字幕已保存，无法打开位置');
    expect(opened, [output.path]);
    expect(bytesAtOpen, source.readAsBytesSync());
    expect(output.readAsBytesSync(), source.readAsBytesSync());
    expect(source.readAsStringSync(), _contents);
    expect(find.text('导出字幕失败'), findsNothing);
  });

  testWidgets('ordinary opener refusal still reports the completed export', (
    tester,
  ) async {
    final opened = <String>[];
    await pumpSheet(tester, (path) async {
      opened.add(path);
      return false;
    });

    await exportExpecting(tester, '字幕已保存，无法打开位置');
    expect(opened, [output.path]);
    expect(output.readAsBytesSync(), source.readAsBytesSync());
    expect(source.readAsStringSync(), _contents);
    expect(find.text('导出字幕失败'), findsNothing);
  });

  testWidgets('successful save and open finish without a result popup', (
    tester,
  ) async {
    final opened = <String>[];
    await pumpSheet(tester, (path) async {
      opened.add(path);
      return true;
    });

    await exportExpecting(tester);
    expect(find.text('字幕已保存'), findsNothing);
    expect(find.text('重试打开位置'), findsNothing);
    expect(opened, [output.path]);
    expect(output.readAsBytesSync(), source.readAsBytesSync());
    expect(source.readAsStringSync(), _contents);
  });

  testWidgets('retry opening a saved subtitle does not export another copy', (
    tester,
  ) async {
    var allowOpen = false;
    final opened = <String>[];
    await pumpSheet(tester, (path) async {
      opened.add(path);
      return allowOpen;
    });
    await exportExpecting(tester, '字幕已保存，无法打开位置');
    expect(find.text('复制路径'), findsOneWidget);
    allowOpen = true;
    await tester.runAsync(() => tester.tap(find.text('重试打开位置')));
    await tester.pumpAndSettle();
    expect(find.text('字幕已保存，无法打开位置'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(opened, [output.path, output.path]);
    expect(downloads.listSync().whereType<File>().length, 1);
    expect(output.readAsBytesSync(), source.readAsBytesSync());
  });

  testWidgets('copy failure keeps source and directory and never opens', (
    tester,
  ) async {
    final collision = Directory(output.path)..createSync();
    final opened = <String>[];
    await pumpSheet(tester, (path) async {
      opened.add(path);
      return true;
    });

    await exportExpecting(tester, '导出字幕失败');
    expect(opened, isEmpty);
    expect(collision.existsSync(), isTrue);
    expect(source.readAsStringSync(), _contents);
    expect(find.text('字幕已保存，无法打开位置'), findsNothing);
  });

  testWidgets('an already saved subtitle stays intact when opener is missing', (
    tester,
  ) async {
    source = File(output.path)..writeAsStringSync(_contents);
    final opened = <String>[];
    await pumpSheet(tester, (path) async {
      opened.add(path);
      throw MissingPluginException('open_file is unavailable');
    });

    await exportExpecting(tester, '字幕已保存，无法打开位置');
    expect(opened, [source.path]);
    expect(source.readAsStringSync(), _contents);
    expect(downloads.listSync().whereType<File>().length, 1);
    expect(find.text('导出字幕失败'), findsNothing);
  });
}
