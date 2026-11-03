import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_offline_details.dart';
import 'package:video_player_app/services/bilibili/bilibili_part_playback.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';
import 'package:video_player_app/widgets/desktop_player_sidebar.dart';

const _bvid = 'BV1xx411c7mD';

class _AccountProbe extends BilibiliApiService {
  _AccountProbe(this.loggedIn);

  final bool loggedIn;
  int reads = 0;

  @override
  Future<void> init() async {
    reads++;
  }

  @override
  Future<bool> hasCookie() async {
    reads++;
    return loggedIn;
  }

  @override
  Future<Map<String, String>> readLoginCookies() async {
    reads++;
    return loggedIn ? {'SESSDATA': 'test-session'} : {};
  }
}

BilibiliVideoDetail _detail() => const BilibiliVideoDetail(
  bvid: _bvid,
  aid: 170001,
  title: '面板标题',
  description: '简介正文',
  owner: BilibiliVideoOwner(mid: 7, name: '测试UP'),
  stat: BilibiliVideoStat(view: 1200, like: 30),
  parts: <BilibiliVideoPart>[
    BilibiliVideoPart(cid: 1, page: 1, title: '第一节'),
    BilibiliVideoPart(cid: 2, page: 2, title: '第二节'),
    BilibiliVideoPart(cid: 3, page: 3, title: '第三节'),
  ],
  season: BilibiliVideoSeason(
    id: 9,
    title: '系列',
    episodes: <BilibiliSeasonEpisode>[
      BilibiliSeasonEpisode(bvid: _bvid, title: '本集'),
      BilibiliSeasonEpisode(bvid: 'BV1bb411c7mB', title: '下一集'),
    ],
  ),
  tags: <String>['标签甲', '标签乙'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    required BilibiliVideoDetailCache cache,
    int page = 2,
    VoidCallback? onCollapse,
    BilibiliPartSwitcher? onSelectPart,
    bool canSelectParts = true,
    List<String>? watched,
    BilibiliOfflineDetails? offlineDetails,
    BilibiliDownloadService? service,
  }) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final panel = BilibiliPlayerPanel(
      bvid: _bvid,
      page: page,
      fallbackTitle: '卡片标题',
      cache: cache,
      offlineDetails: offlineDetails ?? BilibiliOfflineDetails(),
      onCollapse: onCollapse,
      onSelectPart: onSelectPart,
      canSelectParts: canSelectParts,
      onWatchVideo: (context, {required bvid, page, startAt, preview}) async {
        watched?.add('$bvid#${page ?? 0}');
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppToast.navigatorKey,
        home: Scaffold(
          body: service == null
              ? panel
              : ChangeNotifierProvider<BilibiliDownloadService>.value(
                  value: service,
                  child: panel,
                ),
        ),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await AppToast.dismiss(immediate: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('shows every block of the detail', (tester) async {
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(tester, cache: cache);
    await tester.pumpAndSettle();

    expect(find.text('哔哩哔哩'), findsOneWidget);
    expect(find.text('面板标题'), findsOneWidget);
    expect(find.text('测试UP'), findsOneWidget);
    expect(find.byKey(const ValueKey('bilibili-panel-stats')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bilibili-action-like')),
      findsNothing,
      reason: 'account interactions are unavailable',
    );
    expect(find.text('导入'), findsWidgets);
    expect(
      find.byKey(const ValueKey('bilibili-panel-download')),
      findsOneWidget,
    );
    expect(find.text('合集 · 系列（2）'), findsOneWidget);
    expect(find.text('标签甲'), findsOneWidget);
    expect(find.text('简介正文', findRichText: true), findsOneWidget);
    // No play button and no big cover: the video is already playing.
    expect(find.text('播放'), findsNothing);
    await finish(tester);
  });

  for (final loggedIn in [false, true]) {
    testWidgets('opening details never reads account interaction state '
        '(logged in=$loggedIn)', (tester) async {
      final api = _AccountProbe(loggedIn);
      final service = BilibiliDownloadService(apiService: api);
      addTearDown(service.dispose);
      final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
      await pumpPanel(tester, cache: cache, service: service);
      await tester.pumpAndSettle();
      expect(api.reads, 0);
      for (final action in [
        'like',
        'coin',
        'favorite',
        'follow',
        'read-only',
      ]) {
        expect(find.byKey(ValueKey('bilibili-action-$action')), findsNothing);
      }
      expect(find.text('导入'), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('bilibili-panel-download')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bilibili-panel-open-externally')),
        findsOneWidget,
      );
      await finish(tester);
    });
  }

  testWidgets('the part list entry selects only this video\'s parts', (
    tester,
  ) async {
    final selected = <int>[];
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(
      tester,
      cache: cache,
      onSelectPart: (_, detail, page) async => selected.add(page),
    );
    await tester.pumpAndSettle();

    expect(find.text('选集（3）'), findsOneWidget);
    expect(find.text('P2 第二节'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bilibili-panel-episodes')));
    await tester.pumpAndSettle();
    expect(find.text('选集 · 3 P'), findsOneWidget);
    expect(find.byKey(const ValueKey('bilibili-part-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('bilibili-part-3')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bilibili-part-3')));
    await tester.pumpAndSettle();
    expect(selected, [3]);
    await finish(tester);
  });

  testWidgets(
    'selecting the current part or dismissing does not restart playback',
    (tester) async {
      var switches = 0;
      final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
      await pumpPanel(
        tester,
        cache: cache,
        onSelectPart: (_, _, _) async => switches++,
      );
      await tester.pumpAndSettle();
      final entry = find.byKey(const ValueKey('bilibili-panel-episodes'));
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bilibili-part-2')));
      await tester.pumpAndSettle();
      expect(switches, 0);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(switches, 0);
      expect(find.text('P2 第二节'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets('loading page keeps part selection unavailable', (tester) async {
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(tester, cache: cache, canSelectParts: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bilibili-panel-episodes')), findsNothing);
    await finish(tester);
  });

  testWidgets('a collection entry plays in place of this page', (tester) async {
    final watched = <String>[];
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(tester, cache: cache, watched: watched);
    await tester.pumpAndSettle();

    await tester.tap(find.text('本集'));
    await tester.tap(find.text('下一集'));
    await tester.pump();
    expect(watched, <String>['BV1bb411c7mB#1']);
    await finish(tester);
  });

  testWidgets('collapse button', (tester) async {
    var collapsed = 0;
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(tester, cache: cache, onCollapse: () => collapsed++);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bilibili-panel-collapse')));
    expect(collapsed, 1);
    await finish(tester);
  });

  testWidgets('a failed request shows the card title and a retry, '
      'never a spinner', (tester) async {
    var fail = true;
    var asked = 0;
    final cache = BilibiliVideoDetailCache(
      fetch: (_) async {
        asked++;
        if (fail) throw StateError('offline');
        return _detail();
      },
    );
    await pumpPanel(tester, cache: cache);
    await tester.pumpAndSettle();

    expect(find.text('卡片标题'), findsOneWidget);
    expect(find.byKey(const ValueKey('bilibili-panel-failed')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('正在加载详情…'), findsNothing);

    fail = false;
    await tester.tap(find.byKey(const ValueKey('bilibili-panel-retry')));
    await tester.pumpAndSettle();
    expect(asked, 2);
    expect(find.text('面板标题'), findsOneWidget);
    expect(find.byKey(const ValueKey('bilibili-panel-failed')), findsNothing);
    await finish(tester);
  });

  testWidgets('a request that never answers ends in the retry hint', (
    tester,
  ) async {
    final cache = BilibiliVideoDetailCache(
      fetch: (_) => Completer<BilibiliVideoDetail>().future,
      timeout: const Duration(seconds: 5),
    );
    await pumpPanel(tester, cache: cache);
    await tester.pump();
    expect(find.text('正在加载详情…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    // No answer at all reads as offline.
    expect(
      find.byKey(const ValueKey('bilibili-panel-offline')),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await finish(tester);
  });

  group('offline', () {
    BilibiliVideoDetailCache offlineCache() => BilibiliVideoDetailCache(
      fetch: (_) async => throw const BilibiliPublicApiException(
        '视频详情加载失败，请检查网络后重试',
        isNetworkError: true,
      ),
    );

    testWidgets('a downloaded video shows the title, UP and description it '
        'had and the offline hint, no error, no spinner', (tester) async {
      final known = BilibiliOfflineDetails();
      await known.remember(
        const BilibiliOfflineDetail(
          bvid: _bvid,
          title: '离线标题',
          ownerName: '离线UP',
          ownerMid: 7,
          description: '离线简介',
        ),
      );
      await pumpPanel(tester, cache: offlineCache(), offlineDetails: known);
      await tester.pumpAndSettle();

      expect(find.text('离线标题'), findsOneWidget);
      expect(find.text('卡片标题'), findsNothing);
      expect(find.text('离线UP'), findsOneWidget);
      expect(find.text('离线简介', findRichText: true), findsOneWidget);
      expect(find.text('离线，联网后可加载'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const ValueKey('bilibili-panel-failed')), findsNothing);
      await finish(tester);
    });

    testWidgets('never seen online: the card title with the offline hint', (
      tester,
    ) async {
      await pumpPanel(tester, cache: offlineCache());
      await tester.pumpAndSettle();
      expect(find.text('卡片标题'), findsOneWidget);
      expect(find.text('离线，联网后可加载'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await finish(tester);
    });

    testWidgets('back online, 重试 shows the full panel', (tester) async {
      var online = false;
      final cache = BilibiliVideoDetailCache(
        fetch: (_) async {
          if (!online) {
            throw const BilibiliPublicApiException('x', isNetworkError: true);
          }
          return _detail();
        },
      );
      await pumpPanel(tester, cache: cache);
      await tester.pumpAndSettle();
      expect(find.text('离线，联网后可加载'), findsOneWidget);
      online = true;
      await tester.tap(find.byKey(const ValueKey('bilibili-panel-retry')));
      await tester.pumpAndSettle();
      expect(find.text('面板标题'), findsOneWidget);
      expect(find.text('离线，联网后可加载'), findsNothing);
      await finish(tester);
    });

    test(
      'details seen online are kept, newest last, up to the capacity',
      () async {
        final store = BilibiliOfflineDetails(capacity: 2);
        await store.rememberDetail(_detail());
        await store.remember(
          const BilibiliOfflineDetail(bvid: 'BV1bb411c7mB', title: '二'),
        );
        await store.remember(
          const BilibiliOfflineDetail(bvid: 'BV1cc411c7mC', title: '三'),
        );
        // A new instance reads what was saved.
        final again = BilibiliOfflineDetails(capacity: 2);
        expect(await again.lookup(_bvid), isNull);
        expect((await again.lookup('BV1bb411c7mB'))!.title, '二');
        expect((await again.lookup('BV1cc411c7mC'))!.title, '三');

        await store.rememberDetail(_detail());
        final third = BilibiliOfflineDetails(capacity: 2);
        final kept = (await third.lookup(_bvid))!;
        expect(kept.title, '面板标题');
        expect(kept.ownerName, '测试UP');
        expect(kept.description, '简介正文');
      },
    );
  });

  testWidgets('reopening the panel uses the kept detail', (tester) async {
    var asked = 0;
    final cache = BilibiliVideoDetailCache(
      fetch: (_) async {
        asked++;
        return _detail();
      },
    );
    await pumpPanel(tester, cache: cache);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await pumpPanel(tester, cache: cache);
    await tester.pump();
    expect(find.text('面板标题'), findsOneWidget);
    expect(asked, 1);
    await finish(tester);
  });

  testWidgets('collection changes keep expansion and the visible row while '
      'details load and when metadata changes height', (tester) async {
    const nextBvid = 'BV1bb411c7mB';
    final season = BilibiliVideoSeason(
      id: 9,
      title: '长合集',
      episodes: [
        const BilibiliSeasonEpisode(bvid: _bvid, title: '本集'),
        const BilibiliSeasonEpisode(bvid: nextBvid, title: '下一集'),
        for (var i = 2; i < 25; i++)
          BilibiliSeasonEpisode(
            bvid: 'BV1xx411c${i.toString().padLeft(3, '0')}',
            title: '合集视频 $i',
          ),
      ],
    );
    BilibiliVideoDetail detail(String bvid) => BilibiliVideoDetail(
      bvid: bvid,
      title: bvid == _bvid ? '第一集' : '新一集的标题很长，需要更多空间来展示。' * 6,
      owner: const BilibiliVideoOwner(mid: 7, name: '测试UP'),
      parts: bvid == _bvid ? _detail().parts : const [],
      season: season,
    );
    final next = Completer<BilibiliVideoDetail>();
    final requested = <String>[];
    final cache = BilibiliVideoDetailCache(
      fetch: (bvid) {
        requested.add(bvid);
        return bvid == _bvid ? Future.value(detail(bvid)) : next.future;
      },
    );
    tester.view.physicalSize = const Size(420, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final panelKey = GlobalKey();
    Future<void> show(String bvid, {int page = 1}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopPlayerSidebar(
            key: ValueKey((bvid, page)),
            panelId: 'bilibili',
            panel: BilibiliPlayerPanel(
              key: panelKey,
              bvid: bvid,
              page: page,
              cache: cache,
              offlineDetails: BilibiliOfflineDetails(),
            ),
            width: 420,
            retainedId: 'subtitles',
            retainedPanel: const SizedBox(),
            retainedWidth: 420,
            viewportSize: const Size(420, 650),
          ),
        ),
      ),
    );
    await show(_bvid);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('展开全部 25 个'),
      240,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('bilibili-panel-detail')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('展开全部 25 个'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开全部 25 个'));
    await tester.pumpAndSettle();
    final last = find.text('合集视频 24');
    await tester.scrollUntilVisible(
      last,
      240,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('bilibili-panel-detail')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(BilibiliPlayerPanel));
    final top = tester.getTopLeft(last).dy;

    // A part change uses the same detail and list position.
    await show(_bvid, page: 2);
    await tester.pumpAndSettle();
    expect(requested, [_bvid]);
    expect(tester.getTopLeft(last).dy, closeTo(top, 0.5));

    await show(nextBvid);
    await tester.pump();
    expect(tester.state(find.byType(BilibiliPlayerPanel)), same(state));
    expect(find.byKey(const ValueKey('bilibili-panel-pending')), findsNothing);
    expect(find.text('展开全部 25 个'), findsNothing);
    expect(tester.getTopLeft(last).dy, closeTo(top, 0.5));

    next.complete(detail(nextBvid));
    await tester.pumpAndSettle();
    expect(find.text('展开全部 25 个'), findsNothing);
    expect(tester.getTopLeft(last).dy, closeTo(top, 0.5));
    expect(requested, [_bvid, nextBvid]);
    await finish(tester);
  });
}
