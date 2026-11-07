import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/screens/bilibili_download_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/download_queue_controls.dart';

const _multipartTitle = '从零开始学摄影：光线、构图与相机设置的完整入门指南';
const _collectionTitle = '周末漫游计划｜在城市与山野之间，记录平凡日常';

BilibiliVideoItem _video(String id, String title, List<String> parts) {
  final pages = [
    for (var i = 0; i < parts.length; i++)
      BilibiliPage(
        cid: i + 1,
        page: i + 1,
        part: parts[i],
        duration: 360,
        bvid: id,
        aid: id,
      ),
  ];
  final info = BilibiliVideoInfo(
    title: title,
    desc: '',
    pic: '',
    bvid: id,
    aid: id,
    ownerName: '光影记录者',
    ownerMid: '1',
    pubDate: 0,
    pages: pages,
  );
  final quality = StreamItem(
    id: 80,
    baseUrl: '',
    bandwidth: 1000000,
    codecs: 'avc1',
    codecid: 7,
    qualityName: '1080P 高清',
  );
  return BilibiliVideoItem(
    videoInfo: info,
    episodes: [
      for (final page in pages)
        BilibiliDownloadEpisode(page: page, bvid: id)
          ..availableVideoQualities = [quality]
          ..selectedVideoQuality = quality,
    ],
  );
}

List<BilibiliDownloadTask> _tasks(bool streaming) {
  final multipart = _video('BV-PARTS', _multipartTitle, [
    '认识相机：从曝光三要素开始',
    '自然光人像：捕捉生活中的温柔瞬间',
  ]);
  if (!streaming) {
    multipart.episodes.first
      ..status = DownloadStatus.downloading
      ..progress = .584
      ..downloadSize = '68.5 / 117 MB'
      ..downloadSpeed = '3.2 MB/s';
    multipart.episodes.last
      ..status = DownloadStatus.completed
      ..downloadSpeed = '下载完成';
  }
  final collection = [
    _video('BV-WALK', '城市漫游：在老街巷里发现新的风景', ['老街漫游']),
    _video('BV-MOUNTAIN', '山野来信：把周末留给清晨与日落', ['山野来信']),
  ];
  final single = _video('BV-SINGLE', '雨天的窗边，一段让人放松的钢琴现场', ['钢琴现场']);
  return [
    BilibiliDownloadTask(
      taskId: 'layout-parts',
      singleVideoInfo: multipart.videoInfo,
      videos: [multipart],
      isStreamingImport: streaming,
    ),
    BilibiliDownloadTask(
      taskId: 'layout-collection',
      collectionInfo: BilibiliCollectionInfo(
        title: _collectionTitle,
        cover: '',
        videos: collection.map((video) => video.videoInfo).toList(),
      ),
      videos: collection,
      isStreamingImport: streaming,
    ),
    BilibiliDownloadTask(
      taskId: 'layout-single',
      singleVideoInfo: single.videoInfo,
      videos: [single],
      isExpanded: false,
      isStreamingImport: streaming,
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preview = Platform.environment['BILIBILI_TASK_LAYOUT_PREVIEW'] == '1';
  final previewDirectory =
      Platform.environment['BILIBILI_TASK_LAYOUT_PREVIEW_DIR'] ??
      '.artifacts/bilibili-task-layout-20261025';
  late Directory dataRoot;

  setUpAll(() async {
    dataRoot = await Directory.systemTemp.createTemp('bilibili_layout_');
    PathProviderPlatform.instance = _LayoutPathProvider(dataRoot.path);
    if (preview) {
      // A single variable face supplies the real bundled weights.
      await (FontLoader('Noto Sans SC')
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  tearDownAll(() async {
    // Services finish debounced persistence after their screen is disposed.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (dataRoot.existsSync()) await dataRoot.delete(recursive: true);
  });

  Future<GlobalKey> mount(
    WidgetTester tester, {
    required Size size,
    required bool streaming,
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final service = BilibiliDownloadService()
      ..replaceTasksForTesting(_tasks(streaming));
    final boundary = GlobalKey();
    final baseTheme = ThemeData.dark(useMaterial3: true);
    // Mirror the app's light body default to verify the page overrides it.
    final lightText = baseTheme.textTheme.apply(
      fontFamily: preview ? 'Noto Sans SC' : null,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: service),
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: LibraryService()),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: baseTheme.copyWith(
            platform: size.width >= 1000
                ? TargetPlatform.windows
                : TargetPlatform.android,
            textTheme: lightText.copyWith(
              bodyMedium: lightText.bodyMedium?.copyWith(
                fontWeight: FontWeight.w300,
              ),
              labelLarge: lightText.labelLarge?.copyWith(
                fontWeight: FontWeight.w300,
              ),
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: boundary, child: child!),
          ),
          home: const Scaffold(),
          initialRoute: '/bilibili',
          routes: {
            '/bilibili': (_) =>
                BilibiliDownloadScreen(initialStreamingMode: streaming),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      service.dispose();
    });
    return boundary;
  }

  for (final streaming in [false, true]) {
    for (final width in [390.0, 1280.0]) {
      testWidgets(
        'queue scope, primary states and toolbar position $streaming / $width',
        (tester) async {
          await mount(tester, size: Size(width, 1000), streaming: streaming);
          final service = Provider.of<BilibiliDownloadService>(
            tester.element(find.byType(BilibiliDownloadScreen)),
            listen: false,
          );
          final toolbarFinder = find.byType(DownloadQueueToolbar);
          expect(
            tester
                .widget<DownloadQueueToolbar>(toolbarFinder)
                .primary!
                .onPressed,
            isNotNull,
          );
          var queue = tester.widget<DownloadQueueToolbar>(toolbarFinder);
          expect(queue.primary!.label, streaming ? '添加当前列表 5' : '开始当前列表 3');
          if (!streaming) expect(queue.secondary!.label, '暂停当前列表 1');
          final toolbar = tester.getRect(toolbarFinder);
          expect(width < 600 ? toolbar.top > 500 : toolbar.top < 500, isTrue);
          final task = service.tasksForMode(streaming).first;
          final episode = task.videos.first.episodes.first;
          service.setEpisodeSelected(task, task.videos.first, episode, true);
          await tester.pump();
          queue = tester.widget<DownloadQueueToolbar>(toolbarFinder);
          expect(queue.selectionLabel, '已选1项');
          expect(queue.primary!.label, streaming ? '添加所选 1' : '开始所选 0');
          expect(queue.primary!.onPressed, streaming ? isNotNull : isNull);
          service.clearSelection();
          await tester.pump();
          final action = find.byKey(
            ValueKey('bilibili-primary-${task.taskId}-${episode.page.cid}'),
          );
          expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
          episode
            ..status = DownloadStatus.completed
            ..isExported = true
            ..importState = BilibiliImportState.imported
            ..importedVideoIds = ['saved-card'];
          service.notifyListeners();
          await tester.pump();
          expect(tester.widget<IconButton>(action).tooltip, '打开媒体库卡片');
          expect(tester.widget<IconButton>(action).onPressed, isNotNull);
          if (!streaming) {
            episode
              ..isExported = false
              ..status = DownloadStatus.merging;
            service.notifyListeners();
            await tester.pump();
            expect(tester.widget<IconButton>(action).tooltip, '正在处理');
            expect(tester.widget<IconButton>(action).onPressed, isNull);
            episode
              ..status = DownloadStatus.completed
              ..importState = BilibiliImportState.failed
              ..importError = '保存失败';
            service.notifyListeners();
            await tester.pump();
            expect(tester.widget<IconButton>(action).tooltip, '重试入库');
          }
          await tester.pump(const Duration(milliseconds: 1400));
          await tester.pumpAndSettle();
        },
      );
    }
    testWidgets(
      'phone actions and long-press sorting remain usable $streaming',
      (tester) async {
        await mount(tester, size: const Size(360, 900), streaming: streaming);
        final input = find.byKey(const ValueKey('bilibili-download-input'));
        await tester.enterText(input, 'BV1xx411c7mD');
        await tester.tap(find.byTooltip('换行'));
        await tester.pump();
        expect(
          tester.widget<TextField>(input).controller!.text,
          'BV1xx411c7mD\n',
        );
        await tester.tap(find.byIcon(Icons.clear));
        await tester.pump();
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        final first = find.byKey(const ValueKey('bb-task-layout-parts'));
        await tester.tap(first);
        await tester.pumpAndSettle();
        expect(find.text('P1 认识相机：从曝光三要素开始'), findsNothing);
        await tester.tap(first);
        await tester.pumpAndSettle();
        expect(find.text('P1 认识相机：从曝光三要素开始'), findsOneWidget);

        final gesture = await tester.startGesture(tester.getCenter(first));
        await tester.pump(const Duration(milliseconds: 430));
        await tester.pump(const Duration(milliseconds: 300));
        final last = tester.getRect(
          find.byKey(const ValueKey('bb-task-layout-single')),
        );
        await gesture.moveTo(Offset(last.center.dx, last.bottom - 4));
        await tester.pump(const Duration(milliseconds: 80));
        await gesture.up();
        await tester.pumpAndSettle();
        final service = Provider.of<BilibiliDownloadService>(
          tester.element(find.byType(BilibiliDownloadScreen)),
          listen: false,
        );
        expect(service.taskIds.last, 'layout-parts');
        expect(service.getTaskById('layout-parts')!.isExpanded, isTrue);
        // Let the queue's debounced order save finish in fake time.
        await tester.pump(const Duration(milliseconds: 1400));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );

    for (final size in const [
      Size(320, 780),
      Size(360, 800),
      Size(390, 844),
      Size(600, 960),
      Size(768, 1024),
      Size(1280, 900),
      Size(1920, 1080),
      Size(640, 360),
    ]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets(
          'task layout $streaming at $size / text $scale',
          (tester) async {
            await mount(tester, size: size, streaming: streaming, scale: scale);
            expect(tester.takeException(), isNull);
            final input = tester.getRect(
              find.byKey(const ValueKey('bilibili-download-input')),
            );
            final actions = tester.getRect(
              find.byKey(const ValueKey('bilibili-download-input-actions')),
            );
            final card = tester.getRect(
              find.descendant(
                of: find.byKey(const ValueKey('bb-task-layout-parts')),
                matching: find.byType(Card),
              ),
            );
            expect(input.left, closeTo(card.left, .01));
            expect(actions.right, closeTo(card.right, .01));
            expect(input.right, lessThan(actions.left));
            expect(input.center.dy, closeTo(actions.center.dy, 0.1));
            expect(input.width, greaterThanOrEqualTo(size.width * .4));
            if (scale == 1) {
              expect(
                input.width / (actions.right - input.left),
                greaterThanOrEqualTo(.55),
              );
              expect(
                tester.getSize(find.text(_multipartTitle)).width,
                greaterThanOrEqualTo(size.width < 600 ? size.width * .39 : 300),
              );
            }
            expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
            expect(
              find.byWidgetPredicate(
                (widget) => widget is LongPressDraggable<String>,
              ),
              findsWidgets,
            );
            final title = tester.widget<Text>(find.text(_multipartTitle));
            expect(title.style?.fontWeight, FontWeight.w600);
            expect(title.maxLines, 2);
            final subtitle = find.text('P1 认识相机：从曝光三要素开始');
            if (subtitle.evaluate().isNotEmpty) {
              expect(
                tester.widget<Text>(subtitle).style?.fontWeight,
                FontWeight.w500,
              );
              expect(
                Theme.of(
                  tester.element(subtitle),
                ).textTheme.bodyMedium?.fontWeight,
                FontWeight.w400,
              );
            }
            final cover = tester.getSize(
              find.byKey(const ValueKey('bb-task-cover-layout-parts')),
            );
            expect(cover.width, lessThanOrEqualTo(size.width < 600 ? 60 : 72));
            expect(cover.width / cover.height, closeTo(1.6, .01));
          },
          variant: TargetPlatformVariant({
            size.width >= 1000
                ? TargetPlatform.windows
                : TargetPlatform.android,
          }),
        );
      }
    }

    if (preview) {
      for (final size in const [
        Size(320, 780),
        Size(390, 900),
        Size(768, 1024),
        Size(1280, 900),
      ]) {
        testWidgets(
          'preview $streaming ${size.width.toInt()}',
          (tester) async {
            final key = await mount(tester, size: size, streaming: streaming);
            expect(tester.takeException(), isNull);
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 2);
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '$previewDirectory/'
                '${streaming ? 'online' : 'download'}-${size.width.toInt()}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          },
          variant: TargetPlatformVariant({
            size.width >= 1000
                ? TargetPlatform.windows
                : TargetPlatform.android,
          }),
        );
      }
    }
  }
}

class _LayoutPathProvider extends PathProviderPlatform {
  _LayoutPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
