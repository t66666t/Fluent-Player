import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_native_api_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_prompt_composer.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/features/ai_chat/ai_turn_plan.dart';

AiVideoContext _video({
  String text = '独有来源：视频讲解苹果和香蕉的比较。',
  Duration position = Duration.zero,
  Map<String, dynamic>? metadata,
}) => AiVideoContext(
  videoId: 'v',
  title: '视频',
  position: position,
  metadata: metadata ?? {'positionMs': position.inMilliseconds},
  tracks: [
    AiSubtitleTrack(
      id: 'p',
      label: '中文',
      cues: [
        SubtitleItem(
          index: 0,
          startTime: Duration.zero,
          endTime: const Duration(minutes: 1),
          text: text,
        ),
      ],
    ),
  ],
);
List<AiChatMessage> _history(
  String question, {
  String answer = '先前回答',
  Map<String, dynamic>? usage,
}) => [
  AiChatMessage(id: 'u1', role: 'user', content: question),
  AiChatMessage(
    id: 'a1',
    role: 'assistant',
    content: answer,
    usage: usage,
    responseInfo: usage == null
        ? null
        : {
            'generation_usage': {
              'initial_input_tokens': usage['prompt_tokens'],
            },
          },
  ),
];

void main() {
  final composer = AiPromptComposer();
  const settings = AiChatSettings(
    titlePrompt: '',
    optimizeTokens: true,
    fastSummaries: true,
  );
  AiRequestPreview first({
    AiChatSettings config = settings,
    AiVideoContext? video,
    String question = '介绍视频',
  }) => composer.build(
    settings: config,
    video: video ?? _video(),
    question: question,
    selectedTrackIds: {'p'},
    requestTurnId: 'u1',
  );
  test(
    'default API settings reuse sources without lowering thinking or output',
    () {
      const normal = AiChatSettings(titlePrompt: '', maxOutputTokens: 16384);
      final initial = first(config: normal);
      final restored = AiRequestPreview.fromJson(initial.toJson());
      final next = composer.build(
        settings: normal,
        video: _video(),
        question: '继续解释',
        selectedTrackIds: {'p'},
        previousRequest: restored,
        history: _history('介绍视频'),
        requestTurnId: 'u2',
      );
      expect(normal.optimizeTokens, isFalse);
      expect(normal.fastSummaries, isFalse);
      expect(next.reusedRequestPrefix, isTrue);
      expect(
        next.messages.take(restored.messages.length).toList(),
        restored.messages,
      );
      expect(RegExp('独有来源').allMatches(next.messages.toString()), hasLength(1));
      expect(next.outputReserve, 16384);
      final request = normal.forRequest(summaryTask: false, question: '继续解释');
      expect(request.maxOutputTokens, 16384);
      expect(request.thinkingEnabled, isTrue);
      expect(request.reasoningEffort, normal.reasoningEffort);
    },
  );
  test(
    'default reuse uses the configured window beyond the optional 32k soft limit',
    () {
      const normal = AiChatSettings(titlePrompt: '');
      final initial = first(config: normal);
      final next = composer.build(
        settings: normal,
        video: _video(),
        question: '继续',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('介绍视频', usage: {'prompt_tokens': 35000}),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isTrue);
      expect(next.estimatedTokens, greaterThan(32000));
      expect(next.estimatedTokens, lessThan(normal.requestInputBudget));
    },
  );
  test(
    'default reuse still resets for source changes, branches and unrelated feedback',
    () {
      const normal = AiChatSettings(titlePrompt: '');
      final initial = first(config: normal);
      AiRequestPreview follow({
        AiVideoContext? video,
        List<AiChatMessage>? history,
        AiTurnPlan? plan,
      }) => composer.build(
        settings: normal,
        video: video ?? _video(),
        question: '请回应当前问题',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: history ?? _history('介绍视频'),
        turnPlan: plan,
        requestTurnId: 'u2',
      );
      final changed = follow(video: _video(text: '修正后的新字幕'));
      expect(changed.reusedRequestPrefix, isFalse);
      expect(changed.messages.toString(), isNot(contains('独有来源')));
      final branch = follow(
        history: [
          AiChatMessage(id: 'branch-u', role: 'user', content: '另一条分支'),
          AiChatMessage(id: 'branch-a', role: 'assistant', content: '分支回答'),
        ],
      );
      expect(branch.reusedRequestPrefix, isFalse);
      final feedback = follow(
        plan: const AiTurnPlan(source: 'none', relation: 'repair', query: ''),
      );
      expect(feedback.reusedRequestPrefix, isFalse);
      expect(feedback.messages.last['content'], '请回应当前问题');
      expect(feedback.messages.toString(), isNot(contains('独有来源')));
    },
  );
  test(
    'a source-free reply never masquerades as previously supplied complete subtitles',
    () {
      const normal = AiChatSettings(titlePrompt: '');
      final initial = composer.build(
        settings: normal,
        video: _video(),
        question: '刚才的回答不对',
        selectedTrackIds: {'p'},
        requestTurnId: 'u1',
        turnPlan: const AiTurnPlan(
          source: 'none',
          relation: 'repair',
          query: '',
        ),
      );
      expect(initial.rawSourceComplete, isFalse);
      final next = composer.build(
        settings: normal,
        video: _video(),
        question: '介绍视频',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('刚才的回答不对'),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isFalse);
      expect(next.messages.toString(), contains('独有来源'));
      expect(next.rawSourceComplete, isTrue);
    },
  );
  test(
    'a failed new decision rebuilds input instead of guessing a semantic follow-up',
    () {
      const normal = AiChatSettings(titlePrompt: '');
      final initial = composer.build(
        settings: normal,
        video: _video(),
        question: '苹果',
        selectedTrackIds: {'p'},
        requestTurnId: 'u1',
        turnPlan: const AiTurnPlan(
          source: 'topic',
          relation: 'new',
          query: '苹果',
        ),
      );
      final next = composer.build(
        settings: normal,
        video: _video(),
        question: '香蕉',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('苹果'),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isFalse);
      expect(next.sessionResetReason, contains('意图判断'));
      expect(next.messages.last['content'], '香蕉');
    },
  );
  for (final backend in [AiBackend.codex, AiBackend.opencode]) {
    test('$backend keeps its existing transport without API prefix replay', () {
      final normal = AiChatSettings(backend: backend, titlePrompt: '');
      final initial = first(config: normal);
      final next = composer.build(
        settings: normal,
        video: _video(),
        question: '继续',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('介绍视频'),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isFalse);
      expect(next.outputReserve, normal.maxOutputTokens);
    });
  }
  test(
    'a continuation preserves the entire prior request and never reinjects complete subtitles',
    () {
      final initial = first();
      final next = composer.build(
        settings: settings,
        video: _video(position: const Duration(seconds: 20)),
        question: '比较两者',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('介绍视频'),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isTrue);
      expect(
        next.messages.take(initial.messages.length).toList(),
        initial.messages,
      );
      expect(
        RegExp('独有来源')
            .allMatches(
              next.messages.map((message) => message['content']).join(),
            )
            .length,
        1,
      );
      expect(next.messages.last, {'role': 'user', 'content': '比较两者'});
      expect(
        next.messages.any(
          (message) => message['content']!.contains('00:00:20'),
        ),
        isFalse,
      );
    },
  );
  test('saved state can reopen and still reuse its exact request prefix', () {
    final initial = first();
    final restored = AiRequestPreview.fromJson(initial.toJson());
    final next = composer.build(
      settings: settings,
      video: _video(),
      question: '继续',
      selectedTrackIds: {'p'},
      previousRequest: restored,
      history: _history('介绍视频'),
      requestTurnId: 'u2',
    );
    expect(next.reusedRequestPrefix, isTrue);
    expect(
      next.messages.take(restored.messages.length).toList(),
      restored.messages,
    );
    expect(next.outputReserve, 4096);
  });
  test(
    'playback and metadata key order never alter the source prefix or session',
    () {
      final initial = first(
        video: _video(
          metadata: {
            'positionMs': 0,
            'details': {'title': '章节', 'language': 'zh'},
            'durationMs': 60000,
          },
        ),
      );
      final moved = _video(
        position: const Duration(seconds: 30),
        metadata: {
          'durationMs': 60000,
          'details': {'language': 'zh', 'title': '章节'},
          'positionMs': 30000,
        },
      );
      final rebuilt = first(video: moved);
      expect(rebuilt.messages[1], initial.messages[1]);
      expect(rebuilt.messages[1]['content'], isNot(contains('positionMs')));
      final next = composer.build(
        settings: settings,
        video: moved,
        question: '继续',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('介绍视频'),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isTrue);
      expect(
        next.messages.take(initial.messages.length).toList(),
        initial.messages,
      );
    },
  );
  test(
    'editing sources invalidates old injected text while preserving visible history',
    () {
      final initial = first();
      final next = composer.build(
        settings: settings,
        video: _video(text: '新来源：已修正的字幕内容'),
        question: '解释',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('介绍视频'),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isFalse);
      expect(next.sessionResetReason, contains('字幕改变'));
      expect(next.messages.toString(), contains('新来源'));
      expect(next.messages.toString(), isNot(contains('独有来源')));
    },
  );
  test(
    'a branch before the previous turn cannot leak the original future question',
    () {
      final initial = first(question: '未来问题不应泄漏');
      final branch = [
        AiChatMessage(id: 'branch-user', role: 'user', content: '分支的提问'),
        AiChatMessage(id: 'branch-answer', role: 'assistant', content: '分支的回答'),
      ];
      final next = composer.build(
        settings: settings,
        video: _video(),
        question: '继续分支',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: branch,
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isFalse);
      expect(next.messages.toString(), isNot(contains('未来问题不应泄漏')));
    },
  );
  test(
    'pressure resets only active context and leaves full original messages intact',
    () {
      final initial = first();
      final history = _history('介绍视频', answer: '完整长回答' * 5000);
      final next = composer.build(
        settings: settings,
        video: _video(),
        question: '继续',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: history,
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isFalse);
      expect(next.sessionResetReason, contains('达到预算'));
      expect(next.estimatedTokens, lessThan(20000));
      expect(history.last.content.length, greaterThan(10000));
      expect(next.messages[1], initial.messages[1]);
      expect(next.rawSourceComplete, isTrue);
    },
  );
  test(
    'measured provider input anchors the next estimate instead of accumulating CJK overestimates',
    () {
      final initial = first();
      final measured = composer.build(
        settings: settings,
        video: _video(),
        question: '继续',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history(
          '介绍视频',
          usage: {'prompt_tokens': 100, 'completion_tokens': 20},
        ),
        requestTurnId: 'u2',
      );
      final unmeasured = composer.build(
        settings: settings,
        video: _video(),
        question: '继续',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('介绍视频'),
        requestTurnId: 'u2',
      );
      expect(measured.estimatedTokens, lessThan(unmeasured.estimatedTokens));
      expect(measured.reusedRequestPrefix, isTrue);
    },
  );
  test(
    'smart settings bound normal answers but explicit deep tasks preserve configured limits',
    () {
      const configured = AiChatSettings(
        maxOutputTokens: 32768,
        optimizeTokens: true,
        fastSummaries: true,
      );
      final ordinary = configured.forRequest(
        summaryTask: false,
        question: '解释这段内容',
      );
      expect(ordinary.maxOutputTokens, 4096);
      expect(ordinary.thinkingEnabled, isFalse);
      final detailed = configured.forRequest(
        summaryTask: false,
        question: '详细整理主要内容',
      );
      expect(detailed.maxOutputTokens, 8192);
      final deep = configured.forRequest(
        summaryTask: false,
        question: '深入推导并证明这个结论',
      );
      expect(deep.maxOutputTokens, 32768);
      expect(deep.thinkingEnabled, isTrue);
      expect(
        configured
            .forRequest(summaryTask: true, question: '深入总结并评估整个视频')
            .thinkingEnabled,
        isTrue,
      );
      final manual = configured
          .copyWith(optimizeTokens: false)
          .forRequest(summaryTask: false, question: '解释');
      expect(manual.maxOutputTokens, 32768);
      expect(manual.thinkingEnabled, isTrue);
      final smallModel = configured.copyWith(
        model: 'small',
        modelCatalogBaseUrl: configured.baseUrl,
        savedModels: const [AiModelInfo(id: 'small', maxOutputTokens: 1024)],
      );
      expect(
        smallModel
            .forRequest(summaryTask: false, question: '解释')
            .maxOutputTokens,
        1024,
      );
    },
  );
  test(
    'repeated retrieval sends an excerpt once and appends newly relevant sources',
    () {
      final video = AiVideoContext(
        videoId: 'long',
        title: '分散资料',
        tracks: [
          AiSubtitleTrack(
            id: 'p',
            label: '主字幕',
            cues: List.generate(
              100,
              (i) => SubtitleItem(
                index: i,
                startTime: Duration(minutes: i),
                endTime: Duration(minutes: i, seconds: 59),
                text: '独有段落$i ${i == 99 ? '火星' : '苹果'} ${'资料' * 150}',
              ),
            ),
          ),
        ],
      );
      final initial = first(video: video, question: '苹果');
      expect(initial.rawSourceComplete, isFalse);
      final repeated = composer.build(
        settings: settings,
        video: video,
        question: '苹果',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('苹果'),
        requestTurnId: 'u2',
      );
      expect(repeated.reusedRequestPrefix, isTrue);
      expect(repeated.messages.length, initial.messages.length + 2);
      final next = composer.build(
        settings: settings,
        video: video,
        question: '01:39:00 火星',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('苹果'),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isTrue);
      expect(
        next.messages.take(initial.messages.length).toList(),
        initial.messages,
      );
      expect(
        next.messages.skip(initial.messages.length).toString(),
        contains('火星'),
      );
      expect(
        next.injectedContextKeys.length,
        greaterThan(initial.injectedContextKeys.length),
      );
    },
  );
  test(
    'provider measurements prevent false rollover for a conservatively estimated long prefix',
    () {
      final video = _video(text: '完整来源' * 7000);
      final initial = first(video: video, question: '总结整个视频');
      expect(initial.rawSourceComplete, isTrue);
      final next = composer.build(
        settings: settings,
        video: video,
        question: '继续解释',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history('总结整个视频', usage: {'prompt_tokens': 15000}),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isTrue);
      expect(next.estimatedTokens, lessThan(16000));
      expect(next.contextComplete, isTrue);
      expect(
        next.warnings.any((warning) => warning.contains('相关性裁剪')),
        isFalse,
      );
      final requestSettings = settings.forRequest(
        summaryTask: false,
        question: '继续解释',
        contextLimit: 32000,
        estimatedInputTokens: next.estimatedTokens,
      );
      expect(
        () => AiChatTransport.validateApiSettings(
          requestSettings,
          messages: next.messages,
        ),
        returnsNormally,
      );
      final native = requestSettings.copyWith(
        apiProtocol: AiApiProtocol.anthropic,
      );
      expect(
        () => AiNativeApiTransport.requestBody(native, next.messages),
        returnsNormally,
      );
      expect(
        AiChatSettings.fromJson(requestSettings.toJson()).requestInputTokens,
        isNull,
      );
      expect(requestSettings.toJson(), isNot(contains('requestInputTokens')));
      expect(
        () => AiChatTransport.validateApiSettings(
          const AiChatSettings(contextTokens: 32000, maxOutputTokens: 4096),
          messages: next.messages,
        ),
        throwsA(isA<AiChatException>()),
      );
    },
  );
  test(
    'history rollover retains a large full-source prefix using the measured input anchor',
    () {
      final video = _video(text: '完整来源' * 7000);
      final initial = first(video: video, question: '总结整个视频');
      final next = composer.build(
        settings: settings,
        video: video,
        question: '继续',
        selectedTrackIds: {'p'},
        previousRequest: initial,
        history: _history(
          '总结整个视频',
          answer: '长回答' * 12000,
          usage: {'prompt_tokens': 15000},
        ),
        requestTurnId: 'u2',
      );
      expect(next.reusedRequestPrefix, isFalse);
      expect(next.sessionResetReason, contains('保留固定完整字幕'));
      expect(next.rawSourceComplete, isTrue);
      expect(next.messages[1], initial.messages[1]);
      expect(next.estimatedTokens, lessThan(20000));
    },
  );
  test(
    'DeepSeek stale mandatory-thinking metadata cannot disable its documented switch',
    () {
      const configured = AiChatSettings(
        fastSummaries: true,
        modelCatalogBaseUrl: 'https://api.deepseek.com',
        savedModels: [
          AiModelInfo(
            id: 'deepseek-flash',
            supportsThinking: true,
            canDisableThinking: false,
          ),
        ],
      );
      expect(configured.selectedModelInfo!.canDisableThinking, isTrue);
      expect(
        configured
            .forRequest(summaryTask: true, question: '总结')
            .thinkingEnabled,
        isFalse,
      );
    },
  );
}
