import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'ai_chat_models.dart';
import 'ai_chat_settings.dart';
import 'ai_agent_catalog.dart';
import 'ai_chat_transport.dart';
import 'ai_native_api_transport.dart';
import 'ai_context_builder.dart';
import 'ai_video_context.dart';
import 'ai_token_usage.dart';
import 'ai_codex_app_server.dart';
import 'ai_transcript_preparation.dart';
import 'ai_prompt_session.dart';
import 'ai_turn_plan.dart';

/// A conservative local estimate; custom providers have different tokenizers.
/// Reserve output and message
/// overhead before selecting context and keep the user's current question whole.
class AiPromptComposer {
  final AiContextBuilder contextBuilder;
  AiPromptComposer({AiContextBuilder? contextBuilder})
    : contextBuilder = contextBuilder ?? AiContextBuilder();

  static int estimateTokens(String text) => AiTokenEstimate.text(text);
  static int messageTokens(Map<String, String> message) =>
      estimateTokens(message['content'] ?? '') + 16;

  AiRequestPreview build({
    required AiChatSettings settings,
    required AiVideoContext video,
    required String question,
    required Set<String> selectedTrackIds,
    List<AiChatMessage> history = const [],
    String? transcriptDigest,
    AiRequestPreview? previousRequest,
    String requestTurnId = '',
    AiTurnPlan? turnPlan,
    AiContextCheckpoint? checkpoint,
  }) {
    final originalHistory = history;
    final validCheckpoint = checkpoint?.matches(history) == true
        ? checkpoint
        : null;
    if (validCheckpoint != null) {
      history = history.skip(validCheckpoint.coveredMessages).toList();
    }
    final conversationMemory = validCheckpoint?.memory ?? '';
    final background =
        turnPlan?.needsVideoBackground ??
        AiTranscriptPreparation.needsWholeVideo(question);
    final effective = settings.forRequest(
      summaryTask:
          turnPlan?.task == 'summary' ||
          (turnPlan == null && AiTranscriptPreparation.isSummaryTask(question)),
      question: question,
    );
    AiRequestPreview session(AiRequestPreview result) => AiPromptSession.apply(
      candidate: result,
      previous: previousRequest,
      history: originalHistory,
      memoryKey: validCheckpoint == null
          ? ''
          : '${validCheckpoint.prefixHash}:${validCheckpoint.summary}',
      settings: effective.copyWith(contextTokens: result.contextLimit),
      video: video,
      selected: selectedTrackIds,
      requestTurnId: requestTurnId,
      digest: transcriptDigest != null,
      turnPlan: turnPlan,
    );
    final result = _build(
      settings: effective,
      video: video,
      question: question,
      selectedTrackIds: selectedTrackIds,
      history: history,
      transcriptDigest: transcriptDigest,
      conversationMemory: conversationMemory,
      turnPlan: turnPlan,
    );
    final full = settings.contextMode == AiContextMode.full;
    if (transcriptDigest != null ||
        result.contextComplete ||
        (!full &&
            (settings.contextMode != AiContextMode.automatic || !background))) {
      return session(result);
    }
    final modelWindow =
        effective.selectedModelInfo?.contextWindow ?? effective.contextTokens;
    // Automatic expansion is bounded and used only when it lets this request
    // send the complete transcript. It does not increase saved preferences.
    final limit = full
        ? modelWindow
        : settings.optimizeTokens
        ? effective.contextTokens < 64000
              ? effective.contextTokens
              : math.min(modelWindow, math.max(effective.contextTokens, 96000))
        : math.min(modelWindow, math.max(effective.contextTokens, 256000));
    if (limit > effective.contextTokens) {
      // Prefer the smallest complete input tier, not the whole model window.
      final tiers =
          <int>{
                if (!full) ...[96000, 128000],
                limit,
              }
              .where(
                (value) => value > effective.contextTokens && value <= limit,
              )
              .toList()
            ..sort();
      for (final tier in tiers) {
        final expanded = _build(
          settings: effective.copyWith(contextTokens: tier),
          video: video,
          question: question,
          selectedTrackIds: selectedTrackIds,
          history: history,
          conversationMemory: conversationMemory,
          turnPlan: turnPlan,
        );
        if (expanded.contextComplete) return session(expanded);
      }
    }
    if (full) {
      throw StateError(
        '所选字幕无法完整放入模型窗口，请减少所选字幕，或改用自动/分段整理模式。模型窗口未知时请先填写足够的上下文预算。',
      );
    }
    return session(result);
  }

  AiRequestPreview _build({
    required AiChatSettings settings,
    required AiVideoContext video,
    required String question,
    required Set<String> selectedTrackIds,
    List<AiChatMessage> history = const [],
    String? transcriptDigest,
    AiTurnPlan? turnPlan,
    String conversationMemory = '',
  }) {
    final cliOverhead = settings.backend == AiBackend.api
        ? 0
        : estimateTokens(settings.cliPrompt) * 2 + 256;
    int wireCost(Map<String, String> message) =>
        settings.backend == AiBackend.api
        ? messageTokens(message)
        : estimateTokens(jsonEncode(message)) + 16;
    int contextCost(String text) => wireCost({'role': 'user', 'content': text});
    final inputBudget = settings.requestInputBudget - cliOverhead;
    if (inputBudget < 512) throw StateError('上下文窗口过小：请为输入与输出各保留足够空间。');
    final configuredSystem = settings.systemPrompt.trim();
    final system = configuredSystem == AiChatSettings.defaultSystemPrompt
        ? configuredSystem
        : '${AiChatSettings.conversationPolicy}${configuredSystem.isEmpty ? '' : '\n\n自定义助手设定：\n$configuredSystem'}';
    final fixed =
        (system.isEmpty ? 0 : wireCost({'role': 'system', 'content': system})) +
        wireCost({'role': 'user', 'content': question}) +
        (turnPlan == null ? 0 : contextCost(turnContext(turnPlan, video))) +
        80;
    if (fixed > inputBudget - 256) {
      throw StateError('本次问题或系统提示词超过输入预算，请缩短文字或提高上下文窗口。');
    }
    final available = inputBudget - fixed;
    final recent = <Map<String, String>>[];
    final retainedIds = <String>{};
    final economical = settings.contextMode == AiContextMode.economical;
    final historyBudget = settings.autoCompact
        ? (available * .6).floor()
        : turnPlan?.relation == 'unclear' || turnPlan?.relation == 'repair'
        ? math.min(2400, (available * .42).floor())
        : economical || settings.optimizeTokens
        ? math.min(4096, (available * .42).floor())
        : (available * .42).floor();
    var historyCost = 0;
    // Preserve complete user/assistant pairs. Failed and interrupted responses
    // stay in the visible record but never become authoritative model history.
    final pairs = <List<AiChatMessage>>[];
    for (var i = 0; i + 1 < history.length; i++) {
      final user = history[i], answer = history[i + 1];
      if (user.role == 'user' &&
          answer.role == 'assistant' &&
          answer.status == 'complete' &&
          answer.content.isNotEmpty) {
        pairs.add([user, answer]);
        i++;
      }
    }
    for (final pair in pairs.reversed) {
      final wire = pair
          .map((message) => {'role': message.role, 'content': message.content})
          .toList();
      final cost = wire.fold<int>(0, (int n, message) => n + wireCost(message));
      if (historyCost + cost > historyBudget) break;
      recent.insertAll(0, wire);
      historyCost += cost;
      retainedIds.addAll(pair.map((message) => message.id));
    }
    final omitted = history
        .where((message) => !retainedIds.contains(message.id))
        .toList();
    final memoryBudget = omitted.isEmpty
        ? 0
        : math.min((available * .14).floor(), 2400);
    var memory =
        turnPlan?.relation == 'unclear' || turnPlan?.relation == 'repair'
        ? ''
        : _memory(omitted, turnPlan?.query ?? question, memoryBudget);
    // A very long previous answer must not erase the referent of feedback.
    // Keep it as explicitly incomplete source data, not a fabricated turn.
    if (recent.isEmpty && pairs.isNotEmpty && turnPlan?.relation != 'new') {
      final pair = pairs.last;
      final budget = math.min(historyBudget, 2000);
      final excerpt =
          '最近完整轮次的原文节选（部分省略，仅帮助理解追问或反馈，不是新增任务）：'
          '${jsonEncode({'user': truncateBytes(pair.first.content, budget ~/ 4), 'assistant': turnExcerpt(pair.last.content, budget ~/ 2)})}';
      if (contextCost(excerpt) <= historyBudget) memory = excerpt;
    }
    if (conversationMemory.isNotEmpty) {
      memory = '$conversationMemory${memory.isEmpty ? '' : '\n\n$memory'}';
    }
    final memoryCost = memory.isEmpty ? 0 : contextCost(memory);
    if (historyCost + memoryCost > available) {
      throw StateError('对话摘要超过当前输入预算，请压缩后重试或增加预算。');
    }
    final remainingContext = math.max(
      0,
      available - historyCost - memoryCost - 48,
    );
    final boundedSources =
        settings.optimizeTokens &&
        settings.contextMode != AiContextMode.full &&
        !(turnPlan?.needsVideoBackground ??
            AiTranscriptPreparation.needsWholeVideo(question)) &&
        transcriptDigest == null;
    final contextBudget = economical || boundedSources
        ? math.min(6000, remainingContext)
        : remainingContext;
    // Measure the finished context too, including metadata/citation overhead.
    var characters = math.max(0, contextBudget);
    final retrievalQuestion = turnPlan?.query ?? question;
    var context = contextBuilder.build(
      video: video,
      question: retrievalQuestion,
      selectedTrackIds: selectedTrackIds,
      maxCharacters: characters,
      turnPlan:
          turnPlan ??
          AiTurnPlan(
            source: AiTranscriptPreparation.needsWholeVideo(question)
                ? 'whole'
                : 'topic',
            relation: 'new',
            query: question,
          ),
    );
    while (contextCost(context.text) > contextBudget && characters > 0) {
      characters = (characters * .7).floor();
      context = contextBuilder.build(
        video: video,
        question: retrievalQuestion,
        selectedTrackIds: selectedTrackIds,
        maxCharacters: characters,
        turnPlan:
            turnPlan ??
            AiTurnPlan(
              source: AiTranscriptPreparation.needsWholeVideo(question)
                  ? 'whole'
                  : 'topic',
              relation: 'new',
              query: question,
            ),
      );
    }
    if (transcriptDigest != null) {
      final heading = context.text.indexOf('\n字幕资料：');
      final metadata = heading < 0
          ? context.text
          : context.text.substring(0, heading + 1);
      final localHeading = '\n\n提问位置附近的连续原文（全文背景见上方记录）：\n';
      final digestCost = contextCost('$metadata$transcriptDigest');
      // Fit local raw evidence into the space actually left by the completed
      // digest, rather than assuming it used precisely the requested target.
      final detailLimit = math.max(
        0,
        math.min(
          detailBudget(contextBudget, metadata, turnPlan),
          contextBudget - digestCost - contextCost(localHeading) - 32,
        ),
      );
      AiContextResult? detail;
      var detailCharacters = detailLimit;
      if (detailLimit > 0) {
        do {
          detail = contextBuilder.build(
            video: video,
            question: retrievalQuestion,
            selectedTrackIds: selectedTrackIds,
            maxCharacters: detailCharacters,
            turnPlan: turnPlan,
          );
          if (contextCost(detail.text) <= detailLimit) break;
          detailCharacters = (detailCharacters * .7).floor();
        } while (detailCharacters > 0);
      }
      final detailHeading = detail?.text.indexOf('\n字幕资料：') ?? -1;
      final rawDetail = detailHeading < 0
          ? ''
          : detail!.text.substring(detailHeading + 1);
      final combined =
          '$metadata$transcriptDigest${rawDetail.isEmpty ? '' : '$localHeading$rawDetail'}';
      if (contextCost(combined) > contextBudget) {
        throw StateError('全文摘要超过剩余上下文，请增加预算或新建对话。');
      }
      context = AiContextResult(
        text: combined,
        usedCharacters: combined.length,
        totalCharacters: combined.length,
        warnings: const ['全文已分段处理；摘要可能省略细节，具体事实请回查原文。'],
        selectedChunks: detail?.selectedChunks ?? const [],
      );
    }
    final warnings = <String>[...context.warnings];
    if (economical && context.isTruncated) {
      warnings.add('省 token 模式只提供有限片段，全面概括可能遗漏；需要完整分析可选择全文直读。');
    }
    if (omitted.isNotEmpty) {
      warnings.add('较早的 ${omitted.length} 条消息未完整发送；使用有界原文摘录，完整记录仍保存在历史中。');
    }
    warnings.add('Token 为本地保守估算并预留输出空间，实际消耗以服务商返回为准。');
    final contextText = contextCost(context.text) <= contextBudget
        ? context.text
        : '';
    if (contextText.isEmpty && context.text.isNotEmpty) {
      warnings.add('本次剩余预算不足以放入视频资料。');
    }
    // Retrieved passages and historical excerpts depend on the new question.
    // Keep them after stable history, so they cannot invalidate its prefix.
    final api = settings.backend == AiBackend.api;
    final lateContext = api && context.isTruncated;
    final heading = contextText.indexOf('\n字幕资料：');
    final staticContext = lateContext
        ? heading < 0
              ? ''
              : contextText.substring(0, heading + 1)
        : contextText;
    final variableContext = lateContext
        ? contextText.substring(staticContext.length)
        : '';
    final messages = <Map<String, String>>[
      if (system.isNotEmpty) {'role': 'system', 'content': system},
      if (staticContext.isNotEmpty) {'role': 'user', 'content': staticContext},
      if (!api && memory.isNotEmpty) {'role': 'user', 'content': memory},
      ...recent,
      if (api && memory.isNotEmpty) {'role': 'user', 'content': memory},
      if (variableContext.isNotEmpty)
        {'role': 'user', 'content': variableContext},
      if (turnPlan != null)
        {'role': 'user', 'content': turnContext(turnPlan, video)},
      {'role': 'user', 'content': question},
    ];
    final wireTokens =
        cliOverhead + messages.fold<int>(0, (int n, m) => n + wireCost(m));
    final fixedTokens = wireTokens - historyCost - memoryCost;
    final allHistoryTokens = pairs.fold<int>(
      0,
      (int n, pair) =>
          n +
          pair.fold<int>(
            0,
            (int n, m) => n + wireCost({'role': m.role, 'content': m.content}),
          ),
    );
    Map<String, dynamic>? parameters;
    if (settings.backend == AiBackend.api) {
      parameters = settings.apiProtocol == AiApiProtocol.openAiCompatible
          ? AiChatTransport.apiRequestBody(settings, messages)
          : AiNativeApiTransport.requestBody(settings, messages);
      parameters = Map<String, dynamic>.from(parameters)
        ..remove('messages')
        ..remove('contents')
        ..remove('system')
        ..remove('systemInstruction');
      parameters['model'] = settings.model.trim();
    } else if (settings.backend == AiBackend.codex) {
      parameters = {
        'transport': 'codex-app-server/stdio',
        'threadOptions': AiCodexAppServer.threadOptions(settings),
        'turnOptions': AiCodexAppServer.turnOptions(settings),
      };
    } else if (settings.backend.usesAcp) {
      parameters = {
        'transport': 'acp-v1/stdio',
        'agent': settings.backend.label,
        'arguments': settings.backend == AiBackend.acp
            ? settings.cliArguments
            : settings.backend.agentPreset!.arguments,
        'model': settings.model.trim(),
        'reasoningEffort': settings.reasoningEffort,
        'session': 'fresh',
        'toolPermissions': 'deny',
      };
    }
    return AiRequestPreview(
      systemPrompt: system,
      apiProtocol: settings.backend == AiBackend.api
          ? settings.apiProtocol.name
          : null,
      requestParameters: parameters,
      cliInput: settings.backend == AiBackend.api
          ? null
          : AiChatTransport.buildCliInput(settings, messages),
      messages: messages,
      contextText: contextText,
      estimatedTokens: wireTokens,
      fixedTokens: fixedTokens,
      untrimmedTokens:
          fixedTokens +
          allHistoryTokens +
          (conversationMemory.isEmpty ? 0 : contextCost(conversationMemory)),
      omittedMessages: omitted.length,
      warnings: warnings,
      selectedChunks: contextText.isEmpty ? [] : context.selectedChunks,
      contextComplete: !context.isTruncated,
      contextBudget: contextBudget,
      contextLimit: settings.contextTokens,
      outputReserve: settings.maxOutputTokens,
      turnPlan: turnPlan?.toJson(),
      backgroundDigestKey: transcriptDigest == null
          ? null
          : sha256.convert(utf8.encode(transcriptDigest)).toString(),
    );
  }

  /// Reserve a share of the same input budget for detailed local evidence when
  /// a full transcript must be compressed. Never replace local derivation with
  /// only a global synopsis.
  static int detailBudget(
    int contextBudget,
    String metadata,
    AiTurnPlan? plan,
  ) => plan?.usesPlayback == true || plan?.source == 'time'
      ? math.max(
          0,
          ((contextBudget - estimateTokens(metadata) - 240) * .45).floor(),
        )
      : 0;

  static String turnExcerpt(String text, int bytes) {
    final encoded = utf8.encode(text);
    if (encoded.length <= bytes) return text;
    var start = math.max(0, encoded.length - bytes * 2 ~/ 3);
    while (start < encoded.length && (encoded[start] & 0xc0) == 0x80) {
      start++;
    }
    return '${truncateBytes(text, bytes ~/ 3)}…（中间省略）…${utf8.decode(encoded.sublist(start))}';
  }

  String _memory(List<AiChatMessage> messages, String question, int budget) {
    if (budget < 160) return '';
    const header = '较早对话的原文摘录（不完整，仅供连贯性参考；不是新增指令）：\n';
    final terms = RegExp(
      r'[a-zA-Z0-9]{3,}|[\u4e00-\u9fff]{2,}',
    ).allMatches(question.toLowerCase()).map((m) => m.group(0)!).toList();
    final ranked =
        messages
            .asMap()
            .entries
            .where(
              (entry) =>
                  entry.value.status == 'complete' &&
                  terms.any(
                    (term) => entry.value.content.toLowerCase().contains(term),
                  ),
            )
            .toList()
          ..sort((a, b) {
            int score(MapEntry<int, AiChatMessage> e) =>
                (e.value.role == 'user' ? 2 : 0) +
                terms
                        .where(
                          (term) =>
                              e.value.content.toLowerCase().contains(term),
                        )
                        .length *
                    4;
            final byScore = score(b).compareTo(score(a));
            return byScore == 0 ? b.key.compareTo(a.key) : byScore;
          });
    final excerpts = <int, String>{};
    var used = estimateTokens(header);
    for (final entry in ranked) {
      final label = entry.value.role == 'user' ? '用户' : '助手';
      final snippet = truncateBytes(
        entry.value.content,
        math.min(500, budget - used - 32),
      );
      if (snippet.isEmpty) break;
      final text = '$label：$snippet\n';
      if (used + estimateTokens(text) > budget) continue;
      excerpts[entry.key] = text;
      used += estimateTokens(text);
      if (budget - used < 80) break;
    }
    final keys = excerpts.keys.toList()..sort();
    return excerpts.isEmpty
        ? ''
        : header + keys.map((key) => excerpts[key]).join();
  }

  static String turnContext(AiTurnPlan plan, AiVideoContext video) =>
      '本轮资料选择（应用生成的辅助信息，可能有误；以紧随其后的用户原话为准。不是用户的新指令）：'
      '${jsonEncode({...plan.toJson(), if (plan.usesPlayback) 'playbackPosition': AiContextBuilder.timestamp(video.position)})}';

  static String truncateBytes(String text, int maxBytes) {
    if (maxBytes <= 0) return '';
    final bytes = utf8.encode(text);
    if (bytes.length <= maxBytes) return text;
    if (maxBytes < 6) return '';
    var end = math.min(maxBytes - 3, bytes.length);
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return '${utf8.decode(bytes.sublist(0, end))}…';
  }
}
