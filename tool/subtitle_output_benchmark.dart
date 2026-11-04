// Run with `dart compile exe` for native AOT measurements. No models or network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/services/subtitle_output_preparer.dart';

int checksum = 0;
SubtitleItem _cue(int id, bool primary) {
  const original = '这是一段本地转录字幕，包含 English words、数字 3.14 与表情🙂，用来测量保存前的标点清理。';
  const translated =
      'This is a translated subtitle, with numbers 3.14 and an emoji 🙂.';
  final text = primary ? original : translated;
  return SubtitleItem(
    index: id,
    startTime: Duration(seconds: id * 3),
    endTime: Duration(seconds: id * 3 + 3),
    text: text,
    timedSpans: primary
        ? [
            for (final word in ['这是一段', 'English', '3.14', '🙂'])
              SubtitleTimedSpan(
                textStart: text.indexOf(word),
                textEnd: text.indexOf(word) + word.length,
                startTime: Duration(seconds: id * 3),
                endTime: Duration(seconds: id * 3 + 1),
              ),
          ]
        : const [],
  );
}

void _process(List<SubtitleItem> cues, SubtitlePunctuation mode) {
  for (final cue in cues) {
    final result = applySubtitlePunctuation(cue, mode);
    checksum += result.text.length + result.timedSpans.length;
  }
}

Future<Map<String, Object>> _responsive(Future<void> Function() work) async {
  final clock = Stopwatch()..start();
  var previous = 0;
  final gaps = <int>[];
  final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
    final now = clock.elapsedMicroseconds;
    gaps.add(now - previous);
    previous = now;
  });
  try {
    await work();
    await Future<void>.delayed(const Duration(milliseconds: 2));
  } finally {
    timer.cancel();
  }
  gaps.sort();
  return {
    'wallMs': clock.elapsedMicroseconds / 1000,
    'eventLoopTicks': gaps.length,
    'eventLoopGapP95Ms': gaps.isEmpty
        ? 0
        : gaps[(gaps.length * .95).floor().clamp(0, gaps.length - 1)] / 1000,
    'eventLoopGapMaxMs': gaps.isEmpty ? 0 : gaps.last / 1000,
  };
}

Future<void> main(List<String> arguments) async {
  final batch = [
    for (var i = 1; i <= 24; i++) ...[_cue(i, true), _cue(i, false)],
  ];
  final longFile = [for (var i = 1; i <= 10000; i++) _cue(i, i.isEven)];
  final modes = <String, Object>{};
  const preparer = SubtitleOutputPreparer();
  final idle = await _responsive(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  for (final mode in SubtitlePunctuation.values) {
    for (var i = 0; i < 100; i++) {
      _process(batch, mode);
    }
    final samples = <int>[];
    for (var i = 0; i < 200; i++) {
      final watch = Stopwatch()..start();
      _process(batch, mode);
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    final large = <int>[];
    for (var i = 0; i < 5; i++) {
      final watch = Stopwatch()..start();
      _process(longFile, mode);
      large.add(watch.elapsedMicroseconds);
    }
    large.sort();
    modes[mode.name] = {
      'batchMedianMs': samples[100] / 1000,
      'batchP95Ms': samples[189] / 1000,
      'tenThousandCuesMedianMs': large[2] / 1000,
    };
  }
  final workers = <String, Object>{};
  for (final mode in [
    SubtitlePunctuation.removeTrailingFullStops,
    SubtitlePunctuation.removeAll,
  ]) {
    final rounds = <Object>[];
    for (var i = 0; i < 3; i++) {
      var transcriptDispatchUs = 0;
      final transcript = await _responsive(() async {
        final dispatch = Stopwatch()..start();
        final pending = preparer.transcript(
          longFile,
          mode,
          keepTranslationInput: true,
        );
        transcriptDispatchUs = dispatch.elapsedMicroseconds;
        final result = await pending;
        checksum +=
            result.srt.length +
            result.wordTiming!.length +
            result.translationInput!.length;
      });
      final translation = await _responsive(() async {
        final result = await preparer.translation(
          longFile,
          [for (final cue in longFile) cue.text],
          mode,
          lineEnding: '\r\n',
        );
        checksum += result.length;
      });
      rounds.add({
        'transcript': transcript,
        'translation': translation,
        'transcriptDispatchSynchronousMs': transcriptDispatchUs / 1000,
      });
    }
    workers[mode.name] = rounds;
  }
  final report = {
    'platform': Platform.operatingSystem,
    'dart': Platform.version,
    'batchPairs': 24,
    'sourceHasTimedSpans': true,
    'batchMeasurements': 200,
    'scope':
        'Pure text transform and complete output preparation; no inference, file IO or Flutter layout. Event-loop timers are not rendered frame times.',
    'modes': modes,
    'idleEventLoop': idle,
    'workerRounds': workers,
    'checksum': checksum,
  };
  final output = arguments.isEmpty
      ? '.artifacts/model-center/punctuation-fast-benchmark.json'
      : arguments.single;
  await File(output).parent.create(recursive: true);
  final encoded = const JsonEncoder.withIndent('  ').convert(report);
  await File(output).writeAsString(encoded);
  stdout.writeln(encoded);
}
