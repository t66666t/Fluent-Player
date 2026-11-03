import 'dart:io';

import 'package:flutter/material.dart';
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
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

class _Feed extends PodcastHttp {
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
    return PodcastResponse(const [], 304, url, const {});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SettingsService settings;
  late LibraryService library;
  late MediaPlaybackService playback;
  late PodcastStore store;
  late PodcastController controller;
  late PodcastRuntime runtime;
  late _Feed feed;
  late PodcastChannel channel;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
    library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    playback = MediaPlaybackService();
    await playback.stop();
    directory = await Directory.systemTemp.createTemp('podcast-channel-entry-');
    store = PodcastStore(sqlite3.openInMemory());
    feed = _Feed();
    final client = PodcastClient(http: feed);
    controller = PodcastController(
      store: store,
      client: client,
      mediaStore: PodcastMediaStore(root: directory, store: store, http: feed),
    );
    channel = PodcastChannel(
      id: 'channel',
      feedUrl: 'https://entry.test/rss',
      title: '频道详情',
    );
    store.write('channel', channel.id, channel.toJson());
    store.write(
      'episode',
      'cached-episode',
      const PodcastEpisode(
        id: 'cached-episode',
        channelId: 'channel',
        title: '已缓存的节目',
        media: [PodcastMedia(url: 'https://entry.test/episode.mp3')],
      ).toJson(),
      channel: channel.id,
    );
    library.seedCollectionForTesting(
      VideoCollection(
        id: 'podcast-card',
        name: '频道详情',
        createTime: 1,
        podcastRef: PodcastChannelRef(
          channelId: channel.id,
          feedUrl: channel.feedUrl,
        ),
      ),
    );
    runtime = PodcastRuntime.forTesting(controller);
    PodcastRuntime.debugOverride = runtime;
  });

  tearDown(() async {
    PodcastRuntime.debugOverride = null;
    runtime.dispose();
    await controller.close();
    store.close();
    await playback.stop();
    library.resetLibraryForTesting();
    settings.resetForTest();
    if (directory.absolute.parent.path == Directory.systemTemp.absolute.path &&
        directory.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('podcast-channel-entry-')) {
      await directory.delete(recursive: true);
    }
  });

  Future<NavigatorState> host(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ChangeNotifierProvider<BatchImportService>.value(
            value: BatchImportService(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: appPageTransitionsTheme,
          ),
          home: const MediaLibraryShell(home: Scaffold(body: Text('外层'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return Navigator.of(tester.element(find.text('外层')));
  }

  for (final folderRoute in [true, false]) {
    testWidgets(
      'cached podcast stays live and refresh waits for ${folderRoute ? 'library card' : 'ordinary'} entry',
      (tester) async {
        final navigator = await host(tester);
        final route = folderRoute
            ? buildMediaLibraryFolderRoute<void>(
                folderId: 'podcast-card',
                builder: (_) =>
                    const CollectionScreen(collectionId: 'podcast-card'),
              )
            : AppMaterialPageRoute<void>(
                builder: (_) => PodcastChannelPage(channelId: channel.id),
              );
        navigator.push(route);
        await tester.pump();
        await tester.pump();
        expect(
          store.channel(channel.id)!.seenMs,
          greaterThan(0),
          reason: 'keep immediate badge clearing even on a short visit',
        );
        expect(find.text('已缓存的节目'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 120));
        expect(
          (route as ModalRoute).animation!.status,
          AnimationStatus.forward,
        );
        expect(
          feed.requests,
          0,
          reason: 'automatic feed work must not consume transition frames',
        );
        await tester.pumpAndSettle();
        expect(feed.requests, 1);
        expect(store.channel(channel.id)!.checkedMs, greaterThan(0));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Back during entry cancels automatic refresh and retains seen state',
    (tester) async {
      final navigator = await host(tester);
      navigator.push(
        buildMediaLibraryFolderRoute<void>(
          builder: (_) => PodcastChannelPage(channelId: channel.id),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(store.channel(channel.id)!.seenMs, greaterThan(0));
      navigator.pop();
      await tester.pumpAndSettle();
      expect(feed.requests, 0);
      expect(find.text('外层'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'manual refresh during entry runs immediately and supersedes automatic refresh',
    (tester) async {
      final navigator = await host(tester);
      navigator.push(
        buildMediaLibraryFolderRoute<void>(
          builder: (_) => PodcastChannelPage(channelId: channel.id),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.byTooltip('刷新频道'));
      await tester.pump();
      expect(feed.requests, 1);
      expect(store.channel(channel.id)!.checkedMs, greaterThan(0));
      await tester.pumpAndSettle();
      expect(feed.requests, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
