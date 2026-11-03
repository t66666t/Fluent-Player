import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_turn_plan.dart';
import 'package:video_player_app/features/ai_chat/ai_prompt_composer.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';

class _Transport extends AiChatTransport {
  String reply =
      '{"source":"none","relation":"repair","query":"","task":"answer"}';
  bool wait = false;
  bool fail = false;
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (wait) await cancellation.whenCancelled;
    yield AiChatDelta(
      content: reply,
      usage: {
        'prompt_tokens': 100,
        'completion_tokens': 30,
        'total_tokens': 130,
      },
      finishReason: fail ? 'length' : 'stop',
    );
  }
}

void main() {
  final cues = List.generate(
    30,
    (i) => SubtitleItem(
      index: i,
      startTime: Duration(minutes: i),
      endTime: Duration(minutes: i + 1),
      text: '${i < 10 ? '函数极限及连续性' : '概率与贝叶斯定理'} ${'实际讲解' * 100}',
    ),
  );
  AiVideoContext video(int minute) => AiVideoContext(
    videoId: 'v',
    title: '课程',
    position: Duration(minutes: minute),
    tracks: [AiSubtitleTrack(id: 'p', label: '中文', cues: cues)],
  );
  const settings = AiChatSettings(
    contextTokens: 18000,
    maxOutputTokens: 2000,
    optimizeTokens: true,
  );
  final history = [
    AiChatMessage(id: 'u1', role: 'user', content: '解释函数极限'),
    AiChatMessage(id: 'a1', role: 'assistant', content: '此前回答的结论'),
  ];
  final composer = AiPromptComposer();

  test(
    'topic and whole requests are invariant under unrelated playback changes',
    () {
      for (final source in ['topic', 'whole']) {
        final plan = AiTurnPlan(source: source, relation: 'new', query: '函数极限');
        final a = composer.build(
          settings: settings,
          video: video(0),
          question: '概括函数极限',
          selectedTrackIds: {'p'},
          turnPlan: plan,
        );
        final b = composer.build(
          settings: settings,
          video: video(25),
          question: '概括函数极限',
          selectedTrackIds: {'p'},
          turnPlan: plan,
        );
        expect(a.messages, b.messages);
        expect(a.messages.toString(), isNot(contains('playbackPosition')));
      }
    },
  );
  test(
    'repair and unclear acts drop old source injection while preserving latest text and completed dialogue',
    () {
      final first = composer.build(
        settings: settings,
        video: video(0),
        question: history.first.content,
        selectedTrackIds: {'p'},
        requestTurnId: 'u1',
        turnPlan: const AiTurnPlan(
          source: 'playback',
          relation: 'new',
          query: '函数极限',
        ),
      );
      for (final input in ['?', '嗯？', '不对', '你跑题了', '换个说法']) {
        final next = composer.build(
          settings: settings,
          video: video(25),
          question: input,
          selectedTrackIds: {'p'},
          history: history,
          previousRequest: first,
          turnPlan: const AiTurnPlan(
            source: 'none',
            relation: 'repair',
            query: '',
          ),
        );
        expect(next.messages.last, {'role': 'user', 'content': input});
        expect(next.messages.toString(), isNot(contains('playbackPosition')));
        expect(next.selectedChunks, isEmpty);
        expect(next.reusedRequestPrefix, isFalse);
        expect(next.messages.toString(), contains('此前回答的结论'));
      }
    },
  );
  test(
    'explicit playback reference is an auxiliary snapshot, never a user question',
    () {
      final next = composer.build(
        settings: settings,
        video: video(25),
        question: '刚才老师讲的是什么意思',
        selectedTrackIds: {'p'},
        turnPlan: const AiTurnPlan(
          source: 'playback',
          relation: 'new',
          query: '',
        ),
      );
      expect(
        next.messages[next.messages.length - 2]['content'],
        contains('00:25:00'),
      );
      expect(next.messages.last['content'], '刚才老师讲的是什么意思');
      expect(
        next.selectedChunks.first.start.inMinutes,
        greaterThanOrEqualTo(24),
      );
    },
  );
  test(
    'planner preserves all latest input and never sees current playback or incomplete answers',
    () {
      final input = AiTurnPlanner.messages(
        question: '很短',
        title: '课程',
        hasTranscript: true,
        history: [
          ...history,
          AiChatMessage(id: 'u2', role: 'user', content: '未完成任务'),
          AiChatMessage(
            id: 'a2',
            role: 'assistant',
            content: '未完成回答',
            status: 'cancelled',
          ),
        ],
      );
      final data = jsonDecode(input.last['content']!) as Map;
      expect(data['latestUserMessage'], '很短');
      expect(input.last['content'], isNot(contains('未完成')));
      expect(data.keys, isNot(contains('position')));
    },
  );
  test(
    'invalid or truncated semantic decisions fall back without repeated calls',
    () async {
      final transport = _Transport();
      for (final reply in ['not-json', '{"source":"imaginary"}']) {
        transport.reply = reply;
        final result = await AiTurnPlanner(transport: transport).plan(
          settings: settings,
          question: '不对',
          title: '课程',
          hasTranscript: true,
          history: history,
          cancellation: AiChatCancellation(),
        );
        expect(result.plan, isNull);
        expect(result.usage?['total_tokens'], 130);
        expect(result.warning, isNotNull);
      }
      transport.reply =
          '{"source":"topic","relation":"new","query":"极限","task":"answer"}';
      transport.fail = true;
      final result = await AiTurnPlanner(transport: transport).plan(
        settings: settings,
        question: '极限',
        title: '课程',
        hasTranscript: true,
        history: history,
        cancellation: AiChatCancellation(),
      );
      expect(result.plan, isNull);
    },
  );
  test(
    'stop interrupts intent planning as well as answer generation',
    () async {
      final transport = _Transport()..wait = true;
      final cancellation = AiChatCancellation();
      final pending = AiTurnPlanner(transport: transport).plan(
        settings: settings,
        question: '极限',
        title: '课程',
        hasTranscript: true,
        history: history,
        cancellation: cancellation,
      );
      cancellation.cancel();
      await expectLater(pending, throwsA(isA<AiChatException>()));
    },
  );
  test('default prompt migration preserves user authored prompts', () {
    expect(
      AiChatSettings.fromJson({
        'systemPrompt': AiChatSettings.previousDefaultSystemPrompt,
      }).systemPrompt,
      AiChatSettings.defaultSystemPrompt,
    );
    expect(
      AiChatSettings.fromJson({'systemPrompt': '我自己设定的风格'}).systemPrompt,
      '我自己设定的风格',
    );
  });
  test(
    'feedback still has its referent when the previous answer exceeds the history budget',
    () {
      final next = composer.build(
        settings: settings,
        video: video(25),
        question: '这里的结论不对',
        selectedTrackIds: {'p'},
        history: [
          history.first,
          AiChatMessage(
            id: 'long',
            role: 'assistant',
            content: '需要修正的结论 ${'长文讲解' * 5000}',
          ),
        ],
        turnPlan: const AiTurnPlan(
          source: 'none',
          relation: 'repair',
          query: '',
        ),
      );
      expect(next.messages.toString(), contains('最近完整轮次的原文节选'));
      expect(next.messages.toString(), contains('需要修正的结论'));
      expect(next.messages.last['content'], '这里的结论不对');
      expect(next.estimatedTokens, lessThan(settings.contextTokens - 2000));
      expect(next.selectedChunks, isEmpty);
    },
  );
  test(
    'custom setup retains app conversation rules without replacing the new question',
    () {
      final next = composer.build(
        settings: settings.copyWith(systemPrompt: '生成一张角色图片'),
        video: video(0),
        question: '解释函数极限',
        selectedTrackIds: {'p'},
      );
      expect(next.systemPrompt, contains(AiChatSettings.conversationPolicy));
      expect(next.systemPrompt, contains('生成一张角色图片'));
      expect(next.messages.last['content'], '解释函数极限');
    },
  );
}
