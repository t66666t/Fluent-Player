import 'dart:math' as math;

import 'ai_chat_settings.dart';
import 'ai_chat_transport.dart';
import 'ai_token_usage.dart';

/// One bounded continuation of a length-limited API answer. It retains the
/// original request and partial answer, and never repeats source preparation.
class AiAnswerContinuation {
  AiAnswerContinuation(this.transport);
  final AiChatTransport transport;
  static const instruction =
      '继续完成原始提问，从上一条回答中断的位置接着写。'
      '不重写已完成的部分，不重复开头或目录；先补齐未写完的内容与必要结论，然后结束。';
  static const bodyInstruction =
      '上一轮生成在思考过程中达到上限，尚未输出正文。'
      '请直接完成原始提问的正文回答，优先给出必要内容与结论，然后结束。';

  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
    void Function(Map<String, dynamic>)? onUsage,
  }) async* {
    final usage = AiUsageAccumulator();
    final attempts = <Map<String, dynamic>>[];
    var calls = 0, reasoningTotal = 0, reasoningReports = 0;
    var cacheMiss = 0, cacheMissReports = 0;
    var cacheWrite = 0, cacheWriteReports = 0;
    int? initialInput;
    var prefixRetried = false;
    Map<String, dynamic> metadata() => {
      ...usage.toMap(),
      'calls': calls,
      'continuations': math.max(0, calls - 1),
      'call_limit': 2,
      'attempts': attempts,
      'initial_input_tokens': initialInput,
    };
    Map<String, dynamic> aggregate([Map<String, dynamic>? inFlight]) {
      final current = AiTokenUsage.fromMap(inFlight);
      final combined = <String, dynamic>{
        if (usage.reportedCalls > 0 || current.total != null) ...{
          'prompt_tokens': usage.input + (current.input ?? 0),
          'completion_tokens': usage.output + (current.output ?? 0),
          'total_tokens': usage.total + (current.total ?? 0),
        },
        if (reasoningReports + (current.reasoning == null ? 0 : 1) == calls)
          'completion_tokens_details': {
            'reasoning_tokens': reasoningTotal + (current.reasoning ?? 0),
          },
        if (cacheMissReports + (current.cacheMiss == null ? 0 : 1) == calls)
          'prompt_cache_miss_tokens': cacheMiss + (current.cacheMiss ?? 0),
        if (cacheWriteReports + (current.cacheWrite == null ? 0 : 1) == calls)
          'cache_creation_input_tokens': cacheWrite + (current.cacheWrite ?? 0),
      };
      combined.remove('prompt_cache_hit_tokens');
      if (usage.cacheReportedCalls + (current.cached == null ? 0 : 1) ==
          calls) {
        combined['prompt_cache_hit_tokens'] =
            usage.cached + (current.cached ?? 0);
      }
      return combined;
    }

    var config = settings;
    var input = messages;
    final completeBody = StringBuffer(), completeReasoning = StringBuffer();
    for (var pass = 0; pass < 2; pass++) {
      if (cancellation.isCancelled) return;
      calls++;
      onUsage?.call(metadata());
      final body = StringBuffer(), thinking = StringBuffer();
      Map<String, dynamic>? reported;
      String? finish;
      try {
        await for (final delta in transport.stream(
          settings: config,
          messages: input,
          cancellation: cancellation,
        )) {
          if (pass == 0 && delta.reconnecting == true) prefixRetried = true;
          if (delta.contentSnapshot != null) body.clear();
          if (delta.reasoningSnapshot != null) thinking.clear();
          body.write(delta.contentSnapshot ?? delta.content);
          thinking.write(delta.reasoningSnapshot ?? delta.reasoning);
          reported = AiTokenUsage.merge(reported, delta.usage);
          finish = delta.finishReason ?? finish;
          yield pass == 0
              ? delta
              : AiChatDelta(
                  contentSnapshot: '$completeBody$body',
                  reasoningSnapshot: '$completeReasoning$thinking',
                  usageSnapshot: aggregate(reported),
                  finishReason: delta.finishReason,
                  stage: delta.stage,
                  reconnecting: delta.reconnecting,
                );
        }
      } finally {
        usage.add(reported);
        final count = AiTokenUsage.fromMap(reported);
        if (pass == 0 && !prefixRetried && settings.backend == AiBackend.api) {
          // CLI internal calls and Gemini long-decode hops can report cumulative
          // billing input. Only an explicit first-hop count anchors that prefix.
          initialInput =
              reported?['context_input_tokens'] as int? ??
              (settings.apiProtocol == AiApiProtocol.gemini
                  ? null
                  : count.input);
        }
        if (count.reasoning != null) {
          reasoningReports++;
          reasoningTotal += count.reasoning!;
        }
        if (count.cacheMiss != null) {
          cacheMissReports++;
          cacheMiss += count.cacheMiss!;
        }
        if (count.cacheWrite != null) {
          cacheWriteReports++;
          cacheWrite += count.cacheWrite!;
        }
        attempts.add({
          'phase': pass == 0 ? 'answer' : 'continue',
          'output_limit': config.maxOutputTokens,
          'finish_reason': finish,
          'input_tokens': count.input,
          'output_tokens': count.output,
        });
        onUsage?.call(metadata());
      }
      completeBody.write(body);
      completeReasoning.write(thinking);
      if (pass == 1) {
        yield AiChatDelta(
          usageSnapshot: aggregate(),
          finishReason: finish,
          reconnecting: false,
        );
        return;
      }
      if (finish != 'length' ||
          settings.backend != AiBackend.api ||
          cancellation.isCancelled ||
          (body.isEmpty && thinking.isEmpty)) {
        return;
      }
      input = [
        ...messages,
        if (body.isNotEmpty) {'role': 'assistant', 'content': body.toString()},
        {
          'role': 'user',
          'content': body.isEmpty ? bodyInstruction : instruction,
        },
      ];
      // The immutable original prefix has now been measured by the provider.
      // Only the added partial body and continuation instruction need estimates.
      final prefixTokens =
          initialInput ??
          settings.requestInputTokens ??
          messages.fold<int>(
            0,
            (n, m) => n + AiTokenEstimate.text(m['content']!) + 16,
          );
      final projected =
          prefixTokens +
          AiTokenEstimate.text(body.toString()) +
          AiTokenEstimate.text(input.last['content']!) +
          64;
      final info = settings.selectedModelInfo;
      final thinkingEnabled = info?.canDisableThinking == true
          ? false
          : settings.thinkingEnabled;
      final remaining = math.min(
        settings.maxOutputTokens,
        math.min(
          info?.maxOutputTokens ?? settings.maxOutputTokens,
          math.min(
                settings.contextTokens,
                info?.contextWindow ?? settings.contextTokens,
              ) -
              projected -
              512,
        ),
      );
      final inputLimit = info?.inputLimit(
        thinking:
            info.supportsThinking != false &&
            (thinkingEnabled || info.canDisableThinking == false),
      );
      if (remaining < 128 ||
          (inputLimit != null && projected > inputLimit - 512)) {
        return;
      }
      config = settings.copyWith(
        maxOutputTokens: remaining,
        requestInputTokens: projected,
        thinkingEnabled: thinkingEnabled,
        thinkingBudget: thinkingEnabled ? settings.thinkingBudget : 0,
        reasoningEffort: info?.supportsReasoningEffort == true
            ? info?.lowestReasoningEffort ?? ''
            : settings.reasoningEffort,
      );
      yield const AiChatDelta(stage: '正在接着中断处补全回答…', reconnecting: true);
    }
  }
}
