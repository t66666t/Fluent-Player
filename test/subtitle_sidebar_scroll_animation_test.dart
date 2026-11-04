import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'short article content stays at the top at a late playback position',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'autoScrollSubtitles': true,
        'subtitleViewMode': 1,
        'subtitleArticleSentencesPerParagraph': 4,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();

      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/short-article.mp4'),
      );
      controller.value = const VideoPlayerValue(
        duration: Duration(minutes: 1),
        position: Duration(seconds: 33),
        isInitialized: true,
        isPlaying: true,
      );
      final subtitles = List<SubtitleItem>.generate(12, (index) {
        final start = Duration(seconds: index * 3);
        return SubtitleItem(
          index: index,
          startTime: start,
          endTime: start + const Duration(seconds: 2),
          text: '$index',
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 280,
              child: SubtitleSidebar(
                subtitles: subtitles,
                controller: controller,
                isCompact: true,
              ),
            ),
          ),
        ),
      );
      await _pumpPostFrameCallbacks(tester);

      final articleList = find.byKey(
        const PageStorageKey('subtitle-article-list-4'),
      );
      final firstParagraph = find.byType(SubtitleArticleChunk).first;
      final lastParagraph = find.byType(SubtitleArticleChunk).last;
      expect(articleList, findsOneWidget);
      expect(firstParagraph, findsOneWidget);
      expect(lastParagraph, findsOneWidget);
      expect(
        tester.getTopLeft(firstParagraph).dy -
            tester.getTopLeft(articleList).dy,
        lessThanOrEqualTo(20.1),
      );
      expect(
        tester.getBottomRight(lastParagraph).dy,
        lessThanOrEqualTo(tester.getBottomRight(articleList).dy),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );

  for (final articleMode in <bool>[false, true]) {
    testWidgets(
      '${articleMode ? 'article' : 'list'} view animates locate after a confirmed tap',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'autoScrollSubtitles': true,
          'subtitleViewMode': articleMode ? 1 : 0,
          'subtitleArticleSentencesPerParagraph': 1,
        });
        final settings = SettingsService();
        settings.resetForTest();
        await settings.init();

        final controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/video.mp4'),
        );
        controller.value = const VideoPlayerValue(
          duration: Duration(minutes: 2),
          isInitialized: true,
          isPlaying: true,
        );
        final subtitles = List<SubtitleItem>.generate(30, (index) {
          final start = Duration(seconds: index * 3);
          return SubtitleItem(
            index: index,
            startTime: start,
            endTime: start + const Duration(seconds: 2),
            text: 'subtitle $index',
          );
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                height: 360,
                child: SubtitleSidebar(
                  subtitles: subtitles,
                  controller: controller,
                  isCompact: true,
                  onItemTap: (position) {
                    // Seek lands on pointer-up (confirmed click), then the
                    // player reports the new position in the same callback.
                    controller.value = controller.value.copyWith(
                      position: position,
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final target = find.text('subtitle 4', findRichText: articleMode);
        expect(target, findsOneWidget);
        final gesture = await tester.startGesture(tester.getCenter(target));
        await tester.pump();
        final beforeRelease = tester.getTopLeft(target).dy;

        await gesture.up();
        await tester.pump();
        final animationStart = tester.getTopLeft(target).dy;
        await tester.pump(const Duration(milliseconds: 40));
        final duringAnimation = tester.getTopLeft(target).dy;
        await tester.pump(const Duration(milliseconds: 200));
        final afterAnimation = tester.getTopLeft(target).dy;

        expect(duringAnimation, isNot(closeTo(beforeRelease, 0.5)));
        expect(animationStart, isNot(closeTo(afterAnimation, 0.5)));

        await tester.pumpWidget(const SizedBox.shrink());
        await controller.dispose();
      },
    );

    testWidgets(
      '${articleMode ? 'article' : 'list'} view locates the pre-subtitle opening at the top',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'autoScrollSubtitles': true,
          'subtitleViewMode': articleMode ? 1 : 0,
          'subtitleArticleSentencesPerParagraph': 1,
        });
        final settings = SettingsService();
        settings.resetForTest();
        await settings.init();

        final controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/opening.mp4'),
        );
        controller.value = const VideoPlayerValue(
          duration: Duration(minutes: 2),
          position: Duration.zero,
          isInitialized: true,
          isPlaying: true,
        );
        final sidebarKey = GlobalKey<SubtitleSidebarState>();
        final subtitles = _buildSubtitles(firstStartSeconds: 10);

        await _pumpSidebar(
          tester,
          key: sidebarKey,
          controller: controller,
          subtitles: subtitles,
        );
        await _pumpPostFrameCallbacks(tester);

        final firstSubtitle = find.text(
          'subtitle 0',
          findRichText: articleMode,
        );
        sidebarKey.currentState!.jumpToFirstSubtitleTop();
        await _pumpPostFrameCallbacks(tester);
        final topPosition = tester.getTopLeft(firstSubtitle).dy;

        sidebarKey.currentState!.locateToTime(
          const Duration(seconds: 60),
          animated: false,
        );
        await _pumpPostFrameCallbacks(tester);
        expect(controller.value.position, Duration.zero);
        sidebarKey.currentState!.locateToCurrentSubtitle(ignorePointer: true);
        await _pumpPostFrameCallbacks(tester);
        expect(tester.getTopLeft(firstSubtitle).dy, closeTo(topPosition, 0.01));

        sidebarKey.currentState!.locateToTime(
          const Duration(seconds: 60),
          animated: false,
        );
        await _pumpPostFrameCallbacks(tester);
        expect(SettingsService().autoScrollSubtitles, isTrue);
        expect(controller.value.isPlaying, isTrue);
        sidebarKey.currentState!.triggerLocateForAutoFollow();
        await _pumpPostFrameCallbacks(tester);
        expect(tester.getTopLeft(firstSubtitle).dy, closeTo(topPosition, 0.01));

        await tester.pumpWidget(const SizedBox.shrink());
        await controller.dispose();
      },
    );

    testWidgets(
      '${articleMode ? 'article' : 'list'} tap animation ignores stale seek callbacks',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'autoScrollSubtitles': true,
          'subtitleViewMode': articleMode ? 1 : 0,
          'subtitleArticleSentencesPerParagraph': 1,
          'landscapeSidebarLocatePositionPercent': 30,
        });
        final settings = SettingsService();
        settings.resetForTest();
        await settings.init();

        final controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/stale-seek.mp4'),
        );
        controller.value = const VideoPlayerValue(
          duration: Duration(minutes: 2),
          isInitialized: true,
          isPlaying: true,
        );
        final subtitles = _buildSubtitles(firstStartSeconds: 0);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                height: 360,
                child: SubtitleSidebar(
                  subtitles: subtitles,
                  controller: controller,
                  isCompact: true,
                  onItemTap: (position) {
                    controller.value = controller.value.copyWith(
                      position: position,
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await _pumpPostFrameCallbacks(tester);

        final target = find.text('subtitle 4', findRichText: articleMode);
        expect(target, findsOneWidget);
        final gesture = await tester.startGesture(tester.getCenter(target));
        await tester.pump(const Duration(milliseconds: 120));
        await gesture.up();
        await tester.pump();

        final positions = <double>[tester.getTopLeft(target).dy];
        await tester.pump(const Duration(milliseconds: 40));
        positions.add(tester.getTopLeft(target).dy);

        // Some native backends briefly publish the pre-seek position after
        // already reporting the requested one.
        controller.value = controller.value.copyWith(position: Duration.zero);
        await tester.pump(const Duration(milliseconds: 40));
        positions.add(tester.getTopLeft(target).dy);
        controller.value = controller.value.copyWith(
          position: subtitles[4].startTime,
        );

        // Sample beyond the 680ms visible-target budget, including two settled
        // frames, while retaining the no-reversal assertions.
        for (int i = 0; i < 18; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          positions.add(tester.getTopLeft(target).dy);
        }

        for (int i = 1; i < positions.length; i++) {
          expect(
            positions[i],
            lessThanOrEqualTo(positions[i - 1] + 0.5),
            reason: 'the tapped row must move in one uninterrupted direction',
          );
        }
        expect(
          positions.last,
          closeTo(positions[positions.length - 2], 0.1),
          reason: '$positions',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await controller.dispose();
      },
    );
  }

  testWidgets('list tap does not locate when auto-follow is off', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'autoScrollSubtitles': false,
      'subtitleViewMode': 0,
      'landscapeSidebarLocatePositionPercent': 30,
    });
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    await settings.updateSetting('autoScrollSubtitles', false);
    expect(settings.autoScrollSubtitles, isFalse);

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/no-follow-tap.mp4'),
    );
    controller.value = const VideoPlayerValue(
      duration: Duration(minutes: 2),
      isInitialized: true,
      isPlaying: true,
    );
    final subtitles = _buildSubtitles(firstStartSeconds: 0);
    final sidebarKey = GlobalKey<SubtitleSidebarState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 360,
            child: SubtitleSidebar(
              key: sidebarKey,
              subtitles: subtitles,
              controller: controller,
              isCompact: true,
              onItemTap: (position) {
                controller.value = controller.value.copyWith(
                  position: position,
                );
              },
            ),
          ),
        ),
      ),
    );
    await _pumpPostFrameCallbacks(tester);

    final target = find.text('subtitle 4');
    expect(target, findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(controller.value.position, subtitles[4].startTime);
    expect(sidebarKey.currentState!.lastTappedLocateScrollIndex, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });

  testWidgets('changing video automatically locates the new subtitle content', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'autoScrollSubtitles': false,
      'subtitleViewMode': 0,
    });
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    final oldController = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/old.mp4'),
    );
    oldController.value = const VideoPlayerValue(
      duration: Duration(minutes: 2),
      position: Duration(seconds: 60),
      isInitialized: true,
      isPlaying: false,
    );
    final newController = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/new.mp4'),
    );
    newController.value = const VideoPlayerValue(
      duration: Duration(minutes: 2),
      position: Duration.zero,
      isInitialized: true,
      isPlaying: false,
    );
    final sidebarKey = GlobalKey<SubtitleSidebarState>();

    await _pumpSidebar(
      tester,
      key: sidebarKey,
      controller: oldController,
      subtitles: _buildSubtitles(firstStartSeconds: 10, prefix: 'old'),
    );
    await _pumpPostFrameCallbacks(tester);

    await _pumpSidebar(
      tester,
      key: sidebarKey,
      controller: newController,
      subtitles: const <SubtitleItem>[],
    );
    await _pumpPostFrameCallbacks(tester);

    await _pumpSidebar(
      tester,
      key: sidebarKey,
      controller: newController,
      subtitles: _buildSubtitles(firstStartSeconds: 10, prefix: 'new'),
    );
    await _pumpPostFrameCallbacks(tester);

    final firstNewSubtitle = find.text('new subtitle 0');
    expect(firstNewSubtitle, findsOneWidget);
    final firstY = tester.getTopLeft(firstNewSubtitle).dy;
    final secondY = tester.getTopLeft(find.text('new subtitle 1')).dy;
    expect(firstY, lessThan(secondY));

    await tester.pumpWidget(const SizedBox.shrink());
    await oldController.dispose();
    await newController.dispose();
  });

  for (final startsInArticleMode in <bool>[false, true]) {
    for (final atBottom in <bool>[false, true]) {
      testWidgets(
        '${startsInArticleMode ? 'article to list' : 'list to article'} switch has no boundary correction animation at ${atBottom ? 'bottom' : 'top'}',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'autoScrollSubtitles': false,
            'subtitleViewMode': startsInArticleMode ? 1 : 0,
            'subtitleArticleSentencesPerParagraph': 1,
          });
          final settings = SettingsService();
          settings.resetForTest();
          await settings.init();

          final subtitles = _buildSubtitles(firstStartSeconds: 0);
          final controller = VideoPlayerController.networkUrl(
            Uri.parse('https://example.invalid/boundary.mp4'),
          );
          controller.value = VideoPlayerValue(
            duration: const Duration(minutes: 2),
            position: atBottom
                ? subtitles.last.startTime
                : subtitles.first.startTime,
            isInitialized: true,
            isPlaying: false,
          );

          final sidebarKey = GlobalKey<SubtitleSidebarState>();
          await _pumpSidebar(
            tester,
            key: sidebarKey,
            controller: controller,
            subtitles: subtitles,
          );
          await _pumpFrames(tester, 25);
          if (atBottom) {
            sidebarKey.currentState!.locateToTime(
              subtitles.last.startTime,
              preferredIndex: subtitles.length - 1,
              animated: false,
            );
          } else {
            sidebarKey.currentState!.jumpToFirstSubtitleTop();
          }
          await _pumpFrames(tester, 10);

          await tester.tap(
            find.byIcon(startsInArticleMode ? Icons.list : Icons.article),
          );
          await tester.pump();
          final target = find.text(
            atBottom ? 'subtitle 29' : 'subtitle 0',
            findRichText: !startsInArticleMode,
          );
          final positions = await _sampleVerticalPositions(tester, target);
          _expectNoAnimatedDriftAfterRelocate(positions);

          await tester.pumpWidget(const SizedBox.shrink());
          await controller.dispose();
        },
      );
    }
  }

  for (final articleMode in <bool>[false, true]) {
    for (final atBottom in <bool>[false, true]) {
      testWidgets(
        '${articleMode ? 'article' : 'list'} bilingual switch has no boundary correction animation at ${atBottom ? 'bottom' : 'top'}',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'autoScrollSubtitles': false,
            'subtitleViewMode': articleMode ? 1 : 0,
            'subtitleArticleSentencesPerParagraph': 1,
          });
          final settings = SettingsService();
          settings.resetForTest();
          await settings.init();
          final subtitles = _buildSubtitles(firstStartSeconds: 0);
          final secondary = _buildSubtitles(
            firstStartSeconds: 0,
            prefix: 'secondary',
          );
          final controller = VideoPlayerController.networkUrl(
            Uri.parse('https://example.invalid/line-boundary.mp4'),
          );
          controller.value = VideoPlayerValue(
            duration: const Duration(minutes: 2),
            position: atBottom
                ? subtitles.last.startTime
                : subtitles.first.startTime,
            isInitialized: true,
            isPlaying: false,
          );
          final sidebarKey = GlobalKey<SubtitleSidebarState>();
          await _pumpSidebar(
            tester,
            key: sidebarKey,
            controller: controller,
            subtitles: subtitles,
            secondarySubtitles: secondary,
          );
          await _pumpFrames(tester, 25);
          if (atBottom) {
            sidebarKey.currentState!.locateToTime(
              subtitles.last.startTime,
              preferredIndex: subtitles.length - 1,
              animated: false,
            );
          } else {
            sidebarKey.currentState!.jumpToFirstSubtitleTop();
          }
          await _pumpFrames(tester, 10);

          await tester.tap(find.text('1'));
          await tester.pump();
          final target = find.text(
            atBottom ? 'subtitle 29' : 'subtitle 0',
            findRichText: articleMode,
          );
          final positions = await _sampleVerticalPositions(tester, target);
          _expectNoAnimatedDriftAfterRelocate(positions);

          await tester.pumpWidget(const SizedBox.shrink());
          await controller.dispose();
        },
      );
    }
  }

  testWidgets(
    'explicit viewport restore locates while paused with auto-follow disabled',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'autoScrollSubtitles': false,
        'subtitleViewMode': 0,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();
      final subtitles = _buildSubtitles(firstStartSeconds: 0);
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/paused-restore.mp4'),
      );
      controller.value = const VideoPlayerValue(
        duration: Duration(minutes: 2),
        position: Duration(seconds: 30),
        isInitialized: true,
        isPlaying: false,
      );
      final sidebarKey = GlobalKey<SubtitleSidebarState>();
      await _pumpSidebar(
        tester,
        key: sidebarKey,
        controller: controller,
        subtitles: subtitles,
      );
      await _pumpFrames(tester, 10);

      sidebarKey.currentState!.locateToTime(
        subtitles.last.startTime,
        preferredIndex: subtitles.length - 1,
        animated: false,
      );
      await _pumpFrames(tester, 5);
      sidebarKey.currentState!.locateToCurrentSubtitle(ignorePointer: true);
      await _pumpFrames(tester, 20);

      expect(controller.value.isPlaying, isFalse);
      expect(SettingsService().autoScrollSubtitles, isFalse);
      expect(find.text('subtitle 10'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );

  for (final articleMode in <bool>[false, true]) {
    testWidgets(
      '${articleMode ? 'article' : 'list'} playing subtitle keeps its locate alignment after the viewport settles',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'autoScrollSubtitles': true,
          'subtitleViewMode': articleMode ? 1 : 0,
          'subtitleArticleSentencesPerParagraph': 1,
          'portraitSidebarLocatePositionPercent': 30,
        });
        final settings = SettingsService();
        settings.resetForTest();
        await settings.init();
        final subtitles = _buildSubtitles(firstStartSeconds: 0);
        final controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/viewport-settle.mp4'),
        );
        controller.value = const VideoPlayerValue(
          duration: Duration(minutes: 2),
          position: Duration(seconds: 60),
          isInitialized: true,
          isPlaying: true,
        );
        final sidebarKey = GlobalKey<SubtitleSidebarState>();

        await _pumpSidebarAtHeight(
          tester,
          key: sidebarKey,
          controller: controller,
          subtitles: subtitles,
          height: 600,
        );
        sidebarKey.currentState!.locateToCurrentSubtitle(ignorePointer: true);
        await _pumpFrames(tester, 10);
        final target = find.text('subtitle 20', findRichText: articleMode);
        final initialFraction = _leadingFractionInScrollableList(
          tester,
          target,
        );

        await _pumpSidebarAtHeight(
          tester,
          key: sidebarKey,
          controller: controller,
          subtitles: subtitles,
          height: 360,
        );
        await _pumpFrames(tester, 10);
        final settledFraction = _leadingFractionInScrollableList(
          tester,
          target,
        );

        sidebarKey.currentState!.locateToCurrentSubtitle(ignorePointer: true);
        await _pumpFrames(tester, 10);
        final explicitFinalFraction = _leadingFractionInScrollableList(
          tester,
          target,
        );

        expect(settledFraction, closeTo(explicitFinalFraction, 0.01));
        expect(settledFraction, lessThan(initialFraction));

        await tester.pumpWidget(const SizedBox.shrink());
        await controller.dispose();
      },
    );
  }
}

List<SubtitleItem> _buildSubtitles({
  required int firstStartSeconds,
  String prefix = '',
}) {
  final textPrefix = prefix.isEmpty ? '' : '$prefix ';
  return List<SubtitleItem>.generate(30, (index) {
    final start = Duration(seconds: firstStartSeconds + index * 3);
    return SubtitleItem(
      index: index,
      startTime: start,
      endTime: start + const Duration(seconds: 2),
      text: '${textPrefix}subtitle $index',
    );
  });
}

Future<void> _pumpSidebar(
  WidgetTester tester, {
  required GlobalKey<SubtitleSidebarState> key,
  required VideoPlayerController controller,
  required List<SubtitleItem> subtitles,
  List<SubtitleItem> secondarySubtitles = const <SubtitleItem>[],
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 360,
          child: SubtitleSidebar(
            key: key,
            subtitles: subtitles,
            secondarySubtitles: secondarySubtitles,
            controller: controller,
            isCompact: true,
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpSidebarAtHeight(
  WidgetTester tester, {
  required GlobalKey<SubtitleSidebarState> key,
  required VideoPlayerController controller,
  required List<SubtitleItem> subtitles,
  required double height,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            height: height,
            child: SubtitleSidebar(
              key: key,
              subtitles: subtitles,
              controller: controller,
              isCompact: true,
              isPortrait: true,
            ),
          ),
        ),
      ),
    ),
  );
}

double _leadingFractionInScrollableList(WidgetTester tester, Finder target) {
  final scrollables = find.descendant(
    of: find.byType(SubtitleSidebar),
    matching: find.byType(Scrollable),
  );
  Finder scrollable = scrollables.first;
  double maxHeight = -1;
  for (int index = 0; index < scrollables.evaluate().length; index++) {
    final candidate = scrollables.at(index);
    final height = tester.getSize(candidate).height;
    if (height > maxHeight) {
      maxHeight = height;
      scrollable = candidate;
    }
  }
  final listTop = tester.getTopLeft(scrollable).dy;
  final listHeight = tester.getSize(scrollable).height;
  return (tester.getTopLeft(target).dy - listTop) / listHeight;
}

Future<void> _pumpPostFrameCallbacks(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<List<double>> _sampleVerticalPositions(
  WidgetTester tester,
  Finder target,
) async {
  for (int i = 0; i < 10 && target.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(target, findsOneWidget);
  final positions = <double>[];
  for (int i = 0; i < 8; i++) {
    positions.add(tester.getTopLeft(target).dy);
    await tester.pump(const Duration(milliseconds: 16));
  }
  return positions;
}

void _expectNoAnimatedDriftAfterRelocate(List<double> positions) {
  // The first two frames contain the new layout and its synchronous boundary
  // correction. Every subsequent frame must be stationary: a gradual change
  // here is the distracting top/bottom overscroll animation regression.
  final settledPositions = positions.skip(2).toList(growable: false);
  final minimum = settledPositions.reduce((a, b) => a < b ? a : b);
  final maximum = settledPositions.reduce((a, b) => a > b ? a : b);
  expect(maximum - minimum, lessThan(0.2));
}
