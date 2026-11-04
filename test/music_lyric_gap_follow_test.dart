import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

SubtitleItem cue(
  int index,
  int startMs,
  int endMs, {
  int? wordEndMs,
  bool partial = false,
}) {
  final text = 'Gap lyric $index';
  return SubtitleItem(
    index: index,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
    text: text,
    timedSpans: wordEndMs == null
        ? const []
        : [
            SubtitleTimedSpan(
              textStart: 0,
              textEnd: partial ? 3 : text.length,
              startTime: Duration(milliseconds: startMs),
              endTime: Duration(milliseconds: wordEndMs),
            ),
          ],
  );
}

void main() {
  Future<void> show(
    WidgetTester tester,
    TargetPlatform platform,
    ValueNotifier<Duration> clock,
    List<SubtitleItem> cues,
    List<Duration> seeks,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: MusicLyricView(
            subtitles: cues,
            positionListenable: clock,
            isPlaying: false,
            applyEdgeFade: false,
            onSeek: seeks.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, int index) =>
      tester.getTopLeft(find.text('Gap lyric $index')).dy;
  double opacity(WidgetTester tester, int index) => tester
      .widget<AnimatedOpacity>(
        find.byKey(ValueKey('music-lyric-row-opacity-$index')),
      )
      .opacity;

  for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
    for (final words in [false, true]) {
      testWidgets(
        '$platform ${words ? 'word completion' : 'sentence end'} locates the next line before it starts',
        (tester) async {
          final clock = ValueNotifier(const Duration(milliseconds: 1999));
          addTearDown(clock.dispose);
          final seeks = <Duration>[];
          await show(tester, platform, clock, [
            cue(0, 0, words ? 4000 : 2000, wordEndMs: words ? 2000 : null),
            cue(1, 5000, 7000),
            cue(2, 10000, 12000),
          ], seeks);
          expect(top(tester, 0), closeTo(180, 0.2));
          clock.value = const Duration(milliseconds: 2000);
          await tester.pumpAndSettle();
          expect(top(tester, 1), closeTo(180, 0.2));
          expect(opacity(tester, 1), lessThan(1));
          expect(seeks, isEmpty);
          final waitingTop = top(tester, 1);
          clock.value = const Duration(milliseconds: 4999);
          await tester.pumpAndSettle();
          expect(top(tester, 1), closeTo(waitingTop, 0.01));
          clock.value = const Duration(milliseconds: 5000);
          await tester.pumpAndSettle();
          expect(top(tester, 1), closeTo(waitingTop, 0.01));
          expect(opacity(tester, 1), 1);
          // A seek backwards reselects the singing line instead of retaining
          // the previously prepared row. Entering a gap again prepares it again.
          clock.value = const Duration(milliseconds: 1000);
          await tester.pumpAndSettle();
          expect(top(tester, 0), closeTo(180, 0.2));
          clock.value = const Duration(milliseconds: 3000);
          await tester.pumpAndSettle();
          expect(top(tester, 1), closeTo(180, 0.2));
          expect(seeks, isEmpty);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      '$platform waits for overlapping vocals and retains the final line',
      (tester) async {
        final clock = ValueNotifier(const Duration(milliseconds: 1500));
        addTearDown(clock.dispose);
        final seeks = <Duration>[];
        await show(tester, platform, clock, [
          cue(0, 0, 8000, wordEndMs: 8000),
          cue(1, 1000, 2000, wordEndMs: 2000),
          cue(2, 10000, 12000),
        ], seeks);
        clock.value = const Duration(milliseconds: 2000);
        await tester.pumpAndSettle();
        expect(top(tester, 1), closeTo(180, 0.2));
        clock.value = const Duration(milliseconds: 8000);
        await tester.pumpAndSettle();
        expect(top(tester, 2), closeTo(180, 0.2));
        expect(opacity(tester, 2), lessThan(1));
        clock.value = const Duration(seconds: 100);
        await tester.pumpAndSettle();
        expect(top(tester, 2), closeTo(180, 0.2));
        expect(seeks, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$platform initial paused gap and partial timings respect the sentence end',
      (tester) async {
        final clock = ValueNotifier(const Duration(milliseconds: 2500));
        addTearDown(clock.dispose);
        final seeks = <Duration>[];
        final cues = [
          cue(0, 0, 4000, wordEndMs: 2000, partial: true),
          cue(1, 6000, 8000),
        ];
        await show(tester, platform, clock, cues, seeks);
        expect(top(tester, 0), closeTo(180, 0.2));
        // Reenter the page while paused in a genuine gap.
        await tester.pumpWidget(const SizedBox.shrink());
        clock.value = const Duration(milliseconds: 4500);
        await show(tester, platform, clock, cues, seeks);
        expect(top(tester, 1), closeTo(180, 0.2));
        expect(opacity(tester, 1), lessThan(1));
        expect(seeks, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
