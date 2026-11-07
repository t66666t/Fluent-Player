import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_stream_source.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';

class _StreamSource implements SubtitleStreamSource {
  _StreamSource(this.current);
  final SubtitleStreamUpdate current;

  @override
  final ValueNotifier<int> subtitleFilesRevision = ValueNotifier<int>(0);
  @override
  Iterable<SubtitleStreamUpdate> get subtitleStreams => const [];
  @override
  SubtitleStreamUpdate? streamForPath(String path) =>
      current.paths.contains(path) ? current : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File source;
  final original = <int>[
    0xef,
    0xbb,
    0xbf,
    ...utf8.encode('1\r\n00:00:00,000 --> 00:00:01,000\r\n字幕\r\n'),
  ];

  setUp(() async {
    root = Directory.systemTemp.createTempSync('subtitle_ios_export_');
    source = File(p.join(root.path, '测试字幕.srt'))..writeAsBytesSync(original);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    settings.largeDataRootPath = root.path;
  });

  tearDown(() async {
    SettingsService().resetForTest();
    await AppToast.dismiss(immediate: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpSheet(
    WidgetTester tester,
    Future<ShareResult> Function(ShareParams) share, {
    _StreamSource? stream,
    SubtitleManagementAppearance appearance =
        SubtitleManagementAppearance.standard,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1500);
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      stream?.subtitleFilesRevision.dispose();
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<EmbeddedSubtitleService>(
              create: (_) => EmbeddedSubtitleService(),
            ),
            if (stream != null)
              Provider<SubtitleStreamSource>.value(value: stream),
          ],
          child: MaterialApp(
            navigatorKey: AppToast.navigatorKey,
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: Scaffold(
              body: SubtitleManagementSheet(
                videoPath: p.join(root.path, 'video.mp4'),
                localSubtitles: {'字幕': source.path},
                showEmbeddedSubtitles: false,
                appearance: appearance,
                useAndroidDocumentPicker: false,
                shareSubtitle: share,
                revealSavedSubtitle: (_) async =>
                    throw StateError('unexpected'),
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

  for (final appearance in SubtitleManagementAppearance.values) {
    testWidgets('iOS shares the original subtitle safely in $appearance', (
      tester,
    ) async {
      ShareParams? request;
      await pumpSheet(tester, (params) async {
        request = params;
        return const ShareResult('activity', ShareResultStatus.success);
      }, appearance: appearance);
      await tapExport(tester);
      await waitUntil(
        tester,
        () => find.text('字幕导出操作已完成').evaluate().isNotEmpty,
      );
      expect(request!.files!.single.path, source.path);
      final sharedBytes = await tester.runAsync(
        () => request!.files!.single.readAsBytes(),
      );
      expect(sharedBytes, original);
      expect(request!.fileNameOverrides, ['测试字幕.srt']);
      expect(request!.sharePositionOrigin!.width, greaterThan(0));
      expect(source.readAsBytesSync(), original);
    });
  }

  testWidgets('iOS cancellation and unknown results do not claim a save', (
    tester,
  ) async {
    var calls = 0;
    await pumpSheet(tester, (_) async {
      calls++;
      return calls == 1
          ? const ShareResult('', ShareResultStatus.dismissed)
          : const ShareResult('unknown', ShareResultStatus.unavailable);
    });
    await tapExport(tester);
    await waitUntil(tester, () => find.text('已取消导出').evaluate().isNotEmpty);
    await tapExport(tester);
    await waitUntil(tester, () => find.text('无法确认导出结果').evaluate().isNotEmpty);
    expect(find.text('字幕导出操作已完成'), findsNothing);
    expect(source.readAsBytesSync(), original);
  });

  testWidgets('iOS sharing errors can be retried without changing the source', (
    tester,
  ) async {
    var calls = 0;
    await pumpSheet(tester, (_) async {
      calls++;
      if (calls == 1) throw PlatformException(code: 'share_failed');
      return const ShareResult('activity', ShareResultStatus.success);
    });
    await tapExport(tester);
    await waitUntil(tester, () => find.text('导出字幕失败').evaluate().isNotEmpty);
    expect(source.readAsBytesSync(), original);
    await tester.runAsync(() => tester.tap(find.text('重试')));
    await waitUntil(tester, () => find.text('字幕导出操作已完成').evaluate().isNotEmpty);
    expect(calls, 2);
  });

  testWidgets('iOS shares current unfinished cues under the subtitle name', (
    tester,
  ) async {
    final cues = SubtitleCueBuffer()
      ..addAll([
        SubtitleItem(
          index: 1,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          text: '最新内容',
        ),
      ]);
    final stream = _StreamSource(
      SubtitleStreamUpdate(
        generationId: 'generation',
        mediaKey: 'video',
        videoPath: p.join(root.path, 'video.mp4'),
        videoId: null,
        revision: 1,
        primaryPath: source.path,
        secondaryPath: null,
        primary: cues.snapshot,
        secondary: SubtitleCueBuffer().snapshot,
        addedPrimary: const [],
        addedSecondary: const [],
        primaryBytes: 1,
        secondaryBytes: 0,
        processedThrough: const Duration(seconds: 1),
        phase: SubtitleStreamPhase.generating,
      ),
    );
    ShareParams? request;
    await pumpSheet(tester, (params) async {
      request = params;
      return const ShareResult('activity', ShareResultStatus.success);
    }, stream: stream);
    await tapExport(tester);
    await waitUntil(tester, () => find.text('字幕导出操作已完成').evaluate().isNotEmpty);
    expect(request!.files!.single.path, isEmpty);
    expect(request!.fileNameOverrides, ['测试字幕.srt']);
    expect(
      utf8.decode(await request!.files!.single.readAsBytes()),
      '1\n00:00:00,000 --> 00:00:01,000\n最新内容\n\n',
    );
    expect(source.readAsBytesSync(), original);
  });
}
