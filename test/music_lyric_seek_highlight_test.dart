import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final playing in [true, false]) {
      testWidgets(
        '$platform forward seek clears departing words without filling them (playing=$playing)',
        (tester) async {
          final lyrics = _SeekLyrics(tester, platform, playing: playing);
          await lyrics.mount();
          final before = await lyrics.wordPeak(1, second: true);
          expect(before, inInclusiveRange(80, 100));
          expect(await lyrics.wordPeak(1), greaterThan(240));

          await lyrics.tap(2);
          expect(lyrics.clock.value, const Duration(seconds: 4));
          expect(await lyrics.wordPeak(1), lessThan(130));
          for (final delta in [0, 16, 64, 80, 240]) {
            await tester.pump(Duration(milliseconds: delta));
            expect(
              await lyrics.wordPeak(1, second: true),
              lessThan(130),
              reason: 'Skipped words must not flash fully lit during the fade',
            );
          }

          lyrics.clock.value = const Duration(milliseconds: 4700);
          await tester.pumpAndSettle();
          expect(await lyrics.wordPeak(2), greaterThan(240));
          expect(
            await lyrics.wordPeak(2, second: true),
            inInclusiveRange(80, 100),
          );
          await lyrics.close();
        },
      );

      testWidgets(
        '$platform backward seek still clears departing words (playing=$playing)',
        (tester) async {
          final lyrics = _SeekLyrics(tester, platform, playing: playing);
          await lyrics.mount();
          expect(await lyrics.wordPeak(1), greaterThan(240));
          await lyrics.tap(0);
          expect(lyrics.clock.value, Duration.zero);
          expect(await lyrics.wordPeak(1), inInclusiveRange(80, 100));
          expect(
            await lyrics.wordPeak(1, second: true),
            inInclusiveRange(80, 100),
          );
          await lyrics.close();
        },
      );
    }

    testWidgets('$platform natural cue completion retains its existing fade', (
      tester,
    ) async {
      final lyrics = _SeekLyrics(tester, platform);
      await lyrics.mount();
      lyrics.clock.value = const Duration(milliseconds: 3890);
      await tester.pump();
      expect(await lyrics.wordPeak(1, second: true), greaterThan(240));
      lyrics.clock.value = const Duration(milliseconds: 3900);
      await tester.pump();
      expect(await lyrics.wordPeak(1, second: true), greaterThan(240));
      await tester.pump(const Duration(milliseconds: 400));
      expect(await lyrics.wordPeak(1, second: true), lessThan(130));
      await lyrics.close();
    });

    testWidgets('$platform seek leaves overlapping singing rows highlighted', (
      tester,
    ) async {
      final lyrics = _SeekLyrics(tester, platform);
      lyrics.cues[0] = SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(milliseconds: 5900),
        text: 'MMMM NNNN 0',
        timedSpans: const [
          SubtitleTimedSpan(
            textStart: 0,
            textEnd: 4,
            startTime: Duration.zero,
            endTime: Duration(milliseconds: 2600),
          ),
          SubtitleTimedSpan(
            textStart: 5,
            textEnd: 9,
            startTime: Duration(milliseconds: 3100),
            endTime: Duration(milliseconds: 5900),
          ),
        ],
      );
      await lyrics.mount();
      expect(await lyrics.wordPeak(0), greaterThan(240));
      await lyrics.tap(2);
      expect(await lyrics.wordPeak(0), greaterThan(240));
      expect(await lyrics.wordPeak(1, second: true), lessThan(130));
      await lyrics.close();
    });

    testWidgets('$platform returning to a skipped row restores timed words', (
      tester,
    ) async {
      final lyrics = _SeekLyrics(tester, platform);
      await lyrics.mount();
      await lyrics.tap(2);
      await tester.pumpAndSettle();
      await lyrics.tap(1);
      await tester.pump(const Duration(milliseconds: 130));
      expect(lyrics.clock.value, const Duration(seconds: 2));
      lyrics.clock.value = const Duration(milliseconds: 2700);
      await tester.pumpAndSettle();
      expect(await lyrics.wordPeak(1), greaterThan(240));
      expect(await lyrics.wordPeak(1, second: true), inInclusiveRange(80, 100));
      await lyrics.close();
    });

    testWidgets('$platform rapid seeks clear each departing row', (
      tester,
    ) async {
      final lyrics = _SeekLyrics(tester, platform);
      await lyrics.mount();
      await lyrics.tap(2);
      expect(await lyrics.wordPeak(1, second: true), lessThan(130));
      lyrics.clock.value = const Duration(milliseconds: 4700);
      await tester.pump();
      await lyrics.tap(3);
      await tester.pump(const Duration(milliseconds: 130));
      expect(lyrics.clock.value, const Duration(seconds: 6));
      expect(await lyrics.wordPeak(2, second: true), lessThan(130));
      expect(await lyrics.wordPeak(1, second: true), lessThan(130));
      await lyrics.close();
    });

    testWidgets('$platform delayed seek clears words when the clock arrives', (
      tester,
    ) async {
      final lyrics = _SeekLyrics(tester, platform, applySeek: false);
      await lyrics.mount();
      await lyrics.tap(2);
      lyrics.clock.value = const Duration(milliseconds: 2750);
      await tester.pump();
      expect(await lyrics.wordPeak(1), greaterThan(240));
      lyrics.clock.value = const Duration(seconds: 4);
      await tester.pump();
      expect(await lyrics.wordPeak(1, second: true), lessThan(130));
      await lyrics.close();
    });

    testWidgets('$platform unacknowledged seek preserves natural completion', (
      tester,
    ) async {
      final lyrics = _SeekLyrics(tester, platform, applySeek: false);
      await lyrics.mount();
      await lyrics.tap(2);
      lyrics.clock.value = const Duration(milliseconds: 3890);
      await tester.pump();
      expect(await lyrics.wordPeak(1, second: true), greaterThan(240));
      lyrics.clock.value = const Duration(milliseconds: 3900);
      await tester.pump();
      expect(await lyrics.wordPeak(1, second: true), greaterThan(240));
      await lyrics.close();
    });

    testWidgets(
      '$platform seek clears background, translation and romanization',
      (tester) async {
        final lyrics = _SeekLyrics(tester, platform);
        final original = lyrics.cues[1];
        final spans = original.timedSpans;
        lyrics.cues[1] = SubtitleItem(
          index: original.index,
          startTime: original.startTime,
          endTime: original.endTime,
          text: '${original.text}\nBBBB CCCC',
          timedSpans: [
            ...spans,
            for (final span in spans)
              SubtitleTimedSpan(
                textStart: span.textStart + 12,
                textEnd: span.textEnd + 12,
                startTime: span.startTime,
                endTime: span.endTime,
                role: 'x-bg',
              ),
          ],
          lyricTranslation: 'DDDD EEEE',
          lyricTranslationSpans: spans,
          lyricRomanization: 'FFFF GGGG',
          lyricRomanizationSpans: spans,
        );
        await lyrics.mount();
        final fragments = ['BBBB CCCC', 'DDDD EEEE', 'FFFF GGGG'];
        final before = {
          for (final text in fragments)
            text: await lyrics.wordPeak(1, second: true, text: text),
        };
        await lyrics.tap(2);
        for (final text in fragments) {
          expect(
            await lyrics.wordPeak(1, second: true, text: text),
            lessThanOrEqualTo(before[text]! + 10),
            reason: '$text must clear with the main lyric',
          );
        }
        await lyrics.close();
      },
    );

    testWidgets('$platform replacing lyrics resets skipped-row state', (
      tester,
    ) async {
      final lyrics = _SeekLyrics(tester, platform);
      await lyrics.mount();
      await lyrics.tap(2);
      await tester.pumpAndSettle();
      lyrics.cues = [
        for (final cue in lyrics.cues)
          SubtitleItem(
            index: cue.index,
            startTime: cue.startTime + const Duration(seconds: 1),
            endTime: cue.endTime + const Duration(seconds: 1),
            text: cue.text,
            timedSpans: [
              for (final span in cue.timedSpans)
                span.shifted(const Duration(seconds: 1)),
            ],
          ),
      ];
      await lyrics.show();
      await tester.pumpAndSettle();
      expect(await lyrics.wordPeak(1), greaterThan(240));
      await lyrics.close();
    });

    testWidgets('$platform appended secondary rows preserve the skipped lyric', (
      tester,
    ) async {
      final lyrics = _SeekLyrics(tester, platform);
      lyrics.cues[0] = SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
        text: 'MMMM NNNN 0',
      );
      lyrics.cues = (SubtitleCueBuffer()..addAll(lyrics.cues)).snapshot;
      final secondary = SubtitleCueBuffer();
      lyrics.secondary = secondary.snapshot;
      await lyrics.mount();
      await lyrics.tap(2);
      await tester.pumpAndSettle();
      final before = await lyrics.textInk(1);
      secondary.addAll([
        SubtitleItem(
          index: 0,
          startTime: const Duration(milliseconds: 1600),
          endTime: const Duration(milliseconds: 1700),
          text: 'An independent secondary lyric',
        ),
      ]);
      lyrics.secondary = secondary.snapshot;
      await lyrics.show();
      await tester.pumpAndSettle();
      // The secondary row is inserted before the skipped primary row. Its
      // highlight reset must follow the primary cue rather than its old index.
      expect(await lyrics.textInk(1), orderedEquals(before));
      lyrics.clock.value = const Duration(milliseconds: 4700);
      await tester.pumpAndSettle();
      expect(await lyrics.wordPeak(2), greaterThan(240));
      await lyrics.close();
    });
  }
}

class _SeekLyrics {
  _SeekLyrics(
    this.tester,
    this.platform, {
    this.playing = true,
    this.applySeek = true,
  });

  final WidgetTester tester;
  final TargetPlatform platform;
  final bool playing;
  final bool applySeek;
  final clock = ValueNotifier(const Duration(milliseconds: 2700));
  List<SubtitleItem> secondary = const [];
  List<SubtitleItem> cues = List.generate(5, (index) {
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
          textEnd: 9,
          startTime: Duration(milliseconds: start + 900),
          endTime: Duration(milliseconds: start + 1900),
        ),
      ],
    );
  });

  Future<void> mount() async {
    await tester.binding.setSurfaceSize(const Size(900, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(clock.dispose);
    await show();
    await tester.pumpAndSettle();
  }

  Future<void> show() async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: MusicLyricView(
            subtitles: cues,
            secondarySubtitles: secondary,
            positionListenable: clock,
            isPlaying: playing,
            applyEdgeFade: false,
            lyricBlurEnabled: false,
            onSeek: (value) {
              if (applySeek) clock.value = value;
            },
          ),
        ),
      ),
    );
  }

  Future<void> tap(int index) async {
    // The stable viewport owns lyric hit testing while rows are moving.
    await tester.tapAt(tester.getCenter(find.text('MMMM NNNN $index')));
    await tester.pump();
  }

  Future<List<int>> textInk(int index) async {
    final paragraph = find.byWidgetPredicate(
      (widget) =>
          widget is MusicTimedLyricText && widget.text == 'MMMM NNNN $index',
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.descendant(of: paragraph, matching: find.byType(RepaintBoundary)),
    );
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixels = data!.buffer.asUint8List().toList();
      image.dispose();
      return pixels;
    }))!;
  }

  Future<int> wordPeak(int index, {bool second = false, String? text}) async {
    final paragraph = find.byWidgetPredicate(
      (widget) =>
          widget is MusicTimedLyricText &&
          widget.text == (text ?? 'MMMM NNNN $index'),
    );
    final widget = tester.widget<MusicTimedLyricText>(paragraph);
    final context = tester.element(paragraph);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .ancestor(
            of: find
                .ancestor(
                  of: paragraph,
                  matching: find.byType(MusicLyricRowOpacity),
                )
                .first,
            matching: find.byType(RepaintBoundary),
          )
          .first,
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
      TextSelection(baseOffset: second ? 5 : 0, extentOffset: second ? 9 : 4),
    );
    final origin = tester
        .renderObject<RenderBox>(paragraph)
        .localToGlobal(Offset.zero, ancestor: boundary);
    final left = (origin.dx + boxes.first.left + 4).ceil();
    final right = (origin.dx + boxes.last.right - 4).floor();
    final top = origin.dy.floor().clamp(0, boundary.size.height.floor());
    final bottom = (origin.dy + layout.height).ceil();
    layout.dispose();
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      var peak = 0;
      for (var y = top; y < bottom && y < image.height; y++) {
        for (var x = left; x < right && x < image.width; x++) {
          final red = bytes[(y * image.width + x) * 4];
          if (red > peak) peak = red;
        }
      }
      image.dispose();
      return peak;
    }))!;
  }

  Future<void> close() async {
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }
}
