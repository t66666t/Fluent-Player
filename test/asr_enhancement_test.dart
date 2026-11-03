import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_processing.dart';
import 'package:video_player_app/features/model_center/asr_native_enhancer.dart';
import 'package:video_player_app/features/model_center/ctc_forced_alignment.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import 'package:video_player_app/services/transcription_reliability.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

void main() {
  test(
    'auxiliary admission only counts models required by this language and text',
    () async {
      final root = await Directory.systemTemp.createTemp('asr-load-admission-');
      try {
        final punctuation = await Directory(
          '${root.path}/punctuation',
        ).create();
        final alignment = await Directory('${root.path}/alignment').create();
        await File(
          '${punctuation.path}/model.int8.onnx',
        ).writeAsBytes(List.filled(7, 0));
        await File(
          '${alignment.path}/model.int8.onnx',
        ).writeAsBytes(List.filled(13, 0));
        final helper = AsrNativeEnhancer(
          options: const AsrEnhancementOptions(),
          directories: {
            AsrEnhancementOptions.punctuationId: punctuation.path,
            AsrEnhancementOptions.alignmentEnglishId: alignment.path,
          },
          threads: 1,
          language: 'auto',
          recognitionEngine: 'dolphin',
          checkCancelled: () {},
          progress: (_, _, _) {},
        );
        SubtitleItem cue(String text, String lang) => SubtitleItem(
          index: 1,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          text: text,
          asrInfo: SubtitleAsrInfo(language: lang),
        );
        expect(helper.alignmentAllocationBytes([cue('日本語です', 'ja')]), 0);
        expect(helper.punctuationAllocationBytes([cue('日本語です', 'ja')]), 0);
        expect(helper.alignmentAllocationBytes([cue('hello', 'en')]), 39);
        expect(helper.punctuationAllocationBytes([cue('hello', 'en')]), 21);
        expect(helper.punctuationAllocationBytes([cue('hello.', 'en')]), 0);
        expect(helper.residentAlignmentBytes, 0);
        expect(helper.residentPunctuationBytes, 0);
        helper.dispose();
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'legacy diarization preferences never request or freeze speaker models',
    () {
      final options = AsrEnhancementOptions.fromJson({
        'version': 1,
        'diarization': true,
      });
      expect(options.toJson(), isNot(contains('diarization')));
      expect(
        options
            .requiredModels(['zh', 'en'], 'auto')
            .any(retiredAsrModelIds.contains),
        isFalse,
      );
      final spec = ModelJobSpec.fromJson({
        'profile': const ModelServiceProfile(
          id: 'local',
          name: 'local',
          kind: TranscriptionServiceKind.local,
          model: 'sensevoice-small-int8',
        ).toJson(),
        'asrEnhancements': {'diarization': true},
        'enhancementModels': {
          'asr-speaker-campplus': 'old',
          'asr-alignment-en-int8': 'english',
        },
      });
      expect(jsonDecode(spec.enhancementFingerprint)['models'], {
        'asr-alignment-en-int8': 'english',
      });
    },
  );
  test('unknown Latin text is not assumed to be English punctuation input', () {
    final unknown = SubtitleItem(
      index: 1,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 1),
      text: 'xin chao',
    );
    expect(canRestoreAsrPunctuation(unknown, 'auto', 'dolphin'), isFalse);
    expect(canRestoreAsrPunctuation(unknown, 'vi', 'zipformer'), isFalse);
    expect(canRestoreAsrPunctuation(unknown, 'en', 'parakeet'), isTrue);
    expect(canRestoreAsrPunctuation(unknown, 'auto', 'zipformer'), isTrue);
    expect(canRestoreAsrPunctuation(unknown, 'auto', 'firered2'), isTrue);
    expect(canRestoreAsrPunctuation(unknown, 'ja', 'firered2'), isFalse);
  });

  test(
    'alignment context cannot introduce overlap between disjoint original cues',
    () {
      final original = [
        for (var i = 0; i < 2; i++)
          SubtitleItem(
            index: i + 1,
            startTime: Duration(seconds: i),
            endTime: Duration(seconds: i + 1),
            text: 'hello',
          ),
      ];
      final refined = [
        original[0].copyWith(endTime: const Duration(milliseconds: 1080)),
        original[1].copyWith(startTime: const Duration(milliseconds: 980)),
      ];
      final result = guardAsrAlignmentBoundaries(
        original,
        refined,
        review: true,
      );
      expect(result.first.endTime, original.first.endTime);
      expect(result.last.startTime, original.last.startTime);
      expect(
        result.every((c) => c.asrInfo.reviewReason.contains('冲突')),
        isTrue,
      );
      expect(
        guardAsrAlignmentBoundaries(
          original,
          refined,
          review: false,
        ).first.asrInfo.reviewReason,
        isEmpty,
      );
    },
  );
  test('chunk merging keeps identical words spoken by different people', () {
    SubtitleItem cue(int speaker, int start, int end) => SubtitleItem(
      index: speaker,
      startTime: Duration(milliseconds: start),
      endTime: Duration(milliseconds: end),
      text: '是的',
      asrInfo: SubtitleAsrInfo(speaker: 'speaker-$speaker'),
    );
    for (final start in [900, 1100]) {
      final result = TranscriptionSubtitleMerger.finish([
        cue(1, 0, 1000),
        cue(2, start, 1900),
      ]);
      expect(result, hasLength(2));
      expect(result.map((c) => c.asrInfo.speaker), ['speaker-1', 'speaker-2']);
    }
    expect(
      TranscriptionSubtitleMerger.finish([cue(1, 0, 1000), cue(1, 900, 1900)]),
      hasLength(1),
    );
  });
  test(
    'defaults enable all optional stages; task and preference migration differ',
    () {
      final defaults = AsrEnhancementOptions.fromJson(null);
      expect([
        defaults.enabled,
        defaults.denoise,
        defaults.punctuation,
        defaults.alignment,
        defaults.trimSilence,
        defaults.review,
      ], everyElement(isTrue));
      const old = ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'local',
          name: 'local',
          kind: TranscriptionServiceKind.local,
          model: 'sensevoice-small-int8',
        ),
      );
      expect(ModelJobSpec.fromJson(old.toJson()).asrEnhancements, isNull);
      final off = defaults.copyWith(
        enabled: false,
        denoise: false,
        hotwords: '专业词',
      );
      expect(
        AsrEnhancementOptions.fromJson(
          jsonDecode(jsonEncode(off.toJson())),
        ).toJson(),
        off.toJson(),
      );
      expect(off.requiredModels(['zh', 'en'], 'auto'), isEmpty);
      expect(defaults.requiredModels(['zh', 'en', 'ja'], 'ja'), [
        AsrEnhancementOptions.denoiserId,
      ]);
    },
  );

  test(
    'post-processing changes preserve raw recognition key; audio changes invalidate it',
    () {
      ModelJobSpec spec(AsrEnhancementOptions value) => ModelJobSpec(
        profile: const ModelServiceProfile(
          id: 'test',
          name: 'test',
          kind: TranscriptionServiceKind.local,
        ),
        asrEnhancements: value,
      );
      const options = AsrEnhancementOptions();
      final original = spec(options);
      final post = spec(options.copyWith(alignment: false, punctuation: false));
      expect(original.recognitionFingerprint, post.recognitionFingerprint);
      expect(
        original.enhancementFingerprint,
        isNot(post.enhancementFingerprint),
      );
      for (final audioChange in [
        options.copyWith(denoise: false),
        options.copyWith(paddingMs: 200),
        options.copyWith(channel: AsrAudioChannel.left),
        options.copyWith(hotwords: '名词'),
      ]) {
        expect(
          original.recognitionFingerprint,
          isNot(spec(audioChange).recognitionFingerprint),
        );
      }
    },
  );

  test(
    'language tags from SenseVoice normalize without treating Cantonese as Mandarin',
    () {
      expect(normalizeAsrLanguage('<|zh|>'), 'zh');
      expect(normalizeAsrLanguage('en_US'), 'en');
      expect(normalizeAsrLanguage('<|yue|>'), 'yue');
    },
  );

  List<List<double>> logits(List<int> labels, int size) => [
    for (final label in labels)
      [for (var i = 0; i < size; i++) i == label ? 8.0 : -8.0],
  ];
  const vocab = {'<pad>': 0, 'A': 1, 'B': 2, '|': 3, '你': 4};

  test(
    'CTC aligns repeated letters through a blank and preserves offset/time coordinates',
    () {
      final result = alignCtcLogits(
        text: 'Aa B!',
        logits: logits([0, 1, 0, 1, 3, 2, 0], 5),
        vocabulary: vocab,
        offset: const Duration(seconds: 10),
        audioDuration: const Duration(milliseconds: 145),
      );
      expect(result.accepted, isTrue);
      expect(result.hypothesis, 'AA B');
      expect(result.spans.map((s) => (s.textStart, s.textEnd)), [
        (0, 1),
        (1, 2),
        (3, 4),
      ]);
      expect(result.spans.first.startTime, const Duration(milliseconds: 10020));
      expect(
        result.spans.last.endTime,
        lessThanOrEqualTo(const Duration(milliseconds: 10145)),
      );
      expect(result.score, greaterThan(.99));
      final impossible = alignCtcLogits(
        text: 'AA',
        logits: logits([1, 1], 5),
        vocabulary: vocab,
        offset: Duration.zero,
        audioDuration: const Duration(milliseconds: 45),
      );
      expect(impossible.accepted, isFalse);
    },
  );

  test('CTC refuses unknown glyphs, weak acoustics and oversized input', () {
    CtcAlignment align(String text, List<List<double>> rows) => alignCtcLogits(
      text: text,
      logits: rows,
      vocabulary: vocab,
      offset: Duration.zero,
      audioDuration: const Duration(seconds: 2),
    );
    expect(align('你🎵Z', logits([4, 0, 1], 5)).reason, contains('Z'));
    expect(
      align('A', List.generate(10, (_) => List.filled(5, 0.0))).accepted,
      isFalse,
    );
    expect(align('A', logits(List.filled(1601, 1), 5)).accepted, isFalse);
    expect(normalizeAlignmentAudio(Float32List.fromList([.2, .2, .2])), [
      0,
      0,
      0,
    ]);
  });

  test(
    'punctuation preserves words, case, graphemes, metadata and native timings',
    () {
      final cue = SubtitleItem(
        index: 1,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 2),
        text: 'Hello 你好',
        asrInfo: const SubtitleAsrInfo(language: 'zh'),
        timedSpans: const [
          SubtitleTimedSpan(
            textStart: 0,
            textEnd: 5,
            startTime: Duration.zero,
            endTime: Duration(seconds: 1),
          ),
          SubtitleTimedSpan(
            textStart: 6,
            textEnd: 8,
            startTime: Duration(seconds: 1),
            endTime: Duration(seconds: 2),
          ),
        ],
      );
      final restored = restoreAsrPunctuation(cue, 'hello， 你好！');
      expect(restored.text, 'Hello， 你好！');
      expect(restored.timedSpans.last.textStart, 7);
      expect(restored.timedSpans.last.textEnd, 9);
      expect(restored.timedSpans.last.startTime, const Duration(seconds: 1));
      expect(restored.asrInfo.language, 'zh');
      expect(restoreAsrPunctuation(cue, 'hello，你们好！'), same(cue));
      expect(asrTextAgreement('Hello，你好！', 'hello 你好'), 1);
    },
  );

  test(
    'English punctuation uses Latin marks without rewriting lexical text',
    () {
      final cue = SubtitleItem(
        index: 1,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 3),
        text: 'Hello world How are you',
      );
      final restored = restoreAsrPunctuation(
        cue,
        'hello，world！How are you？',
        language: 'en',
      );
      expect(restored.text, 'Hello, world! How are you?');
      expect(
        restoreAsrPunctuation(cue, 'Goodbye，world。', language: 'en'),
        same(cue),
      );
    },
  );

  test('silence trimming protects aligned speech and never deletes text', () {
    final audio = Float32List(48000);
    audio.fillRange(8000, 32000, .1);
    final cue = SubtitleItem(
      index: 1,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 3),
      text: 'hello',
      timedSpans: const [
        SubtitleTimedSpan(
          textStart: 0,
          textEnd: 5,
          startTime: Duration(milliseconds: 400),
          endTime: Duration(milliseconds: 2400),
          role: 'aligned',
        ),
      ],
    );
    final trimmed = trimAsrSilence(cue, audio);
    expect(trimmed.text, 'hello');
    expect(trimmed.startTime, const Duration(milliseconds: 400));
    expect(trimmed.endTime, const Duration(milliseconds: 2400));
    expect(trimAsrSilence(cue, Float32List(48000)), same(cue));
  });

  test(
    'hotwords encode valid model pieces and reject ineffective unknown words',
    () {
      const tokens = '<blk> 0\n▁HELLO 1\n▁ 2\n你 3\n好 4\n';
      expect(encodeAsrHotwords('hello\n你好', tokens), '▁HELLO\n▁ 你 好');
      expect(() => encodeAsrHotwords('unknown', tokens), throwsFormatException);
      expect(() => encodeAsrHotwords('hello:2', tokens), throwsFormatException);
    },
  );

  test(
    'speaker/review metadata survives companion even with no timed tokens',
    () {
      final cue = SubtitleItem(
        index: 1,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
        text: 'Hello',
        asrInfo: const SubtitleAsrInfo(
          speaker: 'speaker-2',
          reviewReason: '复核',
          alignmentScore: .3,
        ),
      );
      const source = '1\n00:00:00,000 --> 00:00:01,000\nHello\n';
      final loaded = SubtitleWordTimingStore.decode(
        source,
        SubtitleWordTimingStore.encode(source, [cue]),
        SubtitleParser.parse(source),
      );
      expect(loaded.single.asrInfo.toJson(), cue.asrInfo.toJson());
    },
  );
}
