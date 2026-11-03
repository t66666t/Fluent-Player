import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
    testWidgets(
      '$platform upcoming rows keep their size under a stationary mouse',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final clock = ValueNotifier(Duration.zero);
        addTearDown(clock.dispose);
        final cues = List.generate(
          12,
          (i) => SubtitleItem(
            index: i,
            startTime: Duration(seconds: i * 5),
            endTime: Duration(seconds: i * 5 + 4),
            text: 'Upcoming lyric $i',
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: MusicLyricView(
                subtitles: cues,
                positionListenable: clock,
                isPlaying: true,
                applyEdgeFade: false,
                onSeek: (value) => clock.value = value,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        double paintedWidth(int index) {
          final box = tester.renderObject<RenderBox>(
            find.text('Upcoming lyric $index'),
          );
          return (box.localToGlobal(Offset(box.size.width, 0)) -
                  box.localToGlobal(Offset.zero))
              .distance;
        }

        final before = paintedWidth(2);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(find.text('Upcoming lyric 2')));
        for (var frame = 0; frame < 50; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(paintedWidth(2), closeTo(before, 0.01));
        }
        // Autoscroll moves a different row underneath that same cursor. The
        // upcoming row must not grow when its hover/dynamic-window state changes.
        clock.value = const Duration(seconds: 5);
        var previousTop = tester.getTopLeft(find.text('Upcoming lyric 1')).dy;
        for (var frame = 0; frame < 60; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(paintedWidth(2), closeTo(before, 0.01));
          final top = tester.getTopLeft(find.text('Upcoming lyric 1')).dy;
          expect(
            top,
            lessThanOrEqualTo(previousTop + 0.1),
            reason:
                'automatic follow should approach the anchor without reversing',
          );
          previousTop = top;
        }
        expect(previousTop, closeTo(800 * 0.3, 0.2));
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
