import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_widgets.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_action_dock.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';

import 'podcast_core_test.dart' show podcastFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final settings = SettingsService();
  final previewRoot = GlobalKey();
  final previewDirectory = Platform.environment['PODCAST_CARD_MENU_PREVIEWS'];
  late Directory directory;
  late PodcastRuntime runtime;
  late PodcastFeed feed;
  late VideoCollection card;
  late _CardPodcastHttp http;
  late Map<String, dynamic> savedCard;

  setUpAll(() async {
    if (previewDirectory == null) return;
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    library.resetLibraryForTesting();
    savedCard = {};
    library.writeLibrarySnapshotOverrideForTesting = () async {
      for (final collection in library.storageCollections) {
        if (collection.isPodcast) savedCard = collection.toJson();
      }
    };
    directory = await Directory.systemTemp.createTemp('podcast-card-actions-');
    final store = PodcastStore(sqlite3.openInMemory());
    http = _CardPodcastHttp();
    final client = PodcastClient(http: http);
    runtime = PodcastRuntime.forTesting(
      PodcastController(
        store: store,
        client: client,
        mediaStore: PodcastMediaStore(
          root: directory,
          store: store,
          http: http,
        ),
      ),
      library: library,
    );
    PodcastRuntime.debugOverride = runtime;
    feed = client.parser.parse(
      utf8.encode(podcastFixture()),
      'https://example.com/rss',
    );
    feed.channel.imageUrl = '';
    store.mergeFeed(feed, initial: true);
    store.setSetting(feed.channel.id, 'autoRefresh', false);
    card = await library.createCollection(
      feed.channel.title,
      null,
      podcastRef: PodcastChannelRef(
        channelId: feed.channel.id,
        feedUrl: feed.channel.feedUrl,
      ),
    );
  });

  tearDown(() async {
    await runtime.shutdown();
    PodcastRuntime.debugOverride = null;
    library.resetLibraryForTesting();
    settings.resetForTest();
    await directory.delete(recursive: true);
  });

  Widget app(Widget body) => MultiProvider(
    providers: [
      ChangeNotifierProvider<LibraryService>.value(value: library),
      ChangeNotifierProvider<SettingsService>.value(value: settings),
    ],
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      builder: (_, child) => RepaintBoundary(key: previewRoot, child: child!),
      home: Scaffold(body: body),
    ),
  );

  Future<void> tapAndSettle(WidgetTester tester, Finder target) async {
    // Library writes share a serial queue across tests. Keep those futures in
    // the real async zone so a disposed widget-test clock cannot retain them.
    await tester.runAsync(() => tester.tap(target));
    await tester.pumpAndSettle();
  }

  for (final nested in [false, true]) {
    test(
      'hidden podcast retains subscription and ${nested ? 'nested' : 'root'} position',
      () async {
        final parent = nested
            ? await library.createCollection('收藏文件夹', null)
            : null;
        if (parent != null) {
          await library.moveItemToCollection(card.id, parent.id);
        }
        final episode = feed.episodes.single;
        runtime.controller.updateState(episode.id, (state) {
          state.positionMs = 45000;
          state.favorite = true;
        });
        final before = library
            .getContents(parent?.id)
            .map((item) => item.id)
            .toList();

        await library.setPodcastVisibleInFolders(card.id, visible: false);

        expect(library.getContents(parent?.id), isNot(contains(card)));
        expect(library.collections, isNot(contains(card)));
        expect(library.searchContents(card.name), isNot(contains(card)));
        expect(card.parentId, parent?.id);
        expect(card.isRecycled, isFalse);
        expect(
          runtime.controller.channels.map((channel) => channel.id),
          contains(feed.channel.id),
        );
        expect(runtime.controller.state(episode.id).positionMs, 45000);
        expect(runtime.controller.state(episode.id).favorite, isTrue);
        expect(VideoCollection.fromJson(savedCard).isHiddenFromFolders, isTrue);
        final legacy = Map<String, dynamic>.from(savedCard)
          ..remove('isHiddenFromFolders');
        expect(VideoCollection.fromJson(legacy).isHiddenFromFolders, isFalse);

        await runtime.showChannelInFolders(feed.channel.id);

        expect(library.getContents(parent?.id).map((item) => item.id), before);
        expect(library.searchContents(card.name), contains(card));
        expect(
          VideoCollection.fromJson(savedCard).isHiddenFromFolders,
          isFalse,
        );
        expect(
          library.storageCollections.where(
            (collection) => collection.isPodcast,
          ),
          hasLength(1),
        );
      },
    );
  }

  test('reordering visible folders retains a hidden podcast card', () async {
    final first = await library.createCollection('其他文件夹一', null);
    final second = await library.createCollection('其他文件夹二', null);
    await library.setPodcastVisibleInFolders(card.id, visible: false);

    await library.reorderItems(null, 0, 1);
    expect(library.getContents(null).map((item) => item.id), [
      second.id,
      first.id,
    ]);

    await runtime.showChannelInFolders(feed.channel.id);
    expect(library.getContents(null).map((item) => item.id), [
      card.id,
      second.id,
      first.id,
    ]);
  });

  testWidgets('folder list menu hides only podcast cards', (tester) async {
    Widget tile(VideoCollection collection) => Center(
      child: SizedBox(
        width: 400,
        height: 100,
        child: MediaLibraryListTile.collection(
          collection: collection,
          index: 0,
          showIndex: false,
          showThumbnail: true,
          isSelected: false,
          isSelectionMode: false,
          onTap: () {},
          titleScale: 1,
          showActivityMenu: true,
          allowHidePodcastFromFolders: true,
        ),
      ),
    );
    await tester.pumpWidget(app(tile(card)));
    await tester.pumpAndSettle();
    expect(find.text('主播'), findsOneWidget);
    expect(find.textContaining('集未听'), findsNothing);
    await tapAndSettle(
      tester,
      find.byKey(const ValueKey('media-library-activity-menu')),
    );
    expect(find.text('不在此页面显示'), findsOneWidget);
    await tapAndSettle(tester, find.text('不在此页面显示'));
    expect(card.isHiddenFromFolders, isTrue);
    expect(runtime.store.channel(feed.channel.id)!.active, isTrue);

    final folder = VideoCollection(
      id: 'ordinary-folder',
      name: '普通文件夹',
      createTime: 1,
    );
    library.seedCollectionForTesting(folder);
    await tester.pumpWidget(app(tile(folder)));
    await tester.pumpAndSettle();
    await tapAndSettle(
      tester,
      find.byKey(const ValueKey('media-library-activity-menu')),
    );
    expect(find.text('不在此页面显示'), findsNothing);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(390, 844),
    const Size(768, 1024),
    const Size(1200, 800),
  ]) {
    testWidgets('overview menu restores hidden cards at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(const PodcastOverviewPage()));
      await tester.pumpAndSettle();
      expect(find.text('主播'), findsOneWidget);
      expect(find.textContaining('集未听'), findsNothing);
      final cardRect = tester.getRect(find.byType(MediaLibraryGridCard));
      final dockRect = tester.getRect(find.byType(MediaLibraryActionDock));
      expect(dockRect.right, closeTo(cardRect.right, .1));
      expect(dockRect.bottom, closeTo(cardRect.bottom, .1));

      final menu = find.byKey(
        ValueKey('podcast-channel-menu-${feed.channel.id}'),
      );
      final anchor = tester.getRect(menu);
      await tapAndSettle(tester, menu);
      expect(find.text('更新'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('添加到文件夹页面'), findsNothing);
      expect(find.byType(PodcastChannelPage), findsNothing);
      final panel = tester.getRect(
        find.byKey(const ValueKey('podcast-compact-menu')),
      );
      expect(panel.width, lessThanOrEqualTo(240));
      expect(panel.height, lessThan(cardRect.height));
      expect(panel.top, closeTo(anchor.bottom + 6, .1));
      expect(panel.overlaps(anchor), isFalse);
      expect(find.text('频道操作'), findsOneWidget);
      expect(find.text('取消订阅并移入回收站，保留已有下载'), findsNothing);
      if (previewDirectory != null) {
        await tester.runAsync(() async {
          final boundary =
              previewRoot.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(previewDirectory).create(recursive: true);
          await File(
            '$previewDirectory/card-menu-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('podcast-compact-menu')), findsNothing);

      await tester.runAsync(
        () => library.setPodcastVisibleInFolders(card.id, visible: false),
      );
      await tapAndSettle(tester, menu);
      expect(find.text('添加到文件夹页面'), findsOneWidget);
      await tapAndSettle(tester, find.text('添加到文件夹页面'));
      expect(library.getContents(null), contains(card));
      expect(card.isHiddenFromFolders, isFalse);
      await tapAndSettle(tester, menu);
      expect(find.text('添加到文件夹页面'), findsNothing);
      Navigator.of(tester.element(find.text('更新'))).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'overview update fetches new episodes and delete recycles the card',
    (tester) async {
      await tester.pumpWidget(app(const PodcastOverviewPage()));
      await tester.pumpAndSettle();
      final menu = find.byKey(
        ValueKey('podcast-channel-menu-${feed.channel.id}'),
      );
      await tapAndSettle(tester, menu);
      await tapAndSettle(tester, find.text('更新'));
      expect(http.requests, 1);
      expect(runtime.store.episodes(feed.channel.id), hasLength(2));
      expect(library.getContents(null), contains(card));
      expect(find.textContaining('集未听'), findsNothing);

      await tapAndSettle(tester, menu);
      await tapAndSettle(tester, find.text('删除'));
      expect(card.isRecycled, isTrue);
      expect(runtime.controller.channels, isEmpty);
      expect(library.getContents(null), isNot(contains(card)));
      expect(runtime.store.episodes(feed.channel.id), hasLength(2));
      expect(find.text('把喜欢的频道带进来'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('missing author uses a neutral channel label', () {
    feed.channel.author = '   ';
    runtime.store.write('channel', feed.channel.id, feed.channel.toJson());
    expect(podcastLibrarySummary(card), '播客频道');
  });
}

class _CardPodcastHttp extends PodcastHttp {
  int requests = 0;

  @override
  Future<PodcastResponse> get(
    String url, {
    Map<String, String> headers = const {},
    int maxBytes = 32 * 1024 * 1024,
    void Function(HttpClient)? onClient,
    bool Function()? isCancelled,
  }) async {
    requests++;
    final xml = podcastFixture(
      second: true,
    ).replaceAll('<itunes:image href="/cover.jpg"/>', '');
    return PodcastResponse(utf8.encode(xml), 200, url, {});
  }
}
