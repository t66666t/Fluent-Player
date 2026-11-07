// Explicit Windows experiment. Never entered by the application or normal tests.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_native_enhancer.dart';
import 'package:video_player_app/features/model_center/cohere_asr_runtime.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_token_timing.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import '../tool/local_asr_probe_assets.dart';

Float32List _readAudio(String path) {
  final bytes = File(path).readAsBytesSync();
  return Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 4);
}

Uint8List _pcmWave(Float32List audio) {
  final bytes = Uint8List(44 + audio.length * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int at, String value) => bytes.setRange(at, at + 4, value.codeUnits);
  tag(0, 'RIFF');
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  tag(36, 'data');
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, audio.length * 2, Endian.little);
  for (var i = 0; i < audio.length; i++) {
    data.setInt16(
      44 + i * 2,
      (audio[i] * 32768).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return bytes;
}

List<({int start, int end})> _vad(Float32List audio, {int padding = 2560}) {
  final detector = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: asrProbeVadPath(),
        threshold: .5,
        minSilenceDuration: .15,
        minSpeechDuration: .18,
        maxSpeechDuration: 8,
      ),
      sampleRate: 16000,
      numThreads: 1,
      debug: false,
    ),
    bufferSizeInSeconds: 60,
  );
  final segments = <({int start, int end})>[];
  void drain() {
    while (!detector.isEmpty()) {
      final front = detector.front();
      final start = front.start.clamp(0, audio.length);
      final end = (front.start + front.samples.length).clamp(
        start,
        audio.length,
      );
      detector.pop();
      if (end > start) segments.add((start: start, end: end));
    }
  }

  try {
    for (var at = 0; at < audio.length; at += 512) {
      final count = math.min(512, audio.length - at);
      detector.acceptWaveform(
        count == 512
            ? Float32List.sublistView(audio, at, at + count)
            : (Float32List(512)..setRange(0, count, audio, at)),
      );
      drain();
    }
    detector.flush();
    drain();
  } finally {
    detector.free();
  }
  final bounded = splitCohereSpeechRanges(segments, audio);
  return [
    for (var i = 0; i < bounded.length; i++)
      (
        start: math.max(
          i > 0 ? (bounded[i - 1].end + bounded[i].start) ~/ 2 : 0,
          bounded[i].start - padding,
        ),
        end: math.min(
          i + 1 < bounded.length
              ? (bounded[i].end + bounded[i + 1].start) ~/ 2
              : audio.length,
          bounded[i].end + padding,
        ),
      ),
  ];
}

List<List<int>> _ranges(List<({int start, int end})> values) => [
  for (final value in values) [value.start, value.end],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const rootPath = String.fromEnvironment('JAPANESE_ABLATION_ROOT');
  const mode = String.fromEnvironment(
    'JAPANESE_ABLATION_MODE',
    defaultValue: 'audio',
  );
  final enabled = Platform.isWindows && rootPath.isNotEmpty;
  test(
    'Windows Japanese processing ablation: $mode',
    () async {
      DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
      final packages =
          jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
              as Map;
      final entry = (packages['packages'] as List).cast<Map>().singleWhere(
        (v) => v['name'] == 'sherpa_onnx_windows',
      );
      final libraryDirectory = p.join(
        File(
          '.dart_tool/package_config.json',
        ).absolute.uri.resolve(entry['rootUri'] as String).toFilePath(),
        'windows',
      );
      sherpa.initBindings(libraryDirectory);
      final root = Directory(rootPath);
      final input =
          jsonDecode(File(p.join(root.path, 'inputs.json')).readAsStringSync())
              as Map;
      final denoiserDirectory = p.absolute(
        '.artifacts/model-center/enhancements/asr-gtcrn',
      );
      if (mode == 'audio') {
        final helper = AsrNativeEnhancer(
          options: const AsrEnhancementOptions(),
          directories: {AsrEnhancementOptions.denoiserId: denoiserDirectory},
          threads: 2,
          checkCancelled: () {},
          progress: (_, _, _) {},
          retainModels: true,
        );
        final whole = sherpa.OfflineSpeechDenoiser(
          sherpa.OfflineSpeechDenoiserConfig(
            model: sherpa.OfflineSpeechDenoiserModelConfig(
              gtcrn: sherpa.OfflineSpeechDenoiserGtcrnModelConfig(
                model: p.join(denoiserDirectory, 'model.onnx'),
              ),
              numThreads: 2,
              provider: 'cpu',
              debug: false,
            ),
          ),
        );
        final cases = <Map<String, dynamic>>[];
        Float32List? firstInput, firstOutput;
        try {
          for (final raw in input['cases'] as List) {
            final item = Map<String, dynamic>.from(raw as Map);
            final audio = _readAudio(item['inputF32'] as String);
            final watch = Stopwatch()..start();
            final denoised = await helper.denoise(audio);
            final elapsed = watch.elapsedMicroseconds / 1e6;
            expect(denoised.length, audio.length);
            expect(denoised.every((v) => v.isFinite), isTrue);
            firstInput ??= audio;
            firstOutput ??= Float32List.fromList(denoised);
            final outputPath = p.join(
              root.path,
              'audio',
              '${item['id']}-gtcrn.f32',
            );
            File(outputPath).writeAsBytesSync(
              denoised.buffer.asUint8List(
                denoised.offsetInBytes,
                denoised.lengthInBytes,
              ),
            );
            final fixed = _ranges(
              splitCohereSpeechRanges([(start: 0, end: audio.length)], audio),
            );
            final originalVad = _vad(audio);
            final processed = <String, dynamic>{
              ...item,
              'samples': audio.length,
              'denoisedF32': outputPath,
              'denoiseSeconds': elapsed,
              'fixedRanges': fixed,
              'rawVadRanges': _ranges(originalVad),
              'rawVadNoPaddingRanges': _ranges(_vad(audio, padding: 0)),
              'denoisedVadRanges': _ranges(_vad(denoised)),
            };
            if (item['category'] == 'clean' || item['category'] == 'video') {
              final padded = Float32List(
                ((audio.length + 255) ~/ 256) * 256 + 512,
              )..setAll(0, audio);
              final run = whole.run(samples: padded, sampleRate: 16000);
              expect(run.sampleRate, 16000);
              expect(run.samples.length, greaterThanOrEqualTo(audio.length));
              final wholeAudio = Float32List.sublistView(
                run.samples,
                0,
                audio.length,
              );
              final wholePath = p.join(
                root.path,
                'audio',
                '${item['id']}-gtcrn-whole.f32',
              );
              File(wholePath).writeAsBytesSync(
                wholeAudio.buffer.asUint8List(
                  wholeAudio.offsetInBytes,
                  wholeAudio.lengthInBytes,
                ),
              );
              processed['wholeDenoisedF32'] = wholePath;
            }
            cases.add(processed);
            File(p.join(root.path, 'prepared.json')).writeAsStringSync(
              jsonEncode({
                'platform': 'Windows',
                'sampleRate': 16000,
                'vad': {
                  'threshold': .5,
                  'minSilenceSeconds': .15,
                  'minSpeechSeconds': .18,
                  'maxSpeechSeconds': 8,
                  'cadenceSamples': 512,
                  'paddingSamples': 2560,
                },
                'fixedWindowMaximumSamples': 120000,
                'cases': cases,
              }),
            );
            // ignore: avoid_print
            print('Prepared ${item['id']} (${audio.length / 16000}s)');
          }
          final repeat = await helper.denoise(firstInput!);
          var maximum = 0.0;
          for (var i = 0; i < repeat.length; i++) {
            maximum = math.max(maximum, (repeat[i] - firstOutput![i]).abs());
          }
          expect(
            maximum,
            lessThanOrEqualTo(1e-6),
            reason: 'Reusing the denoiser must not leak state between files',
          );
          File(p.join(root.path, 'denoiser-reuse.json')).writeAsStringSync(
            jsonEncode({'passed': true, 'maximumSampleDifference': maximum}),
          );
        } finally {
          await helper.dispose();
          whole.free();
        }
      } else if (mode == 'frontend') {
        final independent =
            jsonDecode(
                  File(
                    p.join(root.path, 'recognition.json'),
                  ).readAsStringSync(),
                )
                as Map;
        final results = <Map<String, dynamic>>[];
        final worker = LocalAsrWorker(
          libraryDirectory: libraryDirectory,
          parakeetJapaneseWorkerExecutable: p.absolute(
            'native/parakeet_ja/prebuilt/windows-x64/parakeet_ja_worker.exe',
          ),
        );
        try {
          await worker.start(
            engine: 'parakeet-ja',
            directory: p.absolute(
              '.artifacts/model-center/native/parakeet-ja-0.6b-q8',
            ),
            vadPath: asrProbeVadPath(),
            language: 'ja',
            threads: 4,
            enhancements: const AsrEnhancementOptions(
              denoise: false,
              alignment: false,
              punctuation: false,
              trimSilence: false,
            ),
            stage: LocalAsrStage.recognition,
            retainModels: true,
          );
          for (final item in (input['cases'] as List).cast<Map>().where(
            (c) => c['category'] == 'clean',
          )) {
            final audio = _readAudio(item['inputF32'] as String);
            final wave = File(
              p.join(root.path, 'audio', '${item['id']}-frontend.wav'),
            );
            wave.writeAsBytesSync(_pcmWave(audio));
            final watch = Stopwatch()..start();
            final cues = await worker.recognize(wave.path);
            final control = (independent['cases'] as List)
                .cast<Map>()
                .singleWhere((c) => c['id'] == item['id']);
            final expected =
                ((control['results'] as Map)['raw_vad'] as Map)['text']
                    as String;
            expect(
              cues.map((c) => c.text).join().replaceAll(RegExp(r'\s'), ''),
              expected.replaceAll(RegExp(r'\s'), ''),
              reason:
                  '${item['id']} production frontend differs from independent native control',
            );
            results.add({
              'id': item['id'],
              'seconds': watch.elapsedMicroseconds / 1e6,
              'reference': item['reference'],
              'text': cues.map((c) => c.text).join(),
              'matchesIndependentControl': true,
              'cues': cues.map((c) => c.toTimingJson()).toList(),
            });
            File(p.join(root.path, 'frontend.json')).writeAsStringSync(
              jsonEncode({'platform': 'Windows', 'cases': results}),
            );
            // ignore: avoid_print
            print('Production frontend agrees: ${item['id']}');
          }
        } finally {
          await worker.close();
        }
      } else if (mode == 'post') {
        final frozen =
            jsonDecode(
                  File(
                    p.join(root.path, 'frozen-video.json'),
                  ).readAsStringSync(),
                )
                as Map;
        final audio = _readAudio(frozen['inputF32'] as String);
        final cues = <SubtitleItem>[];
        for (final record in frozen['pieces'] as List) {
          final value = record as Map;
          final result = value['result'] as Map;
          final text = (result['text'] as String).trim();
          if (text.isEmpty) continue;
          final start = (value['range'] as List)[0] as int;
          final end = (value['range'] as List)[1] as int;
          final starts = (result['timestamps'] as List)
              .map((v) => (v as num).toDouble())
              .toList();
          final durations = (result['durations'] as List)
              .map((v) => (v as num).toDouble())
              .toList();
          cues.add(
            SubtitleItem(
              index: cues.length + 1,
              text: text,
              startTime: Duration(microseconds: start * 1000000 ~/ 16000),
              endTime: Duration(microseconds: end * 1000000 ~/ 16000),
              asrInfo: const SubtitleAsrInfo(language: 'ja', backend: 'CPU'),
              timedSpans: alignModelTokens(
                text: text,
                tokens: (result['tokens'] as List).cast<String>(),
                starts: starts,
                ends: durations.length == starts.length
                    ? [
                        for (var i = 0; i < starts.length; i++)
                          starts[i] + durations[i],
                      ]
                    : null,
                offset: start / 16000,
                cueEnd: end / 16000,
              ),
            ),
          );
        }
        final report = <String, dynamic>{
          'rawCues': cues.map((c) => c.toTimingJson()).toList(),
          'profiles': <String, dynamic>{},
        };
        final profiles = report['profiles'] as Map<String, dynamic>;
        final originalText = cues
            .map((c) => c.text)
            .join()
            .replaceAll(RegExp(r'\s'), '');
        for (final variant in [
          'no_post',
          'default',
          'no_trim',
          'no_punctuation',
          'no_japanese_boundaries',
          'force_alignment',
        ]) {
          final options = AsrEnhancementOptions(
            enabled: variant != 'no_post',
            denoise: false,
            trimSilence: variant != 'no_trim',
            punctuation: variant != 'no_punctuation',
            alwaysAlign: variant == 'force_alignment',
          );
          final phases = <String>{};
          final helper = AsrNativeEnhancer(
            options: options,
            directories: {
              AsrEnhancementOptions.punctuationId: p.absolute(
                '.artifacts/model-center/enhancements',
                AsrEnhancementOptions.punctuationId,
              ),
              if (variant == 'force_alignment')
                AsrEnhancementOptions.alignmentQwenId: p.absolute(
                  '.artifacts/model-center/native',
                  AsrEnhancementOptions.alignmentQwenId,
                ),
            },
            threads: 4,
            checkCancelled: () {},
            progress: (phase, _, _) => phases.add(phase),
            language: 'ja',
            recognitionEngine: 'parakeet-ja',
            textProcessingVersion: variant == 'no_japanese_boundaries'
                ? null
                : currentAsrTextProcessingVersion,
            qwenWorkerExecutable: p.absolute(
              'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',
            ),
          );
          final watch = Stopwatch()..start();
          try {
            final enhanced = await helper.enhance(cues, audio);
            if (variant == 'force_alignment') {
              expect(
                enhanced.any(
                  (c) => c.asrInfo.notes.any(
                    (n) => n.contains('Qwen3 ForcedAligner'),
                  ),
                ),
                isTrue,
                reason:
                    'Forced alignment must actually execute; fallback alone is not a successful alignment experiment',
              );
            }
            final result = segmentAsrSubtitles(
              enhanced,
              SubtitleSegmentationOptions.natural,
            );
            expect(
              enhanced.map((c) => c.text).join().replaceAll(RegExp(r'\s'), ''),
              originalText,
              reason: '$variant must preserve frozen ASR characters',
            );
            expect(result.every((c) => c.endTime > c.startTime), isTrue);
            profiles[variant] = {
              'seconds': watch.elapsedMicroseconds / 1e6,
              'phases': phases.toList(),
              'enhancedCues': enhanced.map((c) => c.toTimingJson()).toList(),
              'naturalCues': result.map((c) => c.toTimingJson()).toList(),
              'recognitionCharactersUnchanged': true,
              'residentPunctuationBytes': helper.residentPunctuationBytes,
            };
          } finally {
            await helper.dispose();
          }
          File(
            p.join(root.path, 'postprocessing.json'),
          ).writeAsStringSync(jsonEncode(report));
          // ignore: avoid_print
          print('Frozen-ASR postprocessing: $variant');
        }
      } else {
        fail('Unknown experiment mode: $mode');
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
