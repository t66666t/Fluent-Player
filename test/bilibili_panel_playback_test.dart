import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_panel_playback.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';
import 'package:video_player_app/widgets/desktop_player_sidebar.dart';

import 'test_dir_cleanup.dart';

const _first = 'BV1xx411c7mD';
const _next = 'BV1bb411c7mB';

BilibiliVideoInfo _info(String bvid) => BilibiliVideoInfo(
  bvid: bvid,
  title: bvid == _first ? '当前视频' : '下一集',
  pic: '',
  desc: '',
  aid: '170001',
  ownerName: '测试UP',
  ownerMid: '7',
  pubDate: 0,
  pages: [
    BilibiliPage(cid: 101, page: 1, part: '第一节', duration: 120),
    BilibiliPage(cid: 102, page: 2, part: '第二节', duration: 120),
  ],
);

BilibiliVideoDetail _detail(String bvid) => BilibiliVideoDetail(
  bvid: bvid,
  title: bvid == _first ? '当前视频' : '下一集',
  owner: const BilibiliVideoOwner(mid: 7, name: '测试UP'),
  parts: const [
    BilibiliVideoPart(cid: 101, page: 1, title: '第一节'),
    BilibiliVideoPart(cid: 102, page: 2, title: '第二节'),
  ],
  season: const BilibiliVideoSeason(
    id: 9,
    title: '系列',
    episodes: [
      BilibiliSeasonEpisode(bvid: _first, title: '本集'),
      BilibiliSeasonEpisode(bvid: _next, title: '下个视频'),
    ],
  ),
);

VideoItem _original({String id = 'original', int page = 1}) => VideoItem(
  id: id,
  path: 'bilibili://stream/$_first?cid=${100 + page}',
  title: '当前视频',
  durationMs: 120000,
  lastUpdated: 0,
  isTransient: true,
  sourceRef: MediaSourceRef(
    value: _first,
    kind: MediaSourceKind.bilibiliStream,
    bvid: _first,
    cid: 100 + page,
    page: page,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final navigation = PlaybackNavigationService.instance;
  late Directory root;
  late PathProviderPlatform originalPaths;
  late LibraryService library;
  late BilibiliDownloadService service;
  late _Playback playback;
  late PlaylistManager playlist;
  late BilibiliVideoDetailCache details;
  late BuildContext panelContext;
  final orientationCalls = <MethodCall>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
    navigation.resetNavigationQueueForTesting();
    root = await Directory.systemTemp.createTemp('bilibili_panel_playback_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    service = BilibiliDownloadService(apiService: _Api());
    await service.init();
    playback = _Playback(_original());
    playlist = PlaylistManager()..initialize(libraryService: library);
    playlist.setPlaylist([playback.currentItem]);
    details = BilibiliVideoDetailCache(fetch: (bvid) async => _detail(bvid));
    BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
      details: details,
      fetchInfo: (bvid) async => _info(bvid),
      warmPlayUrl: (_, _) async {},
    );
    orientationCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientationCalls.add(call);
          }
          return null;
        });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    BilibiliWatchSources.overrideForTesting = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await service.shutdown();
    playback.dispose();
    playlist.dispose();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = null;
    BilibiliHistoryService.instance.resetForTest();
    PathProviderPlatform.instance = originalPaths;
    await deleteTestTempDir(root);
  });

  Future<void> pumpPlayer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<NavigatorState>();
    final panelKey = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<BilibiliDownloadService>.value(value: service),
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
        ],
        child: MaterialApp(
          navigatorKey: key,
          navigatorObservers: [navigation.observer],
          home: const Scaffold(body: Text('媒体库')),
        ),
      ),
    );
    unawaited(
      key.currentState!.push(
        MaterialPageRoute<void>(
          settings: PlaybackNavigationService.landscapeRouteSettings(
            playback.currentItem,
          ),
          builder: (context) => Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 400,
                child: AnimatedBuilder(
                  animation: playback,
                  builder: (context, _) {
                    panelContext = context;
                    final ref = playback.currentItem.sourceRef!;
                    return DesktopPlayerSidebar(
                      key: ValueKey((
                        'landscape-player-sidebar',
                        playback.currentItem.id,
                      )),
                      panelId: 'bilibili',
                      panel: BilibiliPlayerPanel(
                        key: panelKey,
                        bvid: ref.bvid!,
                        page: ref.page!,
                        cache: details,
                        fallbackTitle: playback.currentItem.title,
                      ),
                      width: 400,
                      retainedId: 'subtitles',
                      retainedPanel: const SizedBox(),
                      retainedWidth: 400,
                      viewportSize: const Size(1000, 700),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done(), isTrue);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    for (final skipPortrait in [false, true]) {
      for (final collection in [false, true]) {
        testWidgets('${platform.name}, skip portrait=$skipPortrait: '
            '${collection ? 'collection' : 'part'} keeps the route and panel', (
          tester,
        ) async {
          debugDefaultTargetPlatformOverride = platform;
          SettingsService().skipPortraitPlayer = skipPortrait;
          await pumpPlayer(tester);
          final route = navigation.observer.topRoute;
          final panel = tester.state(find.byType(BilibiliPlayerPanel));
          if (collection) {
            await tester.ensureVisible(find.text('下个视频'));
            await tester.tap(find.text('下个视频'));
          } else {
            await tester.tap(
              find.byKey(const ValueKey('bilibili-panel-episodes')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('bilibili-part-2')));
          }
          await until(tester, () => playback.switches.length == 1);
          await until(
            tester,
            () =>
                BilibiliHistoryService.instance
                    .watchEntryOf(collection ? _next : _first)
                    ?.page ==
                (collection ? 1 : 2),
          );
          await tester.pumpAndSettle();
          expect(navigation.observer.topRoute, same(route));
          expect(navigation.observer.routes, hasLength(2));
          expect(tester.state(find.byType(BilibiliPlayerPanel)), same(panel));
          expect(
            playback.currentItem.sourceRef?.bvid,
            collection ? _next : _first,
          );
          expect(playback.currentItem.sourceRef?.page, collection ? 1 : 2);
          expect(playback.autoPlay, isTrue);
          expect(playback.persisted, ['original']);
          expect(orientationCalls, isEmpty);
          expect(library.bilibiliStreamItems, isEmpty);
          expect(playlist.playlist.map((item) => item.sourceRef?.page), [1, 2]);
          await finish(tester);
        });
      }
    }
  }

  testWidgets('failed preparation leaves playback and queue in place', (
    tester,
  ) async {
    BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
      fetchInfo: (_) async => throw StateError('视频暂不可用'),
      warmPlayUrl: (_, _) async {},
    );
    await pumpPlayer(tester);
    final route = navigation.observer.topRoute;
    await tester.ensureVisible(find.text('下个视频'));
    await tester.tap(find.text('下个视频'));
    await until(tester, () => find.text('视频暂不可用').evaluate().isNotEmpty);
    expect(playback.switches, isEmpty);
    expect(playback.currentItem.id, 'original');
    expect(playlist.playlist.map((item) => item.id), ['original']);
    expect(navigation.observer.topRoute, same(route));
    BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
      details: details,
      fetchInfo: (bvid) async => _info(bvid),
      warmPlayUrl: (_, _) async {},
    );
    await tester.ensureVisible(find.text('下个视频'));
    await tester.tap(find.text('下个视频'));
    await until(tester, () => playback.switches.length == 1);
    expect(navigation.observer.topRoute, same(route));
    await finish(tester);
  });

  testWidgets('auto import still fills every part after an in-place switch', (
    tester,
  ) async {
    SettingsService().bilibiliAutoImportOnPlay = true;
    await pumpPlayer(tester);
    await tester.runAsync(
      () => switchBilibiliPanelVideo(panelContext, bvid: _next, page: 1),
    );
    await until(
      tester,
      () =>
          library.bilibiliStreamItems.length == 2 &&
          playlist.playlist.length == 2,
    );
    await tester.runAsync(service.waitForPendingStreamCardData);
    expect(playback.switches, hasLength(1));
    expect(playback.currentItem.isTransient, isFalse);
    expect(playlist.playlist.map((item) => item.sourceRef?.page), [1, 2]);
    await finish(tester);
  });

  testWidgets(
    'description link keeps the previous visit without replacing the route',
    (tester) async {
      await pumpPlayer(tester);
      final route = navigation.observer.topRoute;
      await tester.runAsync(
        () => switchBilibiliPanelVideo(
          panelContext,
          bvid: _next,
          page: 1,
          startAt: const Duration(seconds: 12),
          rememberCurrent: true,
        ),
      );
      expect(navigation.observer.topRoute, same(route));
      final origin = navigation.browseHistory.previousFor(
        playback.currentItem,
      )!;
      expect(origin.item.id, 'original');
      expect(origin.position, const Duration(seconds: 37));
      expect(origin.wasPlaying, isTrue);
      expect(playback.startPosition, const Duration(seconds: 12));
      await finish(tester);
    },
  );

  testWidgets(
    'a link without a page to the playing BV keeps its current part',
    (tester) async {
      playback.media = _original(page: 2);
      playlist.setPlaylist([playback.currentItem]);
      await pumpPlayer(tester);
      await tester.runAsync(
        () => switchBilibiliPanelVideo(
          panelContext,
          bvid: _first,
          startAt: const Duration(seconds: 12),
        ),
      );
      expect(playback.currentItem.sourceRef?.page, 2);
      expect(playback.startPosition, const Duration(seconds: 12));
      await finish(tester);
    },
  );

  for (final leavePage in [false, true]) {
    testWidgets(
      'late preparation is discarded after ${leavePage ? 'leaving the page' : 'another media switch'}',
      (tester) async {
        final warming = Completer<void>();
        var started = false;
        BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
          details: details,
          fetchInfo: (bvid) async => _info(bvid),
          warmPlayUrl: (_, _) {
            started = true;
            return warming.future;
          },
        );
        await pumpPlayer(tester);
        var completed = false;
        unawaited(
          switchBilibiliPanelVideo(
            panelContext,
            bvid: _next,
            page: 1,
          ).whenComplete(() => completed = true),
        );
        await until(
          tester,
          () => started && library.transientVideos.length == 2,
        );
        if (leavePage) {
          navigation.observer.topRoute!.navigator!.pop();
          await tester.pumpAndSettle();
        } else {
          playback
              .notifyListeners(); // No change: preparation must remain live.
          expect(completed, isFalse);
          playback.media = _original(id: 'other-action');
          playback.notifyListeners();
        }
        warming.complete();
        await until(tester, () => completed && library.transientVideos.isEmpty);
        expect(playback.switches, isEmpty);
        expect(BilibiliHistoryService.instance.watchEntryOf(_next), isNull);
        expect(orientationCalls, isEmpty);
        await finish(tester);
      },
    );
  }
}

class _Api extends BilibiliApiService {
  @override
  Future<void> init() async {}

  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async =>
      _info(bvid);

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

class _Playback extends MediaPlaybackService {
  _Playback(this.media) : super.forTesting();
  VideoItem media;
  final switches = <VideoItem>[];
  final persisted = <String?>[];
  bool autoPlay = false;
  Duration? startPosition;

  @override
  VideoItem get currentItem => media;
  @override
  Duration get position => const Duration(seconds: 37);
  @override
  PlaybackState get state => PlaybackState.playing;
  @override
  bool get desiredPlaying => true;

  @override
  Future<void> persistCurrentProgress({
    String? expectedItemId,
    VideoPlayerController? expectedController,
  }) async {
    persisted.add(expectedItemId);
    media.lastPositionMs = position.inMilliseconds;
  }

  @override
  Future<void> playPlaylistItem(
    VideoItem item, {
    bool? autoPlay,
    Duration? startPosition,
    bool forceFromStart = false,
  }) async {
    switches.add(item);
    media = item;
    this.autoPlay = autoPlay ?? false;
    this.startPosition = startPosition;
    notifyListeners();
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}
