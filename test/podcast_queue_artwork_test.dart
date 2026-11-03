import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as pixels;
import 'package:provider/provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/media_artwork_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_app/widgets/media_artwork_view.dart';
import 'package:video_player_app/widgets/playlist_bottom_sheet.dart';

List<String> _imagePaths(WidgetTester tester) => tester
    .widgetList<Image>(
      find.descendant(
        of: find.byType(MediaArtworkView),
        matching: find.byType(Image),
      ),
    )
    .map((image) {
      final provider = image.image;
      final original = provider is ResizeImage
          ? provider.imageProvider
          : provider;
      return (original as FileImage).file.path;
    })
    .toList();

Future<void> _loadCovers(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    final decoded = tester.widgetList<RawImage>(
      find.descendant(
        of: find.byType(MediaArtworkView),
        matching: find.byType(RawImage),
      ),
    );
    if (_imagePaths(tester).length == 3 &&
        decoded.length == 3 &&
        decoded.every((image) => image.image != null)) {
      return;
    }
  }
  expect(_imagePaths(tester), hasLength(3));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PodcastStore store;
  late PodcastController controller;
  late PodcastRuntime runtime;
  late MediaArtworkRepository repository;
  late PodcastChannel channel;
  late List<PodcastEpisode> episodes;
  late PlaylistManager queue;
  final hits = <String, int>{};
  var offline = false;
  Completer<void>? pending;

  void catalog(List<String> images) {
    episodes = List.generate(
      3,
      (index) => PodcastEpisode(
        id: 'ep-$index',
        channelId: channel.id,
        title: '节目 $index',
        imageUrl: images[index],
        media: [
          PodcastMedia(
            url: 'https://example.test/$index.${index == 2 ? 'mp4' : 'mp3'}',
            mimeType: index == 2 ? 'video/mp4' : 'audio/mpeg',
          ),
        ],
      ),
    );
    store.mergeFeed(PodcastFeed(channel, episodes), initial: true);
  }

  setUp(() async {
    hits.clear();
    offline = false;
    pending = null;
    root = await Directory.systemTemp.createTemp('podcast-queue-art-');
    store = PodcastStore(sqlite3.openInMemory());
    final client = PodcastClient();
    controller = PodcastController(
      store: store,
      client: client,
      mediaStore: PodcastMediaStore(
        root: root,
        store: store,
        http: client.http,
      ),
    );
    queue = PlaylistManager();
    runtime = PodcastRuntime.forTesting(controller, playlist: queue);
    PodcastRuntime.debugOverride = runtime;
    channel = PodcastChannel(
      id: 'channel',
      feedUrl: 'https://example.test/rss',
      title: '频道',
      imageUrl: 'https://covers.test/channel.png',
    );
    catalog(['', '', '']);
    repository = await MediaArtworkRepository.open(
      Directory('${root.path}/shared-artwork'),
      installAsActive: false,
      retryBase: Duration.zero,
      fetcher: (request) async {
        hits.update(request.uri.path, (count) => count + 1, ifAbsent: () => 1);
        if (offline) throw const SocketException('offline');
        if (pending != null) await pending!.future;
        final image = pixels.Image(width: 8, height: 8);
        image.setPixelRgb(
          0,
          0,
          request.uri.path == '/single.png' ? 255 : 0,
          request.uri.path == '/channel-v2.png' ? 255 : 0,
          100,
        );
        return ArtworkFetchResponse(
          status: request.uri.path == '/bad.png' ? 404 : 200,
          headers: const {
            'cache-control': 'max-age=3600',
            'content-type': 'image/png',
          },
          bytes: request.uri.path == '/bad.png' ? [] : pixels.encodePng(image),
          finalUri: request.uri,
        );
      },
    );
    MediaArtworkRepository.debugOverride = repository;
  });

  tearDown(() async {
    if (pending != null && !pending!.isCompleted) pending!.complete();
    PodcastRuntime.debugOverride = null;
    await controller.close();
    runtime.dispose();
    store.close();
    repository.close();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    for (var attempt = 0; ; attempt++) {
      try {
        await root.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt >= 5) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  });

  Future<List<VideoItem>> entries() async {
    final items = await Future.wait(
      episodes.map((episode) => runtime.itemFor(episode, persist: false)),
    );
    queue.setPlaylist(items);
    return items;
  }

  Widget frame(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsService>.value(
        value: SettingsService()..resetForTest(),
      ),
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: MediaPlaybackService.forTesting(),
      ),
      ChangeNotifierProvider<PlaylistManager>.value(value: queue),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 560, height: 560, child: child)),
      ),
    ),
  );

  Widget picker() =>
      EpisodePickerPanel(panelWidth: 560, panelHeight: 560, onClose: () {});

  testWidgets(
    'picker and mini queue reuse a cached channel cover for unplayed audio and video',
    (tester) async {
      final cached = await tester.runAsync(
        () => repository.load(
          podcastArtworkRef(
            ownerKind: 'channel',
            ownerId: channel.id,
            primaryUrl: channel.imageUrl,
          ),
        ),
      );
      expect(cached!.hasImage, isTrue);
      offline = true;
      final items = await entries();
      expect(items.every((item) => item.thumbnailPath == null), isTrue);
      expect(items.last.type, MediaType.video);
      await tester.pumpWidget(frame(picker()));
      await _loadCovers(tester);
      expect(_imagePaths(tester).toSet(), {cached.localPath});
      await tester.pumpWidget(
        frame(PlaylistBottomSheet(playlist: items, onItemTap: (_) {})),
      );
      await _loadCovers(tester);
      expect(_imagePaths(tester).toSet(), {cached.localPath});
      expect(hits, {'/channel.png': 1});
      expect(items.every((item) => item.thumbnailPath == null), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'single covers take priority and broken audio/video covers fall back to the channel',
    (tester) async {
      catalog([
        'https://covers.test/single.png',
        'https://covers.test/bad.png',
        'https://covers.test/bad.png',
      ]);
      final items = await entries();
      items.last.thumbnailPath = '${root.path}/missing-legacy-cover.png';
      await tester.pumpWidget(frame(picker()));
      await _loadCovers(tester);
      final paths = _imagePaths(tester);
      expect(paths[0], isNot(paths[1]));
      expect(paths[1], paths[2]);
      expect(hits['/single.png'], 1);
      expect(hits['/channel.png'], 1);
      expect(hits['/bad.png'], inInclusiveRange(1, 3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'visible covers appear when a shared request finishes and update after a catalog refresh',
    (tester) async {
      pending = Completer<void>();
      await entries();
      await tester.pumpWidget(frame(picker()));
      for (var i = 0; i < 10 && hits.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(hits, {'/channel.png': 1});
      expect(_imagePaths(tester), isEmpty);
      pending!.complete();
      await _loadCovers(tester);
      final previous = _imagePaths(tester).first;
      channel.imageUrl = 'https://covers.test/channel-v2.png';
      store.write('channel', channel.id, channel.toJson());
      controller.reload();
      await _loadCovers(tester);
      expect(_imagePaths(tester).every((path) => path != previous), isTrue);
      expect(_imagePaths(tester).toSet(), hasLength(1));
      expect(hits, {'/channel.png': 1, '/channel-v2.png': 1});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
