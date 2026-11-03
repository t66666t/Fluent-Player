import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/app_text_input_focus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_workspace.dart';
import 'package:video_player_app/widgets/subtitle_search_dialog.dart';

import 'subtitle_search_service_test.dart' show MemorySubtitleSecrets;
import 'subtitle_search_workspace_test.dart' show FixtureSubtitleSearchService;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<SubtitleSearchWorkspace> prepared({bool preview = false}) async {
    final workspace = SubtitleSearchWorkspace(
      service: FixtureSubtitleSearchService(),
      secrets: MemorySubtitleSecrets(),
    );
    await workspace.initialize();
    final session = workspace.acquire('video', 'Frieren S01E01.mkv');
    await session.restored;
    await session.search();
    if (preview) {
      await session.select(session.hits.first);
      await session.preview();
    }
    workspace.release(session);
    return workspace;
  }

  Future<void> pump(
    WidgetTester tester,
    SubtitleSearchWorkspace workspace,
    Size size, {
    double scale = 1,
    Future<String> Function(SubtitleSearchImportRequest, String?)? onImport,
    GlobalKey? imageKey,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'Noto Sans SC',
          ),
        ),
        builder: (_, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: AppTextInputFocus(child: child!),
        ),
        home: RepaintBoundary(
          key: imageKey,
          child: SubtitleSearchDialog(
            mediaKey: 'video',
            title: '葬送のフリーレン · 第 1 集',
            workspace: workspace,
            onImport: onImport ?? (_, _) async => '/saved/subtitle.srt',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in TargetPlatform.values.where(
    (p) => p != TargetPlatform.fuchsia,
  )) {
    testWidgets(
      'search and preview fit $platform on phone, landscape, tablet and desktop',
      (tester) async {
        addTearDown(tester.view.reset);
        final workspace = await prepared();
        for (final (size, scale) in [
          (const Size(320, 568), 1.0),
          (const Size(667, 280), 1.0),
          (const Size(248, 440), 1.3),
          (const Size(768, 1024), 1.0),
          (const Size(1280, 800), 1.0),
          (const Size(360, 640), 2.0),
        ]) {
          await pump(tester, workspace, size, scale: scale);
          expect(
            tester.takeException(),
            isNull,
            reason: '$platform $size scale=$scale search',
          );
          final session = workspace.acquire('video', '');
          await session.select(session.hits.first);
          await session.preview();
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$platform $size scale=$scale preview',
          );
          session.closeDetail();
          workspace.release(session);
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'work picker fits small screens and choosing a quarter scopes and remembers the search',
    (tester) async {
      addTearDown(tester.view.reset);
      final workspace = await prepared();
      final service = workspace.service as FixtureSubtitleSearchService;
      service.works = const [
        SubtitleSearchWork(
          id: '3586996',
          title: '绝命毒师 第二季',
          originalTitle: 'Breaking Bad',
          year: '2009',
          type: 'TVSeries',
        ),
        SubtitleSearchWork(
          id: '2373195',
          title: '绝命毒师 第一季',
          originalTitle: 'Breaking Bad',
          year: '2008',
          type: 'TVSeries',
        ),
      ];
      final s = workspace.acquire('video', '');
      await s.lookupWorks();
      for (final size in [
        const Size(248, 440),
        const Size(320, 568),
        const Size(667, 280),
        const Size(1280, 900),
      ]) {
        await pump(tester, workspace, size, scale: size.width == 248 ? 1.4 : 1);
        await tester.ensureVisible(
          find.byKey(const ValueKey('subtitle-work-3586996')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('subtitle-work-3586996')));
      await tester.pumpAndSettle();
      expect(s.work?.id, '3586996');
      expect(s.season, '2');
      expect(find.textContaining('已限定 SubHD'), findsOneWidget);
      expect(service.requests.last.work?.id, '3586996');
      workspace.release(s);
      await tester.pumpWidget(const SizedBox());
      workspace.dispose();
    },
  );

  testWidgets(
    'a subtitle without a detail page never opens a provider homepage as its detail',
    (tester) async {
      addTearDown(tester.view.reset);
      final workspace = await prepared();
      final s = workspace.acquire('video', '');
      await s.select(
        s.hits.firstWhere((h) => h.source == SubtitleSearchSource.xunlei),
      );
      await pump(tester, workspace, const Size(1280, 900));
      expect(find.text('该来源未提供字幕发布页地址'), findsOneWidget);
      expect(find.text('查看这条字幕的详情页'), findsNothing);
      workspace.release(s);
      await tester.pumpWidget(const SizedBox());
      workspace.dispose();
    },
  );

  testWidgets(
    'close and reopen retains search results and cached preview with no extra requests',
    (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      final workspace = await prepared();
      final service = workspace.service as FixtureSubtitleSearchService;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSubtitleSearchDialog(
                  context,
                  mediaKey: 'video',
                  title: 'Frieren',
                  workspace: workspace,
                  onImport: (_, _) async => '/saved.srt',
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('Frieren · 示例剧集'), findsWidgets);
      final session = workspace.acquire('video', '');
      await session.select(session.hits.first);
      await session.preview();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭字幕搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('设为主字幕'), findsOneWidget);
      expect(service.searches, 3);
      expect(service.downloads, 1);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subtitle-search-query')),
        findsOneWidget,
      );
      workspace.release(session);
      await tester.pumpWidget(const SizedBox());
      workspace.dispose();
    },
  );

  testWidgets(
    'import awaits completion, prevents back and reuses the saved file',
    (tester) async {
      addTearDown(tester.view.reset);
      final workspace = await prepared(preview: true);
      final requests = <String?>[];
      final gate = Completer<void>();
      await pump(
        tester,
        workspace,
        const Size(1280, 800),
        onImport: (request, existing) async {
          requests.add(existing);
          await gate.future;
          return '/saved.srt';
        },
      );
      await tester.tap(find.byKey(const ValueKey('subtitle-search-import')));
      await tester.pump();
      expect(find.text('正在保存…'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('正在保存…'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('已保存并设为主字幕'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subtitle-search-import')));
      await tester.pumpAndSettle();
      expect(requests, [null, '/saved.srt']);
      await tester.pumpWidget(const SizedBox());
      workspace.dispose();
    },
  );

  testWidgets('default page searches without showing a key setup requirement', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final workspace = SubtitleSearchWorkspace(
      service: FixtureSubtitleSearchService(),
      secrets: MemorySubtitleSecrets(),
    );
    await workspace.initialize();
    await pump(tester, workspace, const Size(390, 844));
    expect(find.textContaining('访问密钥'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('subtitle-search-submit')));
    await tester.pumpAndSettle();
    expect((workspace.service as FixtureSubtitleSearchService).searches, 3);
    expect(find.textContaining('个字幕结果'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    workspace.dispose();
  });

  testWidgets(
    'selecting part of the video filename searches that text directly',
    (tester) async {
      addTearDown(tester.view.reset);
      final workspace = await prepared();
      await pump(tester, workspace, const Size(1000, 800));
      await tester.tap(find.text('从视频名快速选词'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('subtitle-search-filename')),
      );
      final expected = field.controller!.text.substring(0, 7);
      field.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 7,
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('subtitle-search-selected-name')),
      );
      await tester.tap(
        find.byKey(const ValueKey('subtitle-search-selected-name')),
      );
      await tester.pumpAndSettle();
      expect(
        (workspace.service as FixtureSubtitleSearchService).queries.last,
        expected,
      );
      await tester.pumpWidget(const SizedBox());
      workspace.dispose();
    },
  );

  testWidgets(
    'visual review with real bundled fonts',
    (tester) async {
      addTearDown(tester.view.reset);
      final loader = FontLoader('Noto Sans SC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
      await tester.runAsync(() async {
        await loader.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      final workspace = await prepared();
      final review = workspace.acquire('video', '');
      review.works = const [
        SubtitleSearchWork(
          id: '36093351',
          title: '葬送的芙莉莲',
          originalTitle: '葬送のフリーレン',
          year: '2023',
          type: 'TVSeries',
        ),
        SubtitleSearchWork(
          id: '36829083',
          title: '葬送的芙莉莲 第二季',
          originalTitle: '葬送のフリーレン 第2期',
          year: '2026',
          type: 'TVSeries',
        ),
      ];
      final dir = Directory('.artifacts/subtitle-search-review')
        ..createSync(recursive: true);
      for (final (name, size, preview) in [
        ('desktop-works', const Size(1280, 900), false),
        ('phone-works', const Size(390, 844), false),
        ('desktop', const Size(1280, 900), true),
        ('phone', const Size(390, 844), true),
      ]) {
        if (preview && review.selected == null) {
          await review.chooseWork(review.works.first);
          await review.select(review.hits.first);
          await review.preview();
        }
        final key = GlobalKey();
        await pump(tester, workspace, size, imageKey: key);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${dir.path}/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      workspace.release(review);
      workspace.dispose();
    },
    skip: Platform.environment['SUBTITLE_SEARCH_VISUAL'] != '1',
  );
}
