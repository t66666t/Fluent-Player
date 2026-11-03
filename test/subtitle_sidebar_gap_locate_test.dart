import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

const _offset = Duration(seconds: 3);
const _paragraphSize = 3;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final mode in ['list', 'paragraph', 'continuous']) {
    for (final animated in [false, true]) {
      testWidgets('$mode locates silent times with animated=$animated', (
        tester,
      ) async {
        final harness = await _pumpSidebar(tester, mode: mode);
        for (final targetIndex in [0, 40, 79]) {
          harness.key.currentState!.locateToTime(
            harness.subtitles[10].startTime + _offset,
            animated: false,
          );
          await tester.pumpAndSettle();

          final target = harness.gapTime(targetIndex);
          harness.key.currentState!.locateToTime(target, animated: animated);
          await tester.pumpAndSettle();
          harness.expectLocated(tester, targetIndex);
          harness.expectGapHighlight(tester, targetIndex);

          // Native players may report their old position during the seek.
          // Keep the target's reading cursor during that lock too.
          harness.controller.value = harness.controller.value.copyWith(
            isBuffering: !harness.controller.value.isBuffering,
          );
          await tester.pump();
          harness.expectGapHighlight(tester, targetIndex);
          harness.controller.value = harness.controller.value.copyWith(
            position: target,
          );
          await tester.pumpAndSettle();
          harness.expectLocated(tester, targetIndex);
          harness.expectGapHighlight(tester, targetIndex);
        }
      });
    }

    testWidgets('$mode repairs current silent time while paused', (
      tester,
    ) async {
      final harness = await _pumpSidebar(tester, mode: mode);
      for (final targetIndex in [0, 40, 79]) {
        harness.controller.value = harness.controller.value.copyWith(
          position: harness.gapTime(targetIndex),
        );
        // Leave a pending target and lock elsewhere, as a recent seek would.
        harness.key.currentState!.locateToTime(
          harness.subtitles[10].startTime + _offset,
          animated: false,
        );
        await tester.pumpAndSettle();
        expect(
          harness.key.currentState!.locateToCurrentSubtitle(
            ignorePointer: true,
          ),
          isTrue,
        );
        await tester.pumpAndSettle();
        harness.expectLocated(tester, targetIndex);
        harness.expectGapHighlight(tester, targetIndex);
      }
    });

    testWidgets('$mode auto follows silent times and cue endings', (
      tester,
    ) async {
      final harness = await _pumpSidebar(tester, mode: mode, autoFollow: true);
      for (final targetIndex in [40, 79, 0]) {
        harness.controller.value = harness.controller.value.copyWith(
          position: harness.gapTime(targetIndex),
        );
        await tester.pumpAndSettle();
        harness.expectLocated(tester, targetIndex);
        harness.expectGapHighlight(tester, targetIndex);
      }

      harness.controller.value = harness.controller.value.copyWith(
        position: harness.subtitles[40].startTime + _offset,
      );
      await tester.pumpAndSettle();
      // The reading cursor stays on the same cue across its end boundary.
      harness.controller.value = harness.controller.value.copyWith(
        position: harness.subtitles[40].endTime + _offset,
      );
      await tester.pumpAndSettle();
      harness.expectLocated(tester, 40);
      harness.expectHighlight(tester, 40);

      harness.list(tester).itemScrollController!.jumpTo(index: 0);
      await tester.pumpAndSettle();
      harness.key.currentState!.triggerLocateForAutoFollow(animated: true);
      await tester.pumpAndSettle();
      harness.expectLocated(tester, 40);
      harness.expectHighlight(tester, 40);
    });

    for (final isAudio in [false, true]) {
      testWidgets('$mode keeps a continuous reading cursor, audio=$isAudio', (
        tester,
      ) async {
        final harness = await _pumpSidebar(
          tester,
          mode: mode,
          autoFollow: true,
          isAudio: isAudio,
        );
        for (final continuousOverlay in [false, true]) {
          final settings = SettingsService();
          await settings.saveVideoContinuousSubtitle(continuousOverlay);
          await settings.saveAudioContinuousSubtitle(continuousOverlay);
          // Overlay gap filling must not control the transcript's cursor.
          for (final position in [
            harness.subtitles[40].startTime + _offset,
            harness.subtitles[40].endTime + _offset,
            harness.subtitles[41].startTime +
                _offset -
                const Duration(milliseconds: 1),
          ]) {
            harness.controller.value = harness.controller.value.copyWith(
              position: position,
            );
            await tester.pumpAndSettle();
            harness.expectLocated(tester, 40);
            harness.expectHighlight(tester, 40);
          }
          harness.controller.value = harness.controller.value.copyWith(
            position: harness.subtitles[41].startTime + _offset,
          );
          await tester.pumpAndSettle();
          harness.expectLocated(tester, 41);
          harness.expectHighlight(tester, 41);
        }
      });
    }
  }
}

Future<_SidebarHarness> _pumpSidebar(
  WidgetTester tester, {
  required String mode,
  bool autoFollow = false,
  bool isAudio = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'autoScrollSubtitles': autoFollow,
    'subtitleViewMode': mode == 'list' ? 0 : 1,
    'subtitleArticleParagraphModeEnabled': mode != 'continuous',
    'subtitleArticleSentencesPerParagraph': _paragraphSize,
    'portraitSidebarShowTimestamps': true,
    'videoContinuousSubtitle': false,
    'audioContinuousSubtitle': false,
  });
  final settings = SettingsService()..resetForTest();
  await settings.init();
  await settings.saveSubtitleOffsetMilliseconds(_offset.inMilliseconds);
  final controller = VideoPlayerController.networkUrl(
    Uri.parse('https://example.invalid/sidebar-gaps.mp4'),
  );
  controller.value = VideoPlayerValue(
    duration: const Duration(minutes: 10),
    isInitialized: true,
    isPlaying: autoFollow,
  );
  final subtitles = List<SubtitleItem>.generate(80, (index) {
    final start = Duration(seconds: 10 + index * 5);
    return SubtitleItem(
      index: index,
      startTime: start,
      endTime: start + const Duration(seconds: 2),
      text:
          'Sentence $index has enough words to fill a line of the transcript.',
    );
  });
  final key = GlobalKey<SubtitleSidebarState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 380,
            height: 380,
            child: SubtitleSidebar(
              key: key,
              subtitles: subtitles,
              controller: controller,
              isCompact: true,
              isPortrait: true,
              isAudio: isAudio,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _SidebarHarness(key, controller, subtitles, mode);
}

class _SidebarHarness {
  _SidebarHarness(this.key, this.controller, this.subtitles, this.mode);

  final GlobalKey<SubtitleSidebarState> key;
  final VideoPlayerController controller;
  final List<SubtitleItem> subtitles;
  final String mode;

  Duration gapTime(int index) => index == 0
      ? Duration.zero
      : subtitles[index].endTime + const Duration(seconds: 1) + _offset;

  ScrollablePositionedList list(WidgetTester tester) => tester
      .widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));

  void expectLocated(WidgetTester tester, int subtitleIndex) {
    final itemIndex = switch (mode) {
      'list' => subtitleIndex,
      'paragraph' => subtitleIndex ~/ _paragraphSize,
      _ =>
        tester
            .widget<ContinuousArticleView>(find.byType(ContinuousArticleView))
            .layout
            .lineForSentence(subtitleIndex),
    };
    final positions = list(tester).itemPositionsNotifier!.itemPositions.value;
    expect(
      positions.any(
        (item) =>
            item.index == itemIndex &&
            item.itemTrailingEdge > 0 &&
            item.itemLeadingEdge < 1,
      ),
      isTrue,
      reason: '$mode must bring subtitle $subtitleIndex into the viewport',
    );
    expect(tester.takeException(), isNull);
  }

  void expectGapHighlight(WidgetTester tester, int index) {
    // Before the first cue and after the final cue there is no reading cursor.
    expectHighlight(tester, index == 0 || index == 79 ? null : index);
  }

  void expectHighlight(WidgetTester tester, int? index) {
    if (mode == 'continuous') {
      expect(
        tester
            .widget<ContinuousArticleView>(find.byType(ContinuousArticleView))
            .activeIndices
            .value,
        index == null ? isEmpty : orderedEquals([index]),
      );
    } else if (mode == 'paragraph') {
      final chunks = tester.widgetList<SubtitleArticleChunk>(
        find.byType(SubtitleArticleChunk),
      );
      expect(chunks, isNotEmpty);
      if (index != null) {
        expect(
          chunks.any(
            (chunk) => index >= chunk.startIndex && index < chunk.endIndex,
          ),
          isTrue,
          reason: 'The highlighted paragraph must be mounted',
        );
      }
      for (final chunk in chunks) {
        // Each paragraph now subscribes to its own highlight range. Verify both
        // the visible highlight and the absence of highlights in other chunks.
        expect(chunk.activeIndices, {
          if (index != null &&
              index >= chunk.startIndex &&
              index < chunk.endIndex)
            index,
        });
      }
    } else {
      final timestamps = tester.widgetList<Text>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'subtitle-time-',
              ),
        ),
      );
      expect(timestamps, isNotEmpty);
      if (index != null) {
        expect(
          tester
              .widget<Text>(find.byKey(ValueKey('subtitle-time-$index')))
              .style
              ?.color,
          Colors.blueAccent,
        );
      }
      for (final timestamp in timestamps) {
        final isCurrent = timestamp.key == ValueKey('subtitle-time-$index');
        expect(
          timestamp.style?.color,
          isCurrent ? Colors.blueAccent : isNot(Colors.blueAccent),
        );
      }
    }
  }
}
