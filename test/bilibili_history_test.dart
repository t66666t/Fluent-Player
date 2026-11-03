import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_card_actions.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_history_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_stream_card.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

const String _bvid = 'BV1xx411c7mD';

BilibiliWatchHistoryEntry _entry(
  String bvid, {
  int page = 1,
  String cover = '',
  int minute = 0,
}) => BilibiliWatchHistoryEntry(
  bvid: bvid,
  title: 'Title $bvid',
  ownerName: 'UP',
  coverUrl: cover,
  page: page,
  watchedAt: DateTime(2026, 10, 8, 12, minute),
);

String _fakeBvid(int i) => 'BV1${i.toString().padLeft(9, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final history = BilibiliHistoryService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    history.resetForTest();
  });

  tearDown(() {
    SettingsService().resetForTest();
    history.resetForTest();
  });

  group('search history', () {
    test('keeps 12 newest keywords, one entry per trimmed keyword', () async {
      for (var i = 0; i < 15; i++) {
        await history.addSearch('k$i');
      }
      expect(history.searchHistory, hasLength(12));
      expect(history.searchHistory.first, 'k14');
      expect(history.searchHistory.last, 'k3');

      await history.addSearch('  k5 ');
      expect(history.searchHistory.first, 'k5');
      expect(history.searchHistory.where((k) => k == 'k5'), hasLength(1));
      expect(history.searchHistory, hasLength(12));

      // Case is kept as typed, so these are two keywords.
      await history.addSearch('Flutter');
      await history.addSearch('flutter');
      expect(history.searchHistory.take(2), ['flutter', 'Flutter']);

      await history.addSearch('   ');
      expect(history.searchHistory.first, 'flutter');
    });

    test('remove, clear and persistence', () async {
      await history.addSearch('a');
      await history.addSearch('b');
      await history.addSearch('c');
      await history.removeSearch('b');
      expect(history.searchHistory, ['c', 'a']);

      history.resetForTest();
      await history.ensureLoaded();
      expect(history.searchHistory, ['c', 'a']);

      await history.clearSearch();
      expect(history.searchHistory, isEmpty);
      history.resetForTest();
      await history.ensureLoaded();
      expect(history.searchHistory, isEmpty);
    });

    test(
      'switch off records nothing but keeps and clears old entries',
      () async {
        await history.addSearch('old');
        SettingsService().bilibiliRecordSearchHistory = false;
        await history.addSearch('new');
        expect(history.searchHistory, ['old']);
        await history.clearSearch();
        expect(history.searchHistory, isEmpty);
      },
    );

    test('switch is a registered setting, on by default', () async {
      final settings = SettingsService();
      await settings.init();
      expect(settings.bilibiliRecordSearchHistory, isTrue);
      expect(settings.bilibiliRecordWatchHistory, isTrue);
      await settings.updateSetting('bilibiliRecordSearchHistory', false);
      await settings.updateSetting('bilibiliRecordWatchHistory', false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('bilibiliRecordSearchHistory'), isFalse);
      expect(prefs.getBool('bilibiliRecordWatchHistory'), isFalse);
      settings.resetForTest();
      await settings.init();
      expect(settings.bilibiliRecordSearchHistory, isFalse);
      expect(settings.bilibiliRecordWatchHistory, isFalse);
    });
  });

  group('watch history', () {
    test(
      'keeps 50 newest videos, one entry per BV with the latest part',
      () async {
        for (var i = 0; i < 55; i++) {
          await history.recordWatch(_entry(_fakeBvid(i), minute: i));
        }
        expect(history.watchHistory, hasLength(50));
        expect(history.watchHistory.first.bvid, _fakeBvid(54));
        expect(history.watchHistory.last.bvid, _fakeBvid(5));

        await history.recordWatch(_entry(_fakeBvid(10), page: 3));
        expect(history.watchHistory.first.bvid, _fakeBvid(10));
        expect(history.watchHistory.first.page, 3);
        expect(
          history.watchHistory.where((e) => e.bvid == _fakeBvid(10)),
          hasLength(1),
        );
        expect(history.watchHistory, hasLength(50));
      },
    );

    test('a later record without cover keeps the known cover', () async {
      await history.recordWatch(
        _entry(_bvid, cover: 'https://i0.hdslb.com/a.jpg'),
      );
      await history.recordWatch(_entry(_bvid, page: 2));
      expect(
        history.watchHistory.single.coverUrl,
        'https://i0.hdslb.com/a.jpg',
      );
      expect(history.watchHistory.single.page, 2);
    });

    test('remove, clear and persistence', () async {
      await history.recordWatch(_entry('BV1aa411c7mD'));
      await history.recordWatch(_entry('BV1bb411c7mD', page: 2));
      await history.removeWatch('BV1aa411c7mD');
      history.resetForTest();
      await history.ensureLoaded();
      expect(history.watchHistory.single.bvid, 'BV1bb411c7mD');
      expect(history.watchHistory.single.page, 2);
      expect(history.watchHistory.single.title, 'Title BV1bb411c7mD');

      await history.clearWatch();
      history.resetForTest();
      await history.ensureLoaded();
      expect(history.watchHistory, isEmpty);
    });

    test(
      'switch off records nothing but keeps and clears old entries',
      () async {
        await history.recordWatch(_entry('BV1aa411c7mD'));
        SettingsService().bilibiliRecordWatchHistory = false;
        await history.recordWatch(_entry('BV1bb411c7mD'));
        expect(history.watchHistory.single.bvid, 'BV1aa411c7mD');
        await history.removeWatch('BV1aa411c7mD');
        expect(history.watchHistory, isEmpty);
      },
    );

    test(
      'missing covers are filled with limited concurrency and saved',
      () async {
        for (var i = 0; i < 8; i++) {
          await history.recordWatch(_entry(_fakeBvid(i), minute: i));
        }
        await history.recordWatch(
          _entry('BV1cc411c7mD', cover: 'https://i0.hdslb.com/keep.jpg'),
        );
        var running = 0;
        var maxRunning = 0;
        final asked = <String>[];
        Future<String?> fetch(String bvid) async {
          asked.add(bvid);
          running++;
          maxRunning = running > maxRunning ? running : maxRunning;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          running--;
          if (bvid == _fakeBvid(7)) throw StateError('offline');
          if (bvid == _fakeBvid(6)) return null;
          return 'https://i0.hdslb.com/$bvid.jpg';
        }

        final filled = await history.fillMissingCovers(
          fetch,
          limit: 5,
          concurrency: 2,
        );
        expect(asked, hasLength(5));
        expect(asked, isNot(contains('BV1cc411c7mD')));
        expect(maxRunning, 2);
        // Newest first: 7 (fails), 6 (none), 5, 4, 3.
        expect(filled, 3);
        String coverOf(String bvid) =>
            history.watchHistory.firstWhere((e) => e.bvid == bvid).coverUrl;
        expect(
          coverOf(_fakeBvid(5)),
          'https://i0.hdslb.com/${_fakeBvid(5)}.jpg',
        );
        expect(coverOf(_fakeBvid(7)), isEmpty);
        expect(coverOf('BV1cc411c7mD'), 'https://i0.hdslb.com/keep.jpg');

        // Failures are not retried in the same session.
        asked.clear();
        await history.fillMissingCovers(fetch, limit: 10);
        expect(asked, isNot(contains(_fakeBvid(7))));
        expect(asked, containsAll(<String>[_fakeBvid(2), _fakeBvid(0)]));

        history.resetForTest();
        await history.ensureLoaded();
        expect(
          coverOf(_fakeBvid(5)),
          'https://i0.hdslb.com/${_fakeBvid(5)}.jpg',
        );
      },
    );
  });

  group('opening from history', () {
    testWidgets('a tap hands BV and part to the opener; delete and clear', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await history.recordWatch(_entry('BV1aa411c7mD', page: 3));
      await history.recordWatch(_entry('BV1bb411c7mD'));
      final opened = <(String, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: BilibiliWatchHistoryScreen(
            fetchCover: (_) async => null,
            onOpen: (context, entry) async =>
                opened.add((entry.bvid, entry.page)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Title BV1aa411c7mD'), findsOneWidget);
      expect(find.text('UP · P3'), findsOneWidget);

      await tester.tap(find.text('Title BV1aa411c7mD'));
      await tester.pump();
      expect(opened, [('BV1aa411c7mD', 3)]);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('bilibili-watch-BV1bb411c7mD')),
          matching: find.byTooltip('更多操作'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除记录'));
      await tester.pumpAndSettle();
      expect(find.text('Title BV1bb411c7mD'), findsNothing);

      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清空'));
      await tester.pumpAndSettle();
      expect(find.text('还没有观看记录'), findsOneWidget);
    });

    group('card entry', () {
      late LibraryService library;
      late _FakeApi api;
      late BilibiliDownloadService service;

      setUp(() async {
        final root = await Directory.systemTemp.createTemp('bilibili_history_');
        final originalPathProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _FakePathProvider(root.path);
        SettingsService().largeDataRootPath = root.path;
        library = LibraryService()..resetLibraryForTesting();
        await library.init();
        api = _FakeApi();
        service = BilibiliDownloadService(apiService: api);
        addTearDown(() async {
          await service.shutdown();
          library.resetLibraryForTesting();
          PathProviderPlatform.instance = originalPathProvider;
          if (await root.exists()) await root.delete(recursive: true);
        });
      });

      test(
        'reopening a history entry reuses its card and refreshes the entry',
        () async {
          final first = await obtainBilibiliPlaybackCard(
            service,
            library,
            bvid: _bvid,
            page: 2,
          );
          final entry = history.watchHistory.single;
          expect(entry.bvid, _bvid);
          expect(entry.page, 2);
          expect(entry.title, 'Video');
          expect(entry.ownerName, 'owner');
          expect(entry.coverUrl, 'https://i0.hdslb.com/cover.jpg');
          expect(entry.partTitle, 'Part 2');

          final again = await obtainBilibiliPlaybackCard(
            service,
            library,
            bvid: entry.bvid,
            page: entry.page,
          );
          expect(again.createdCount, 0);
          expect(again.cards.single.item.id, first.cards.single.item.id);
          expect(
            findBilibiliStreamCardsOfVideo(
              library.bilibiliStreamItems,
              bvid: _bvid,
              collectionOf: library.getCollection,
            ),
            hasLength(1),
          );
          expect(history.watchHistory, hasLength(1));
        },
      );

      test('no history entry when recording is off', () async {
        SettingsService().bilibiliRecordWatchHistory = false;
        await obtainBilibiliPlaybackCard(
          service,
          library,
          bvid: _bvid,
          page: 1,
        );
        expect(history.watchHistory, isEmpty);
      });
    });
  });

  group('download page short links', () {
    test('resolve through the cookie-free parser', () async {
      final adapter = _RedirectAdapter(
        'https://www.bilibili.com/video/$_bvid?p=2',
      );
      final api = _FakeApi();
      final service = BilibiliDownloadService(
        apiService: api,
        publicApi: BilibiliPublicApiService(httpClientAdapter: adapter),
      );
      addTearDown(service.shutdown);

      final task = await service.parseSingleLine('分享 https://b23.tv/abc');
      expect(task!.singleVideoInfo!.bvid, _bvid);
      expect(api.infoRequests, [_bvid]);
      expect(adapter.requests.single.uri.host, 'b23.tv');
      expect(
        adapter.requests.single.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('cookie')),
      );

      // An http short link is upgraded to https first.
      final upgraded = await service.parseSingleLine('http://b23.tv/abc');
      expect(upgraded!.singleVideoInfo!.bvid, _bvid);
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last.uri.scheme, 'https');
    });
  });
}

BilibiliVideoInfo _videoInfo(String bvid) => BilibiliVideoInfo(
  title: 'Video',
  desc: '',
  pic: 'https://i0.hdslb.com/cover.jpg',
  bvid: bvid,
  aid: '2',
  ownerName: 'owner',
  ownerMid: '1',
  pubDate: 0,
  pages: <BilibiliPage>[
    for (var i = 1; i <= 2; i++)
      BilibiliPage(
        cid: 1000 + i,
        page: i,
        part: 'Part $i',
        duration: 60,
        bvid: bvid,
        aid: '2',
      ),
  ],
);

class _FakeApi extends BilibiliApiService {
  final List<String> infoRequests = <String>[];

  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    infoRequests.add(bvid);
    return _videoInfo(bvid);
  }

  @override
  Future<String> resolveShortLink(String url) =>
      throw StateError('the cookie client must not resolve short links');

  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async => const BilibiliPlayerMetadata();

  @override
  Future<String> fetchDanmakuXml(int cid) async => '<i></i>';

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

class _RedirectAdapter implements HttpClientAdapter {
  _RedirectAdapter(this.location);

  final String location;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(<String, Object>{}),
      302,
      headers: {
        'location': [location],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
