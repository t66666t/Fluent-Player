import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/video_compose/video_compose_timeline.dart';

void main() {
  test('sweep preserves overlapping unsorted bilingual cue selection', () {
    final random = Random(42);
    for (var iteration = 0; iteration < 25; iteration++) {
      List<SubtitleItem> track() => List.generate(60, (i) {
        final start = random.nextInt(1200) - 100;
        return _cue(i, start, start + random.nextInt(250), 'cue $i');
      })..shuffle(random);
      final primary = track(), secondary = track();
      final segments = buildComposeTimeline(
        duration: const Duration(milliseconds: 1000),
        primary: primary,
        secondary: secondary,
        splitSubtitleByLine: false,
      );
      expect(segments.first.startMs, 0);
      expect(segments.last.endMs, 1000);
      for (final scene in segments) {
        final activePrimary = primary
            .where(
              (cue) =>
                  cue.startTime.inMilliseconds <= scene.startMs &&
                  cue.endTime.inMilliseconds > scene.startMs,
            )
            .toList();
        final activeSecondary = secondary
            .where(
              (cue) =>
                  cue.startTime.inMilliseconds <= scene.startMs &&
                  cue.endTime.inMilliseconds > scene.startMs,
            )
            .toList();
        if (activePrimary.isEmpty) {
          expect(
            scene.entries.map((e) => e.secondaryText),
            activeSecondary.map((e) => e.text),
          );
          continue;
        }
        expect(
          scene.entries.map((e) => e.text),
          activePrimary.map((e) => e.text),
        );
        for (var i = 0; i < activePrimary.length; i++) {
          final current = activePrimary[i];
          final sorted = [...activeSecondary]
            ..sort(
              (a, b) => (a.startTime - current.startTime).inMilliseconds
                  .abs()
                  .compareTo(
                    (b.startTime - current.startTime).inMilliseconds.abs(),
                  ),
            );
          expect(
            scene.entries[i].secondaryText,
            sorted.isEmpty ? null : sorted.first.text,
          );
        }
      }
    }
  });
  test(
    'duplicate text ignores cue numbers while image cues keep distinct identities',
    () {
      final scenes = buildComposeTimeline(
        duration: const Duration(seconds: 2),
        primary: [_cue(1, 0, 500, 'same'), _cue(2, 500, 1000, 'same')],
        secondary: [],
        splitSubtitleByLine: true,
      );
      expect(scenes, hasLength(2));
      expect(scenes.first.endMs, 1000);
      final images = buildComposeTimeline(
        duration: const Duration(seconds: 1),
        primary: [
          SubtitleItem(
            index: 1,
            startTime: Duration.zero,
            endTime: const Duration(milliseconds: 500),
            text: '',
            imageLoader: () async => Uint8List.fromList([1]),
          ),
          SubtitleItem(
            index: 1,
            startTime: const Duration(milliseconds: 500),
            endTime: const Duration(seconds: 1),
            text: '',
            imageLoader: () async => Uint8List.fromList([2]),
          ),
        ],
        secondary: [],
        splitSubtitleByLine: false,
      );
      expect(images, hasLength(2));
      expect(images.first.signature, isNot(images.last.signature));
    },
  );
  test('signature cannot collide on text delimiters, null or literal null', () {
    final scenes = buildComposeTimeline(
      duration: const Duration(seconds: 1),
      primary: [
        _cue(0, 0, 500, 'a|b\u001enull'),
        _cue(0, 500, 1000, 'a|b\u001e'),
      ],
      secondary: [],
      splitSubtitleByLine: false,
    );
    expect(scenes, hasLength(2));
    expect(scenes.first.signature, isNot(scenes.last.signature));
  });
  test(
    'invalid cues are excluded and unknown duration uses the last cue end',
    () {
      final scenes = buildComposeTimeline(
        duration: Duration.zero,
        primary: [
          _cue(0, -100, 50, 'first\nsecond'),
          _cue(1, 80, 70, 'invalid'),
        ],
        secondary: [_cue(2, 100, 200, 'translation')],
        splitSubtitleByLine: true,
      );
      expect(scenes.first.startMs, 0);
      expect(scenes.first.entries.single.text, 'first');
      expect(scenes.first.entries.single.secondaryText, 'second');
      expect(scenes[1].entries, isEmpty);
      expect(scenes.last.endMs, 200);
      expect(scenes.last.entries.single.secondaryText, 'translation');
    },
  );
  test('large tracks retain only active cues without quadratic rescanning', () {
    final cues = List.generate(
      20000,
      (i) => _cue(i, i * 1000, i * 1000 + 900, '$i'),
    );
    final watch = Stopwatch()..start();
    final scenes = buildComposeTimeline(
      duration: Duration.zero,
      primary: cues,
      secondary: [],
      splitSubtitleByLine: false,
    );
    watch.stop();
    expect(scenes, hasLength(39999));
    expect(scenes.last.entries.single.text, '19999');
    // An intentionally broad guard catches accidentally reintroducing N² work.
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    // ignore: avoid_print
    print('20,000 cues / 39,999 scenes: ${watch.elapsedMilliseconds} ms');
  });
}

SubtitleItem _cue(int id, int start, int end, String text) => SubtitleItem(
  index: id,
  startTime: Duration(milliseconds: start),
  endTime: Duration(milliseconds: end),
  text: text,
);
