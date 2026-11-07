import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

class _SearchClient extends PodcastClient {
  final calls = <String>[];
  final filters = <(String, String)>[];
  Completer<List<PodcastSearchResult>>? pending;
  Completer<PodcastResolution>? pendingPreview;
  bool fail = false;
  @override
  Future<List<PodcastSearchResult>> search(
    String query, {
    String region = 'CN',
    String provider = 'apple',
  }) async {
    calls.add(query);
    filters.add((region, provider));
    if (pending != null) return pending!.future;
    if (fail) throw const FormatException('目录暂时不可用');
    if (query == '没有结果') return [];
    return [
      for (final (index, title, author) in const [
        (0, '日谈公园', '日谈公园'),
        (1, '忽左忽右', 'JustPod'),
        (2, '随机波动', '随机波动 StochasticVolatility'),
        (3, '在场之间：关于生活、远方和那些值得被听见的故事', '小满与阿野'),
      ])
        PodcastSearchResult(
          title: title,
          author: author,
          feedUrl: 'https://example.test/$index.xml',
        ),
    ];
  }

  @override
  Future<PodcastResolution> resolve(
    String input, {
    Set<String>? visited,
    PodcastResolveRequest? request,
  }) async => pendingPreview != null
      ? await pendingPreview!.future
      : PodcastResolution(
          PodcastFeed(
            PodcastChannel(id: 'preview', feedUrl: input, title: '日谈公园'),
            [],
          ),
        );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PodcastStore store;
  late _SearchClient client;
  late PodcastController controller;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('podcast-search-');
    store = PodcastStore(sqlite3.openInMemory());
    client = _SearchClient();
    controller = PodcastController(
      store: store,
      client: client,
      mediaStore: PodcastMediaStore(
        root: directory,
        store: store,
        http: client.http,
      ),
    );
    PodcastRuntime.debugOverride = PodcastRuntime.forTesting(controller);
  });
  tearDown(() async {
    PodcastRuntime.debugOverride = null;
    await controller.close();
    store.close();
    directory.deleteSync(recursive: true);
  });

  test('history survives reopening, deduplicates, caps and deletes', () {
    final path = '${directory.path}/history.sqlite';
    var saved = PodcastStore.open(path);
    for (var i = 0; i < 15; i++) {
      saved.rememberSearch('keyword $i');
    }
    saved.rememberSearch(' KEYWORD 4 ');
    saved.rememberSearch('  ');
    saved.close();
    saved = PodcastStore.open(path);
    expect(saved.searchHistory, hasLength(12));
    expect(saved.searchHistory.first, 'KEYWORD 4');
    expect(
      saved.searchHistory.where((v) => v.toLowerCase() == 'keyword 4'),
      hasLength(1),
    );
    saved.removeSearch('KEYWORD 4');
    expect(saved.searchHistory, hasLength(11));
    saved.clearSearchHistory();
    expect(saved.searchHistory, isEmpty);
    saved.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1000, 900),
    double scale = 1,
    GlobalKey? captureKey,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: RepaintBoundary(key: captureKey, child: child!),
        ),
        home: const PodcastDiscoverPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, String value) async {
    await tester.enterText(
      find.byKey(const ValueKey('podcast-search-input')),
      value,
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  Future<void> chooseMode(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(TextButton, label));
    await tester.pumpAndSettle();
  }

  for (final escape in [false, true]) {
    testWidgets('${escape ? 'Escape' : 'system back'} unwinds discovery', (
      tester,
    ) async {
      await mount(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const PodcastDiscoverPage()),
      );
      await tester.pumpAndSettle();

      Future<void> back() async {
        // The shared keyboard handler first dismisses focused text editing.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        if (escape) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
      }

      await submit(tester, '生活');
      await tester.tap(
        find.byKey(
          const ValueKey('podcast-search-result-https://example.test/0.xml'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('订阅整个频道'), findsOneWidget);
      await back();
      expect(find.text('搜索结果 · 4'), findsOneWidget);
      expect(client.calls, ['生活']);
      expect(navigator.canPop(), isTrue);

      final preview = Completer<PodcastResolution>();
      client.pendingPreview = preview;
      await tester.tap(
        find.byKey(
          const ValueKey('podcast-search-result-https://example.test/1.xml'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('取消加载'), findsOneWidget);
      await back();
      expect(find.text('搜索结果 · 4'), findsOneWidget);
      preview.complete(
        PodcastResolution(
          PodcastFeed(
            PodcastChannel(
              id: 'late',
              feedUrl: 'https://late.test',
              title: '迟到详情',
            ),
            [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('订阅整个频道'), findsNothing);

      await back();
      expect(find.text('搜索喜欢的播客'), findsOneWidget);
      expect(navigator.canPop(), isTrue);
      expect(store.searchHistory, ['生活']);

      final pending = Completer<List<PodcastSearchResult>>();
      client.pending = pending;
      await submit(tester, '加载中');
      await back();
      expect(find.text('搜索喜欢的播客'), findsOneWidget);
      pending.complete([
        const PodcastSearchResult(
          title: '过时结果',
          author: '',
          feedUrl: 'https://late.test',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('过时结果'), findsNothing);
      expect(navigator.canPop(), isTrue);
      await back();
      expect(navigator.canPop(), isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('visible filters rerun search and survive mode switches', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('中国大陆'), findsOneWidget);
    expect(find.text('Apple Podcasts'), findsOneWidget);
    expect(find.byTooltip('搜索筛选'), findsNothing);
    await submit(tester, '生活');
    expect(find.text('来源：Apple Podcasts / iTunes Search API'), findsOneWidget);
    await tester.tap(find.text('中国大陆'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('美国').last);
    await tester.pumpAndSettle();
    expect(client.filters.last, ('US', 'apple'));
    await tester.tap(find.text('Apple Podcasts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Podcast Index').last);
    await tester.pumpAndSettle();
    expect(client.filters.last, ('US', 'index'));
    expect(find.text('来源：Podcast Index'), findsOneWidget);
    await chooseMode(tester, '链接导入');
    await chooseMode(tester, '在线搜索');
    expect(find.text('美国'), findsOneWidget);
    expect(find.text('Podcast Index'), findsOneWidget);
    expect(store.searchHistory, ['生活']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('submit, clear, history replay, deletion and preview work', (
    tester,
  ) async {
    await mount(tester);
    await submit(tester, '  生活  ');
    expect(client.calls, ['生活']);
    expect(store.searchHistory, ['生活']);
    expect(find.text('搜索结果 · 4'), findsOneWidget);
    await tester.tap(find.byTooltip('清除搜索内容'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('搜索喜欢的播客'), findsOneWidget);
    expect(find.byTooltip('清除搜索内容'), findsNothing);
    await tester.tap(find.widgetWithText(InputChip, '生活'));
    await tester.pumpAndSettle();
    expect(client.calls, ['生活', '生活']);
    await tester.tap(
      find.byKey(
        const ValueKey('podcast-search-result-https://example.test/0.xml'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('订阅整个频道'), findsOneWidget);
    expect(store.channels, isEmpty);
    await tester.tap(find.byTooltip('返回').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('podcast-search-input')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除搜索记录：生活'));
    await tester.pumpAndSettle();
    expect(store.searchHistory, isEmpty);
    await submit(tester, '旅行');
    await tester.tap(find.byKey(const ValueKey('podcast-search-input')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空历史'));
    await tester.pumpAndSettle();
    expect(store.searchHistory, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'clearing and editing invalidate in-flight searches and debounce',
    (tester) async {
      await mount(tester);
      final pending = Completer<List<PodcastSearchResult>>();
      client.pending = pending;
      await tester.enterText(find.byType(TextField), '旧关键词');
      await tester.pump(const Duration(milliseconds: 500));
      expect(client.calls, ['旧关键词']);
      expect(
        store.searchHistory,
        isEmpty,
        reason: 'Incomplete automatic requests are not saved',
      );
      await tester.enterText(find.byType(TextField), '新关键词');
      pending.complete([
        const PodcastSearchResult(
          title: '过时结果',
          author: '',
          feedUrl: 'https://old.test',
        ),
      ]);
      await tester.pump();
      expect(find.text('过时结果'), findsNothing);
      await tester.tap(find.byTooltip('清除搜索内容'));
      await tester.pump(const Duration(seconds: 1));
      expect(client.calls, ['旧关键词']);
      expect(find.text('搜索喜欢的播客'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('empty results, error retry and import tabs are distinct', (
    tester,
  ) async {
    await mount(tester);
    await submit(tester, '没有结果');
    expect(find.text('没有找到相关播客，试试其他关键词'), findsOneWidget);
    client.fail = true;
    await submit(tester, '科技');
    expect(find.text('目录暂时不可用'), findsOneWidget);
    expect(find.text('没有找到相关播客，试试其他关键词'), findsNothing);
    client.fail = false;
    await tester.tap(find.text('重新搜索'));
    await tester.pumpAndSettle();
    expect(find.text('搜索结果 · 4'), findsOneWidget);
    await chooseMode(tester, '链接导入');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.test/rss');
    await tester.pump();
    await tester.tap(find.byTooltip('清除链接'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await chooseMode(tester, 'OPML / 备份');
    await tester.pumpAndSettle();
    expect(find.text('选择订阅列表或备份'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (name, size, scale, keyboard) in const [
    ('small-large-text', Size(320, 640), 1.7, 0.0),
    ('phone', Size(390, 844), 1.0, 0.0),
    ('phone-keyboard', Size(390, 844), 1.0, 310.0),
    ('landscape', Size(844, 390), 1.2, 0.0),
    ('tablet', Size(768, 1024), 1.2, 0.0),
    ('desktop', Size(1440, 1000), 1.0, 0.0),
    ('ultrawide', Size(2560, 1080), 1.0, 0.0),
  ]) {
    testWidgets('discovery layout and results at $name', (tester) async {
      await tester.runAsync(() async {
        await (FontLoader(
          'MiSans',
        )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      store.rememberSearch('一个名字很长很长的播客以及它的作者和生活故事');
      store.rememberSearch('日谈公园');
      final key = GlobalKey();
      await mount(
        tester,
        size: size,
        scale: scale,
        keyboard: keyboard,
        captureKey: key,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('podcast-search-input')));
      await tester.pumpAndSettle();
      final inputRect = tester.getRect(
        find.byKey(const ValueKey('podcast-search-input')),
      );
      final historyRect = tester.getRect(
        find.byKey(const ValueKey('podcast-search-history')),
      );
      expect(historyRect.top, greaterThanOrEqualTo(inputRect.bottom));
      if (keyboard == 0) await _capture(tester, key, 'search-$name');
      await tester.ensureVisible(
        find.byKey(const ValueKey('podcast-search-input')),
      );
      await submit(tester, '生活');
      expect(tester.takeException(), isNull);
      final first = find.byKey(
        const ValueKey('podcast-search-result-https://example.test/0.xml'),
      );
      await tester.ensureVisible(first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(first).right, lessThanOrEqualTo(size.width));
      expect(
        find.byKey(const ValueKey('podcast-search-history')),
        findsNothing,
      );
      if (keyboard == 0) await _capture(tester, key, 'results-$name');
      final loading = Completer<List<PodcastSearchResult>>();
      client.pending = loading;
      await tester.enterText(
        find.byKey(const ValueKey('podcast-search-input')),
        '加载中的播客',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (keyboard == 0) await _capture(tester, key, 'loading-$name');
      loading.complete([]);
      await tester.pumpAndSettle();
      client.pending = null;
      await chooseMode(tester, '链接导入');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('解析并预览'), findsOneWidget);
      await chooseMode(tester, 'OPML / 备份');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('.artifacts/podcast-search/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
