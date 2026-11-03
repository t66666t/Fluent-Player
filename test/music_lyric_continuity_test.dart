import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

void main() {
  testWidgets(
    'cue activation dims unplayed ink immediately and deactivation fades it back',
    (tester) async {
      final dim = ValueNotifier(false);
      addTearDown(dim.dispose);
      final key = GlobalKey();
      final spans = [
        SubtitleTimedSpan(
          textStart: 0,
          textEnd: 5,
          startTime: const Duration(seconds: 10),
          endTime: const Duration(seconds: 12),
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 300,
                child: ValueListenableBuilder<bool>(
                  valueListenable: dim,
                  builder: (context, value, _) => MusicTimedLyricText(
                    text: 'Hello',
                    spans: spans,
                    dimUnplayed: value,
                    style: const TextStyle(fontSize: 40, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<int> ink() async => (await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final bytes = data!.buffer.asUint8List();
        var brightness = 0;
        for (var i = 0; i < bytes.length; i += 4) {
          brightness += bytes[i];
        }
        image.dispose();
        return brightness;
      }))!;
      final before = await ink();
      dim.value = true;
      await tester.pump();
      expect(await ink() / before, closeTo(0.35, 0.02));
      // Activation deliberately dims immediately, also covered by the next
      // word-line regression. Only deactivation interpolates the dim alpha.
      dim.value = false;
      await tester.pump();
      expect(await ink() / before, closeTo(0.35, 0.02));
      await tester.pump(const Duration(milliseconds: 160));
      final during = await ink();
      expect(during, lessThan(before));
      expect(during, greaterThan(before * 0.35));
      await tester.pumpAndSettle();
      expect(await ink() / before, closeTo(1, 0.02));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'gap focus starts the departing line depth with the scroll and does not restart at the next cue',
    (tester) async {
      final clock = ValueNotifier(Duration.zero);
      addTearDown(clock.dispose);
      final cues = List.generate(
        4,
        (i) => SubtitleItem(
          index: i,
          startTime: Duration(seconds: i * 5),
          endTime: Duration(seconds: i * 5 + 4),
          text: 'Gap lyric $i',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: MusicLyricView(subtitles: cues, positionListenable: clock),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final depth = find.ancestor(
        of: find.text('Gap lyric 0'),
        matching: find.byType(MusicLyricDepth),
      );
      clock.value = const Duration(milliseconds: 4100);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      final inGap = tester.widget<MusicLyricDepth>(depth);
      expect(inGap.distance, -1);
      expect(inGap.active, isFalse);
      clock.value = const Duration(seconds: 5);
      await tester.pump();
      final singing = tester.widget<MusicLyricDepth>(depth);
      expect(singing.distance, inGap.distance);
      expect(singing.active, inGap.active);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('continuous viewport updates do not starve the row spring', (
    tester,
  ) async {
    final motion = MusicLyricFollowMotion()..enabled = true;
    addTearDown(motion.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MusicLyricFollow(
          motion: motion,
          distance: 1,
          child: const Text('Moving lyric'),
        ),
      ),
    );
    final line = find.text('Moving lyric');
    final initialTop = tester.getTopLeft(line).dy;
    final offsets = <double>[];
    for (var frame = 0; frame < 70; frame++) {
      motion.advance(2);
      await tester.pump(const Duration(milliseconds: 16));
      offsets.add(tester.getTopLeft(line).dy - initialTop);
    }
    expect(
      offsets.last,
      lessThan(18),
      reason:
          'steady motion must be followed while it is moving, rather than after it stops',
    );
    for (var frame = 25; frame < offsets.length; frame++) {
      expect((offsets[frame] - offsets[frame - 1]).abs(), lessThan(0.3));
    }
    await tester.pumpAndSettle();
    expect((tester.getTopLeft(line).dy - initialTop).abs(), lessThan(0.05));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'focus reversal preserves blur velocity instead of restarting at rest',
    (tester) async {
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (context, selected, _) => MusicLyricDepth(
              active: selected,
              distance: 2,
              browsing: false,
              child: const Text('Focus lyric'),
            ),
          ),
        ),
      );
      double blur() {
        final value = tester
            .widget<ImageFiltered>(find.byType(ImageFiltered))
            .imageFilter
            .toString();
        return double.parse(
          RegExp(r'blur\(([^,]+),').firstMatch(value)!.group(1)!,
        );
      }

      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 152));
      final before = blur();
      await tester.pump(const Duration(milliseconds: 8));
      final atRetarget = blur();
      final incomingDelta = atRetarget - before;
      active.value = false;
      await tester.pump();
      expect(blur(), closeTo(atRetarget, 0.00001));
      await tester.pump(const Duration(milliseconds: 8));
      final outgoingDelta = blur() - atRetarget;
      expect(
        outgoingDelta,
        lessThan(0),
        reason:
            'momentum must decelerate continuously when the destination changes',
      );
      expect((outgoingDelta - incomingDelta).abs(), lessThan(0.008));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
