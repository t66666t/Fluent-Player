import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

const _firstFeed = 'https://podnews.test/a.xml';
const _secondFeed = 'https://podnews.test/b.xml';

PodcastResponse _feed(String address, {String? title}) => PodcastResponse(
  utf8.encode('''<rss version="2.0"><channel>
<title>${title ?? (address == _firstFeed ? 'Podnews Daily' : 'Second podcast')}</title>
<item><guid>one</guid><title>Sample episode</title>
<enclosure url="https://media.test/one.mp3" type="audio/mpeg"/>
</item></channel></rss>'''),
  200,
  address,
  {},
);

class _PreviewHttp extends PodcastHttp {
  final feeds = <String>[];
  int searches = 0;
  Future<PodcastResponse> Function(String)? source;

  @override
  Future<PodcastResponse> get(
    String url, {
    Map<String, String> headers = const {},
    int maxBytes = 32 * 1024 * 1024,
    void Function(HttpClient)? onClient,
    bool Function()? isCancelled,
  }) async {
    if (Uri.parse(url).host == 'itunes.apple.com') {
      searches++;
      return PodcastResponse(
        utf8.encode(
          jsonEncode({
            'results': [
              {'collectionName': 'Podnews Daily', 'feedUrl': _firstFeed},
              {'collectionName': 'Second podcast', 'feedUrl': _secondFeed},
            ],
          }),
        ),
        200,
        url,
        {},
      );
    }
    feeds.add(url);
    return source == null ? _feed(url) : source!(url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PodcastStore store;
  late _PreviewHttp http;
  late PodcastController controller;
  var offline = false;

  setUp(() {
    offline = false;
    directory = Directory.systemTemp.createTempSync(
      'podcast-preview-recovery-',
    );
    store = PodcastStore(sqlite3.openInMemory());
    http = _PreviewHttp();
    final client = PodcastClient(http: http);
    controller = PodcastController(
      store: store,
      client: client,
      readConnectivity: () async => [
        offline ? ConnectivityResult.none : ConnectivityResult.wifi,
      ],
      mediaStore: PodcastMediaStore(root: directory, store: store, http: http),
    );
    PodcastRuntime.debugOverride = PodcastRuntime.forTesting(controller);
  });

  tearDown(() async {
    PodcastRuntime.debugOverride = null;
    await controller.close();
    store.close();
    directory.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {bool narrow = false}) async {
    tester.view.physicalSize = narrow
        ? const Size(360, 800)
        : const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        builder: narrow
            ? (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.6)),
                child: child!,
              )
            : null,
        home: const PodcastDiscoverPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('podcast-search-input')),
      'Podnews',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, [String feed = _firstFeed]) async {
    await tester.tap(find.byKey(ValueKey('podcast-search-result-$feed')));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets('a transient first failure recovers without leaving the page', (
    tester,
  ) async {
    http.source = (address) async {
      if (http.feeds.length == 1) {
        throw const HttpException('Connection closed before full header');
      }
      return _feed(address);
    };
    await mount(tester);
    await select(tester);
    // Advance the retry timer explicitly; loading no longer drives frames.
    await tester.pump(controller.previews.retryDelay);
    await tester.pumpAndSettle();
    expect(http.feeds, [_firstFeed, _firstFeed]);
    expect(find.text('订阅整个频道'), findsOneWidget);
    expect(find.text('Sample episode'), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);
    expect(store.channels, isEmpty);
    expect(store.episodes(), isEmpty);
    await close(tester);
  });

  testWidgets('offline preview retries that feed directly after reconnection', (
    tester,
  ) async {
    await mount(tester);
    offline = true;
    await select(tester);
    await tester.pumpAndSettle();
    expect(http.feeds, isEmpty);
    expect(find.text('当前未连接网络，请连接后重新加载。'), findsOneWidget);
    expect(find.text('返回搜索结果'), findsOneWidget);
    expect(find.text('重新搜索'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    offline = false;
    await tester.tap(find.byKey(const ValueKey('podcast-preview-retry')));
    await tester.pumpAndSettle();
    expect(http.searches, 1);
    expect(http.feeds, [_firstFeed]);
    expect(find.text('订阅整个频道'), findsOneWidget);
    await close(tester);
  });

  testWidgets(
    'cached preview remains readable offline and on a narrow screen',
    (tester) async {
      await mount(tester, narrow: true);
      await select(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回').last);
      await tester.pumpAndSettle();
      offline = true;
      await select(tester);
      await tester.pumpAndSettle();
      expect(http.feeds, [_firstFeed]);
      expect(find.text('Sample episode'), findsOneWidget);
      expect(find.text('订阅整个频道'), findsOneWidget);
      expect(find.textContaining('当前显示最近成功加载的节目'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(store.channels, isEmpty);
      expect(store.episodes(), isEmpty);
      await close(tester);
    },
  );

  testWidgets(
    'refresh keeps cached content and a late result cannot replace B',
    (tester) async {
      await mount(tester);
      await select(tester);
      await tester.pumpAndSettle();
      final pending = Completer<PodcastResponse>();
      http.source = (address) =>
          address == _firstFeed ? pending.future : Future.value(_feed(address));
      await tester.tap(find.byKey(const ValueKey('podcast-preview-refresh')));
      await tester.pump();
      expect(find.text('Sample episode'), findsOneWidget);
      expect(find.text('正在检查节目更新…'), findsOneWidget);
      await tester.tap(find.byTooltip('返回').last);
      await tester.pumpAndSettle();
      await select(tester, _secondFeed);
      await tester.pumpAndSettle();
      pending.complete(_feed(_firstFeed, title: 'Late old channel'));
      await tester.pumpAndSettle();
      expect(find.text('Second podcast'), findsWidgets);
      expect(find.text('Late old channel'), findsNothing);
      expect(
        controller.previews.cached(_firstFeed)!.feed.channel.title,
        'Podnews Daily',
      );
      await close(tester);
    },
  );

  testWidgets('cancelling first load preserves results and ignores late A', (
    tester,
  ) async {
    final pending = Completer<PodcastResponse>();
    http.source = (address) =>
        address == _firstFeed ? pending.future : Future.value(_feed(address));
    await mount(tester);
    await select(tester);
    await tester.tap(find.text('取消加载'));
    await tester.pumpAndSettle();
    expect(find.text('搜索结果 · 2'), findsOneWidget);
    await select(tester, _secondFeed);
    await tester.pumpAndSettle();
    pending.complete(_feed(_firstFeed, title: 'Late old channel'));
    await tester.pumpAndSettle();
    expect(find.text('Second podcast'), findsWidgets);
    expect(find.text('Late old channel'), findsNothing);
    expect(controller.previews.cached(_firstFeed), isNull);
    await close(tester);
  });

  testWidgets('disposing during retry prevents further requests', (
    tester,
  ) async {
    http.source = (_) async => throw PodcastHttpStatusException(503);
    await mount(tester);
    await select(tester);
    await tester.pump();
    expect(find.text('连接暂时中断，正在重新加载…'), findsOneWidget);
    await close(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(http.feeds, [_firstFeed]);
  });

  testWidgets('a refused refresh keeps old data and allows another refresh', (
    tester,
  ) async {
    await mount(tester);
    await select(tester);
    await tester.pumpAndSettle();
    http.source = (_) async => throw PodcastHttpStatusException(403);
    await tester.tap(find.byKey(const ValueKey('podcast-preview-refresh')));
    await tester.pumpAndSettle();
    expect(http.feeds, [_firstFeed, _firstFeed]);
    expect(find.text('Sample episode'), findsOneWidget);
    expect(find.textContaining('拒绝访问'), findsOneWidget);
    http.source = (address) async => _feed(address, title: 'Updated channel');
    await tester.tap(find.byKey(const ValueKey('podcast-preview-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('Updated channel'), findsWidgets);
    expect(find.byKey(const ValueKey('podcast-preview-notice')), findsNothing);
    await close(tester);
  });
}
