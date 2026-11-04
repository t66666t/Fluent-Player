import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_native_enhancer.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/asr_text_processing.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_processing.dart';
import 'package:video_player_app/features/model_center/qwen_asr_runtime.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';
import 'package:video_player_app/models/subtitle_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('QWEN_NATIVE_MODEL_ROOT');
  test(
    'existing enhancement readiness entry runs shared native components',
    () async {
      final audio = decodeModelWave(
        await File('assets/models/asr/speech_probe_zh.wav').readAsBytes(),
      );
      final records = <String, String>{};
      for (final entry in {
        'ecapa-language-id': AsrEnhancementOptions.languageId,
        'qwen3-alignment': AsrEnhancementOptions.alignmentQwenId,
      }.entries) {
        final result = await probeAsrEnhancement(
          entry.key,
          {entry.value: p.join(root, entry.value)},
          audio,
          qwenWorkerExecutable: p.absolute(
            'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',
          ),
        );
        expect(result, isNotEmpty);
        records[entry.key] = result;
      }
      final processor = AsrTextProcessor(
        directories: {
          AsrEnhancementOptions.languageId: p.join(
            root,
            AsrEnhancementOptions.languageId,
          ),
        },
        threads: 1,
        checkCancelled: () {},
        runtime: QwenAsrRuntime(
          executable: p.absolute(
            'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',
          ),
        ),
      );
      try {
        const korean = '한국어를공부합니다OpenAI';
        final units = await processor.units(korean, 'ko');
        expect(units.length, greaterThan(2));
        expect(units.map((word) => word.text).join(), korean);
        expect(units.any((word) => word.text == 'OpenAI'), isTrue);
        final japanese = await processor.units('😀カ\u3099ッツとOpenAI。', 'ja');
        expect(japanese.first.start, 2);
        expect(japanese.any((word) => word.text == 'OpenAI'), isTrue);
        records['text-processing'] = '日韩原文映射、混合英文和韩语无空格分词通过';
        for (final language in ['zh', 'en']) {
          final samples = language == 'zh'
              ? audio
              : decodeModelWave(
                  await File(
                    'assets/models/asr/speech_probe.wav',
                  ).readAsBytes(),
                );
          final cue = SubtitleItem(
            index: 1,
            startTime: Duration.zero,
            endTime: Duration(microseconds: samples.length * 1000000 ~/ 16000),
            text: language == 'zh' ? '欢迎识别' : 'The weather is nice.',
          );
          final resolved = await processor.resolveLanguages(
            [cue],
            samples,
            'auto',
          );
          // The short JFK probe scores 0.797 in the frozen LID export.
          // Preserve the agreed 0.8 threshold instead of guessing English.
          final expected = language == 'en' ? 'und' : 'zh';
          expect(resolved.single.asrInfo.language, expected);
          expect(
            asrAlignmentModelId(
              resolved.single,
              'auto',
              recognitionEngine: 'zipformer',
              textProcessingVersion: 1,
            ),
            language == 'zh' ? AsrEnhancementOptions.alignmentChineseId : '',
          );
          if (language == 'en') {
            expect(resolved.single.asrInfo.reviewReason, isNotEmpty);
            final tagged = await processor.resolveLanguages(
              [cue.copyWith(asrInfo: const SubtitleAsrInfo(language: 'en'))],
              samples,
              'auto',
            );
            expect(
              asrAlignmentModelId(
                tagged.single,
                'auto',
                recognitionEngine: 'zipformer',
                textProcessingVersion: 1,
              ),
              AsrEnhancementOptions.alignmentEnglishId,
            );
          }
        }
        records['legacy-auto-routing'] = '中文音频及可靠英文标签沿用原 CTC；英文低置信度音频保留未知与原时间';
      } finally {
        await processor.close();
      }
      await File(
        '.artifacts/qwen-integration/native-readiness.json',
      ).writeAsString(jsonEncode(records));
    },
    skip: !Platform.isWindows || root.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
