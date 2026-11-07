import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_agent_translation.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/smart_subtitle_translator.dart';
import 'package:video_player_app/services/subtitle_translation_languages.dart';
import 'package:video_player_app/services/subtitle_translation_policy.dart';

SubtitleItem _cue(int index, String text) => SubtitleItem(
  index: index,
  startTime: Duration(seconds: index),
  endTime: Duration(seconds: index + 1),
  text: text,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'smart Agent parts reproduce the actual router and protect literals',
    () async {
      final items = [
        _cue(1, '<i>大家好。</i> Please sit down.ありがとう。'),
        _cue(2, '  大家好。 https://example.test/subtitle?a=1 %s {{speaker}}  '),
        _cue(3, '12345 !?'),
        _cue(
          4,
          '<i data-marker="\uE000fluent-player-agent-translation:0:">你好。</i>',
        ),
      ];
      const policy = SmartTranslationPolicy();
      final plan = await ExternalAiAgentTranslationPlanner().plan(
        items: items,
        cueIds: ['one', 'two', 'three', 'four'],
        policy: policy,
      );
      final expected = await SmartSubtitleTranslator().translate(
        items: items,
        policy: policy,
        onProgress: (_) {},
        translateBatch:
            (group, source, target, scope, progress, translated) async => [
              for (final item in group) '[$target:${item.text}]',
            ],
      );
      final output = plan.reassemble({
        for (final part in plan.parts)
          part.partId: '[${part.targetLanguage}:${part.text}]',
      });
      expect(output, expected);
      expect(
        plan.partsForCue('one').map((part) => part.targetLanguage).toSet(),
        {'en', 'zh-CN'},
      );
      expect(output[1], contains('https://example.test/subtitle?a=1'));
      expect(output[1], contains('%s {{speaker}}'));
      expect(plan.partsForCue('three'), isEmpty);
      expect(output[2], items[2].text);
      expect(
        output[3],
        startsWith(
          '<i data-marker="\uE000fluent-player-agent-translation:0:">',
        ),
      );
    },
  );

  test(
    'custom keep rules and uncertain text stay in reconstruction templates',
    () async {
      const policy = SmartTranslationPolicy(
        rules: [
          SmartTranslationRule(source: 'zh-CN', target: keepOriginal),
          SmartTranslationRule(source: 'en', target: 'fr'),
        ],
        otherTarget: 'zh-CN',
      );
      final plan = await ExternalAiAgentTranslationPlanner().plan(
        items: [_cue(1, '<b>大家好。</b> Please sit down.')],
        policy: policy,
      );
      expect(plan.parts, hasLength(1));
      expect(plan.parts.single.sourceLanguage, 'en');
      expect(plan.parts.single.targetLanguage, 'fr');
      expect(plan.reassemble({plan.parts.single.partId: 'Asseyez-vous.'}), [
        '<b>大家好。</b> Asseyez-vous.',
      ]);
      // A nearby English cue can correctly disambiguate a short Latin token.
      // Route this uncertain sample alone, without that language evidence.
      final uncertain = await ExternalAiAgentTranslationPlanner().plan(
        items: [_cue(1, 'qzxv')],
        policy: policy,
      );
      expect(uncertain.parts, isEmpty);
      expect(uncertain.reassemble({}), ['qzxv']);
      final reference = await SmartSubtitleTranslator().translate(
        items: [_cue(1, 'qzxv')],
        policy: policy,
        onProgress: (_) {},
        translateBatch:
            (group, source, target, scope, progress, translated) async {
              fail(
                'An isolated uncertain token must be retained by the real router',
              );
            },
      );
      expect(uncertain.reassemble({}), reference);
    },
  );

  test(
    'unsupported smart source languages follow the existing keep behavior',
    () async {
      final plan = await ExternalAiAgentTranslationPlanner().plan(
        items: [_cue(1, '皆さん、こんにちは。'), _cue(2, '大家好。')],
        policy: const SmartTranslationPolicy(),
        supportedSourceLanguages: const [
          SubtitleTranslationLanguage(code: 'zh-CN', label: '中文'),
        ],
      );
      expect(plan.partsForCue('cue-1'), isEmpty);
      expect(plan.reassemble({plan.parts.single.partId: 'Hello.'}), [
        '皆さん、こんにちは。',
        'Hello.',
      ]);
    },
  );

  test(
    'fixed mode keeps whole cues and durable plans restore exact structure',
    () async {
      final items = [
        _cue(1, '<i>Hello.</i> 你好。'),
        _cue(2, '   '),
        _cue(3, 'Thanks.'),
      ];
      final plan = await ExternalAiAgentTranslationPlanner().plan(
        items: items,
        cueIds: ['alpha', 'blank', 'omega'],
        fixedTargetLanguage: 'ja',
        sourceLanguage: 'auto',
      );
      final restored = ExternalAiAgentTranslationPlan.fromJson(
        jsonDecode(jsonEncode(plan.toJson())) as Map,
      );
      expect(restored.parts.map((part) => part.text), [
        items[0].text,
        items[2].text,
      ]);
      expect(
        restored.parts.every((part) => part.targetLanguage == 'ja'),
        isTrue,
      );
      expect(restored.reassemble({'part-1': '一', 'part-2': '二'}), [
        '一',
        '   ',
        '二',
      ]);
      expect(restored.reassembleForCue('alpha', {'part-1': '一'}), '一');
      expect(restored.toJson(), plan.toJson());
    },
  );

  test(
    'part writes cannot silently omit, add, or blank translated fragments',
    () async {
      final plan = await ExternalAiAgentTranslationPlanner().plan(
        items: [_cue(1, 'Hello.'), _cue(2, 'Thanks.')],
        fixedTargetLanguage: 'fr',
      );
      expect(
        () => plan.reassemble({'part-1': 'Bonjour.'}),
        throwsArgumentError,
      );
      expect(
        () => plan.reassemble({'part-1': ' ', 'part-2': 'Merci.'}),
        throwsArgumentError,
      );
      expect(
        () => plan.reassemble({
          'part-1': 'Bonjour.',
          'part-2': 'Merci.',
          'unknown': 'X',
        }),
        throwsArgumentError,
      );
      expect(() => plan.reassembleForCue('unknown', {}), throwsArgumentError);
      final malformed = jsonDecode(jsonEncode(plan.toJson())) as Map;
      ((malformed['cues'] as List).first as Map)['segments'] = [
        {'partId': 'part-2'},
      ];
      expect(
        () => ExternalAiAgentTranslationPlan.fromJson(malformed),
        throwsFormatException,
      );
    },
  );

  test(
    'missing policy and duplicate cue IDs are rejected before routing',
    () async {
      final planner = ExternalAiAgentTranslationPlanner();
      await expectLater(
        planner.plan(items: [_cue(1, 'Hello.')]),
        throwsArgumentError,
      );
      await expectLater(
        planner.plan(
          items: [_cue(1, 'Hello.'), _cue(2, 'Thanks.')],
          cueIds: ['same', 'same'],
          fixedTargetLanguage: 'fr',
        ),
        throwsArgumentError,
      );
    },
  );
}
