import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/subtitle_timeline_resolver.dart';
import 'package:video_player_app/widgets/transcript_cue_window.dart';

SubtitleItem cue(int index, int start, int end) => SubtitleItem(
  index: index,
  startTime: Duration(milliseconds: start),
  endTime: Duration(milliseconds: end),
  text: 'Subtitle $index',
);

void main() {
  test('steady reading reuses its cursor at 24 through 240 Hz', () {
    final subtitles = [cue(0, 0, 3000), cue(1, 4000, 6000)];
    final resolver = SubtitleTimelineResolver(subtitles);
    for (final hz in [24, 60, 90, 120, 144, 240]) {
      final window = TranscriptCueWindow();
      final first = window.activeIndicesAtMs(resolver, subtitles, 1000);
      expect(first, [0]);
      for (var frame = 1; frame < hz; frame++) {
        expect(
          window.activeIndicesAtMs(
            resolver,
            subtitles,
            1000 + (1000 * frame / hz).floor(),
          ),
          same(first),
          reason: 'An unchanged cue must not allocate a cursor every frame.',
        );
      }
    }
  });

  test('overlaps, duplicate boundaries, gaps and reverse seeks stay exact', () {
    final subtitles = [
      cue(0, 100, 1500),
      cue(1, 100, 1500),
      cue(2, 200, 450),
      cue(3, 700, 1100),
      cue(4, 2000, 2300),
      cue(5, 2000, 2000),
      cue(6, 3000, 3100),
      cue(7, 3000, 4100),
    ];
    final resolver = SubtitleTimelineResolver(subtitles);
    final window = TranscriptCueWindow();
    final random = Random(104);
    final times = [
      ...List.generate(4500, (i) => i - 200),
      ...List.generate(4500, (i) => 4300 - i),
      ...List.generate(1000, (_) => random.nextInt(5000) - 200),
    ];
    for (final ms in times) {
      expect(
        window.activeIndicesAtMs(resolver, subtitles, ms),
        resolver.activeIndicesAtMs(ms, extendToNextStart: true),
        reason: 'Reading cursor differs at $ms ms.',
      );
    }
  });

  test('appending invalidates an open-ended trailing gap', () {
    final subtitles = [cue(0, 0, 500)];
    final resolver = SubtitleTimelineResolver(subtitles);
    final window = TranscriptCueWindow();
    expect(window.activeIndicesAtMs(resolver, subtitles, 1500), isEmpty);
    subtitles.add(cue(1, 2000, 2500));
    resolver.append(subtitles);
    expect(window.activeIndicesAtMs(resolver, subtitles, 1500), [0]);
    expect(window.activeIndicesAtMs(resolver, subtitles, 2000), [1]);
  });

  test('replacement and empty transcripts invalidate the previous cursor', () {
    final subtitles = [cue(0, 0, 1500)];
    final window = TranscriptCueWindow();
    final old = SubtitleTimelineResolver(subtitles);
    expect(window.activeIndicesAtMs(old, subtitles, 1000), [0]);
    final replacement = [cue(0, 2000, 2500)];
    expect(
      window.activeIndicesAtMs(
        SubtitleTimelineResolver(replacement),
        replacement,
        1001,
      ),
      isEmpty,
    );
    final empty = <SubtitleItem>[];
    expect(
      window.activeIndicesAtMs(SubtitleTimelineResolver(empty), empty, 1002),
      isEmpty,
    );
  });
}
