import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      '$platform word activation keeps brightness continuous without a flash',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 650));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final clock = ValueNotifier(const Duration(milliseconds: 1700));
        addTearDown(clock.dispose);
        final cues = List.generate(8, (index) {
          final start = index * 2000;
          return SubtitleItem(
            index: index,
            startTime: Duration(milliseconds: start),
            endTime: Duration(milliseconds: start + 1900),
            text: 'MMMM NNNN $index',
            timedSpans: [
              SubtitleTimedSpan(
                textStart: 0,
                textEnd: 4,
                startTime: Duration(milliseconds: start),
                endTime: Duration(milliseconds: start + 600),
              ),
              SubtitleTimedSpan(
                textStart: 5,
                textEnd: 11,
                startTime: Duration(milliseconds: start + 900),
                endTime: Duration(milliseconds: start + 1900),
              ),
            ],
          );
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              backgroundColor: Colors.black,
              body: MusicLyricView(
                subtitles: cues,
                positionListenable: clock,
                isPlaying: false,
                applyEdgeFade: false,
                lyricBlurEnabled: false,
                onSeek: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Finder paragraph(int index) => find.byWidgetPredicate(
          (widget) =>
              widget is MusicTimedLyricText &&
              widget.text == 'MMMM NNNN $index',
        );
        // Far visible rows keep their real timings too; entering the active
        // window must not replace a sentence-only, fully lit paragraph.
        for (final widget in tester.widgetList<MusicTimedLyricText>(
          find.byType(MusicTimedLyricText),
        )) {
          expect(widget.spans, isNotEmpty);
          expect(widget.position, same(clock));
        }
        Future<int> peak({bool secondWordOnly = false}) async {
          final finder = paragraph(1);
          final widget = tester.widget<MusicTimedLyricText>(finder);
          final context = tester.element(finder);
          // Capture outside the row fade: inner text alone cannot detect a
          // brightness dip caused by multiplying word and row opacity.
          final boundaryFinder = find
              .ancestor(
                of: find.byKey(const ValueKey('music-lyric-row-opacity-1')),
                matching: find.byType(RepaintBoundary),
              )
              .first;
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            boundaryFinder,
          );
          final layout = TextPainter(
            text: TextSpan(
              text: widget.text,
              style: DefaultTextStyle.of(context).style.merge(widget.style),
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: boundary.size.width);
          final boxes = layout.getBoxesForSelection(
            const TextSelection(baseOffset: 5, extentOffset: 9),
          );
          final textOrigin = tester
              .renderObject<RenderBox>(finder)
              .localToGlobal(Offset.zero, ancestor: boundary);
          final left = secondWordOnly
              ? (textOrigin.dx + boxes.first.left + 4).ceil()
              : 0;
          final right = secondWordOnly
              ? (textOrigin.dx + boxes.last.right - 4).floor()
              : boundary.size.width.floor();
          layout.dispose();
          return (await tester.runAsync(() async {
            final image = await boundary.toImage();
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final bytes = data!.buffer.asUint8List();
            var result = 0;
            for (var y = 0; y < image.height; y++) {
              for (var x = left; x < right && x < image.width; x++) {
                final red = bytes[(y * image.width + x) * 4];
                if (red > result) result = red;
              }
            }
            image.dispose();
            return result;
          }))!;
        }

        expect(
          await peak(),
          inInclusiveRange(80, 95),
          reason: 'inactive rows must not receive extra word-level dimming',
        );
        clock.value = const Duration(milliseconds: 2000);
        await tester.pump();
        expect(
          await peak(),
          inInclusiveRange(80, 95),
          reason: 'cue activation must neither dim nor flash the whole line',
        );
        for (var step = 1; step <= 25; step++) {
          clock.value = Duration(milliseconds: 2000 + step * 16);
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            await peak(secondWordOnly: true),
            inInclusiveRange(80, 100),
            reason: 'unplayed second word dipped or flashed at step $step',
          );
        }
        expect(
          await peak(),
          greaterThan(160),
          reason: 'the sung first word still lights progressively',
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
