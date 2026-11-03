import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_collection_import.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_uploader_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'reference video switches P1/P2 on the same page without importing P2',
    (tester) async {
      NativeVideoPlayerMediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp(
        'bilibili_parts_live_',
      );
      SharedPreferences.setMockInitialValues({'largeDataRootPath': root.path});
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      final settings = SettingsService()..resetForTest();
      await settings.init();
      settings.largeDataRootPath = root.path;
      settings.bilibiliAutoImportOnPlay = true;
      final library = LibraryService()..resetLibraryForTesting();
      final service = BilibiliDownloadService();
      final playback = MediaPlaybackService();
      final queue = PlaylistManager()..initialize(libraryService: library);
      final tracker = ProgressTracker();
      BilibiliWatchCards? cards;
      try {
        expect(
          (await settings.resolveLargeDataRootDir()).absolute.path,
          root.absolute.path,
        );
        await library.init();
        expect(
          library.bilibiliStreamItems,
          isEmpty,
          reason: 'live tests start in an empty isolated library',
        );
        tracker.initialize(libraryService: library);
        await service.init();
        final liveDetail = await service.publicApi.fetchVideoDetail(
          bvid: 'BV1LpD3YsETa',
        );
        final info = bilibiliWatchInfoFromDetail(liveDetail);
        expect(info.pages.length, 2);
        final detail = BilibiliVideoDetail(
          bvid: info.bvid,
          title: info.title,
          coverUrl: info.pic,
          owner: BilibiliVideoOwner(
            mid: int.parse(info.ownerMid),
            name: info.ownerName,
          ),
          parts: [
            for (final p in info.pages)
              BilibiliVideoPart(
                cid: p.cid,
                page: p.page,
                title: p.part,
                durationSeconds: p.duration,
              ),
          ],
        );
        BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
          details: BilibiliVideoDetailCache(fetch: (_) async => detail),
        );
        final first = info.pages.first;
        final item = VideoItem(
          id: 'imported-p1',
          title: first.part,
          path: 'bilibili://stream/${info.bvid}?cid=${first.cid}',
          durationMs: first.duration * 1000,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          isBilibiliExported: true,
          sourceRef: MediaSourceRef(
            value: info.bvid,
            kind: MediaSourceKind.bilibiliStream,
            bvid: info.bvid,
            cid: first.cid,
            page: 1,
          ),
        );
        await library.addSingleVideo(item, reuseExistingItem: false);
        queue.setPlaylist([item]);
        await playback.initialize(
          playlistManager: queue,
          progressTracker: tracker,
          libraryService: library,
          bilibiliStreamingService: service.streamingService,
        );
        cards = BilibiliWatchCards.forApp(
          library: library,
          playbackChanges: playback,
          currentItemId: () => playback.currentItem?.id,
          openPageItemIds: () => [
            if (playback.currentItem != null) playback.currentItem!.id,
          ],
          queueItemIds: () => queue.playlist.map((item) => item.id),
          prepareCurrentItem: (id) async {
            await service.completeWatchPart(library, id);
          },
        );
        BilibiliWatchCards.install(cards);
        tester.view.physicalSize = const Size(420, 900);
        tester.view.devicePixelRatio = 1;
        // Mirror the real navigation entry, which holds visibility before
        // the page registers so the initial cover notification is outside build.
        final warmOwner = Object();
        playback.setPlaybackPageVisible(warmOwner, true);
        final starting = playback.play(item, autoPlay: true);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<LibraryService>.value(value: library),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: playback,
              ),
              ChangeNotifierProvider<PlaylistManager>.value(value: queue),
              ChangeNotifierProvider<BilibiliDownloadService>.value(
                value: service,
              ),
              ChangeNotifierProvider<TranscriptionManager>.value(
                value: TranscriptionManager(),
              ),
              ChangeNotifierProvider<EmbeddedSubtitleService>.value(
                value: EmbeddedSubtitleService(),
              ),
              ChangeNotifierProvider<OcrSubtitleManager>.value(
                value: OcrSubtitleManager(library: library),
              ),
            ],
            child: MaterialApp(
              home: PortraitVideoScreen(videoItem: item, autoPlayOnEntry: true),
            ),
          ),
        );
        playback.setPlaybackPageVisible(warmOwner, false);

        Future<void> until(bool Function() condition, String reason) async {
          final deadline = DateTime.now().add(const Duration(seconds: 75));
          while (!condition() && DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(
            condition(),
            isTrue,
            reason: '$reason; state=${playback.state}',
          );
        }

        await until(
          () =>
              playback.controller?.value.isInitialized == true &&
              playback.position.inMilliseconds > 500,
          'P1 really plays from the supplied Bilibili video',
        );
        await starting;
        final screenState = tester.state(find.byType(PortraitVideoScreen));
        await playback.seekTo(const Duration(seconds: 8));
        await tester.tap(find.byKey(const ValueKey('bilibili-panel-episodes')));
        await until(
          () => find
              .byKey(const ValueKey('bilibili-part-2'))
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'part picker is visible and interactive',
        );
        await tester.tap(find.byKey(const ValueKey('bilibili-part-2')));
        await until(
          () =>
              playback.currentItem?.sourceRef?.page == 2 &&
              playback.controller?.value.isInitialized == true &&
              playback.position.inMilliseconds > 500,
          'P2 really plays after selecting it',
        );
        expect(
          tester.state(find.byType(PortraitVideoScreen)),
          same(screenState),
        );
        expect(
          tester
              .widget<BilibiliPlayerPanel>(find.byType(BilibiliPlayerPanel))
              .page,
          2,
        );
        expect(playback.currentItem!.isTransient, isTrue);
        expect(library.bilibiliStreamItems.map((item) => item.id), [
          'imported-p1',
        ]);
        expect(queue.playlist.map((item) => item.sourceRef?.page), [1, 2]);
        expect(queue.currentIndex, 1);
        expect(
          playback.position.inSeconds,
          lessThan(8),
          reason: 'P1 position must not leak into P2',
        );
        final secondId = playback.currentItem!.id;
        await playback.pause();
        await tester.tap(find.byKey(const ValueKey('bilibili-panel-episodes')));
        await until(
          () => find
              .byKey(const ValueKey('bilibili-part-1'))
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'part picker can reopen after the first switch',
        );
        await tester.tap(find.byKey(const ValueKey('bilibili-part-1')));
        await until(
          () =>
              playback.currentItem?.id == item.id &&
              playback.controller?.value.isInitialized == true,
          'switching back reuses the imported P1 card',
        );
        expect(
          tester.state(find.byType(PortraitVideoScreen)),
          same(screenState),
        );
        expect(queue.currentIndex, 0);
        expect(queue.playlist.last.id, secondId);
        expect(library.bilibiliStreamItems, hasLength(1));
        expect(playback.position.inSeconds, greaterThanOrEqualTo(7));
        await until(
          () =>
              playback.isPlaying &&
              BilibiliHistoryService.instance.watchEntryOf(info.bvid)?.page ==
                  1,
          'switching back restores playback and records P1 as the current part',
        );

        final uploader = BilibiliUploaderService(api: service.publicApi);
        final collections = await uploader.fetchCollections(
          int.parse(info.ownerMid),
        );
        expect(collections.isSuccess, isTrue, reason: collections.message);
        final multiPage = collections.data!.items.firstWhere(
          (c) => c.videoCount > 20 && c.videoCount <= 60,
        );
        final members = await loadBilibiliCollectionBvids(
          uploader: uploader,
          source: BilibiliCollectionImportSource(
            mid: int.parse(info.ownerMid),
            collection: multiPage,
          ),
        );
        expect(
          members,
          hasLength(multiPage.videoCount),
          reason: 'real collection pagination is complete',
        );
        final small = collections.data!.items.firstWhere(
          (c) => c.videoCount > 0 && c.videoCount <= 3,
        );
        final count = await importBilibiliCollection(
          service: service,
          library: library,
          uploader: uploader,
          source: BilibiliCollectionImportSource(
            mid: int.parse(info.ownerMid),
            collection: small,
          ),
        );
        expect(count, greaterThanOrEqualTo(small.videoCount));
        expect(library.bilibiliStreamItems, hasLength(1 + count));
        expect(
          library.collections.any((folder) => folder.name == small.title),
          isTrue,
        );
        final importedCollection = library.collections.firstWhere(
          (folder) => folder.name == small.title,
        );
        await until(
          () => importedCollection.thumbnailPath != null,
          'the imported collection receives a real cover file',
        );
        expect(
          await File(importedCollection.thumbnailPath!).length(),
          greaterThan(0),
        );
        expect(importedCollection.bilibiliPendingCoverUrl, isNull);
        expect(
          playback.currentItem!.id,
          item.id,
          reason: 'import does not replace the playing part',
        );
        expect(queue.playlist.map((item) => item.sourceRef?.page), [1, 2]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await playback.stop();
        BilibiliWatchCards.install(null);
        await service.shutdown();
        library.resetLibraryForTesting();
        BilibiliWatchSources.overrideForTesting = null;
        settings.resetForTest();
        settings.largeDataRootPath = null;
        PathProviderPlatform.instance = originalPaths;
        tester.view.reset();
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          /* temp cleanup */
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: Platform.environment['BILIBILI_PARTS_LIVE'] != '1',
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}
