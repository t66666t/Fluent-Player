import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/bilibili_video_shot.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/player_control_metrics.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'disabled seek thumbnails keep time feedback without an image preview',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/video.mp4'),
      );
      controller.value = VideoPlayerValue(
        duration: const Duration(seconds: 100),
        position: const Duration(seconds: 10),
        isInitialized: true,
      );
      final playbackService = MediaPlaybackService();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService(),
            ),
            ChangeNotifierProvider<MediaPlaybackService>.value(
              value: playbackService,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: VideoControlsOverlay(
                controller: controller,
                enableSeekThumbnailPreview: false,
                isLocked: false,
                isPreviewMode: true,
                onTogglePlay: () {},
                onBackPressed: () {},
                onToggleLock: () {},
                onSpeedUpdate: (_) async {},
                showSubtitles: false,
                onToggleSubtitles: () {},
                onMoveSubtitles: () {},
                isLongPressing: false,
                longPressFeedbackText: '',
                onLongPressStart: () => true,
                onLongPressEnd: () {},
                subtitleEntries: const [],
                subtitleStyle: const SubtitleStyle(),
                subtitleAlignment: Alignment.bottomCenter,
                onEnterSubtitleDragMode: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final hoverRegion = find.byKey(
        const ValueKey('video-controls-progress-hover-region'),
      );
      final progressRect = tester.getRect(hoverRegion);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: progressRect.center);
      await tester.pump(const Duration(milliseconds: 180));

      expect(
        find.byKey(const ValueKey('video-controls-seek-preview-time')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('seek-preview-loading')), findsNothing);

      await mouse.down(progressRect.center);
      await mouse.moveTo(
        Offset(progressRect.right - 20, progressRect.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        find.byKey(const ValueKey('video-controls-seek-preview-time')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('seek-preview-loading')), findsNothing);

      await mouse.cancel();
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
      await controller.dispose();
    },
  );

  testWidgets('Bilibili sprite metadata drives hover and drag thumbnails', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    controller.value = VideoPlayerValue(
      duration: const Duration(seconds: 100),
      position: const Duration(seconds: 10),
      isInitialized: true,
    );
    final playbackService = MediaPlaybackService();
    final videoShot = BilibiliVideoShot(
      spritePaths: const ['assets/icon/fluent-player.png'],
      timestampsSeconds: const [0, 40],
      columns: 2,
      rows: 1,
      cellWidth: 480,
      cellHeight: 270,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: playbackService,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: VideoControlsOverlay(
              controller: controller,
              bilibiliVideoShot: videoShot,
              isLocked: false,
              isPreviewMode: true,
              onTogglePlay: () {},
              onBackPressed: () {},
              onToggleLock: () {},
              onSpeedUpdate: (_) async {},
              showSubtitles: false,
              onToggleSubtitles: () {},
              onMoveSubtitles: () {},
              isLongPressing: false,
              longPressFeedbackText: '',
              onLongPressStart: () => true,
              onLongPressEnd: () {},
              subtitleEntries: const [],
              subtitleStyle: const SubtitleStyle(),
              subtitleAlignment: Alignment.bottomCenter,
              onEnterSubtitleDragMode: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final hoverRegion = find.byKey(
      const ValueKey('video-controls-progress-hover-region'),
    );
    final progressRect = tester.getRect(hoverRegion);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: progressRect.center);
    await tester.pump(const Duration(milliseconds: 180));

    expect(
      find.byKey(const ValueKey('bilibili-video-shot-0-0-1')),
      findsOneWidget,
    );

    await mouse.down(progressRect.center);
    await mouse.moveTo(Offset(progressRect.left + 20, progressRect.center.dy));
    await tester.pump(const Duration(milliseconds: 180));
    expect(
      find.byKey(const ValueKey('bilibili-video-shot-0-0-0')),
      findsOneWidget,
    );

    await mouse.cancel();
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
    await controller.dispose();
  });

  testWidgets(
    'mouse hover previews time and cancelled drag restores the playing chapter',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/video.mp4'),
      );
      controller.value = VideoPlayerValue(
        duration: const Duration(seconds: 100),
        position: const Duration(seconds: 10),
        buffered: <DurationRange>[
          DurationRange(Duration.zero, const Duration(seconds: 60)),
        ],
        isInitialized: true,
      );
      final playbackService = MediaPlaybackService();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService(),
            ),
            ChangeNotifierProvider<MediaPlaybackService>.value(
              value: playbackService,
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.35)),
              child: child!,
            ),
            home: Scaffold(
              body: VideoControlsOverlay(
                controller: controller,
                isLocked: false,
                isPreviewMode: true,
                onTogglePlay: () {},
                onBackPressed: () {},
                onToggleLock: () {},
                onSpeedUpdate: (_) async {},
                showSubtitles: false,
                onToggleSubtitles: () {},
                onMoveSubtitles: () {},
                isLongPressing: false,
                longPressFeedbackText: '',
                showBufferedProgress: true,
                onLongPressStart: () => true,
                onLongPressEnd: () {},
                subtitleEntries: const [],
                subtitleStyle: const SubtitleStyle(),
                subtitleAlignment: Alignment.bottomCenter,
                onEnterSubtitleDragMode: () {},
                chapters: const <MediaChapter>[
                  MediaChapter(title: '章节', startMs: 0, endMs: 30000),
                  MediaChapter(title: '第二章', startMs: 30000, endMs: 70000),
                  MediaChapter(title: '第三章', startMs: 70000, endMs: 100000),
                ],
                onOpenChapters: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final progressSlider = tester.widget<Slider>(
        find.descendant(
          of: find.byKey(
            const ValueKey('video-controls-progress-hover-region'),
          ),
          matching: find.byType(Slider),
        ),
      );
      expect(progressSlider.secondaryTrackValue, 60 * 1000);

      Finder chapterTitle(String text) => find.descendant(
        of: find.byKey(const ValueKey('video-controls-chapter-title')),
        matching: find.text(text),
      );

      expect(chapterTitle('章节'), findsOneWidget);
      final hoverRegion = find.byKey(
        const ValueKey('video-controls-progress-hover-region'),
      );
      final progressRect = tester.getRect(hoverRegion);
      final progressAreaRect = tester.getRect(
        find.byKey(const ValueKey('video-controls-progress-area')),
      );
      final chapterButtonRect = tester.getRect(
        find.byKey(const ValueKey('video-controls-chapter-button')),
      );
      final chapterTitleFinder = chapterTitle('章节');
      final chapterTitleRect = tester.getRect(chapterTitleFinder);
      final chapterTitleText = tester.widget<Text>(chapterTitleFinder);
      final chapterTitleContext = tester.element(chapterTitleFinder);
      final measuredChapterTitle = TextPainter(
        text: TextSpan(
          text: chapterTitleText.data,
          style: DefaultTextStyle.of(
            chapterTitleContext,
          ).style.merge(chapterTitleText.style),
        ),
        maxLines: 1,
        textDirection: Directionality.of(chapterTitleContext),
        textScaler: MediaQuery.textScalerOf(chapterTitleContext),
        locale: Localizations.maybeLocaleOf(chapterTitleContext),
        textWidthBasis: TextWidthBasis.longestLine,
      )..layout();
      final timeDisplayRect = tester.getRect(
        find.byKey(const ValueKey('video-controls-time-display')),
      );
      final metrics = PlayerControlMetrics.fromSize(const Size(1000, 600));
      final expectedTrackLeft =
          progressRect.left +
          math.max(metrics.overlayRadius, metrics.thumbRadius);

      expect(chapterButtonRect.width, lessThan(progressRect.width * 0.25));
      expect(
        chapterTitleRect.width,
        greaterThanOrEqualTo(measuredChapterTitle.width - 0.01),
      );
      expect(chapterButtonRect.left, closeTo(expectedTrackLeft, 0.01));
      expect(timeDisplayRect.left, closeTo(expectedTrackLeft, 0.01));
      expect(
        chapterTitleRect.left - chapterButtonRect.left,
        inInclusiveRange(8, 16),
      );
      final gapAboveProgress =
          progressRect.center.dy - chapterButtonRect.bottom;
      final gapBelowProgress = progressAreaRect.bottom - progressRect.center.dy;
      expect(gapAboveProgress, closeTo(gapBelowProgress, 0.01));

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: Offset(progressRect.center.dx, progressRect.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 180));

      expect(
        find.byKey(const ValueKey('video-controls-seek-preview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('video-controls-progress-hover-marker')),
        findsOneWidget,
      );
      final previewTime = tester
          .widget<Text>(
            find.byKey(const ValueKey('video-controls-seek-preview-time')),
          )
          .data;
      expect(previewTime, anyOf('0:49', '0:50', '00:49', '00:50'));

      await mouse.moveTo(const Offset(500, 80));
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        find.byKey(const ValueKey('video-controls-seek-preview')),
        findsNothing,
      );
      await mouse.removePointer();

      final dragStart = Offset(
        progressRect.left + (progressRect.width * 0.1),
        progressRect.center.dy,
      );
      final dragEnd = Offset(
        progressRect.left + (progressRect.width * 0.5),
        progressRect.center.dy,
      );
      final drag = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await drag.addPointer(location: dragStart);
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        find.byKey(const ValueKey('video-controls-seek-preview')),
        findsOneWidget,
      );
      await drag.down(dragStart);
      await drag.moveTo(dragEnd);
      await tester.pump(const Duration(milliseconds: 180));

      expect(
        find.byKey(const ValueKey('video-controls-chapter-title')),
        findsOneWidget,
      );
      expect(chapterTitle('第二章'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('video-controls-seek-preview')),
        findsOneWidget,
      );

      // A real desktop drag must remain captured even if the pointer leaves
      // the narrow hover region while the primary mouse button stays down.
      await drag.moveTo(
        Offset(
          progressRect.left + (progressRect.width * 0.8),
          progressRect.top - 6,
        ),
      );
      await tester.pump(const Duration(milliseconds: 180));
      expect(chapterTitle('第三章'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('video-controls-seek-preview')),
        findsOneWidget,
      );

      await drag.cancel();
      await tester.pump(const Duration(milliseconds: 180));
      expect(chapterTitle('章节'), findsOneWidget);

      // The native desktop mouse path must not disable touch-screen dragging.
      final touchDrag = await tester.startGesture(
        dragStart,
        kind: PointerDeviceKind.touch,
      );
      await touchDrag.moveTo(dragEnd);
      await tester.pump(const Duration(milliseconds: 180));
      expect(chapterTitle('第二章'), findsOneWidget);
      await touchDrag.cancel();
      await tester.pump(const Duration(milliseconds: 180));
      expect(chapterTitle('章节'), findsOneWidget);
      await drag.removePointer();

      final parkedMouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await parkedMouse.addPointer(location: progressRect.center);
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        find.byKey(const ValueKey('video-controls-seek-preview')),
        findsOneWidget,
      );
      final finger = await tester.startGesture(
        progressRect.center,
        kind: PointerDeviceKind.touch,
      );
      await finger.moveTo(
        Offset(
          progressRect.left + (progressRect.width * 0.6),
          progressRect.center.dy,
        ),
      );
      await finger.moveTo(const Offset(500, 40));
      await finger.up();
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        find.byKey(const ValueKey('video-controls-seek-preview')),
        findsNothing,
      );
      await parkedMouse.removePointer();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
      await controller.dispose();
      playbackService.dispose();
    },
  );
}
