import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.downloads);
  final String downloads;
  @override
  Future<String?> getDownloadsPath() async => downloads;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory downloads;
  late File source;
  late PathProviderPlatform previousPaths;
  const contents = '1\n00:00:00,000 --> 00:00:01,000\n字幕内容\n\n';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('subtitle_desktop_export_');
    downloads = Directory(p.join(root.path, 'system-downloads'))..createSync();
    source = File(p.join(root.path, 'source', '字幕.srt'));
    source.parent.createSync();
    source.writeAsStringSync(contents);
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(downloads.path);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    settings.largeDataRootPath = root.path;
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPaths;
    SettingsService().resetForTest();
    await AppToast.dismiss(immediate: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    required Future<Directory> Function() resolve,
    required Future<bool> Function(String) reveal,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1500);
    addTearDown(tester.view.reset);
    addTearDown(() async {
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
                videoPath: p.join(root.path, 'video.mp4'),
                localSubtitles: {'字幕': source.path},
                showEmbeddedSubtitles: false,
                resolveDownloadTargetDirForTest: resolve,
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

  Future<void> waitUntil(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(condition(), isTrue);
  }

  Future<void> tapExport(WidgetTester tester) async {
    final button = find.byTooltip('导出字幕');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.runAsync(() => tester.tap(button));
  }

  testWidgets(
    'Windows falls back to system Downloads on default access denial',
    (tester) async {
      final opened = <String>[];
      var resolutions = 0;
      await pumpSheet(
        tester,
        resolve: () async {
          resolutions++;
          throw const FileSystemException(
            'access denied',
            'program directory',
            OSError('access denied', 5),
          );
        },
        reveal: (path) async {
          opened.add(path);
          return true;
        },
      );
      await tapExport(tester);
      await waitUntil(tester, () => opened.isNotEmpty);
      final output = File(p.join(downloads.path, '字幕.srt'));
      expect(opened, [output.path]);
      expect(output.readAsStringSync(), contents);
      expect(source.readAsStringSync(), contents);
      expect(find.text('默认: ${downloads.path}'), findsOneWidget);
      await tapExport(tester);
      await waitUntil(tester, () => opened.length == 2);
      expect(resolutions, 1);
      expect(File(opened.last).readAsStringSync(), contents);
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Windows does not silently bypass a chosen directory',
    (tester) async {
      final custom = Directory(p.join(root.path, 'custom'))..createSync();
      final collision = Directory(p.join(custom.path, '字幕.srt'))..createSync();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('subtitle_download_path', custom.path);
      final opened = <String>[];
      await pumpSheet(
        tester,
        resolve: () async => throw const FileSystemException(
          'access denied',
          'chosen directory',
          OSError('access denied', 5),
        ),
        reveal: (path) async {
          opened.add(path);
          return true;
        },
      );
      await tapExport(tester);
      await waitUntil(tester, () => find.text('导出字幕失败').evaluate().isNotEmpty);
      expect(opened, isEmpty);
      expect(downloads.listSync(), isEmpty);
      expect(collision.existsSync(), isTrue);
      expect(source.readAsStringSync(), contents);
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Windows reports non-permission failures instead of falling back',
    (tester) async {
      await pumpSheet(
        tester,
        resolve: () async => throw const FileSystemException(
          'disk full',
          'program directory',
          OSError('disk full', 112),
        ),
        reveal: (_) async => throw StateError('unexpected'),
      );
      await tapExport(tester);
      await waitUntil(tester, () => find.text('导出字幕失败').evaluate().isNotEmpty);
      expect(downloads.listSync(), isEmpty);
      expect(source.readAsStringSync(), contents);
    },
    skip: !Platform.isWindows,
  );
}
