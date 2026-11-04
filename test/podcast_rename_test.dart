import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'podcast_core_test.dart' show podcastFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final settings = SettingsService();
  late Directory root;
  late PodcastRuntime runtime;
  late PodcastFeed feed;
  late PlaylistManager playlist;

  PodcastRuntime openRuntime() {
    final store = PodcastStore.open(p.join(root.path, 'podcasts.sqlite'));
    final client = PodcastClient();
    return PodcastRuntime.forTesting(
      PodcastController(
        store: store,
        client: client,
        mediaStore: PodcastMediaStore(
          root: Directory(p.join(root.path, 'media')),
          store: store,
          http: client.http,
        ),
      ),
      library: library,
      playlist: playlist,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    await settings.init();
    library.resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    root = await Directory.systemTemp.createTemp('podcast-rename-');
    playlist = PlaylistManager();
    runtime = openRuntime();
    PodcastRuntime.debugOverride = runtime;
    feed = runtime.controller.client.parser.parse(
      utf8.encode(podcastFixture(second: true)),
      'https://example.com/rss',
    );
    feed.channel.imageUrl = '';
    runtime.store.mergeFeed(feed, initial: true);
    library.seedCollectionForTesting(
      VideoCollection(
        id: 'channel-card',
        name: feed.channel.title,
        createTime: 1,
        podcastRef: PodcastChannelRef(
          channelId: feed.channel.id,
          feedUrl: feed.channel.feedUrl,
        ),
      ),
    );
  });

  tearDown(() async {
    await runtime.shutdown();
    PodcastRuntime.debugOverride = null;
    playlist.dispose();
    library.resetLibraryForTesting();
    settings.resetForTest();
    await root.delete(recursive: true);
  });

  test(
    'library renames unify podcast cards and live queue, retaining RSS',
    () async {
      final episode = feed.episodes.first;
      final adapter = await runtime.itemFor(episode, persist: false);
      adapter.thumbnailPath = '/existing-cover.jpg';
      library.seedVideoForTesting(adapter);
      final copy = VideoItem.fromJson({
        ...adapter.toJson(),
        'id': 'imported-copy',
      });
      library.seedVideoForTesting(copy);
      final queue = [
        for (final entry in feed.episodes)
          await runtime.itemFor(entry, persist: false),
      ];
      playlist.setPlaylist(queue, currentItemId: queue.last.id);
      final beforeIds = playlist.playlist.map((item) => item.id).toList();
      final beforeCurrent = playlist.currentItem!.id;
      var notifications = 0;
      runtime.addListener(() => notifications++);

      await library.renameItem('channel-card', '我的英语播客');
      await library.renameItem(adapter.id, '周一听力练习');

      expect(runtime.channelTitle(feed.channel), '我的英语播客');
      expect(runtime.episodeTitle(episode), '周一听力练习');
      expect(copy.title, '周一听力练习');
      expect(playlist.playlist.first.title, '周一听力练习');
      expect(playlist.playlist.map((item) => item.id), beforeIds);
      expect(playlist.currentItem!.id, beforeCurrent);
      expect(notifications, greaterThan(0));
      expect(runtime.store.channel(feed.channel.id)!.title, '频道');
      expect(runtime.store.episode(episode.id)!.title, '第一集');
      expect(runtime.persistedEpisodeIds, isEmpty);

      final refreshed = runtime.controller.client.parser.parse(
        utf8.encode(
          podcastFixture(
            second: true,
            title: '官方频道新标题',
          ).replaceAll('第一集', '官方单集新标题'),
        ),
        feed.channel.feedUrl,
      );
      runtime.store.mergeFeed(refreshed);
      expect(runtime.channelTitle(refreshed.channel), '我的英语播客');
      expect(runtime.episodeTitle(refreshed.episodes.first), '周一听力练习');
      expect(runtime.store.episode(episode.id)!.title, '官方单集新标题');

      await runtime.shutdown();
      runtime = openRuntime();
      PodcastRuntime.debugOverride = runtime;
      expect(
        runtime.channelTitle(runtime.store.channel(feed.channel.id)!),
        '我的英语播客',
      );
      expect(
        runtime.episodeTitle(runtime.store.episode(episode.id)!),
        '周一听力练习',
      );
      final projected = await runtime.itemFor(
        runtime.store.episode(episode.id)!,
        persist: false,
      );
      expect(projected.title, '周一听力练习');
    },
  );

  test(
    'catalog aliases are searchable and do not create library adapters',
    () async {
      final episode = feed.episodes.last;
      final snapshot = PodcastCatalogSnapshot();
      void resolve() => snapshot.resolve(
        store: runtime.store,
        channelId: feed.channel.id,
        filter: 'all',
        query: '周五复习',
        sort: 'newest',
        hidePlayed: false,
        downloaded: {},
        countFilters: ['all'],
      );
      resolve();
      expect(snapshot.ids, isEmpty);
      await runtime.renameEpisode(episode.id, '周五复习');
      resolve();
      expect(snapshot.ids, [episode.id]);
      expect(library.storageVideos, isEmpty);
      expect(runtime.persistedEpisodeIds, isEmpty);
      expect(runtime.store.episode(episode.id)!.title, episode.title);
      final projected = await runtime.itemFor(episode, persist: false);
      expect(projected.title, '周五复习');
      final exported = runtime.store.exportChannel(feed.channel.id);
      expect(exported['presentations'], contains(episode.id));
    },
  );

  testWidgets('podcast episode menu reuses rename editor before first play', (
    tester,
  ) async {
    final episode = feed.episodes.first;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<SettingsService>.value(value: settings),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: runtime,
              builder: (context, _) =>
                  ListView(children: [PodcastEpisodeTile(episode: episode)]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('节目操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('library-rename-name-field'));
    final controller = tester.widget<TextField>(field).controller!;
    expect(controller.selection.start, 0);
    expect(controller.selection.end, controller.text.length);
    expect(find.textContaining('RSS 原始标题不变'), findsOneWidget);
    await tester.enterText(field, '我的单集别名');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('我的单集别名'), findsOneWidget);
    expect(runtime.episodeTitle(episode), '我的单集别名');
    expect(library.storageVideos, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('channel menu rename also updates the subscription overview', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    runtime.store.setSetting(feed.channel.id, 'autoRefresh', false);
    settings.folderPlaceholderSettings = settings.folderPlaceholderSettings
        .copyWith(showCoverText: true);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<SettingsService>.value(value: settings),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData.dark(useMaterial3: true),
          home: const Scaffold(body: PodcastOverviewPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final titleKey = ValueKey('podcast-channel-title-${feed.channel.id}');
    expect(tester.widget<Text>(find.byKey(titleKey)).data, feed.channel.title);
    await tester.tap(find.byKey(titleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多频道操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('library-rename-name-field'));
    expect(tester.widget<TextField>(field).style!.fontWeight, FontWeight.w600);
    expect(
      find.byKey(const ValueKey('library-rename-cover-field')),
      findsNothing,
    );
    await tester.enterText(field, '重命名后的订阅频道');
    await tester.runAsync(() async {
      await tester.tap(find.text('确定'));
      await library.saveLibraryForTesting();
    });
    await tester.pumpAndSettle();
    expect(find.text('重命名后的订阅频道'), findsOneWidget);
    expect(runtime.store.channel(feed.channel.id)!.title, feed.channel.title);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(titleKey)).data, '重命名后的订阅频道');
    expect(tester.takeException(), isNull);
  });
}
