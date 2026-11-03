import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_answer_continuation.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_prompt_composer.dart';
import 'package:video_player_app/features/ai_chat/ai_token_usage.dart';

class _Transport extends AiChatTransport {
  _Transport(this.respond);
  final Stream<AiChatDelta> Function(int, AiChatCancellation) respond;
  final requests = <List<Map<String, String>>>[];
  final configurations = <AiChatSettings>[];
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) {
    requests.add(messages);
    configurations.add(settings);
    return respond(requests.length - 1, cancellation);
  }
}

class _Reply {
  String content = '', reasoning = '';
  String? finish;
  Map<String, dynamic>? usage;
  void add(AiChatDelta delta) {
    content = delta.contentSnapshot ?? '$content${delta.content}';
    reasoning = delta.reasoningSnapshot ?? '$reasoning${delta.reasoning}';
    finish = delta.finishReason ?? finish;
    usage = delta.usageSnapshot ?? AiTokenUsage.merge(usage, delta.usage);
  }
}

void main() {
  const messages = <Map<String, String>>[
    {'role': 'system', 'content': '直接回答最新问题'},
    {'role': 'user', 'content': '全文资料：从头到尾的证据'},
    {'role': 'user', 'content': '概括整体联系'},
  ];
  const settings = AiChatSettings(
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'glm_5.3_prime',
    contextTokens: 64000,
    maxOutputTokens: 8192,
    thinkingEnabled: true,
    reasoningEffort: 'max',
    requestInputTokens: 60000,
  );
  const firstUsage = <String, dynamic>{
    'prompt_tokens': 200,
    'completion_tokens': 8192,
    'total_tokens': 8392,
    'prompt_cache_hit_tokens': 100,
    'prompt_cache_miss_tokens': 100,
    'cache_creation_input_tokens': 20,
    'completion_tokens_details': {'reasoning_tokens': 8000},
  };
  const secondUsage = <String, dynamic>{
    'prompt_tokens': 400,
    'completion_tokens': 200,
    'total_tokens': 600,
    'prompt_cache_hit_tokens': 200,
    'prompt_cache_miss_tokens': 200,
    'cache_creation_input_tokens': 0,
    'completion_tokens_details': {'reasoning_tokens': 100},
  };

  test(
    'cumulative CLI and Gemini billing never anchors the original context',
    () async {
      for (final config in [
        settings.copyWith(backend: AiBackend.codex),
        settings.copyWith(apiProtocol: AiApiProtocol.gemini),
      ]) {
        final transport = _Transport((_, _) async* {
          yield const AiChatDelta(
            content: '回答',
            finishReason: 'stop',
            usage: {
              'prompt_tokens': 900000,
              'completion_tokens': 20,
              'total_tokens': 900020,
            },
          );
        });
        Map<String, dynamic>? metadata;
        await AiAnswerContinuation(transport)
            .stream(
              settings: config,
              messages: messages,
              cancellation: AiChatCancellation(),
              onUsage: (value) => metadata = value,
            )
            .drain<void>();
        expect(metadata!['initial_input_tokens'], isNull);
        expect(metadata!['prompt_tokens'], 900000);
      }
      final transport = _Transport((_, _) async* {
        yield const AiChatDelta(
          content: '回答',
          finishReason: 'stop',
          usage: {
            'prompt_tokens': 900000,
            'context_input_tokens': 200,
            'completion_tokens': 20,
          },
        );
      });
      Map<String, dynamic>? metadata;
      await AiAnswerContinuation(transport)
          .stream(
            settings: settings.copyWith(apiProtocol: AiApiProtocol.gemini),
            messages: messages,
            cancellation: AiChatCancellation(),
            onUsage: (value) => metadata = value,
          )
          .drain<void>();
      expect(metadata!['initial_input_tokens'], 200);
    },
  );

  test(
    'length recovery preserves original evidence, body and exact usage once',
    () async {
      final transport = _Transport((pass, _) async* {
        if (pass == 0) {
          yield const AiChatDelta(
            content: '第一部分。',
            reasoning: '原思考',
            usage: firstUsage,
            finishReason: 'length',
          );
        } else {
          yield const AiChatDelta(content: '第二部分', reasoning: '补写思考');
          yield const AiChatDelta(
            content: '。完成。',
            usage: secondUsage,
            finishReason: 'stop',
          );
        }
      });
      final reply = _Reply();
      Map<String, dynamic>? metadata;
      await for (final delta in AiAnswerContinuation(transport).stream(
        settings: settings,
        messages: messages,
        cancellation: AiChatCancellation(),
        onUsage: (value) => metadata = value,
      )) {
        reply.add(delta);
      }
      expect(reply.content, '第一部分。第二部分。完成。');
      expect(reply.reasoning, '原思考补写思考');
      expect(reply.finish, 'stop');
      expect(transport.requests, hasLength(2));
      expect(transport.requests.last.take(messages.length), messages);
      expect(transport.requests.last[messages.length], {
        'role': 'assistant',
        'content': '第一部分。',
      });
      expect(
        transport.requests.last.last['content'],
        AiAnswerContinuation.instruction,
      );
      expect(transport.configurations.first.reasoningEffort, 'max');
      expect(transport.configurations.last.reasoningEffort, 'low');
      expect(transport.configurations.last.requestInputTokens, lessThan(1000));
      expect(transport.configurations.last.maxOutputTokens, 8192);
      final counted = AiTokenUsage.fromMap(reply.usage);
      expect(counted.input, 600);
      expect(counted.output, 8392);
      expect(counted.total, 8992);
      expect(counted.reasoning, 8100);
      expect(counted.cached, 300);
      expect(counted.cacheMiss, 300);
      expect(counted.cacheWrite, 20);
      expect(metadata!['calls'], 2);
      expect(metadata!['reported_calls'], 2);
      expect(metadata!['continuations'], 1);
      expect(metadata!['initial_input_tokens'], 200);
      expect(settings.reasoningEffort, 'max');
    },
  );

  test('permanent truncation has a strict two-generation ceiling', () async {
    final transport = _Transport((_, _) async* {
      yield const AiChatDelta(content: '片段', finishReason: 'length');
    });
    final reply = _Reply();
    await for (final delta in AiAnswerContinuation(transport).stream(
      settings: settings,
      messages: messages,
      cancellation: AiChatCancellation(),
    )) {
      reply.add(delta);
    }
    expect(transport.requests, hasLength(2));
    expect(reply.content, '片段片段');
    expect(reply.finish, 'length');
    expect(AiTokenUsage.fromMap(reply.usage).total, isNull);
  });

  test(
    'network replacement snapshots stay inside the partial answer and billing sums do not inflate context measurement',
    () async {
      final transport = _Transport((pass, _) async* {
        if (pass == 0) {
          yield const AiChatDelta(content: '断线前残稿', usage: firstUsage);
          yield const AiChatDelta(stage: '重连', reconnecting: true);
          yield const AiChatDelta(
            contentSnapshot: '恢复后正文',
            reasoningSnapshot: '恢复后思考',
            usage: {'prompt_tokens': 40000, 'completion_tokens': 9000},
            finishReason: 'length',
            reconnecting: false,
          );
        } else {
          yield const AiChatDelta(content: '补全', finishReason: 'stop');
        }
      });
      final reply = _Reply();
      Map<String, dynamic>? metadata;
      await for (final delta in AiAnswerContinuation(transport).stream(
        settings: settings.copyWith(requestInputTokens: 1000),
        messages: messages,
        cancellation: AiChatCancellation(),
        onUsage: (value) => metadata = value,
      )) {
        reply.add(delta);
      }
      expect(reply.content, '恢复后正文补全');
      expect(reply.reasoning, '恢复后思考');
      expect(transport.configurations.last.requestInputTokens, lessThan(2000));
      expect(transport.requests.last[messages.length]['content'], '恢复后正文');
      expect(metadata!['initial_input_tokens'], isNull);
    },
  );

  test('optional thinking is disabled only for the continuation', () async {
    final transport = _Transport((pass, _) async* {
      yield AiChatDelta(
        content: '内容',
        finishReason: pass == 0 ? 'length' : 'stop',
      );
    });
    await AiAnswerContinuation(transport)
        .stream(
          settings: settings.copyWith(model: 'qwen-plus'),
          messages: messages,
          cancellation: AiChatCancellation(),
        )
        .drain<void>();
    expect(transport.configurations.first.thinkingEnabled, isTrue);
    expect(transport.configurations.last.thinkingEnabled, isFalse);
    expect(transport.configurations.last.thinkingBudget, 0);
  });

  test(
    'thought-only truncation requests the missing body without sending thoughts as history',
    () async {
      final transport = _Transport((pass, _) async* {
        yield pass == 0
            ? const AiChatDelta(reasoning: '推理', finishReason: 'length')
            : const AiChatDelta(content: '正文', finishReason: 'stop');
      });
      final reply = _Reply();
      await for (final delta in AiAnswerContinuation(transport).stream(
        settings: settings,
        messages: messages,
        cancellation: AiChatCancellation(),
      )) {
        reply.add(delta);
      }
      expect(reply.content, '正文');
      expect(reply.reasoning, '推理');
      expect(transport.requests.last, hasLength(messages.length + 1));
      expect(
        transport.requests.last.last['content'],
        AiAnswerContinuation.bodyInstruction,
      );
      expect(transport.requests.last.toString(), isNot(contains('推理')));
    },
  );

  for (final finish in [
    'stop',
    'content_filter',
    'aborted',
    'tool_calls',
    null,
  ]) {
    test('finish $finish does not trigger automatic continuation', () async {
      final transport = _Transport((_, _) async* {
        yield AiChatDelta(content: '保留内容', finishReason: finish);
      });
      await AiAnswerContinuation(transport)
          .stream(
            settings: settings,
            messages: messages,
            cancellation: AiChatCancellation(),
          )
          .drain<void>();
      expect(transport.requests, hasLength(1));
    });
  }

  test(
    'empty response and CLI truncation do not create API continuation calls',
    () async {
      for (final config in [
        settings,
        settings.copyWith(backend: AiBackend.codex),
      ]) {
        final transport = _Transport((_, _) async* {
          yield AiChatDelta(
            content: config.backend == AiBackend.api ? '' : 'CLI',
            finishReason: 'length',
          );
        });
        await AiAnswerContinuation(transport)
            .stream(
              settings: config,
              messages: messages,
              cancellation: AiChatCancellation(),
            )
            .drain<void>();
        expect(transport.requests, hasLength(1));
      }
    },
  );

  test(
    'cancellation prevents extra generation and keeps visible text',
    () async {
      final cancellation = AiChatCancellation();
      final transport = _Transport((_, _) async* {
        yield const AiChatDelta(
          content: '已生成',
          usage: firstUsage,
          finishReason: 'length',
        );
      });
      final reply = _Reply();
      await for (final delta in AiAnswerContinuation(transport).stream(
        settings: settings,
        messages: messages,
        cancellation: cancellation,
      )) {
        reply.add(delta);
        cancellation.cancel();
      }
      expect(transport.requests, hasLength(1));
      expect(reply.content, '已生成');
      expect(AiTokenUsage.fromMap(reply.usage).total, 8392);
    },
  );

  test('cancellation during continuation retains both known charges', () async {
    final cancellation = AiChatCancellation();
    final transport = _Transport((pass, _) async* {
      yield AiChatDelta(
        content: pass == 0 ? '原文' : '补文',
        usage: pass == 0 ? firstUsage : secondUsage,
        finishReason: pass == 0 ? 'length' : null,
      );
      if (pass == 1) cancellation.cancel();
    });
    final reply = _Reply();
    await for (final delta in AiAnswerContinuation(transport).stream(
      settings: settings,
      messages: messages,
      cancellation: cancellation,
    )) {
      reply.add(delta);
    }
    expect(transport.requests, hasLength(2));
    expect(reply.content, '原文补文');
    expect(AiTokenUsage.fromMap(reply.usage).total, 8992);
  });

  test(
    'second-call failure preserves first and partial bodies and reports incomplete usage',
    () async {
      final transport = _Transport((pass, _) async* {
        yield AiChatDelta(
          content: pass == 0 ? '原文' : '半句',
          usage: pass == 0 ? firstUsage : null,
          finishReason: pass == 0 ? 'length' : null,
        );
        if (pass == 1) throw const AiChatException('模拟失败');
      });
      final reply = _Reply();
      Map<String, dynamic>? metadata;
      await expectLater(() async {
        await for (final delta in AiAnswerContinuation(transport).stream(
          settings: settings,
          messages: messages,
          cancellation: AiChatCancellation(),
          onUsage: (value) => metadata = value,
        )) {
          reply.add(delta);
        }
      }(), throwsA(isA<AiChatException>()));
      expect(reply.content, '原文半句');
      expect(AiTokenUsage.fromMap(reply.usage).total, 8392);
      expect(AiTokenUsage.fromMap(reply.usage).cached, isNull);
      expect(metadata!['calls'], 2);
      expect(metadata!['reported_calls'], 1);
    },
  );

  test(
    'absent continuation cache or reasoning metadata stays unknown instead of inheriting stale counters',
    () async {
      final transport = _Transport((pass, _) async* {
        yield AiChatDelta(
          content: '正文',
          usage: pass == 0
              ? firstUsage
              : {'prompt_tokens': 400, 'completion_tokens': 200},
          finishReason: pass == 0 ? 'length' : 'stop',
        );
      });
      final reply = _Reply();
      await for (final delta in AiAnswerContinuation(transport).stream(
        settings: settings,
        messages: messages,
        cancellation: AiChatCancellation(),
      )) {
        reply.add(delta);
      }
      final counted = AiTokenUsage.fromMap(reply.usage);
      expect(counted.total, 8992);
      expect(counted.cached, isNull);
      expect(counted.reasoning, isNull);
      expect(counted.cacheMiss, isNull);
      expect(counted.cacheWrite, isNull);
    },
  );

  test(
    'insufficient total or input-only room never sends an invalid continuation',
    () async {
      for (final config in [
        settings.copyWith(contextTokens: 900),
        settings.copyWith(
          savedModels: const [
            AiModelInfo(
              id: 'glm_5.3_prime',
              maxInputTokens: 700,
              maxThinkingInputTokens: 700,
            ),
          ],
          modelCatalogBaseUrl: settings.baseUrl,
        ),
      ]) {
        final transport = _Transport((_, _) async* {
          yield const AiChatDelta(
            content: '正文',
            usage: firstUsage,
            finishReason: 'length',
          );
        });
        await AiAnswerContinuation(transport)
            .stream(
              settings: config,
              messages: messages,
              cancellation: AiChatCancellation(),
            )
            .drain<void>();
        expect(transport.requests, hasLength(1));
      }
    },
  );

  test('long prior-turn excerpt preserves its opening, cutoff and Unicode', () {
    final text = '开头😀${'中间🙂' * 600}最后被截断的一句话😀';
    final excerpt = AiPromptComposer.turnExcerpt(text, 120);
    expect(excerpt, startsWith('开头😀'));
    expect(excerpt, endsWith('最后被截断的一句话😀'));
    expect(excerpt, contains('中间省略'));
    expect(excerpt, isNot(contains('�')));
  });
}
