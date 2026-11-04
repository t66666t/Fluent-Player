import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/models/bilibili_uploader_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/screens/bilibili/bilibili_uploader_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_uploader_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/bilibili_adaptive_list.dart';
import 'package:video_player_app/widgets/bilibili_image_reveal.dart';
import 'package:video_player_app/widgets/bilibili_loading.dart';

class _Search extends BilibiliPublicApiService {
  final pending =
      <String, Completer<BilibiliSearchPage<BilibiliSearchVideo>>>{};

  @override
  Future<List<String>> suggestKeywords(String text) async => [];

  @override
  Future<BilibiliSearchPage<BilibiliSearchVideo>> searchVideos(
    String keyword, {
    int page = 1,
    BilibiliVideoSearchFilter filter = const BilibiliVideoSearchFilter(),
    DateTime? now,
  }) => (pending[keyword] = Completer()).future;

  void complete(String keyword) => pending[keyword]!.complete(
    BilibiliSearchPage(
      page: 1,
      numPages: 1,
      items: List.generate(
        12,
        (i) => BilibiliSearchVideo(
          bvid: 'BV1GJ411x7h7-$i',
          title: '$keyword · 视频 $i',
          author: '光影记录者',
          durationSeconds: 120,
          playCount: 23000,
        ),
      ),
    ),
  );
}

class _Uploader extends BilibiliUploaderService {
  final profile = Completer<BilibiliUploaderResult<BilibiliUploaderProfile>>();
  final videos =
      Completer<
        BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderVideo>>
      >();
  final articles =
      Completer<
        BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderArticle>>
      >();
  final collections =
      Completer<
        BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderCollection>>
      >();
  int articleRequests = 0;
  int collectionRequests = 0;

  @override
  Future<BilibiliUploaderResult<BilibiliUploaderProfile>> fetchProfile(
    int mid, {
    void Function(BilibiliUploaderProfile profile)? onProfile,
  }) => profile.future;

  @override
  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderVideo>>>
  fetchVideos(
    int mid, {
    int page = 1,
    BilibiliUploaderVideoOrder order = BilibiliUploaderVideoOrder.latest,
    String keyword = '',
  }) => videos.future;

  @override
  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderArticle>>>
  fetchArticles(int mid, {int page = 1}) {
    articleRequests++;
    return articles.future;
  }

  @override
  Future<
    BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderCollection>>
  >
  fetchCollections(int mid, {int page = 1}) {
    collectionRequests++;
    return collections.future;
  }
}

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _search(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byType(TextField).first, keyword);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
}

final _previewKey = GlobalKey();
final _preview = Platform.environment['BILIBILI_LOADING_PREVIEW'] == '1';

Widget _app(Widget child, {bool reduceMotion = false, double scale = 1}) =>
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppTokens.bgBase,
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: _preview ? 'BilibiliLoadingPreview' : null,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(scale),
        ),
        child: RepaintBoundary(key: _previewKey, child: child!),
      ),
      home: Scaffold(body: child),
    );

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_preview) return;
  final boundary =
      _previewKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('.artifacts/bilibili-loading/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
    if (_preview) {
      await (FontLoader('BilibiliLoadingPreview')..addFont(
            Future.value(
              ByteData.sublistView(
                File(
                  'assets/fonts/NotoSansCJKsc-Regular.otf',
                ).readAsBytesSync(),
              ),
            ),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  testWidgets('slow search blends results over bones, then stops ticking', (
    tester,
  ) async {
    _window(tester, const Size(390, 844));
    final api = _Search();
    await tester.pumpWidget(_app(BilibiliHomePage(isActive: true, api: api)));
    await _search(tester, '摄影入门');
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.byType(BilibiliListSkeleton), findsOneWidget);
    expect(find.text('摄影入门 · 视频 0'), findsNothing);
    await _capture(tester, 'search-phone-loading');

    api.complete('摄影入门');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(BilibiliListSkeleton), findsOneWidget);
    expect(find.text('摄影入门 · 视频 0'), findsOneWidget);
    final fading = tester.widgetList<FadeTransition>(
      find.byType(FadeTransition),
    );
    expect(
      fading.any((f) => f.opacity.value > 0 && f.opacity.value < 1),
      isTrue,
    );
    await _capture(tester, 'search-phone-revealing');
    await tester.pumpAndSettle();
    expect(find.byType(BilibiliListSkeleton), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await _capture(tester, 'search-phone-ready');
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid searches remove old rows and ignore late responses', (
    tester,
  ) async {
    final api = _Search();
    await tester.pumpWidget(_app(BilibiliHomePage(isActive: true, api: api)));
    await _search(tester, '第一批');
    api.complete('第一批');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await _search(tester, '过时请求');
    expect(find.text('第一批 · 视频 0'), findsNothing);
    await _search(tester, '最终请求');
    api.complete('最终请求');
    await tester.pumpAndSettle();
    api.complete('过时请求');
    await tester.pumpAndSettle();
    expect(find.text('最终请求 · 视频 0'), findsOneWidget);
    expect(find.text('过时请求 · 视频 0'), findsNothing);
    expect(find.byType(BilibiliListSkeleton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uploader tabs load independently and retain the video list', (
    tester,
  ) async {
    _window(tester, const Size(900, 1000));
    final service = _Uploader();
    await tester.pumpWidget(
      _app(
        BilibiliUploaderScreen(
          mid: 9527,
          initialName: '光影记录者',
          service: service,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.byType(BilibiliProfileSkeleton), findsOneWidget);
    expect(find.byType(BilibiliListSkeleton), findsOneWidget);
    await _capture(tester, 'uploader-loading');
    service.profile.complete(
      const BilibiliUploaderResult.success(
        BilibiliUploaderProfile(mid: 9527, name: '光影记录者', sign: '记录日常的光与影'),
      ),
    );
    service.videos.complete(
      BilibiliUploaderResult.success(
        BilibiliUploaderPage(
          page: 1,
          total: 20,
          items: List.generate(
            20,
            (i) => BilibiliUploaderVideo(
              bvid: 'BV1GJ411x7h7-$i',
              title: '摄影课堂 · 第 $i 集',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final videoList = tester.state(find.byType(BilibiliAdaptiveList));

    await tester.tap(find.widgetWithText(Tab, '专栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(service.articleRequests, 1);
    expect(
      tester
          .widget<BilibiliListSkeleton>(find.byType(BilibiliListSkeleton))
          .kind,
      BilibiliSkeletonKind.article,
    );
    await _capture(tester, 'uploader-articles-loading');
    service.articles.complete(
      const BilibiliUploaderResult.success(
        BilibiliUploaderPage<BilibiliUploaderArticle>(page: 1, items: []),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有专栏'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, '合集'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(service.collectionRequests, 1);
    expect(
      tester
          .widget<BilibiliListSkeleton>(find.byType(BilibiliListSkeleton))
          .kind,
      BilibiliSkeletonKind.collection,
    );
    service.collections.complete(
      const BilibiliUploaderResult.success(
        BilibiliUploaderPage<BilibiliUploaderCollection>(page: 1, items: []),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '投稿'));
    await tester.pumpAndSettle();
    expect(
      identical(tester.state(find.byType(BilibiliAdaptiveList)), videoList),
      isTrue,
    );
    expect(find.byType(BilibiliListSkeleton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new pages reveal without replaying old or scrolled-in rows', (
    tester,
  ) async {
    final count = ValueNotifier(3);
    final scroll = ScrollController();
    addTearDown(count.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<int>(
          valueListenable: count,
          builder: (context, count, _) => BilibiliAdaptiveList(
            controller: scroll,
            animateItems: true,
            itemCount: count,
            itemBuilder: (context, i) => SizedBox(
              key: ValueKey('row-$i'),
              height: 80,
              child: Text('row $i'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double opacity(int i) => tester
        .widget<Opacity>(
          find
              .ancestor(
                of: find.byKey(ValueKey('row-$i')),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    count.value = 5;
    await tester.pump();
    expect(opacity(0), 1);
    expect(opacity(3), 0);
    await tester.pump(const Duration(milliseconds: 90));
    expect(opacity(3), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    count.value = 50;
    await tester.pumpAndSettle();
    scroll.jumpTo(25 * 80);
    await tester.pump();
    expect(
      opacity(25),
      1,
      reason: 'Late lazy builds must not animate on scrolling',
    );
    scroll.jumpTo(0);
    await tester.pump();
    expect(opacity(0), 1, reason: 'Already seen rows stay fully visible');
  });

  testWidgets('image frames fade in place, cached frames appear immediately', (
    tester,
  ) async {
    Future<void> show({required bool ready, bool synchronous = false}) =>
        tester.pumpWidget(
          _app(
            Center(
              child: SizedBox(
                width: 160,
                height: 100,
                child: BilibiliImageReveal(
                  ready: ready,
                  synchronous: synchronous,
                  placeholder: const ColoredBox(
                    key: ValueKey('placeholder'),
                    color: Colors.grey,
                  ),
                  child: const ColoredBox(
                    key: ValueKey('pixels'),
                    color: Colors.blue,
                  ),
                ),
              ),
            ),
          ),
        );
    double opacity() => tester
        .widget<Opacity>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('pixels')),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    await show(ready: false);
    await tester.pump(const Duration(milliseconds: 100));
    final bounds = tester.getRect(find.byKey(const ValueKey('pixels')));
    await show(ready: true);
    await tester.pump(const Duration(milliseconds: 80));
    expect(opacity(), inExclusiveRange(0, 1));
    expect(find.byKey(const ValueKey('placeholder')), findsOneWidget);
    expect(tester.getRect(find.byKey(const ValueKey('pixels'))), bounds);
    await tester.pumpAndSettle();
    await show(ready: true);
    expect(
      opacity(),
      1,
      reason: 'Further frames and parent rebuilds do not restart',
    );
    expect(find.byKey(const ValueKey('placeholder')), findsNothing);

    await show(ready: false);
    await show(ready: true, synchronous: true);
    expect(opacity(), 1);
  });

  for (final profile in [
    (size: const Size(320, 740), scale: 1.8),
    (size: const Size(915, 360), scale: 1.0),
    (size: const Size(1440, 900), scale: 1.0),
  ]) {
    testWidgets(
      'skeletons fit ${profile.size} at ${profile.scale} text scale',
      (tester) async {
        _window(tester, profile.size);
        for (final kind in BilibiliSkeletonKind.values) {
          await tester.pumpWidget(
            _app(
              BilibiliListSkeleton(kind: kind),
              reduceMotion: true,
              scale: profile.scale,
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(tester.binding.hasScheduledFrame, isFalse);
          if (profile.size.width == 1440 &&
              kind == BilibiliSkeletonKind.video) {
            await _capture(tester, 'search-desktop-loading');
          }
        }
      },
    );
  }

  testWidgets('hidden loading regions stop scheduling animation frames', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const TickerMode(enabled: false, child: BilibiliListSkeleton())),
    );
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
