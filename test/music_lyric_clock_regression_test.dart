import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/widgets/music_lyric_frame_coordinator.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

SubtitleItem _cue(int index, int start, int end) => SubtitleItem(
  index: index,
  startTime: Duration(milliseconds: start),
  endTime: Duration(milliseconds: end),
  text: 'Line $index',
  timedSpans: [
    SubtitleTimedSpan(
      textStart: 0,
      textEnd: 6,
      startTime: Duration(milliseconds: start),
      endTime: Duration(milliseconds: end),
    ),
  ],
);

void main() {
  test(
    'cached dispatch tolerates disposal and registration during notification',
    () {
      final source = ValueNotifier(Duration.zero);
      addTearDown(source.dispose);
      final frames = MusicLyricFrameCoordinator(source);
      final first = frames.register(0);
      final removed = frames.register(1);
      final added = frames.register(2);
      addTearDown(first.dispose);
      addTearDown(added.dispose);
      var removedCalls = 0;
      var addedCalls = 0;
      var replaced = false;
      first.addListener(() {
        if (replaced) return;
        replaced = true;
        removed.dispose();
        added.addListener(() => addedCalls++);
      });
      removed.addListener(() => removedCalls++);
      frames.publishPosition();
      expect(removedCalls, 0);
      expect(addedCalls, 0);
      frames.publishPosition();
      expect(addedCalls, 1);
      frames.setVisibleRange(20, 21);
      frames.publishPosition();
      expect(addedCalls, 1);
      frames.setVisibleRange(1, 2);
      expect(addedCalls, 2);
      frames.publishPosition();
      expect(addedCalls, 3);
    },
  );

  testWidgets(
    'precise line windows respect overlapping ends and backwards seeks',
    (tester) async {
      final clock = ValueNotifier(const Duration(milliseconds: 2500));
      addTearDown(clock.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: MusicLyricView(
              subtitles: [
                _cue(0, 1000, 4000),
                _cue(1, 2000, 3000),
                _cue(2, 5000, 7000),
              ],
              positionListenable: clock,
              lyricBlurEnabled: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      bool singing(int index) => tester
          .widget<MusicTimedLyricText>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is MusicTimedLyricText && widget.text == 'Line $index',
            ),
          )
          .dimUnplayed;
      expect(singing(0), isTrue);
      expect(singing(1), isTrue);
      clock.value = const Duration(milliseconds: 3100);
      await tester.pumpAndSettle();
      expect(singing(0), isTrue);
      expect(singing(1), isFalse);
      clock.value = const Duration(milliseconds: 4100);
      await tester.pumpAndSettle();
      expect(singing(0), isFalse);
      expect(singing(1), isFalse);
      clock.value = const Duration(seconds: 60);
      await tester.pumpAndSettle();
      clock.value = const Duration(milliseconds: 1500);
      await tester.pumpAndSettle();
      expect(singing(0), isTrue);
      expect(singing(1), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('stream append invalidates a cached open-ended lyric gap', (
    tester,
  ) async {
    final clock = ValueNotifier(const Duration(milliseconds: 5500));
    addTearDown(clock.dispose);
    final buffer = SubtitleCueBuffer()..addAll([_cue(0, 1000, 2000)]);
    Future<void> show() => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: MusicLyricView(
            subtitles: buffer.snapshot,
            positionListenable: clock,
            lyricBlurEnabled: false,
          ),
        ),
      ),
    );
    await show();
    await tester.pumpAndSettle();
    buffer.addAll([_cue(1, 5000, 7000)]);
    await show();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MusicTimedLyricText>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is MusicTimedLyricText && widget.text == 'Line 1',
            ),
          )
          .dimUnplayed,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
