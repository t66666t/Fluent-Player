import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_accelerator_transport.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_processing.dart';
import 'package:video_player_app/features/model_center/asr_native_enhancer.dart';
import 'package:video_player_app/features/model_center/asr_text_processing.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/qwen_asr_runtime.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';
import 'package:video_player_app/models/subtitle_model.dart';

class _Transport implements AsrAcceleratorTransport {
  _Transport(this.respond);
  final FutureOr<Map<String, dynamic>> Function(Map<String, dynamic>) respond;
  bool closed = false;
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) async =>
      respond(value);
  @override
  Future<void> close() async {
    closed = true;
  }
}

SubtitleItem cue(
  String text, {
  String language = '',
  List<int> boundaries = const [],
}) => SubtitleItem(
  index: 1,
  startTime: const Duration(seconds: 3),
  endTime: const Duration(seconds: 6),
  text: text,
  asrInfo: SubtitleAsrInfo(language: language, wordBoundaries: boundaries),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'new task and component preparation freeze the current Qwen dependencies',
    () async {
      final center = ModelCenterService()..catalog = await loadModelCatalog();
      try {
        center.asrEnhancements = const AsrEnhancementOptions(
          denoise: false,
          punctuation: false,
        );
        for (final id in ['qwen3-asr-0.6b-f16', 'qwen3-asr-1.7b-f16']) {
          center.profiles['test'] = ModelServiceProfile(
            id: 'test',
            name: 'Qwen',
            kind: TranscriptionServiceKind.local,
            model: id,
          );
          center.asrProfileId = 'test';
          center.selectedLanguage = 'en';
          final en = center.transcriptionConfiguration;
          expect(en.asrTextProcessingVersion, currentAsrTextProcessingVersion);
          expect(en.enhancementModels.keys, [
            AsrEnhancementOptions.alignmentEnglishId,
          ]);
          expect(
            center
                .asrEnhancementArtifacts(center.artifact(id)!)
                .map((m) => m.id),
            en.enhancementModels.keys,
          );
          center.selectedLanguage = 'auto';
          expect(
            center.transcriptionConfiguration.enhancementModels.keys,
            containsAll([
              AsrEnhancementOptions.alignmentEnglishId,
              AsrEnhancementOptions.alignmentQwenId,
              AsrEnhancementOptions.languageId,
            ]),
          );
        }
      } finally {
        center.dispose();
      }
    },
  );
  test(
    'language aliases normalize Japanese Korean and shared alignment languages',
    () {
      for (final input in ['Japanese', 'ja_JP', 'jpn', '日本語']) {
        expect(normalizeAsrLanguage(input), 'ja');
      }
      for (final input in ['Korean', 'ko_KR', 'kor', '한국어']) {
        expect(normalizeAsrLanguage(input), 'ko');
      }
      expect(normalizeAsrLanguage('Portuguese'), 'pt');
      expect(normalizeAsrLanguage('ja-Jpan-JP'), 'ja');
      expect(
        normalizeAsrLanguage('en-AU'),
        'en-au',
      ); // Preserve old unsupported regions.
    },
  );
  test(
    'manual selection wins; conflicting native tags use script evidence',
    () {
      expect(
        decideAsrLanguage(
          text: '東京へ行く',
          selected: 'ko',
          recognized: 'ja',
        ).language,
        'ko',
      );
      expect(decideAsrLanguage(text: '東京へ行く', recognized: 'zh').language, 'ja');
      expect(
        decideAsrLanguage(text: '안녕하세요 Python', recognized: 'en').language,
        'ko',
      );
    },
  );
  test('Han and Latin without audio evidence stay uncertain', () {
    for (final text in ['東京大学', '明日', 'Python', 'Bonjour']) {
      expect(decideAsrLanguage(text: text).known, isFalse);
    }
    expect(
      decideAsrLanguage(text: '東京', recognized: 'Japanese').language,
      'ja',
    );
    expect(
      decideAsrLanguage(text: 'Bonjour', recognized: 'French').language,
      'fr',
    );
  });
  test('LID acceptance is exactly 0.8, finite, and requires enough speech', () {
    expect(
      decideAsrLanguage(text: '東京', identified: 'ja', confidence: .8).language,
      'ja',
    );
    for (final probability in [.799, double.nan, double.infinity]) {
      expect(
        decideAsrLanguage(
          text: '東京',
          identified: 'ja',
          confidence: probability,
        ).known,
        isFalse,
      );
    }
    expect(
      decideAsrLanguage(
        text: '東京',
        identified: 'ja',
        confidence: .99,
        shortSpeech: true,
      ).known,
      isFalse,
    );
    expect(
      decideAsrLanguage(
        text: '東京',
        shortSpeech: true,
        neighboring: 'ja',
      ).language,
      'ja',
    );
    expect(
      decideAsrLanguage(text: '東京', identified: 'unknown', confidence: 1).known,
      isFalse,
    );
  });
  test(
    'new text version changes enhancement identity only and old jobs stay old',
    () {
      const profile = ModelServiceProfile(
        id: 'test',
        name: 'ASR',
        kind: TranscriptionServiceKind.local,
        model: 'sensevoice-small-int8',
        language: 'auto',
      );
      const old = ModelJobSpec(profile: profile, artifactIdentity: 'frozen');
      const modern = ModelJobSpec(
        profile: profile,
        artifactIdentity: 'frozen',
        asrTextProcessingVersion: 1,
      );
      expect(old.recognitionFingerprint, modern.recognitionFingerprint);
      expect(old.enhancementFingerprint, isNot(modern.enhancementFingerprint));
      const faster = ModelJobSpec(
        profile: profile,
        artifactIdentity: 'frozen',
        asrTextProcessingVersion: 2,
      );
      expect(faster.recognitionFingerprint, modern.recognitionFingerprint);
      expect(
        faster.enhancementFingerprint,
        isNot(modern.enhancementFingerprint),
      );
      expect(
        ModelJobSpec.fromJson(faster.toJson()).asrTextProcessingVersion,
        2,
      );
      expect(
        ModelJobSpec.fromJson(old.toJson()).asrTextProcessingVersion,
        isNull,
      );
      expect(old.toJson(), isNot(contains('asrTextProcessingVersion')));
      expect(
        ModelJobSpec.fromJson(modern.toJson()).asrTextProcessingVersion,
        1,
      );
    },
  );
  test(
    'dependencies and aligner routing are frozen by text version and engine',
    () {
      const options = AsrEnhancementOptions(denoise: false, punctuation: false);
      final old = options.requiredModels(['ja', 'ko', 'zh', 'en'], 'auto');
      expect(old, isNot(contains(AsrEnhancementOptions.alignmentQwenId)));
      expect(old, isNot(contains(AsrEnhancementOptions.languageId)));
      final modern = options.requiredModels(
        ['ja', 'ko', 'zh', 'en'],
        'auto',
        textProcessingVersion: 1,
        recognitionEngine: 'sensevoice',
      );
      expect(
        modern,
        containsAll([
          AsrEnhancementOptions.alignmentQwenId,
          AsrEnhancementOptions.languageId,
          AsrEnhancementOptions.alignmentEnglishId,
        ]),
      );
      expect(
        asrAlignmentModelId(
          cue('Hello', language: 'en'),
          'auto',
          recognitionEngine: 'sensevoice',
          textProcessingVersion: 1,
        ),
        AsrEnhancementOptions.alignmentEnglishId,
      );
      expect(
        asrAlignmentModelId(
          cue('Hello', language: 'en'),
          'auto',
          recognitionEngine: 'qwen3-asr',
          textProcessingVersion: 1,
        ),
        AsrEnhancementOptions.alignmentQwenId,
      );
      expect(
        asrAlignmentModelId(cue('東京大学'), 'auto', textProcessingVersion: 1),
        '',
      );
      expect(
        options.requiredModels(['ja'], 'ja', textProcessingVersion: 1),
        isNot(contains(AsrEnhancementOptions.languageId)),
      );
      expect(
        options.requiredModels(
          ['zh', 'en'],
          'auto',
          textProcessingVersion: 1,
          recognitionEngine: 'zipformer',
        ),
        contains(AsrEnhancementOptions.languageId),
      );
    },
  );
  test(
    'unknown language reserves prepared aligners and punctuation before LID',
    () async {
      final root = await Directory.systemTemp.createTemp('qwen-budget-');
      final directories = <String, String>{};
      try {
        for (final entry in {
          AsrEnhancementOptions.alignmentEnglishId: 101,
          AsrEnhancementOptions.alignmentChineseId: 211,
          AsrEnhancementOptions.punctuationId: 37,
        }.entries) {
          final directory = await Directory(
            '${root.path}/${entry.key}',
          ).create();
          directories[entry.key] = directory.path;
          await File(
            '${directory.path}/model.int8.onnx',
          ).writeAsBytes(List.filled(entry.value, 0));
        }
        final unknown = cue('Bonjour');
        expect(
          asrAlignmentModelCandidates(
            cue('Hello', language: 'en'),
            'ko',
            availableModels: const [AsrEnhancementOptions.alignmentQwenId],
            textProcessingVersion: 1,
          ),
          [AsrEnhancementOptions.alignmentQwenId],
        );
        expect(
          canRestoreAsrPunctuation(
            cue('Bonjour', language: 'fr'),
            'en',
            'dolphin',
            textProcessingVersion: 1,
          ),
          isTrue,
        );
        expect(
          canRestoreAsrPunctuation(
            cue('Bonjour', language: 'fr'),
            'en',
            'dolphin',
          ),
          isFalse,
        );
        final enhancer = AsrNativeEnhancer(
          options: const AsrEnhancementOptions(denoise: false),
          directories: directories,
          threads: 1,
          recognitionEngine: 'zipformer',
          textProcessingVersion: 1,
          checkCancelled: () {},
          progress: (_, _, _) {},
        );
        try {
          expect(enhancer.alignmentAllocationBytes([unknown]), 211 * 3);
          expect(enhancer.punctuationAllocationBytes([unknown]), 37 * 3);
          expect(
            asrAlignmentModelCandidates(
              unknown,
              'auto',
              availableModels: directories.keys,
            ),
            [AsrEnhancementOptions.alignmentEnglishId],
          );
          expect(
            asrAlignmentModelCandidates(
              cue('Bonjour', language: 'fr'),
              'auto',
              availableModels: directories.keys,
              textProcessingVersion: 1,
            ),
            isEmpty,
          );
        } finally {
          await enhancer.dispose();
        }
        final punctuationOnly = AsrNativeEnhancer(
          options: const AsrEnhancementOptions(
            denoise: false,
            alignment: false,
          ),
          directories: directories,
          threads: 1,
          textProcessingVersion: 1,
          checkCancelled: () {},
          progress: (_, _, _) {},
        );
        try {
          expect(punctuationOnly.punctuationAllocationBytes([unknown]), 37 * 3);
          expect(punctuationOnly.alignmentAllocationBytes([unknown]), 0);
        } finally {
          await punctuationOnly.dispose();
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test('resolved languages admit only the aligner that will actually run', () {
    const prepared = [
      AsrEnhancementOptions.alignmentQwenId,
      AsrEnhancementOptions.alignmentChineseId,
      AsrEnhancementOptions.alignmentEnglishId,
    ];
    List<String> candidates(SubtitleItem item, {bool resolved = true}) =>
        asrAlignmentModelCandidates(
          item,
          'auto',
          availableModels: prepared,
          recognitionEngine: 'sensevoice',
          textProcessingVersion: currentAsrTextProcessingVersion,
          languagesResolved: resolved,
        );
    // An uncertain Han-only cue stays uncertain after LID; forecasting the
    // largest installed model is allowed only before routing has finished.
    expect(candidates(cue('東京', language: 'und')), isEmpty);
    expect(candidates(cue('東京'), resolved: false), containsAll(prepared));
    expect(candidates(cue('欢迎', language: 'zh')), [prepared[1]]);
    expect(candidates(cue('Hello', language: 'en')), [prepared[2]]);
    expect(candidates(cue('東京', language: 'ja')), [prepared[0]]);
    expect(candidates(cue('안녕하세요', language: 'ko')), [prepared[0]]);
  });
  test('Qwen CPU admission covers measured Android alignment peak', () {
    // Phone's 25-second aligner peak was 2,700,060 KiB. CPU maps a single
    // weight file; the old three-weight-copy estimate rejected 4.87 GiB free.
    const weight = 1840000000;
    final cpu = asrAlignmentWorkingSetBytes(
      AsrEnhancementOptions.alignmentQwenId,
      weight,
    );
    final gpu = asrAlignmentWorkingSetBytes(
      AsrEnhancementOptions.alignmentQwenId,
      weight,
      gpu: true,
    );
    expect(
      cpu + AsrTextProcessor.textWorkingSetBytes,
      greaterThan(2700060 * 1024),
    );
    expect(
      cpu + AsrTextProcessor.textWorkingSetBytes + 256 * 1048576,
      lessThan(4.87 * 1073741824),
    );
    expect(gpu - cpu, weight);
    expect(qwenAudioWorkingSetBytes(0), 0);
    expect(
      asrAlignmentWorkingSetBytes(
        AsrEnhancementOptions.alignmentChineseId,
        weight,
      ),
      weight * 3,
    );
  });
  test(
    'language admission and memory fallback do not guess Han as Chinese',
    () async {
      final transport = _Transport(
        (_) => throw StateError('must not load LID'),
      );
      final processor = AsrTextProcessor(
        directories: const {AsrEnhancementOptions.languageId: 'prepared'},
        threads: 1,
        checkCancelled: () {},
        runtime: QwenAsrRuntime(openTransport: () async => transport),
      );
      final enhancer = AsrNativeEnhancer(
        options: const AsrEnhancementOptions(denoise: false),
        directories: const {},
        threads: 1,
        textProcessingVersion: currentAsrTextProcessingVersion,
        checkCancelled: () {},
        progress: (_, _, _) {},
      );
      try {
        expect(
          enhancer.languageAllocationBytes([cue('東京')]),
          AsrTextProcessor.textWorkingSetBytes,
        );
        expect(enhancer.languageAllocationBytes([cue('こんにちは')]), 0);
        expect(
          enhancer.languageAllocationBytes([cue('你好', language: 'zh')]),
          0,
        );
        final result = await processor.resolveLanguages(
          [cue('東京')],
          Float32List(96000),
          'auto',
          allowAudioModel: false,
        );
        expect(result.single.text, '東京');
        expect(result.single.asrInfo.language, 'und');
        expect(result.single.asrInfo.reviewReason, isNotEmpty);
        expect(
          enhancer.alignmentAllocationBytes(result, languagesResolved: true),
          0,
        );
        expect(processor.runtime.isOpen, isFalse);
      } finally {
        await processor.close();
        await enhancer.dispose();
      }
    },
  );
  test(
    'v2 English uses its frozen CTC; v1 and missing dependencies retain Qwen',
    () {
      const options = AsrEnhancementOptions(denoise: false, punctuation: false);
      final v2 = options.requiredModels(
        ['zh', 'en', 'ja', 'ko'],
        'auto',
        recognitionEngine: 'qwen3-asr',
        textProcessingVersion: 2,
      );
      expect(v2, contains(AsrEnhancementOptions.alignmentEnglishId));
      expect(v2, contains(AsrEnhancementOptions.alignmentQwenId));
      expect(
        options.requiredModels(
          ['en'],
          'en',
          recognitionEngine: 'qwen3-asr',
          textProcessingVersion: 2,
        ),
        [AsrEnhancementOptions.alignmentEnglishId],
      );
      for (final version in [1, 2]) {
        expect(
          asrAlignmentModelId(
            cue('Hello', language: 'en'),
            'auto',
            recognitionEngine: 'qwen3-asr',
            textProcessingVersion: version,
            availableModels: [AsrEnhancementOptions.alignmentEnglishId],
          ),
          version == 2
              ? AsrEnhancementOptions.alignmentEnglishId
              : AsrEnhancementOptions.alignmentQwenId,
        );
      }
      expect(
        asrAlignmentModelId(
          cue('Hello', language: 'en'),
          'auto',
          recognitionEngine: 'qwen3-asr',
          textProcessingVersion: 2,
        ),
        AsrEnhancementOptions.alignmentQwenId,
      );
    },
  );
  test('auto alignment accounts for the actual CPU resident backend', () async {
    final folder = await Directory.systemTemp.createTemp('qwen-resident-');
    const weightBytes = 1024 * 1024;
    await File(
      '${folder.path}/qwen3-forced-aligner-0.6b-f16.gguf',
    ).writeAsBytes(Uint8List(weightBytes));
    final transport = _Transport(
      (message) => switch (message['op']) {
        'tokenize' => {
          'units': [
            {'text': '東京', 'start': 0, 'end': 2},
          ],
        },
        'capabilities' => {'devices': <Map>[]},
        'load' => {'backend': 'CPU'},
        'align' => {
          'times': [
            {'startMs': 0, 'endMs': 500},
          ],
        },
        _ => throw StateError('Unexpected operation'),
      },
    );
    final processor = AsrTextProcessor(
      directories: {AsrEnhancementOptions.alignmentQwenId: folder.path},
      threads: 1,
      acceleration: 'auto',
      checkCancelled: () {},
      runtime: QwenAsrRuntime(openTransport: () async => transport),
    );
    try {
      expect(
        processor.modelBytes(AsrEnhancementOptions.alignmentQwenId),
        qwenAudioWorkingSetBytes(weightBytes, gpu: true),
      );
      expect(
        await processor.align(
          cue('東京', language: 'ja'),
          Float32List.fromList(List.filled(96000, .2)),
        ),
        isNotNull,
      );
      expect(processor.residentBytes, qwenAudioWorkingSetBytes(weightBytes));
    } finally {
      await processor.close();
      await folder.delete(recursive: true);
    }
  });
  test('alignment preserves original offsets and absolute PCM coordinates', () {
    final result = validatedQwenAlignment(
      cue('東京大学 Python'),
      [const AsrTextUnit('東京大学', 0, 4), const AsrTextUnit('Python', 5, 11)],
      [
        {'startMs': 160, 'endMs': 800},
        {'startMs': 960, 'endMs': 2000},
      ],
      48000,
    )!;
    expect(result.first.textEnd, 4);
    expect(result.last.textStart, 5);
    expect(result.first.startTime, const Duration(milliseconds: 3160));
    expect(result.last.endTime, const Duration(seconds: 5));
  });
  test(
    'zero duration bins coalesce, bad order and out of range reject whole alignment',
    () {
      const units = [AsrTextUnit('東', 0, 1), AsrTextUnit('京', 1, 2)];
      final result = validatedQwenAlignment(cue('東京'), units, [
        {'startMs': 0, 'endMs': 0},
        {'startMs': 0, 'endMs': 400},
      ], 48000)!;
      expect(result, hasLength(1));
      expect(result.single.textStart, 0);
      expect(result.single.textEnd, 2);
      for (final times in [
        [
          {'startMs': 500, 'endMs': 800},
          {'startMs': 400, 'endMs': 900},
        ],
        [
          {'startMs': 0, 'endMs': 800},
          {'startMs': 900, 'endMs': 4000},
        ],
        [
          {'startMs': 0, 'endMs': 800},
          {'startMs': double.nan, 'endMs': 900},
        ],
      ]) {
        expect(validatedQwenAlignment(cue('東京'), units, times, 48000), isNull);
      }
    },
  );
  test(
    'word boundaries survive serialization and trimming without fabricating times',
    () {
      final original = cue(
        '  東京大学で学びます。 ',
        language: 'ja',
        boundaries: [2, 6, 7, 9, 11],
      );
      final restored = SubtitleItem.fromTimingJson(
        original.toTimingJson(),
      ).trimmed();
      expect(restored.asrInfo.wordBoundaries, [0, 4, 5, 7, 9]);
      final segmented = segmentAsrSubtitles([
        restored,
      ], const SubtitleSegmentationOptions(maxWidth: 4));
      expect(segmented, hasLength(1));
      expect(segmented.single.timedSpans, isEmpty);
      expect(segmented.single.startTime, original.startTime);
    },
  );
  test(
    'invalid UTF16 boundary from tokenizer is rejected at grapheme boundary',
    () async {
      final transport = _Transport(
        (_) => {
          'units': [
            {'text': 'x', 'start': 1, 'end': 2},
          ],
        },
      );
      final processor = AsrTextProcessor(
        directories: const {},
        threads: 1,
        checkCancelled: () {},
        runtime: QwenAsrRuntime(openTransport: () async => transport),
      );
      try {
        await expectLater(processor.units('😀東京', 'ja'), throwsStateError);
      } finally {
        await processor.close();
      }
    },
  );
  test(
    'cancelling an in-flight native owner discards late output and closes transport',
    () async {
      final entered = Completer<void>(),
          response = Completer<Map<String, dynamic>>();
      final transport = _Transport((_) {
        entered.complete();
        return response.future;
      });
      final runtime = QwenAsrRuntime(openTransport: () async => transport);
      final future = runtime.request({'op': 'capabilities'});
      final assertion = expectLater(future, throwsStateError);
      await entered.future;
      await runtime.release();
      expect(transport.closed, isTrue);
      response.complete({'ok': true});
      await assertion;
      await runtime.close();
    },
  );
  test(
    'PCM transport uses original float samples and cleans its task scratch files',
    () async {
      final parent = await Directory.systemTemp.createTemp('qwen-pcm-test-');
      final transport = _Transport((request) async {
        final bytes = await File(request['path'] as String).readAsBytes();
        expect(ByteData.sublistView(bytes).getFloat32(4, Endian.little), .5);
        return {'ok': true};
      });
      final runtime = QwenAsrRuntime(
        runtimeDirectory: '${parent.path}/nested',
        openTransport: () async => transport,
      );
      try {
        await runtime.audioRequest(
          'decode',
          Float32List.fromList([-.25, .5]),
          () {},
        );
        await runtime.release();
        expect(
          await Directory('${parent.path}/nested').list().toList(),
          isEmpty,
        );
      } finally {
        await runtime.close();
        await parent.delete(recursive: true);
      }
    },
  );
  test(
    'short unknown neighbors share enough audio without rewriting text',
    () async {
      var identified = 0;
      final transport = _Transport((request) async {
        if (request['op'] == 'load') return {'backend': 'CPU'};
        identified++;
        expect(await File(request['path'] as String).length(), 32000 * 4);
        return {'language': 'ja', 'confidence': .95};
      });
      final processor = AsrTextProcessor(
        directories: const {AsrEnhancementOptions.languageId: 'prepared'},
        threads: 1,
        checkCancelled: () {},
        runtime: QwenAsrRuntime(openTransport: () async => transport),
      );
      final input = [
        cue('東京').copyWith(
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
        cue('大学').copyWith(
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
        ),
      ];
      try {
        final output = await processor.resolveLanguages(
          input,
          Float32List.fromList(List.filled(32000, .2)),
          'auto',
        );
        expect(output.map((c) => c.text), ['東京', '大学']);
        expect(output.map((c) => c.asrInfo.language), ['ja', 'ja']);
        expect(identified, 1);
      } finally {
        await processor.close();
      }
    },
  );
  test('a word crossing long silence falls back to sentence timing', () {
    final audio = Float32List(48000);
    for (var i = 0; i < 8000; i++) {
      audio[i] = .2;
      audio[audio.length - 1 - i] = .2;
    }
    expect(
      validatedQwenAlignment(
        cue('東京大学'),
        [const AsrTextUnit('東京大学', 0, 4)],
        [
          {'startMs': 0, 'endMs': 3000},
        ],
        audio.length,
        audio,
      ),
      isNull,
    );
  });
  test(
    'CPU recognition reopens after another GPU owner resets the process',
    () async {
      final transports = <_Transport>[];
      final decoder = QwenAsrDecoder(
        model: 'prepared.gguf',
        identity: 'frozen-model',
        language: 'ja',
        hotwords: '',
        threads: 1,
        mode: 'cpu',
        onLoad: () {},
        onState: (_) {},
        runtimeFactory: () {
          final first = transports.isEmpty;
          final transport = _Transport((message) {
            if (message['op'] == 'load') return {'backend': 'CPU'};
            if (first) throw StateError('Qwen 音频进程已退出，已保留有效断点');
            return {
              'result': {
                'text': '東京へ行く',
                'lang': 'ja',
                'timingKind': 'segment',
              },
            };
          });
          transports.add(transport);
          return QwenAsrRuntime(openTransport: () async => transport);
        },
      );
      try {
        expect(
          (await decoder.decode(Float32List(16000), () {}))['text'],
          '東京へ行く',
        );
        expect(transports, hasLength(2));
        expect(transports.first.closed, isTrue);
      } finally {
        await decoder.close();
      }
    },
  );
  test('explicit decoder cancellation never reopens a CPU owner', () async {
    final entered = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    var opened = 0;
    final decoder = QwenAsrDecoder(
      model: 'prepared.gguf',
      identity: 'frozen-model',
      language: 'ja',
      hotwords: '',
      threads: 1,
      mode: 'cpu',
      onLoad: () {},
      onState: (_) {},
      runtimeFactory: () {
        opened++;
        return QwenAsrRuntime(
          openTransport: () async => _Transport((message) {
            if (message['op'] == 'load') return {'backend': 'CPU'};
            entered.complete();
            return response.future;
          }),
        );
      },
    );
    final result = decoder.decode(Float32List(16000), () {});
    final rejected = expectLater(result, throwsStateError);
    await entered.future;
    await decoder.release();
    response.completeError(StateError('Qwen 音频组件已关闭'));
    await rejected;
    expect(opened, 1);
    await decoder.close();
  });
  test(
    'idle tokenizer reopens after the shared native process was reset',
    () async {
      var opened = 0;
      final processor = AsrTextProcessor(
        directories: const {},
        threads: 1,
        checkCancelled: () {},
        runtime: QwenAsrRuntime(
          openTransport: () async {
            final first = ++opened == 1;
            return _Transport((message) {
              if (first) {
                throw StateError('Qwen 原生组件不可用（IllegalStateException）');
              }
              return {
                'units': [
                  {'text': '東京', 'start': 0, 'end': 2},
                ],
              };
            });
          },
        ),
      );
      try {
        final units = await processor.units('東京', 'ja');
        expect(units.single.text, '東京');
        expect((units.single.start, units.single.end), (0, 2));
        expect(opened, 2);
      } finally {
        await processor.close();
      }
    },
  );
  for (final rejected in ['load', 'operators']) {
    test(
      'GPU $rejected failure opens a fresh CPU owner and preserves text',
      () async {
        final transports = <_Transport>[];
        final selected = <String>[];
        final decoder = QwenAsrDecoder(
          model: 'prepared.gguf',
          identity: 'frozen-model',
          language: 'ja-JP',
          hotwords: '',
          threads: 1,
          mode: 'gpu',
          onLoad: () {},
          onState: (_) {},
          runtimeFactory: () {
            var backend = 'CPU';
            final transport = _Transport((message) {
              if (message['op'] == 'capabilities') {
                return {
                  'devices': [
                    {'name': 'Vulkan0', 'gpu': true},
                  ],
                };
              }
              if (message['op'] == 'load') {
                expect(message['language'], 'ja');
                selected.add(message['backend'] as String);
                backend = message['backend'] == 'cpu' ? 'CPU' : 'Vulkan0';
                if (backend != 'CPU' && rejected == 'load') {
                  throw StateError('driver failed');
                }
                return {'backend': backend};
              }
              return {
                'result': {
                  'text': '東京へ行く',
                  'lang': 'ja',
                  'timingKind': 'segment',
                  'gpuOperators': 0,
                },
              };
            });
            transports.add(transport);
            return QwenAsrRuntime(openTransport: () async => transport);
          },
        );
        try {
          final result = await decoder.decode(Float32List(16000), () {});
          expect(result['text'], '東京へ行く');
          expect(result['_backend'], 'CPU');
          expect(selected, ['vulkan', 'cpu']);
          expect(transports, hasLength(2));
          expect(transports.first.closed, isTrue);
        } finally {
          await decoder.close();
        }
        expect(transports.every((t) => t.closed), isTrue);
      },
    );
  }
}
