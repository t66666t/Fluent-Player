import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      '$platform paused lyric seek ignores intermediate native samples',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final clock = ValueNotifier(const Duration(seconds: 10));
        addTearDown(clock.dispose);
        final seeks = <Duration>[];
        final cues = List.generate(
          30,
          (i) => SubtitleItem(
            index: i,
            startTime: Duration(seconds: i * 5),
            endTime: Duration(seconds: i * 5 + 5),
            text: 'Lyric line $i',
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: MusicLyricView(
                subtitles: cues,
                positionListenable: clock,
                onSeek: seeks.add,
                isPlaying: false,
                wordByWordEnabled: false,
                lyricBlurEnabled: false,
                applyEdgeFade: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final line = find.text('Lyric line 4');
        await tester.tapAt(tester.getTopLeft(line) + const Offset(15, 12));
        await tester.pump();
        expect(seeks, [const Duration(seconds: 20)]);
        final positions = <double>[tester.getTopLeft(line).dy];
        for (var frame = 1; frame <= 190; frame++) {
          if (frame == 8) clock.value = const Duration(milliseconds: 19920);
          if (frame == 16) clock.value = const Duration(seconds: 20);
          if (frame == 55) clock.value = const Duration(milliseconds: 19960);
          if (frame == 72) clock.value = const Duration(seconds: 20);
          await tester.pump(const Duration(microseconds: 6944));
          positions.add(tester.getTopLeft(line).dy);
        }
        final direction = (positions.last - positions.first).sign;
        for (var i = 1; i < positions.length; i++) {
          expect(
            (positions[i] - positions[i - 1]) * direction,
            greaterThanOrEqualTo(-0.15),
            reason:
                'frame $i reversed during one direct tap: ${positions[i - 1]} -> ${positions[i]}',
          );
        }
        expect(positions.last, closeTo(700 * .3, .3));
        expect(
          seeks.length,
          1,
          reason: 'visual continuity must not add media seeks',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
