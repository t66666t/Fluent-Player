import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_prompt_composer.dart';
import 'package:video_player_app/features/ai_chat/ai_turn_plan.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const endpoint = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
  const qwen = AiChatSettings(
    baseUrl: endpoint,
    model: 'qwen3.8-max',
    modelCatalogBaseUrl: endpoint,
    savedModels: [AiModelInfo(id: 'qwen3.8-max')],
  );

  test(
    'Alibaba GLM Prime aliases retain the request ID and mandatory reasoning capabilities',
    () {
      for (final id in ['glm-5.3', 'glm-5.3-prime', 'glm_5.3_prime']) {
        final settings = qwen.copyWith(
          model: id,
          maxOutputTokens: 8192,
          thinkingEnabled: false,
          reasoningEffort: 'max',
        );
        final info = settings.selectedModelInfo!;
        expect(info.contextWindow, 1048576);
        expect(info.maxOutputTokens, 131072);
        expect(info.canDisableThinking, isFalse);
        expect(info.lowestReasoningEffort, 'low');
        final body = AiChatTransport.apiRequestBody(settings, const [
          {'role': 'user', 'content': '你好'},
        ]);
        expect(body['model'], id);
        expect(body['max_tokens'], 8192);
        expect(body['reasoning_effort'], 'low');
        expect(body.containsKey('thinking_budget'), isFalse);
        expect(body.containsKey('enable_thinking'), isFalse);
      }
    },
  );

  test(
    'cached ID-only Qwen catalogs receive documented limits without a paid refresh',
    () {
      final info = qwen.selectedModelInfo!;
      expect(info.contextWindow, 1000000);
      expect(info.maxOutputTokens, 131072);
      expect(info.inputLimit(thinking: true), 983616);
      expect(info.inputLimit(thinking: false), 991808);
      final restored = AiModelInfo.fromJson(info.toJson());
      expect(restored.maxThinkingInputTokens, 983616);
      expect(
        qwen.copyWith(baseUrl: 'https://proxy.example/v1').selectedModelInfo,
        isNull,
      );
      expect(
        qwen.copyWith(model: 'qwen3.8-custom-snapshot').selectedModelInfo,
        isNull,
      );
      expect(
        qwen
            .copyWith(
              baseUrl:
                  'https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
            )
            .selectedModelInfo
            ?.contextWindow,
        1000000,
      );
    },
  );

  test(
    'provider limits and explicit capability denials win over fallback metadata',
    () {
      final info = qwen
          .copyWith(
            savedModels: const [
              AiModelInfo(
                id: 'qwen3.8-max',
                contextWindow: 32000,
                maxInputTokens: 28000,
                maxOutputTokens: 2048,
                supportsThinking: false,
              ),
            ],
          )
          .selectedModelInfo!;
      expect(info.contextWindow, 32000);
      expect(info.maxOutputTokens, 2048);
      expect(info.maxInputTokens, 28000);
      expect(info.supportsThinking, isFalse);
      expect(info.thinkingTypes, isEmpty);
    },
  );

  test(
    'different Qwen snapshots retain different input and output ceilings',
    () {
      final modern = const AiChatSettings(
        baseUrl: endpoint,
        model: 'qwen-plus',
      ).selectedModelInfo!;
      final old = const AiChatSettings(
        baseUrl: endpoint,
        model: 'qwen-plus-2025-07-14',
      ).selectedModelInfo!;
      expect(modern.contextWindow, 1000000);
      expect(old.contextWindow, 131072);
      expect(old.maxInputTokens, 98304);
      expect(old.maxOutputTokens, 16384);
      final numeric = AiModelInfo.fromJson({
        'id': 'test',
        'context_length': '100000',
        'max_input_tokens': '90000',
        'max_output_tokens': '4096',
      });
      expect(numeric.contextWindow, 100000);
      expect(numeric.maxInputTokens, 90000);
    },
  );

  test(
    'a smaller model fits inherited response settings before composition without changing saved preferences',
    () {
      final settings = qwen.copyWith(
        contextTokens: 128000,
        maxOutputTokens: 32768,
        savedModels: const [
          AiModelInfo(
            id: 'qwen3.8-max',
            contextWindow: 8192,
            maxOutputTokens: 4096,
          ),
        ],
      );
      final effective = settings.forRequest(summaryTask: false);
      expect(effective.contextTokens, 8192);
      expect(effective.maxOutputTokens, 4096);
      expect(settings.contextTokens, 128000);
      expect(settings.maxOutputTokens, 32768);
      final request = AiPromptComposer().build(
        settings: settings,
        video: AiVideoContext(videoId: 'v', title: '视频'),
        question: '你好',
        selectedTrackIds: {},
      );
      expect(request.contextLimit, 8192);
      expect(request.outputReserve, 4096);
      AiChatTransport.validateApiSettings(
        effective,
        messages: request.messages,
      );
    },
  );

  final video = AiVideoContext(
    videoId: 'long',
    title: '完整字幕',
    position: const Duration(minutes: 2),
    tracks: [
      AiSubtitleTrack(
        id: 's',
        label: '中文',
        cues: List.generate(
          700,
          (i) => SubtitleItem(
            index: i,
            startTime: Duration(seconds: i * 10),
            endTime: Duration(seconds: i * 10 + 9),
            text: '资料编号$i ${'定义概念及其相互联系' * 9}',
          ),
        ),
      ),
    ],
  );

  test(
    'documented Qwen capacity allows a complete automatic request without unnecessary preprocessing',
    () {
      final settings = qwen.copyWith(
        contextTokens: 64000,
        maxOutputTokens: 32768,
      );
      final request = AiPromptComposer().build(
        settings: settings,
        video: video,
        question: '总结整个视频',
        selectedTrackIds: {'s'},
        turnPlan: const AiTurnPlan(
          source: 'whole',
          relation: 'new',
          query: '总结全片',
          task: 'summary',
        ),
      );
      expect(request.rawSourceComplete, isTrue);
      expect(request.contextLimit, greaterThan(64000));
      for (final cue in video.tracks.first.cues) {
        expect(request.contextText, contains(cue.text));
      }
      AiChatTransport.validateApiSettings(
        settings.forRequest(
          summaryTask: true,
          contextLimit: request.contextLimit,
          estimatedInputTokens: request.estimatedTokens,
        ),
        messages: request.messages,
      );
    },
  );

  test(
    'completed digest leaves actual room for current raw evidence instead of failing late',
    () {
      const settings = AiChatSettings(
        contextTokens: 7000,
        maxOutputTokens: 1000,
        contextMode: AiContextMode.segmented,
      );
      final request = AiPromptComposer().build(
        settings: settings,
        video: video,
        question: '现在讲什么',
        selectedTrackIds: {'s'},
        transcriptDigest: '全文主题记录：${'主要主题。' * 250}',
        turnPlan: const AiTurnPlan(
          source: 'playback',
          relation: 'new',
          query: '当前位置',
          task: 'answer',
        ),
      );
      expect(request.contextText, contains('全文主题记录'));
      expect(request.selectedChunks, isNotEmpty);
      expect(
        request.estimatedTokens + request.outputReserve,
        lessThanOrEqualTo(request.contextLimit),
      );
      AiChatTransport.validateApiSettings(
        settings.copyWith(requestInputTokens: request.estimatedTokens),
        messages: request.messages,
      );
    },
  );

  test(
    'input-only limits roll history before it can violate a larger total window',
    () {
      final settings = qwen.copyWith(
        optimizeTokens: true,
        contextTokens: 64000,
        maxOutputTokens: 1000,
        savedModels: const [
          AiModelInfo(
            id: 'qwen3.8-max',
            contextWindow: 1000000,
            maxInputTokens: 2600,
            maxThinkingInputTokens: 2600,
          ),
        ],
      );
      final source = AiVideoContext(videoId: 'history', title: '课程');
      final history = <AiChatMessage>[];
      AiRequestPreview? previous;
      var rollovers = 0;
      for (var i = 0; i < 20; i++) {
        final request = AiPromptComposer().build(
          settings: settings,
          video: source,
          question: '再举一个例子',
          selectedTrackIds: {},
          history: history,
          previousRequest: previous,
          requestTurnId: 'u$i',
          turnPlan: const AiTurnPlan(
            source: 'topic',
            relation: 'followup',
            query: '再举例',
          ),
        );
        if (request.sessionResetReason?.contains('达到预算') == true) rollovers++;
        expect(request.estimatedTokens, lessThanOrEqualTo(2600));
        AiChatTransport.validateApiSettings(
          settings.forRequest(
            summaryTask: false,
            contextLimit: request.contextLimit,
            estimatedInputTokens: request.estimatedTokens,
          ),
          messages: request.messages,
        );
        history.add(AiChatMessage(id: 'u$i', role: 'user', content: '再举一个例子'));
        history.add(
          AiChatMessage(
            id: 'a$i',
            role: 'assistant',
            status: 'complete',
            content: '解释与例子' * 25,
            usage: {
              'prompt_tokens': request.estimatedTokens,
              'completion_tokens': 120,
            },
          ),
        );
        previous = request;
      }
      expect(rollovers, greaterThan(0));
    },
  );
}
