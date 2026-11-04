import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/local_translation_batch.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';

void main() {
  test(
    'copied Korean sentences are rejected and Qwen repairs keep other prompts',
    () {
      const korean = '<i>조만 생각을 하면서 살 훨씬 편할 거야.</i> %s';
      expect(
        () => validateLocalTranslation(korean, korean, targetLanguage: 'zh-CN'),
        throwsFormatException,
      );
      expect(
        () => validateLocalTranslation(
          korean,
          '<i>多想一想，生活会轻松得多。</i> %s',
          targetLanguage: 'zh-CN',
        ),
        returnsNormally,
      );
      expect(
        () => validateLocalTranslation('삼성', '삼성', targetLanguage: 'zh-CN'),
        returnsNormally,
      );
      final repaired = localTranslationSingleRetryPrompt(
        initialPrompt: 'first',
        engine: 'qwen3',
        source: korean,
        targetLanguage: 'zh-CN',
        targetLabel: '简体中文',
        glossary: '生活',
      );
      expect(repaired, contains('不要重复韩语原文'));
      expect(repaired, contains(korean));
      expect(repaired, contains('生活'));
      for (final engine in ['hy-mt', 'qwen3']) {
        expect(
          localTranslationSingleRetryPrompt(
            initialPrompt: 'first',
            engine: engine,
            source: 'Hello world',
            targetLanguage: 'zh-CN',
            targetLabel: '简体中文',
          ),
          'first',
        );
      }
      expect(
        localTranslationSingleRetryPrompt(
          initialPrompt: 'first',
          engine: 'qwen3',
          source: korean,
          targetLanguage: 'en',
          targetLabel: 'English',
        ),
        'first',
      );
    },
  );
  test(
    'local failure summaries explain categories without exposing raw errors',
    () {
      expect(
        localTranslationFailureSummary(
          const LocalTranslationIncomplete('已完成 1899/1900 条，第 901 条待补译'),
        ),
        contains('1899/1900'),
      );
      expect(
        localTranslationFailureSummary(
          const FormatException('private subtitle'),
        ),
        contains('完整性检查'),
      );
      expect(
        localTranslationFailureSummary(StateError('可用内存不足')),
        contains('内存余量不足'),
      );
      expect(
        localTranslationFailureSummary(StateError('private subtitle')),
        isNot(contains('private subtitle')),
      );
    },
  );

  test('batch rows keep IDs, quotes, Unicode and embedded newlines', () {
    final reply = [
      jsonEncode([12, '第二行\n<i>你好😀</i>']),
      jsonEncode([7, '他说："再见"。']),
      jsonEncode([88, '不属于此批次']),
      '[9,"unfinished',
    ].join('\n');
    expect(parseLocalTranslationBatch(reply, {7, 9, 12}), {
      12: '第二行\n<i>你好😀</i>',
      7: '他说："再见"。',
    });
  });
  test('duplicate IDs are discarded rather than silently overwritten', () {
    expect(
      parseLocalTranslationBatch('[0,"甲"]\n[1,"乙"]\n[0,"错位"]\n[0,"仍然重复"]', {
        0,
        1,
      }),
      {1: '乙'},
    );
  });
  test(
    'localized JSON punctuation is repaired without changing text or IDs',
    () {
      expect(
        parseLocalTranslationBatch(
          '[8,"连接一直很松动。”]\n[9,“让我们再试一次。”]\n[10，“他说：“好的，走吧。””]\n[11,「名前は何ですか？」]',
          {8, 9, 10, 11},
        ),
        {8: '连接一直很松动。', 9: '让我们再试一次。', 10: '他说：“好的，走吧。”', 11: '名前は何ですか？'},
      );
      expect(parseLocalTranslationBatch('[12，"A，B, C"]', {12}), {12: 'A，B, C'});
      expect(
        () => validateLocalTranslation('hello', '译文。”] [9,'),
        throwsFormatException,
      );
    },
  );
  test(
    'explicit ID rows in arrays, fences and trailing commas are accepted',
    () {
      expect(parseLocalTranslationBatch('[["2","乙"],[1,"甲"]]', {1, 2}), {
        2: '乙',
        1: '甲',
      });
      expect(
        parseLocalTranslationBatch('```json\n[\n[2,"乙"],\n[1,"甲"]\n]\n```', {
          1,
          2,
        }),
        {2: '乙', 1: '甲'},
      );
      expect(parseLocalTranslationBatch('[[0,"甲"],[0,"重复"]]', {0}), isEmpty);
    },
  );
  test('never invent cue IDs for positional text or invalid value types', () {
    for (final reply in [
      '["译文一","译文二"]',
      '[1,42]',
      '[true,"甲"]',
      '{"0":"甲","0":"重复"}',
    ]) {
      expect(parseLocalTranslationBatch(reply, {0, 1}), isEmpty);
    }
  });
  test(
    'rejects untranslated sentences, leaked instructions and stray batch punctuation',
    () {
      expect(
        () => validateLocalTranslation(
          '<i>Hello, welcome.</i>',
          '<i>Hello, welcome.</i>',
          targetLanguage: 'zh-CN',
        ),
        throwsFormatException,
      );
      expect(
        () => validateLocalTranslation(
          'hello',
          'Background (no translation): hello',
        ),
        throwsFormatException,
      );
      expect(
        () => validateLocalTranslation('hello', '你好]'),
        throwsFormatException,
      );
      expect(
        () => validateLocalTranslation('hello', '你好 [叹气]'),
        returnsNormally,
      );
      expect(
        () => validateLocalTranslation(
          'John Smith',
          'John Smith',
          targetLanguage: 'zh-CN',
        ),
        returnsNormally,
      );
      expect(
        () => validateLocalTranslation('%s', '%s', targetLanguage: 'zh-CN'),
        returnsNormally,
      );
      expect(
        () => validateLocalTranslation(
          '请保存设置，然后关闭窗口。',
          '请保存设置，然后关闭窗口。',
          targetLanguage: 'en',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'repairs only format fragments while preserving words and required placeholders',
    () {
      expect(
        normalizeLocalTranslation('Save <b>here</b>.', '请在<b>这里</b>保存。</b>'),
        '请在<b>这里</b>保存。',
      );
      expect(normalizeLocalTranslation('hello', '你好。</b>'), '你好。');
      expect(normalizeLocalTranslation('hello', 'Hello.]'), 'Hello.');
      expect(normalizeLocalTranslation('array[0]', '数组[0]'), '数组[0]');
      final lost = normalizeLocalTranslation('<i>Hello {{name}}</i>', '你好');
      expect(
        () => validateLocalTranslation('<i>Hello {{name}}</i>', lost),
        throwsFormatException,
      );
      expect(parseLocalTranslationBatch('[0,"Hello.]', {0}), isEmpty);
      expect(
        parseLocalTranslationBatch('[0,"Hello.]', {
          0,
        }, allowMissingClosingQuote: true),
        {0: 'Hello.'},
      );
      expect(
        parseLocalTranslationBatch('[0,"unfinished', {
          0,
        }, allowMissingClosingQuote: true),
        isEmpty,
      );
    },
  );
  test(
    'natural EOS repairs only a missing outer bracket after complete JSON text',
    () {
      const rows = '[2,"不，谢谢。我已经喝了两杯了。"\n[3,"好的，明天见。"';
      expect(parseLocalTranslationBatch(rows, {2, 3}), isEmpty);
      expect(
        parseLocalTranslationBatch(rows, {
          2,
          3,
        }, allowMissingClosingBracket: true),
        {2: '不，谢谢。我已经喝了两杯了。', 3: '好的，明天见。'},
      );
      expect(
        parseLocalTranslationBatch(
          '[2,"<i>你好</i> {{name}}\\n他说：\\"再见\\"。"',
          {2},
          allowMissingClosingBracket: true,
        ),
        {2: '<i>你好</i> {{name}}\n他说："再见"。'},
      );
      for (final incomplete in [
        '[2,"unfinished',
        '[2,"unfinished\\"',
        '[2,"unfinished]',
        'Text: [2,"你好"',
      ]) {
        expect(
          parseLocalTranslationBatch(incomplete, {
            2,
          }, allowMissingClosingBracket: true),
          isEmpty,
        );
      }
      expect(
        parseLocalTranslationBatch('[2,"甲"\n[2,"重复"]', {
          2,
        }, allowMissingClosingBracket: true),
        isEmpty,
      );
    },
  );

  test('batch prompt escapes cue text and caps contextual overhead', () {
    final prompt = localTranslationBatchPrompt(
      texts: {4: 'Hello\n"world" 😀'},
      target: '中文',
      glossary: '术' * 700,
    );
    expect(prompt, contains(jsonEncode([4, 'Hello\n"world" 😀'])));
    expect(prompt, contains('术' * 500));
    expect(prompt, isNot(contains('术' * 501)));
    expect(() => localTranslationBatchGrammar([2, 2]), throwsArgumentError);
    expect(() => localTranslationBatchGrammar([]), throwsArgumentError);
    expect(
      localTranslationBatchGrammar([0, 12]),
      startsWith('root ::= "[0," string "]" "\\n" "[12,"'),
    );
  });
  test(
    'long cues split without cutting Unicode, subtitle tags or placeholders',
    () {
      final source =
          '${'😀' * 395}<font color="red">hello</font> {{name}} ${'字幕。' * 280}';
      final parts = splitLocalTranslationText(source);
      expect(parts.join(), source);
      expect(parts, isNot(contains(contains('\uFFFD'))));
      expect(parts.any((p) => p.contains('<font color="red">')), isTrue);
      expect(parts.any((p) => p.contains('{{name}}')), isTrue);
      expect(
        () => splitLocalTranslationText('a', maxRunes: 0),
        throwsArgumentError,
      );
      expect(
        () => validateLocalTranslation('hello', '<think>hidden'),
        throwsFormatException,
      );
    },
  );
  test('automatic CPU budgets are bounded and leave UI capacity', () {
    for (final mobile in [true, false]) {
      expect(
        localTranslationThreadBudget(
          requested: 0,
          processors: 1,
          mobile: mobile,
        ),
        1,
      );
      expect(
        localTranslationThreadBudget(
          requested: 8,
          processors: 2,
          mobile: mobile,
        ),
        // Manual preferences still leave a core for the player and UI.
        1,
      );
    }
    expect(
      localTranslationThreadBudget(requested: 0, processors: 16, mobile: true),
      4,
    );
    expect(
      localTranslationThreadBudget(requested: 0, processors: 16, mobile: false),
      6,
    );
  });
  test(
    'model prompts use full target language names for structured translation',
    () {
      expect(
        localTranslationEnglishTarget('zh-TW', '中文'),
        'Traditional Chinese',
      );
      expect(
        localTranslationEnglishTarget('zh-CN', '中文'),
        'Simplified Chinese',
      );
      expect(localTranslationEnglishTarget('en-US', '英语'), 'English');
      expect(localTranslationEnglishTarget('ja', '日语'), 'Japanese');
      final prompt = localTranslationBatchPrompt(
        texts: {0: '<i>Hello.</i>'},
        target: 'Simplified Chinese',
        english: true,
      );
      expect(prompt, contains('second element'));
      expect(prompt, contains('Translate text inside HTML tags'));
    },
  );
  for (final platform in ['android', 'ios', 'macos', 'windows', 'linux']) {
    test(
      '$platform uses the safe default backend and an explicit CPU fallback',
      () {
        final automatic = localTranslationModelParams(
          const LocalTranslationOptions(),
          platform: platform,
          processors: 16,
        );
        final apple = platform == 'ios';
        expect(
          automatic.device,
          apple ? ComputeDevice.auto : ComputeDevice.cpu,
        );
        expect(
          automatic.preferredBackend,
          apple ? GpuBackend.auto : GpuBackend.cpu,
        );
        final cpu = localTranslationModelParams(
          const LocalTranslationOptions(),
          platform: platform,
          processors: 16,
          forceCpu: true,
        );
        expect(cpu.device, ComputeDevice.cpu);
        expect(cpu.preferredBackend, GpuBackend.cpu);
        expect(
          cpu.numberOfThreads,
          platform == 'ios' || platform == 'android' ? 4 : 6,
        );
        expect(cpu.batchSize, greaterThanOrEqualTo(cpu.microBatchSize));
        final preferred = localTranslationModelParams(
          const LocalTranslationOptions(
            acceleration: TranslationAcceleration.gpu,
          ),
          platform: platform,
          processors: 16,
        );
        expect(
          preferred.device,
          platform == 'ios' ? ComputeDevice.auto : ComputeDevice.cpu,
        ); // GPU requests outside iOS use the private worker, including Android.
        expect(
          preferred.preferredBackend,
          platform == 'ios' ? GpuBackend.auto : GpuBackend.cpu,
        );
        if (platform == 'android') {
          expect(preferred.preferredBackend, GpuBackend.cpu);
        }
      },
    );
  }
  test('translation preferences round trip and old jobs get safe defaults', () {
    const options = LocalTranslationOptions(
      acceleration: TranslationAcceleration.cpu,
      threads: 4,
      batchSize: 6,
    );
    expect(
      LocalTranslationOptions.fromJson(options.toJson()).toJson(),
      options.toJson(),
    );
    final spec = ModelJobSpec.fromJson({
      'profile': const ModelServiceProfile(
        id: 'old',
        name: 'old',
        kind: TranscriptionServiceKind.local,
      ).toJson(),
      'threads': 2,
    });
    expect(spec.translation.toJson(), const LocalTranslationOptions().toJson());
    final bounded = LocalTranslationOptions.fromJson({
      'threads': 100,
      'batchSize': 0,
      'acceleration': 'unknown',
    });
    expect(bounded.threads, 12);
    expect(bounded.batchSize, 1);
    expect(bounded.acceleration, TranslationAcceleration.auto);
  });
}
