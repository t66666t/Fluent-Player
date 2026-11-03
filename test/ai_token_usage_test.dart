import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_token_usage.dart';

void main() {
  test('interface-specific presentation hides CLI cache percentages', () {
    final usage = AiTokenUsage.fromMap({
      'input_tokens': 100,
      'cached_input_tokens': 0,
      'output_tokens': 20,
    });
    final codex = AiUsagePresentation.forReply({
      'backend': 'codex',
    }, usage.toMap());
    expect(codex.label, 'Codex CLI');
    expect(codex.footer(usage), '');
    expect(codex.cachedLabel, '已复用输入');
    expect(
      AiUsagePresentation.forReply({}, {'cached_input_tokens': 10}).kind,
      'codex',
    );
    expect(
      AiUsagePresentation.forReply({
        'backend': 'api',
        'api_protocol': 'gemini',
      }, {}).kind,
      'gemini',
    );
    expect(
      AiUsagePresentation.forReply({
        'backend': 'api',
        'provider_host': 'api.deepseek.com',
      }, {}).kind,
      'deepseek',
    );
  });
  test('tiny cache hits are not rounded down to zero', () {
    expect(AiUsagePresentation.percent(.002), '0.2%');
    expect(AiUsagePresentation.percent(.00001), '<0.1%');
    expect(AiUsagePresentation.percent(0), '0%');
    const deepseek = AiUsagePresentation('deepseek');
    expect(
      deepseek.footer(const AiTokenUsage(input: 100, cached: 0)),
      contains('本次未命中缓存'),
    );
    expect(deepseek.footer(const AiTokenUsage(input: 100)), '');
  });
  test(
    'DeepSeek misses and Codex optional reasoning/write counters survive normalization',
    () {
      expect(
        AiTokenUsage.fromMap({'prompt_cache_miss_tokens': 120}).cacheMiss,
        120,
      );
      final usage = AiTokenUsage.fromMap({
        'input_tokens': 100,
        'output_tokens': 30,
        'reasoning_output_tokens': 10,
        'cache_write_input_tokens': 0,
      });
      expect(usage.reasoning, 10);
      expect(usage.output, 30);
      expect(usage.cacheWrite, 0);
    },
  );
  test(
    'prefix diagnostics detect changed source data without storing content',
    () {
      const before = [
        {'role': 'system', 'content': '规则'},
        {'role': 'user', 'content': '资料AAA'},
      ];
      final trace = aiCachePrefixTrace(before, [
        {'role': 'system', 'content': '规则'},
        {'role': 'user', 'content': '资料BBB'},
      ]);
      expect(trace['cache_prefix_chars'], 4);
      expect(trace['cache_prefix_state'], contains('第 2 条'));
      expect(trace.toString(), isNot(contains('AAA')));
      expect(
        aiCachePrefixTrace(null, before)['cache_prefix_state'],
        contains('没有上一条'),
      );
    },
  );
  test('DeepSeek cached input is not added twice to the total', () {
    final usage = AiTokenUsage.fromMap({
      'prompt_tokens': 1000,
      'completion_tokens': 200,
      'total_tokens': 1200,
      'prompt_cache_hit_tokens': 800,
      'prompt_cache_miss_tokens': 200,
    });
    expect(usage.total, 1200);
    expect(usage.cacheHitRate, .8);
  });
  test('OpenAI reasoning and cache are subsets of output and input', () {
    final usage = AiTokenUsage.fromMap({
      'prompt_tokens': 1000,
      'completion_tokens': 200,
      'prompt_tokens_details': {'cached_tokens': 500},
      'completion_tokens_details': {'reasoning_tokens': 120},
    });
    expect(usage.total, 1200);
    expect(usage.reasoning, 120);
    expect(usage.cacheHitRate, .5);
  });
  test('Claude fresh, cached and cache-write inputs form inclusive input', () {
    final usage = AiTokenUsage.fromMap({
      'input_tokens': 20,
      'output_tokens': 10,
      'cache_read_input_tokens': 70,
      'cache_creation_input_tokens': 10,
    });
    expect(usage.input, 100);
    expect(usage.total, 110);
    expect(usage.cacheHitRate, .7);
    expect(AiTokenUsage.fromMap(usage.toMap()).input, 100);
  });
  test('Gemini thought tokens are included once and cache is inclusive', () {
    final usage = AiTokenUsage.fromMap({
      'promptTokenCount': 100,
      'cachedContentTokenCount': 80,
      'candidatesTokenCount': 30,
      'thoughtsTokenCount': 20,
      'totalTokenCount': 150,
    });
    expect(usage.output, 50);
    expect(usage.total, 150);
    expect(usage.cacheHitRate, .8);
  });
  test('Codex and OpenCode normalize their distinct CLI usage formats', () {
    expect(
      AiTokenUsage.fromMap({
        'input_tokens': 100,
        'cached_input_tokens': 80,
        'output_tokens': 20,
      }).cacheHitRate,
      .8,
    );
    final usage = AiTokenUsage.fromMap({
      'input': 20,
      'output': 10,
      'reasoning': 5,
      'cache': {'read': 70, 'write': 10},
    });
    expect(usage.input, 100);
    expect(usage.output, 15);
    expect(usage.total, 115);
  });
  test('missing and malformed fields remain unknown instead of zero', () {
    expect(AiTokenUsage.fromMap(null).total, isNull);
    expect(
      AiTokenUsage.fromMap({
        'prompt_tokens': -1,
        'completion_tokens': '10',
      }).complete,
      isFalse,
    );
    expect(
      AiTokenUsage.fromMap({
        'prompt_tokens': 100,
        'completion_tokens': 20,
      }).cacheHitRate,
      isNull,
    );
    expect(
      AiTokenUsage.fromMap({
        'prompt_tokens': 100,
        'prompt_tokens_details': {'cached_tokens': 0},
      }).cacheHitRate,
      0,
    );
  });
  test('separate request aggregation tracks missing reports', () {
    final sum = AiUsageAccumulator()
      ..add({'prompt_tokens': 100, 'completion_tokens': 20})
      ..add(null);
    expect(sum.toMap()['total_tokens'], 120);
    expect(sum.toMap()['calls'], 2);
    expect(sum.toMap()['reported_calls'], 1);
    expect(sum.toMap().containsKey('prompt_cache_hit_tokens'), isFalse);
  });
  test(
    'cumulative SSE usage merges fields without summing repeated events',
    () {
      var usage = AiTokenUsage.merge(null, {
        'prompt_tokens': 100,
        'completion_tokens': 5,
        'prompt_tokens_details': {'cached_tokens': 80},
      });
      usage = AiTokenUsage.merge(usage, {
        'prompt_tokens': 100,
        'completion_tokens': 20,
        'prompt_tokens_details': {'cached_tokens': null, 'audio_tokens': 0},
      });
      expect(AiTokenUsage.fromMap(usage).total, 120);
      expect(AiTokenUsage.fromMap(usage).cacheHitRate, .8);
    },
  );
  test(
    'reply metrics survive conversation JSON and older records still load',
    () {
      final message = AiChatMessage(
        id: 'm',
        role: 'assistant',
        content: '回答',
        usage: {'total_tokens': 123},
        responseInfo: {
          'backend': 'codex',
          'model': 'custom',
          'estimated_input': 200,
          'preparation_usage': {'calls': 3, 'total_tokens': 500},
        },
      );
      final restored = AiChatMessage.fromJson(message.toJson());
      expect(restored.responseInfo, message.responseInfo);
      expect(
        AiUsagePresentation.forReply(
          restored.responseInfo!,
          restored.usage,
        ).kind,
        'codex',
      );
      expect(restored.usage, message.usage);
      final old = message.toJson()..remove('responseInfo');
      expect(AiChatMessage.fromJson(old).responseInfo, isNull);
    },
  );
  test('Chinese estimate does not equate every UTF-8 byte to a token', () {
    expect(AiTokenEstimate.text('中文'), 4);
    expect(AiTokenEstimate.text('example text'), lessThan(12));
  });
}
