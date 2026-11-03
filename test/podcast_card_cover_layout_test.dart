import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_widgets.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_browse_grid_cards.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preview = Platform.environment['PODCAST_CARD_PREVIEW'] == '1';
  late Directory directory;
  late PodcastRuntime runtime;

  VideoCollection collection({String? thumbnail}) => VideoCollection(
    id: thumbnail == null ? 'podcast-empty' : 'podcast-custom',
    name: '在场之间',
    createTime: 1,
    thumbnailPath: thumbnail,
    podcastRef: const PodcastChannelRef(
      channelId: 'cover-channel',
      feedUrl: 'https://example.com/rss',
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('podcast-cover-layout-');
    final store = PodcastStore(sqlite3.openInMemory());
    final channel = PodcastChannel(
      id: 'cover-channel',
      feedUrl: 'https://example.com/rss',
      title: '在场之间',
      author: '在场编辑部',
    );
    store.write('channel', channel.id, channel.toJson());
    for (var i = 0; i < 3; i++) {
      final episode = PodcastEpisode(
        id: 'episode-$i',
        channelId: channel.id,
        title: '节目 $i',
        media: const [],
        discoveredMs: 100,
      );
      store.write('episode', episode.id, episode.toJson(), channel: channel.id);
    }
    runtime = PodcastRuntime.forTesting(
      PodcastController(
        store: store,
        client: PodcastClient(),
        mediaStore: PodcastMediaStore(
          root: directory,
          store: store,
          http: PodcastHttp(),
        ),
      ),
    );
    PodcastRuntime.debugOverride = runtime;
  });

  tearDown(() async {
    await runtime.shutdown();
    PodcastRuntime.debugOverride = null;
    await directory.delete(recursive: true);
  });

  Widget app(Widget child, {double textScale = 1}) =>
      ChangeNotifierProvider<LibraryService>.value(
        value: LibraryService(),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            scaffoldBackgroundColor: AppTokens.bgBase,
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: preview ? 'PodcastPreview' : null,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(body: Center(child: child)),
        ),
      );

  testWidgets('badge and fallback grow with the cover when resizing', (
    tester,
  ) async {
    double? previousBadge;
    double? previousFallback;
    for (final width in [80.0, 160.0, 320.0]) {
      await tester.pumpWidget(
        app(
          SizedBox(
            width: width,
            height: width * 9 / 16,
            child: PodcastCardCover(collection: collection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cover = tester.getRect(find.byType(PodcastCardCover));
      final badgeFinder = find.byKey(const ValueKey('podcast-card-badge'));
      final badge = tester.getRect(badgeFinder);
      final fallback = tester
          .getSize(
            find.descendant(
              of: find.byType(PodcastArtwork),
              matching: find.byIcon(Icons.podcasts_rounded),
            ),
          )
          .width;
      final updates = tester.getRect(
        find.byKey(const ValueKey('podcast-card-updates')),
      );
      expect(cover.contains(badge.topLeft), isTrue);
      expect(cover.contains(badge.bottomRight), isTrue);
      expect(badge.top, greaterThan(cover.center.dy));
      expect(badge.overlaps(updates), isFalse);
      if (previousBadge != null) {
        expect(badge.width / previousBadge, closeTo(2, .01));
        expect(fallback / previousFallback!, closeTo(2, .01));
      }
      previousBadge = badge.width;
      previousFallback = fallback;
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('square list thumbnails keep badges apart with large text', (
    tester,
  ) async {
    for (final extent in [32.0, 48.0, 96.0]) {
      await tester.pumpWidget(
        app(
          SizedBox.square(
            dimension: extent,
            child: PodcastCardCover(collection: collection()),
          ),
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      final badge = tester.getRect(
        find.byKey(const ValueKey('podcast-card-badge')),
      );
      final updates = tester.getRect(
        find.byKey(const ValueKey('podcast-card-updates')),
      );
      expect(badge.overlaps(updates), isFalse);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('custom folder covers retain podcast identity and selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        SizedBox(
          width: 180,
          height: 190,
          child: MediaLibraryFolderGridCard(
            collection: collection(thumbnail: '${directory.path}/missing.png'),
            titleScale: MediaLibraryLayoutDefaults.defaultTitleScale,
            onTap: () {},
            isSelectionMode: true,
            isSelected: true,
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('podcast-card-badge')), findsOneWidget);
    expect(find.byIcon(Icons.folder), findsNothing);
    final badge = tester.getRect(
      find.byKey(const ValueKey('podcast-card-badge')),
    );
    final selection = tester.getRect(find.byIcon(Icons.check_circle));
    expect(badge.overlaps(selection), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('render actual folder cards at three sizes', (tester) async {
    if (!preview) return;
    await tester.runAsync(() async {
      await (FontLoader(
            'PodcastPreview',
          )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(const SizedBox.shrink()));
    await tester.runAsync(
      () => precacheImage(
        FileImage(
          File('.artifacts/podcast-previews/fixture-cover.png').absolute,
        ),
        tester.element(find.byType(Scaffold)),
      ),
    );
    const boundaryKey = ValueKey('podcast-cover-preview');
    Widget row(bool artwork) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final width in [160.0, 240.0, 320.0])
          Padding(
            padding: const EdgeInsets.only(right: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${width.toInt()} px',
                  style: const TextStyle(fontSize: 13, color: AppTokens.text2),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: width,
                  height: width * 1.02,
                  child: MediaLibraryFolderGridCard(
                    collection: collection(
                      thumbnail: artwork
                          ? File(
                              '.artifacts/podcast-previews/fixture-cover.png',
                            ).absolute.path
                          : null,
                    ),
                    titleScale: MediaLibraryLayoutDefaults.defaultTitleScale,
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: app(
          Padding(
            padding: const EdgeInsets.all(44),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '文件夹里的播客卡片',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    color: AppTokens.text1,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '图标、边距与更新提示随卡片等比例缩放',
                  style: TextStyle(fontSize: 15, color: AppTokens.text2),
                ),
                const SizedBox(height: 28),
                row(true),
                const SizedBox(height: 28),
                const Text(
                  '无封面时',
                  style: TextStyle(fontSize: 16, color: AppTokens.text2),
                ),
                const SizedBox(height: 14),
                row(false),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey))
          .toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '.artifacts/podcast-previews/folder-card-responsive.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
