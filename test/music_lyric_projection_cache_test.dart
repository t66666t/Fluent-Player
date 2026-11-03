import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_region.dart';

class _ReadCountingCues extends ListBase<SubtitleItem> {
  final List<SubtitleItem> cues;
  int reads = 0;
  _ReadCountingCues(this.cues);
  @override
  int get length => cues.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  SubtitleItem operator [](int index) {
    reads++;
    return cues[index];
  }

  @override
  void operator []=(int index, SubtitleItem value) =>
      throw UnsupportedError('immutable');
}

void main() {
  testWidgets(
    'player layout changes reuse lyric content and source changes invalidate it',
    (tester) async {
      final original = _ReadCountingCues([
        for (var i = 0; i < 1000; i++)
          SubtitleItem(
            index: i,
            startTime: Duration(seconds: i * 5),
            endTime: Duration(seconds: i * 5 + 4),
            text: 'Lyric $i',
            lyricTranslation: '翻译 $i',
          ),
      ]);
      List<SubtitleItem> cues = original;
      var scale = 1.0;
      var spacing = 1.0;
      var split = false;
      var mode = MusicLyricTrackDisplayMode.both;
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicLyricRegion(
              mediaId: 'song',
              subtitles: cues,
              secondarySubtitles: const [],
              splitSubtitleByLine: split,
              preference: mode,
              onPreferenceChanged: (_) {},
              lyricFontSizeScale: scale,
              lyricSpacingScale: spacing,
            ),
          ),
        ),
      );
      await show();
      await tester.pumpAndSettle();
      expect(original.reads, greaterThan(0));
      original.reads = 0;
      scale = 0.9;
      await show();
      await tester.pumpAndSettle();
      expect(
        original.reads,
        0,
        reason: 'resizing must not parse the entire transcript again',
      );
      spacing = 3.123456;
      await show();
      await tester.pumpAndSettle();
      expect(
        original.reads,
        0,
        reason: 'spacing changes must reuse the lyric projection',
      );

      cues = [
        SubtitleItem(
          index: 0,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 5),
          text: 'New original\nNew translation',
        ),
      ];
      await show();
      await tester.pumpAndSettle();
      expect(find.text('New original\nNew translation'), findsOneWidget);
      split = true;
      mode = MusicLyricTrackDisplayMode.secondary;
      await show();
      await tester.pumpAndSettle();
      expect(find.text('New translation'), findsOneWidget);
      expect(find.text('New original\nNew translation'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
