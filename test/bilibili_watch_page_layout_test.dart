import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_loading_page.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_page_layout.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart';
import 'package:video_player_app/screens/video_player_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_open_timeline.dart';
import 'package:video_player_app/services/bilibili/bilibili_startup.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_memory.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
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
import 'package:video_player_app/widgets/bilibili_cover_image.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';
import 'package:video_player_app/widgets/bilibili_portrait_tabs.dart';
import 'package:video_player_app/widgets/player_subtitle_sidebar_toggle.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

import 'test_dir_cleanup.dart';

void main() {
  group('layout of the playback page, worked out ahead', () {
    const wide = Size(1280, 720);
    const narrow = Size(900, 600);

    BilibiliWatchLandscapeLayout landscape(
      Size window, {
      bool leftHanded = false,
      bool panel = true,
      bool subtitles = true,
      bool mobile = false,
      EdgeInsets padding = EdgeInsets.zero,
    }) {
      return BilibiliWatchPageShape(
        landscape: true,
        leftHanded: leftHanded,
        bilibiliPanelRemembered: panel,
        subtitleSidebarRemembered: subtitles,
        isMobilePlatform: mobile,
      ).landscapeLayout(window: window, padding: padding);
    }

    test('wide window: both tabs use the resizable subtitle slot', () {
      final layout = landscape(wide);
      expect(layout.slot, BilibiliWatchSidebarSlot.subtitles);
      expect(layout.surface, const Rect.fromLTWH(0, 0, 1005.6, 720));
      expect(layout.sidebar, const Rect.fromLTWH(1005.6, 0, 274.4, 720));
    });

    test('left-handed mode puts the panel on the left', () {
      final layout = landscape(wide, leftHanded: true);
      expect(layout.surface, const Rect.fromLTWH(274.4, 0, 1005.6, 720));
      expect(layout.sidebar, const Rect.fromLTWH(0, 0, 274.4, 720));
    });

    test('narrow window: no docked panel, the subtitle list keeps its '
        'place with its handle', () {
      final layout = landscape(narrow);
      expect(layout.slot, BilibiliWatchSidebarSlot.subtitles);
      expect(layout.sidebar.width, closeTo(262.4 + 12, 1e-9));
      expect(layout.surface.width, closeTo(900 - 274.4, 1e-9));

      final bare = landscape(narrow, subtitles: false);
      expect(bare.slot, BilibiliWatchSidebarSlot.none);
      expect(bare.surface, const Rect.fromLTWH(0, 0, 900, 600));
      expect(bare.sidebar.width, 0);
    });

    test('panel closed, or a phone: no Bilibili panel', () {
      expect(
        landscape(wide, panel: false).slot,
        BilibiliWatchSidebarSlot.subtitles,
      );
      expect(
        landscape(const Size(844, 390), mobile: true).slot,
        BilibiliWatchSidebarSlot.subtitles,
      );
      expect(
        landscape(const Size(1366, 1024), mobile: true).slot,
        BilibiliWatchSidebarSlot.subtitles,
      );
    });

    test('only the top inset is kept free in landscape', () {
      final layout = landscape(
        wide,
        padding: const EdgeInsets.fromLTRB(30, 24, 30, 10),
      );
      expect(layout.surface, const Rect.fromLTWH(0, 24, 1005.6, 696));
    });

    test(
      'portrait: at most 500 wide and centered, 16:9 under the top inset',
      () {
        expect(
          bilibiliWatchPortraitVideoArea(
            window: const Size(390, 844),
            padding: const EdgeInsets.only(top: 47, bottom: 34),
            aspectRatio: 16 / 9,
          ),
          const Rect.fromLTWH(0, 47, 390, 390 * 9 / 16),
        );
        expect(
          bilibiliWatchPortraitVideoArea(
            window: const Size(800, 1280),
            padding: EdgeInsets.zero,
            aspectRatio: 16 / 9,
          ),
          const Rect.fromLTWH(150, 0, 500, 500 * 9 / 16),
        );
      },
    );

    test('the video is fitted into the area as the landscape page fits it', () {
      const area = Rect.fromLTWH(0, 0, 870.4, 720);
      final video = containedVideoRect(area, 16 / 9);
      expect(video.width, closeTo(870.4, 1e-9));
      expect(video.height, closeTo(870.4 * 9 / 16, 1e-9));
      expect(video.center, area.center);
      final tall = containedVideoRect(area, 9 / 16);
      expect(tall.height, 720);
      expect(tall.width, closeTo(405, 1e-9));
    });

    test('the numbers are the playback pages\' own', () {
      final landscapeSource = File(
        'lib/screens/video_player_screen.dart',
      ).readAsStringSync();
      final portraitSource = File(
        'lib/screens/portrait_video_screen.dart',
      ).readAsStringSync();
      for (final line in <String>[
        'static const double _subtitleSidebarResizerLayoutWidth = '
            '${kPlayerSubtitleSidebarResizerWidth.toStringAsFixed(1)};',
        'static const double _subtitleSidebarMinWidth = '
            '${kPlayerSubtitleSidebarMinWidth.toStringAsFixed(1)};',
        'static const double _subtitleSidebarMinRemainingPlayerWidth = '
            '${kPlayerSubtitleSidebarMinRemainingWidth.toStringAsFixed(1)};',
        'LandscapeSidebarTarget get _defaultTarget => landscapeDefaultSidebar(',
        'return LandscapeSidebarLayout.functionalWidthFor(screenSize);',
        'if (isLeftHandedMode) ...sidebarWidgets,',
        'if (!isLeftHandedMode) ...sidebarWidgets,',
        'height = width / safeAspectRatio;',
        'width = height * safeAspectRatio;',
      ]) {
        expect(landscapeSource, contains(line));
      }
      expect(
        portraitSource,
        contains(
          'constraints: const BoxConstraints(maxWidth: '
          '${kPortraitPlayerMaxWidth.toInt()}),',
        ),
      );
    });
  });

  group('the loading page shows the cover where the playback page shows '
      'the video', () {
    late Directory root;
    late PathProviderPlatform originalPaths;
    late LibraryService library;
    late MediaPlaybackService playback;
    late _NeverReadyStreaming streaming;
    final settings = SettingsService();

    setUp(() async {
      Provider.debugCheckInvalidValueType = null;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      settings.resetForTest();
      await settings.init();
      root = await Directory.systemTemp.createTemp('bilibili_watch_layout_');
      originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      library = LibraryService()..resetLibraryForTesting();
      // The playback pages stay on their loading cover: the video never
      // gets ready.
      streaming = _NeverReadyStreaming();
      playback = MediaPlaybackService();
      await playback.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );
    });

    tearDown(() async {
      BilibiliPortraitTabMemory.takeHandOff(_item().id);
      settings
        ..isLeftHandedMode = false
        ..bilibiliPlayerPanelOpen = true
        ..isLandscapeSubtitleSidebarVisible = true
        ..userSubtitleSidebarWidth = 262.4
        ..resetForTest();
      library.resetLibraryForTesting();
      PathProviderPlatform.instance = originalPaths;
      Provider.debugCheckInvalidValueType = _defaultValueTypeCheck;
      await deleteTestTempDir(root);
    });

    void window(WidgetTester tester, Size size, {EdgeInsets? padding}) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      if (padding != null) {
        tester.view.padding = FakeViewPadding(
          left: padding.left,
          top: padding.top,
          right: padding.right,
          bottom: padding.bottom,
        );
      }
      addTearDown(tester.view.reset);
    }

    Widget host(Widget page) {
      // The playback service goes in as a plain value: the page starts
      // playback while it is built, which must not rebuild the tree here.
      return MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<TranscriptionManager>.value(
            value: TranscriptionManager(),
          ),
          ChangeNotifierProvider<EmbeddedSubtitleService>.value(
            value: EmbeddedSubtitleService(),
          ),
          ChangeNotifierProvider<OcrSubtitleManager>.value(
            value: OcrSubtitleManager(library: library),
          ),
          ChangeNotifierProvider<PlaylistManager>.value(
            value: PlaylistManager(),
          ),
          Provider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(home: page),
      );
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    }

    /// Rects of what both pages show while the video gets ready.
    Future<_Shown> showLoadingPage(
      WidgetTester tester,
      BilibiliWatchPageShape shape,
    ) async {
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (_, _, _, _) async {},
            timeline: () => BilibiliOpenTimeline(_bvid),
            shape: shape,
          ),
        ),
      );
      await tester.pump();
      if (shape.landscape) {
        expect(
          tester
              .state<VideoControlsOverlayState>(
                find.byType(VideoControlsOverlay),
              )
              .controlsVisible,
          isFalse,
        );
      }
      final area = find.byKey(
        const ValueKey('bilibili-watch-loading-video-area'),
      );
      final shown = _Shown(
        area: tester.getRect(area),
        back: tester.getRect(
          find.byKey(const ValueKey('bilibili-watch-loading-back')),
        ),
        title: shape.landscape ? tester.getRect(find.text(_title).first) : null,
      );
      await close(tester);
      return shown;
    }

    Future<_Shown> showLandscapePlayer(WidgetTester tester) async {
      await tester.pumpWidget(
        host(VideoPlayerScreen(videoItem: _item(), autoPlayOnEntry: false)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final surface = find.byKey(const ValueKey('landscape-player-surface'));
      final shown = _Shown(
        area: tester.getRect(surface),
        back: tester.getRect(
          find.descendant(
            of: surface,
            matching: find.byKey(const ValueKey('video-controls-close')),
          ),
        ),
        title: tester.getRect(
          find.descendant(of: surface, matching: find.text(_title)),
        ),
      );
      await close(tester);
      return shown;
    }

    Future<Rect> showPortraitPlayer(WidgetTester tester) async {
      await tester.pumpWidget(
        host(PortraitVideoScreen(videoItem: _item(), autoPlayOnEntry: false)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final area = tester.getRect(
        find
            .descendant(
              of: find.byType(PortraitVideoScreen),
              matching: find.byType(AspectRatio),
            )
            .first,
      );
      await close(tester);
      return area;
    }

    Future<void> expectSameLandscape(WidgetTester tester) async {
      final player = await showLandscapePlayer(tester);
      final shape = BilibiliWatchPageShape.current();
      expect(shape.landscape, isTrue);
      final loading = await showLoadingPage(tester, shape);
      expect(loading.area, player.area);
      expect(loading.back.center, player.back.center);
      expect(loading.title!.topLeft, player.title!.topLeft);
      final media = MediaQueryData.fromView(tester.view);
      expect(
        shape
            .landscapeLayout(window: media.size, padding: media.padding)
            .surface,
        player.area,
      );
    }

    for (final landscape in [false, true]) {
      for (final coverSize in [
        const Size(9, 16),
        const Size(1, 1),
        const Size(4, 3),
      ]) {
        testWidgets(
          'loading ${landscape ? 'landscape' : 'portrait'} keeps its video frame with a $coverSize cover',
          (tester) async {
            window(
              tester,
              landscape ? const Size(1280, 720) : const Size(412, 915),
            );
            final file = File('${root.path}/own-cover.png');
            await tester.runAsync(() async {
              final recorder = ui.PictureRecorder();
              ui.Canvas(
                recorder,
              ).drawColor(const ui.Color(0xFF808080), ui.BlendMode.src);
              final picture = recorder.endRecording();
              final image = await picture.toImage(
                coverSize.width.toInt(),
                coverSize.height.toInt(),
              );
              picture.dispose();
              await file.writeAsBytes(
                (await image.toByteData(
                  format: ui.ImageByteFormat.png,
                ))!.buffer.asUint8List(),
              );
              image.dispose();
            });
            // Start the real file decode outside the widget test's fake clock.
            // Waiting for an already pending fake-zone load in runAsync can
            // deadlock before the frame callback gets a chance to be pumped.
            await tester.pumpWidget(host(const Scaffold()));
            await tester.runAsync(
              () => precacheImage(
                FileImage(file),
                tester.element(find.byType(Scaffold).first),
              ),
            );
            final startup = BilibiliStartupContext();
            final item = _item()..thumbnailPath = file.path;
            playback.prepareBilibiliStartup(item.id, startup);
            final page = landscape
                ? VideoPlayerScreen(videoItem: item, autoPlayOnEntry: false)
                : PortraitVideoScreen(videoItem: item, autoPlayOnEntry: false);
            await tester.pumpWidget(host(page));
            await tester.pump();
            await tester.pump();
            expect(startup.geometry.coverAspectRatio, coverSize.aspectRatio);
            Rect videoRect() => tester.getRect(
              landscape
                  ? find
                        .descendant(
                          of: find.byType(BilibiliVideoPosterSlot).first,
                          matching: find.byType(AspectRatio),
                        )
                        .first
                  : find
                        .descendant(
                          of: find.byType(PortraitVideoScreen),
                          matching: find.byType(AspectRatio),
                        )
                        .first,
            );
            expect(
              videoRect().width / videoRect().height,
              closeTo(16 / 9, .001),
              reason: 'A cover must not create an intermediate video size',
            );
            // Once this video's stream dimensions arrive, a late cover must not
            // resize the video or require a controller to trigger the rebuild.
            startup.geometry.reportVideo(4 / 3);
            await tester.pump();
            expect(
              videoRect().width / videoRect().height,
              closeTo(4 / 3, .001),
            );
            await close(tester);
          },
        );
      }
    }

    for (final landscape in [false, true]) {
      testWidgets(
        'the loading route uses this attempt geometry (${landscape ? 'landscape' : 'portrait'})',
        (tester) async {
          window(
            tester,
            landscape ? const Size(1280, 720) : const Size(412, 915),
          );
          final timeline = BilibiliOpenTimeline(_bvid);
          timeline.startup.geometry.reportCover(9 / 16);
          await tester.pumpWidget(
            host(
              BilibiliWatchLoadingPage(
                bvid: _bvid,
                preview: const BilibiliWatchPreview(title: _title),
                load: (_) => Completer<BilibiliWatchPlan>().future,
                open: (_, _, _, _) async {},
                timeline: () => timeline,
                shape: BilibiliWatchPageShape(landscape: landscape),
              ),
            ),
          );
          await tester.pump();
          Rect videoRect() => tester.getRect(
            landscape
                ? find.descendant(
                    of: find.byKey(
                      const ValueKey('bilibili-watch-loading-cover-frame'),
                    ),
                    matching: find.byType(AspectRatio),
                  )
                : find.byKey(
                    const ValueKey('bilibili-watch-loading-video-area'),
                  ),
          );
          expect(videoRect().width / videoRect().height, closeTo(16 / 9, .001));
          timeline.startup.geometry.reportVideo(4 / 3);
          await tester.pump();
          expect(videoRect().width / videoRect().height, closeTo(4 / 3, .001));
          await close(tester);
        },
      );
    }

    for (final previousRatio in [1.0, 16 / 9]) {
      testWidgets(
        'portrait search entry keeps its frame through a square cover and route handoff (previous=$previousRatio)',
        (tester) async {
          window(tester, const Size(412, 915));
          final previous = VideoItem(
            id: 'previous-local-video',
            path: '${root.path}/previous.mp4',
            title: 'Previous local video',
            durationMs: 600000,
            lastUpdated: 0,
            portraitDisplayAspectRatio: previousRatio,
          );
          // Only the previous entry's metadata is needed here; native
          // controller ownership is covered by bilibili_quality_handoff_test.
          playback.debugOverrideStreamQualityChrome(item: previous);
          final timeline = BilibiliOpenTimeline(_bvid);
          final load = Completer<BilibiliWatchPlan>();
          await tester.pumpWidget(
            host(
              BilibiliWatchLoadingPage(
                bvid: _bvid,
                preview: const BilibiliWatchPreview(title: _title),
                load: (_) => load.future,
                timeline: () => timeline,
                shape: const BilibiliWatchPageShape(landscape: false),
                open: (navigator, page, plan, timeline) async {
                  playback.prepareBilibiliStartup(
                    plan.item.id,
                    timeline.startup,
                  );
                  navigator.replace(
                    oldRoute: page,
                    newRoute: MaterialPageRoute<void>(
                      builder: (_) => PortraitVideoScreen(
                        videoItem: plan.item,
                        autoPlayOnEntry: false,
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pump();
          Rect loadingRect() => tester.getRect(
            find.byKey(const ValueKey('bilibili-watch-loading-video-area')),
          );
          final initialFrame = loadingRect();
          expect(
            initialFrame.width / initialFrame.height,
            closeTo(16 / 9, .001),
          );

          // The search cover decodes before the play address. Its square
          // artwork must never insert a 1:1 frame into this widescreen entry.
          timeline.startup.geometry.reportCover(1);
          await tester.pump();
          expect(loadingRect(), initialFrame);
          timeline.startup.geometry.reportVideo(16 / 9);
          await tester.pump();
          expect(loadingRect(), initialFrame);

          load.complete(_plan());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(PortraitVideoScreen), findsOneWidget);
          final playerFrame = tester.getRect(
            find
                .descendant(
                  of: find.byType(PortraitVideoScreen),
                  matching: find.byType(AspectRatio),
                )
                .first,
          );
          expect(playerFrame, initialFrame);
          expect(previous.portraitDisplayAspectRatio, previousRatio);
          await close(tester);
        },
      );
    }

    testWidgets('a manual portrait ratio survives arriving stream dimensions', (
      tester,
    ) async {
      window(tester, const Size(412, 915));
      final startup = BilibiliStartupContext();
      startup.geometry.reportCover(9 / 16);
      final item = _item()..portraitDisplayAspectRatio = 4 / 3;
      playback.prepareBilibiliStartup(item.id, startup);
      await tester.pumpWidget(
        host(PortraitVideoScreen(videoItem: item, autoPlayOnEntry: false)),
      );
      await tester.pump();
      Rect videoRect() => tester.getRect(
        find
            .descendant(
              of: find.byType(PortraitVideoScreen),
              matching: find.byType(AspectRatio),
            )
            .first,
      );
      expect(videoRect().width / videoRect().height, closeTo(4 / 3, .001));
      startup.geometry.reportVideo(16 / 9);
      await tester.pump();
      expect(videoRect().width / videoRect().height, closeTo(4 / 3, .001));
      expect(item.portraitDisplayAspectRatio, 4 / 3);
      await close(tester);
    });

    testWidgets('landscape cover sits in the video rectangle', (tester) async {
      window(tester, const Size(1280, 720));
      settings.bilibiliPlayerPanelOpen = true;
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (_, _, _, _) async {},
            timeline: () => BilibiliOpenTimeline(_bvid),
            shape: BilibiliWatchPageShape.current(),
          ),
        ),
      );
      await tester.pump();
      final area = tester.getRect(
        find.byKey(const ValueKey('bilibili-watch-loading-video-area')),
      );
      final cover = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('bilibili-watch-loading-cover-frame')),
          matching: find.byType(AspectRatio),
        ),
      );
      final video = containedVideoRect(area, 16 / 9);
      expect(cover.width, closeTo(video.width, 0.5));
      expect(cover.height, closeTo(video.height, 0.5));
      expect(cover.center.dx, closeTo(video.center.dx, 0.5));
      expect(cover.center.dy, closeTo(video.center.dy, 0.5));
      // The surface beside the panel is taller than 16:9. Filling it used
      // to zoom the cover, then the video snapped back to this rectangle.
      expect(cover.height, lessThan(area.height - 1));
      final poster = tester.widget<BilibiliSharpCoverImage>(
        find.byKey(const ValueKey('bilibili-watch-loading-cover')),
      );
      expect(poster.videoFrame, isTrue);
      await close(tester);
    });

    testWidgets('wide window, the Bilibili panel docked', (tester) async {
      window(tester, const Size(1280, 720));
      settings.bilibiliPlayerPanelOpen = true;
      await expectSameLandscape(tester);
      final layout = BilibiliWatchPageShape.current().landscapeLayout(
        window: const Size(1280, 720),
        padding: EdgeInsets.zero,
      );
      expect(layout.slot, BilibiliWatchSidebarSlot.subtitles);
    });

    testWidgets('narrow window, the panel not docked', (tester) async {
      window(tester, const Size(900, 600));
      settings.bilibiliPlayerPanelOpen = true;
      await expectSameLandscape(tester);
      settings.isLandscapeSubtitleSidebarVisible = false;
      await expectSameLandscape(tester);
    });

    for (final subtitles in <bool>[false, true]) {
      testWidgets('resizing keeps the shared sidebar and selected tab '
          'without changing memory '
          '(subtitle list ${subtitles ? 'left open' : 'closed'})', (
        tester,
      ) async {
        window(tester, const Size(1280, 720));
        settings
          ..bilibiliPlayerPanelOpen = true
          ..isLandscapeSubtitleSidebarVisible = subtitles;
        await tester.pumpWidget(
          host(VideoPlayerScreen(videoItem: _item(), autoPlayOnEntry: false)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final surface = find.byKey(const ValueKey('landscape-player-surface'));
        expect(
          find.byType(BilibiliPlayerPanel),
          subtitles ? findsOneWidget : findsNothing,
        );
        final wideVideo = tester.getRect(surface).width;

        // Resizing no longer swaps Bilibili for subtitles or changes width.
        tester.view.physicalSize = const Size(900, 720);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.byType(BilibiliPlayerPanel),
          subtitles ? findsOneWidget : findsNothing,
        );
        expect(
          tester.getRect(surface).width,
          closeTo(900 - (subtitles ? 274.4 : 0), .001),
        );
        if (!subtitles) {
          expect(tester.getRect(surface).width, 900);
        }
        expect(settings.bilibiliPlayerPanelOpen, isTrue);

        // Wide again: back as remembered.
        tester.view.physicalSize = const Size(1280, 720);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.byType(BilibiliPlayerPanel),
          subtitles ? findsOneWidget : findsNothing,
        );
        expect(tester.getRect(surface).width, wideVideo);
        expect(settings.bilibiliPlayerPanelOpen, isTrue);
        expect(settings.isLandscapeSubtitleSidebarVisible, subtitles);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('bilibiliPlayerPanelOpen'), isNull);
        await close(tester);
      });
    }

    testWidgets('left-handed mode', (tester) async {
      window(tester, const Size(1280, 720));
      settings
        ..isLeftHandedMode = true
        ..bilibiliPlayerPanelOpen = true;
      await expectSameLandscape(tester);
      window(tester, const Size(900, 600));
      await expectSameLandscape(tester);
    });

    testWidgets('panel left closed, with a top inset', (tester) async {
      window(
        tester,
        const Size(1280, 720),
        padding: const EdgeInsets.only(top: 24),
      );
      settings.bilibiliPlayerPanelOpen = false;
      await expectSameLandscape(tester);
    });

    testWidgets('the side panel\'s place shows on the matching side', (
      tester,
    ) async {
      window(tester, const Size(1280, 720));
      const shape = BilibiliWatchPageShape(
        landscape: true,
        bilibiliPanelRemembered: true,
        subtitleSidebarRemembered: true,
        leftHanded: true,
      );
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (_, _, _, _) async {},
            timeline: () => BilibiliOpenTimeline(_bvid),
            shape: shape,
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.getRect(
          find.byKey(
            const ValueKey('bilibili-watch-loading-sidebar-subtitles'),
          ),
        ),
        const Rect.fromLTWH(0, 0, 274.4, 720),
      );
      await close(tester);
    });

    testWidgets('the loading page shows the player\'s own Bilibili panel; '
        'collapsing it there is remembered as in the player', (tester) async {
      window(tester, const Size(1280, 720));
      settings.bilibiliPlayerPanelOpen = true;
      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            page: 2,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (_, _, _, _) async {},
            timeline: () => BilibiliOpenTimeline(_bvid),
          ),
        ),
      );
      await tester.pump();
      final sidebar = find.byKey(
        const ValueKey('bilibili-watch-loading-sidebar-subtitles'),
      );
      expect(
        find.descendant(
          of: sidebar,
          matching: find.byType(BilibiliPlayerPanel),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('bilibili-panel-copy-link')));
      await tester.pump();
      expect(copied, 'https://www.bilibili.com/video/$_bvid/?p=2');
      await tester.tap(find.byKey(const ValueKey('bilibili-landscape-close')));
      await tester.pump();
      expect(sidebar, findsNothing);
      expect(settings.bilibiliPlayerPanelOpen, isTrue);
      expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);
      expect(
        find.byKey(const ValueKey('bilibili-watch-loading-sidebar-subtitles')),
        findsNothing,
      );
      await close(tester);
    });

    for (final leftHanded in [false, true]) {
      testWidgets('shared landscape tabs keep width, elements and tool return; '
          'left=$leftHanded', (tester) async {
        window(tester, const Size(1280, 800));
        settings
          ..isLeftHandedMode = leftHanded
          ..userSubtitleSidebarWidth = 320;
        await tester.pumpWidget(
          host(VideoPlayerScreen(videoItem: _item(), autoPlayOnEntry: false)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final tabs = find.byKey(const ValueKey('landscape-reading-tabs'));
        final subtitles = find.byType(SubtitleSidebar, skipOffstage: false);
        final originalSubtitles = tester.state(subtitles);
        final originalDetails = tester.state(find.byType(BilibiliPlayerPanel));
        final video = find.byKey(const ValueKey('landscape-player-surface'));
        final videoBounds = tester.getRect(video);
        expect(tester.getSize(tabs).width, 320);
        expect(tester.widget<SubtitleSidebar>(subtitles).isVisible, isFalse);

        await tester.tap(
          find.byKey(const ValueKey('bilibili-landscape-tab-subtitles')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 70));
        expect(tester.getRect(video), videoBounds);
        expect(tester.getSize(tabs).width, 320);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.state(subtitles), same(originalSubtitles));
        expect(settings.bilibiliLandscapeShowsSubtitles, isTrue);
        expect(tester.widget<SubtitleSidebar>(subtitles).isVisible, isTrue);

        tester.widget<SubtitleSidebar>(subtitles).onOpenSubtitleManager!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        tester
            .widget<SubtitleManagementSheet>(
              find.byType(SubtitleManagementSheet),
            )
            .onClose!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widget<BilibiliPortraitTabs>(tabs).tab,
          PortraitBilibiliTab.subtitles,
        );
        expect(tester.state(subtitles), same(originalSubtitles));

        // The common close button hides both tabs, then the edge handle
        // restores the remembered tab without rebuilding either document.
        await tester.tap(
          find.byKey(const ValueKey('bilibili-landscape-close')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);
        expect(tabs.hitTestable(), findsNothing);
        await tester.tap(find.byType(PlayerSubtitleSidebarToggle));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.state(subtitles), same(originalSubtitles));
        expect(
          tester.widget<BilibiliPortraitTabs>(tabs).tab,
          PortraitBilibiliTab.subtitles,
        );
        await tester.tap(
          find.byKey(const ValueKey('bilibili-landscape-tab-details')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.state(find.byType(BilibiliPlayerPanel)),
          same(originalDetails),
        );
        expect(tester.getRect(video), videoBounds);
        expect(tester.takeException(), isNull);
        await close(tester);
      });
    }

    testWidgets('landscape touch and Alt arrows remember tabs across videos; '
        'dialogs keep their keys', (tester) async {
      window(tester, const Size(1280, 800));
      await tester.pumpWidget(
        host(VideoPlayerScreen(videoItem: _item(), autoPlayOnEntry: false)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final tabs = find.byKey(const ValueKey('landscape-reading-tabs'));
      final bounds = tester.getRect(tabs);
      await tester.timedDragFrom(
        Offset(bounds.right - 45, bounds.bottom - 70),
        Offset(-bounds.width * .6, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.bilibiliLandscapeShowsSubtitles, isTrue);
      Future<void> altArrow(LogicalKeyboardKey arrow) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(arrow);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await altArrow(LogicalKeyboardKey.arrowLeft);
      expect(settings.bilibiliLandscapeShowsSubtitles, isFalse);
      await altArrow(LogicalKeyboardKey.arrowRight);
      expect(settings.bilibiliLandscapeShowsSubtitles, isTrue);

      // Same page, another BV id: keep the selected tab and the shared width.
      playback.debugOverrideStreamQualityChrome(
        item: _item(id: 'watch-2', bvid: 'BV1bb411c7mB'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<BilibiliPortraitTabs>(tabs).tab,
        PortraitBilibiliTab.subtitles,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('bilibiliLandscapeShowsSubtitles'), isTrue);

      unawaited(
        showDialog<void>(
          context: tester.element(tabs),
          builder: (_) =>
              const AlertDialog(content: TextField(autofocus: true)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await altArrow(LogicalKeyboardKey.arrowLeft);
      expect(settings.bilibiliLandscapeShowsSubtitles, isTrue);
      Navigator.of(tester.element(find.byType(TextField))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await close(tester);

      // A new page, another video: memory survives leaving the player too.
      await tester.pumpWidget(
        host(
          VideoPlayerScreen(
            videoItem: _item(id: 'watch-3', bvid: 'BV1cc411c7mC'),
            autoPlayOnEntry: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<BilibiliPortraitTabs>(tabs).tab,
        PortraitBilibiliTab.subtitles,
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    /// Rects of the portrait lower area: the switch and the whole area.
    Future<(Rect, Rect)> portraitLowerArea(WidgetTester tester) async {
      final tabs = find.byType(BilibiliPortraitTabs);
      return (
        tester.getRect(
          find.descendant(
            of: tabs,
            matching: find.byKey(const ValueKey('bilibili-portrait-tab-bar')),
          ),
        ),
        tester.getRect(tabs),
      );
    }

    for (final size in const <Size>[Size(412, 915), Size(800, 1280)]) {
      testWidgets('portrait ${size.width.toInt()} wide: the 详情 | 字幕 area '
          'starts and ends where the player\'s does', (tester) async {
        window(
          tester,
          size,
          padding: const EdgeInsets.only(top: 30, bottom: 20),
        );
        await tester.pumpWidget(
          host(PortraitVideoScreen(videoItem: _item(), autoPlayOnEntry: false)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final player = await portraitLowerArea(tester);
        expect(
          tester
              .widget<BilibiliPortraitTabs>(find.byType(BilibiliPortraitTabs))
              .tab,
          PortraitBilibiliTab.details,
        );
        await close(tester);

        final load = Completer<BilibiliWatchPlan>();
        await tester.pumpWidget(
          host(
            BilibiliWatchLoadingPage(
              bvid: _bvid,
              preview: const BilibiliWatchPreview(title: _title),
              load: (_) => load.future,
              open: (_, _, _, _) async {},
              timeline: () => BilibiliOpenTimeline(_bvid),
              shape: const BilibiliWatchPageShape(landscape: false),
            ),
          ),
        );
        await tester.pump();
        final loading = await portraitLowerArea(tester);
        expect(loading.$1, player.$1);
        expect(loading.$2, player.$2);
        // The details tab: the panel the player shows, its outline while
        // the detail loads.
        expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
        expect(
          find.byKey(const ValueKey('bilibili-watch-loading-controls')),
          findsOneWidget,
        );
        await close(tester);
      });
    }

    testWidgets('the tab picked on the loading page carries over to the '
        'player, which does not snap back; nothing is remembered', (
      tester,
    ) async {
      window(tester, const Size(412, 915));
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (navigator, page, plan, _) async {
              navigator.replace(
                oldRoute: page,
                newRoute: MaterialPageRoute<void>(
                  builder: (_) => PortraitVideoScreen(
                    videoItem: plan.item,
                    autoPlayOnEntry: false,
                  ),
                ),
              );
            },
            timeline: () => BilibiliOpenTimeline(_bvid),
            shape: const BilibiliWatchPageShape(landscape: false),
          ),
        ),
      );
      await tester.pump();
      PortraitBilibiliTab shown() => tester
          .widget<BilibiliPortraitTabs>(find.byType(BilibiliPortraitTabs))
          .tab;
      expect(shown(), PortraitBilibiliTab.details);

      await tester.tap(
        find.byKey(const ValueKey('bilibili-portrait-tab-subtitles')),
      );
      await tester.pump();
      expect(shown(), PortraitBilibiliTab.subtitles);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);

      load.complete(_plan());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BilibiliWatchLoadingPage), findsNothing);
      expect(find.byType(PortraitVideoScreen), findsOneWidget);
      expect(shown(), PortraitBilibiliTab.subtitles);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      await close(tester);
    });

    testWidgets('a tab picked on the loading page that is not opened '
        'changes nothing', (tester) async {
      window(tester, const Size(412, 915));
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (_, _, _, _) async {},
            timeline: () => BilibiliOpenTimeline(_bvid),
            shape: const BilibiliWatchPageShape(landscape: false),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('bilibili-portrait-tab-subtitles')),
      );
      await tester.pump();
      await close(tester);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      expect(BilibiliPortraitTabMemory.takeHandOff(_item().id), isNull);
    });

    for (final size in const <Size>[Size(412, 915), Size(800, 1280)]) {
      testWidgets('portrait ${size.width.toInt()} wide', (tester) async {
        window(
          tester,
          size,
          padding: const EdgeInsets.only(top: 30, bottom: 20),
        );
        final player = await showPortraitPlayer(tester);
        final loading = await showLoadingPage(
          tester,
          const BilibiliWatchPageShape(landscape: false),
        );
        expect(loading.area, player);
        expect(
          bilibiliWatchPortraitVideoArea(
            window: size,
            padding: const EdgeInsets.only(top: 30, bottom: 20),
            aspectRatio: 16 / 9,
          ),
          player,
        );
      });
    }
  });
}

final _defaultValueTypeCheck = Provider.debugCheckInvalidValueType;

class _Shown {
  const _Shown({required this.area, required this.back, this.title});

  final Rect area;
  final Rect back;
  final Rect? title;
}

const _bvid = 'BV1xx411c7mD';
const _title = '测试视频';

VideoItem _item({String id = 'watch-1', String bvid = _bvid}) => VideoItem(
  id: id,
  path: 'bilibili://stream/$bvid?cid=101',
  title: _title,
  durationMs: 600000,
  lastUpdated: 0,
  isTransient: true,
  isBilibiliExported: true,
  sourceRef: MediaSourceRef(
    value: bvid,
    kind: MediaSourceKind.bilibiliStream,
    bvid: bvid,
    cid: 101,
    page: 1,
  ),
);

BilibiliWatchPlan _plan() => BilibiliWatchPlan(
  item: _item(),
  imported: false,
  videoInfo: BilibiliVideoInfo(
    title: _title,
    desc: '',
    pic: '',
    bvid: _bvid,
    aid: '123',
    ownerName: 'UP',
    ownerMid: '1',
    pubDate: 0,
    pages: <BilibiliPage>[
      BilibiliPage(
        cid: 101,
        page: 1,
        part: '第 1 部分',
        duration: 600,
        bvid: _bvid,
        aid: '123',
      ),
    ],
  ),
);

class _NeverReadyStreaming extends BilibiliStreamingService {
  _NeverReadyStreaming() : super(BilibiliApiService());

  @override
  Future<BilibiliPreparedPlayback> prepare(
    VideoItem item, {
    int? qualityId,
    int? audioQualityId,
    bool allowWarmReuse = true,
    bool forceRefresh = false,
  }) => Completer<BilibiliPreparedPlayback>().future;
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
