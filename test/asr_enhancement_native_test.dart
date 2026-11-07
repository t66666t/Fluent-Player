import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:path/path.dart' as p;

import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_native_enhancer.dart';
import 'package:video_player_app/features/model_center/asr_onnx_session.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import '../tool/local_asr_probe_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('ASR_ENHANCEMENT_NATIVE');
  test(
    'real default enhancement pipeline, raw resume, hotwords and OCR coexist',
    () async {
      final dll = p.absolute('windows/runtime/onnxruntime.dll');
      DynamicLibrary.open(dll);
      OrtEnv.instance.init();
      final providers = OrtEnv.instance.availableProviders();
      final directories = <String, String>{
        for (final id in const AsrEnhancementOptions().requiredModels([
          'zh',
          'en',
        ], 'auto'))
          id: p.absolute('.artifacts/model-center/enhancements/$id'),
      };
      final report = <String, dynamic>{};
      for (final language in ['zh', 'en']) {
        final worker = LocalAsrWorker();
        try {
          await worker.start(
            engine: 'sensevoice',
            directory: p.absolute(
              '.artifacts/model-center/native/sensevoice-small-int8',
            ),
            vadPath: asrProbeVadPath(),
            language: language,
            threads: 2,
            libraryDirectory:
                '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows',
            enhancements: const AsrEnhancementOptions(alwaysAlign: true),
            enhancementDirectories: directories,
            runtimeDirectory: p.absolute('.artifacts/model-center'),
          );
          final phases = <String>{};
          var raw = <SubtitleItem>[];
          final path = p.absolute(
            'assets/models/asr/speech_probe${language == 'zh' ? '_zh' : ''}.wav',
          );
          final cues = await worker.recognize(
            path,
            onRecognized: (value) async {
              raw = value;
            },
            onPhase: (phase, _, message) {
              phases.add(phase);
            },
          );
          expect(cues, isNotEmpty);
          expect(raw, isNotEmpty);
          await File(
            '.artifacts/model-center/enhancement-native-$language.json',
          ).writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'raw': raw.map((c) => c.toTimingJson()).toList(),
              'enhanced': cues.map((c) => c.toTimingJson()).toList(),
              'phases': phases.toList(),
            }),
          );
          expect(phases, containsAll(['denoising', 'aligning', 'refining']));
          expect(cues.any((c) => c.asrInfo.alignmentScore != null), isTrue);
          expect(cues.every((c) => c.endTime > c.startTime), isTrue);
          final resumed = await worker.recognize(
            path,
            recognizedCues: raw,
            onRecognized: (_) async {
              fail('cached raw ASR decoded again');
            },
          );
          expect(
            resumed.map((e) => e.toTimingJson()).toList(),
            cues.map((e) => e.toTimingJson()).toList(),
          );
          report[language] = {
            'raw': raw.map((e) => e.toTimingJson()).toList(),
            'enhanced': cues.map((e) => e.toTimingJson()).toList(),
            'phases': phases.toList(),
          };
          if (language == 'en') {
            final cancelled = Completer<void>();
            await expectLater(
              worker.recognize(
                path,
                recognizedCues: raw,
                cancelSignal: cancelled.future,
                onPhase: (phase, _, _) {
                  if (phase == 'aligning' && !cancelled.isCompleted) {
                    cancelled.complete();
                  }
                },
              ),
              throwsStateError,
            );
            report['enhancementCancellation'] = true;
          }
        } finally {
          await worker.close();
        }
      }
      final hotwordWorker = LocalAsrWorker();
      try {
        await hotwordWorker.start(
          engine: 'zipformer',
          directory: p.absolute(
            '.artifacts/model-center/enhancements/zipformer-zh-en-tiny-int8',
          ),
          vadPath: asrProbeVadPath(),
          language: 'auto',
          threads: 2,
          libraryDirectory:
              '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows',
          enhancements: const AsrEnhancementOptions(
            denoise: false,
            alignment: false,
            punctuation: false,
            hotwords: '测试语音\nwelcome',
          ),
          runtimeDirectory: p.absolute('.artifacts/model-center'),
        );
        final cues = await hotwordWorker.recognize(
          p.absolute('assets/models/asr/speech_probe_zh.wav'),
        );
        expect(cues, isNotEmpty);
        report['hotwords'] = cues.map((e) => e.toTimingJson()).toList();
      } finally {
        await hotwordWorker.close();
      }
      final sample = decodeModelWave(
        await File('assets/models/asr/speech_probe_zh.wav').readAsBytes(),
      );
      report['punctuationProbe'] = await probeAsrEnhancement(
        'punctuation',
        directories,
        sample,
        libraryDirectory:
            '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows',
      );
      expect(report['punctuationProbe'], matches(RegExp(r'[，。！？]')));
      final unicode = await Directory.systemTemp.createTemp('模型路径测试-');
      try {
        final modelPath = p.join(unicode.path, '轻量模型.onnx');
        await File(
          p.join(directories[AsrEnhancementOptions.denoiserId]!, 'model.onnx'),
        ).copy(modelPath);
        final session = openAsrOnnxSession(modelPath, 1);
        try {
          expect(session.inputNames, isNotEmpty);
        } finally {
          session.release();
        }
        report['unicodeModelPath'] = true;
      } finally {
        await unicode.delete(recursive: true);
      }
      expect(OrtEnv.instance.availableProviders(), providers);
      await File(
        '.artifacts/model-center/enhancement-native.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      OrtEnv.instance.release();
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
