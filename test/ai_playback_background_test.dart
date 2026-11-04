import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_context_builder.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_prompt_composer.dart';
import 'package:video_player_app/features/ai_chat/ai_turn_plan.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

AiVideoContext _video({int minute = 50, int characters = 80}) => AiVideoContext(
  videoId: 'lesson',
  title: '有跨章节定义的课程',
  position: Duration(minutes: minute),
  tracks: [
    AiSubtitleTrack(
      id: 'p',
      label: '中文',
      role: 'primary',
      cues: List.generate(
        100,
        (i) => SubtitleItem(
          index: i,
          startTime: Duration(minutes: i),
          endTime: Duration(minutes: i + 1),
          text:
              '段落$i ${i == 0
                  ? '此前定义'
                  : i == 99
                  ? '后文结论'
                  : '连续推导'} ${'文' * characters}',
        ),
      ),
    ),
  ],
);

class _Loader extends AiVideoContextLoader {
  _Loader(this.source);
  final AiVideoContext source;
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async => source;
}

class _Transport extends AiChatTransport {
  final requests = <List<Map<String, String>>>[];
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    requests.add(messages);
    if (messages.first['content'] == AiTurnPlanner.prompt) {
      yield const AiChatDelta(
        content:
            '{"source":"playback","relation":"new","query":"","task":"answer"}',
        finishReason: 'stop',
      );
    } else if (messages.first['content'] == settings.transcriptPrompt) {
      yield const AiChatDelta(
        content: '全局记录：此前定义支撑后面的连续推导，并联系后文结论。',
        finishReason: 'stop',
      );
    } else {
      yield const AiChatDelta(content: '当前讲解以先前定义为基础。', finishReason: 'stop');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final composer = AiPromptComposer();
  test(
    'automatic playback and explicit-time answers receive all readable subtitles when they fit',
    () {
      final video = _video();
      for (final source in ['playback', 'time']) {
        final request = composer.build(
          settings: const AiChatSettings(optimizeTokens: true),
          video: video,
          question: '现在在讲啥',
          selectedTrackIds: {'p'},
          turnPlan: AiTurnPlan(
            source: source,
            relation: 'new',
            query: '',
            focusSeconds: source == 'time' ? 3000 : null,
          ),
        );
        expect(request.contextComplete, isTrue);
        expect(request.rawSourceComplete, isTrue);
        for (final cue in video.tracks.first.cues) {
          expect(request.contextText, contains(cue.text));
        }
        expect(request.contextText, contains('已选字幕的完整文字'));
        expect(request.contextText, isNot(contains('以下仅为摘录')));
        expect(request.contextBudget, greaterThan(6000));
        expect(request.messages.last['content'], '现在在讲啥');
      }
    },
  );
  test('explicit economical mode still declares limited source coverage', () {
    final request = composer.build(
      settings: const AiChatSettings(contextMode: AiContextMode.economical),
      video: _video(characters: 400),
      question: '现在在讲啥',
      selectedTrackIds: {'p'},
      turnPlan: const AiTurnPlan(
        source: 'playback',
        relation: 'new',
        query: '',
      ),
    );
    expect(request.contextComplete, isFalse);
    expect(request.contextBudget, lessThanOrEqualTo(6000));
    expect(request.warnings.join(), contains('省 token 模式'));
  });
  test(
    'dense local evidence expands beyond three chunks without clipping every chunk',
    () {
      final video = _video(characters: 700);
      final result = AiContextBuilder().build(
        video: video,
        question: '',
        selectedTrackIds: {'p'},
        maxCharacters: 10000,
        turnPlan: const AiTurnPlan(
          source: 'playback',
          relation: 'new',
          query: '',
        ),
      );
      expect(result.selectedChunks.length, greaterThan(6));
      final indices =
          result.selectedChunks.map((chunk) => chunk.start.inMinutes).toList()
            ..sort();
      for (var i = 1; i < indices.length; i++) {
        expect(indices[i], indices[i - 1] + 1);
      }
      for (final chunk in result.selectedChunks) {
        expect(
          chunk.text
              .replaceAll(RegExp(r'\[[\d:]+\]\s*'), '')
              .replaceAll('\n', ''),
          video.tracks.first.cues[chunk.start.inMinutes].text,
        );
      }
      expect(
        result.text.indexOf(
          '[${AiContextBuilder.timestamp(Duration(minutes: indices.first))}]',
        ),
        lessThan(
          result.text.indexOf(
            '[${AiContextBuilder.timestamp(Duration(minutes: indices.last))}]',
          ),
        ),
      );
      expect(result.usedCharacters, lessThanOrEqualTo(10000));
    },
  );
  test(
    'compressed background retains local raw evidence and is injected only once as playback moves',
    () {
      const settings = AiChatSettings(
        contextTokens: 32000,
        maxOutputTokens: 1000,
        optimizeTokens: true,
      );
      const digest = '全文背景独有标记：此前定义与后文结论已经逐段处理。';
      final first = composer.build(
        settings: settings,
        video: _video(characters: 600),
        question: '现在在讲啥',
        selectedTrackIds: {'p'},
        requestTurnId: 'u1',
        transcriptDigest: digest,
        turnPlan: const AiTurnPlan(
          source: 'playback',
          relation: 'new',
          query: '',
        ),
      );
      expect(first.contextText, contains(digest));
      expect(first.contextText, contains('段落50'));
      expect(first.selectedChunks, isNotEmpty);
      expect(first.rawSourceComplete, isFalse);
      final next = composer.build(
        settings: settings,
        video: _video(minute: 80, characters: 600),
        question: '现在呢',
        selectedTrackIds: {'p'},
        requestTurnId: 'u2',
        transcriptDigest: digest,
        previousRequest: AiRequestPreview.fromJson(first.toJson()),
        history: [
          AiChatMessage(id: 'u1', role: 'user', content: '现在在讲啥'),
          AiChatMessage(id: 'a1', role: 'assistant', content: '先前解释'),
        ],
        turnPlan: const AiTurnPlan(
          source: 'playback',
          relation: 'followup',
          query: '',
        ),
      );
      expect(next.reusedRequestPrefix, isTrue);
      final text = next.messages.map((m) => m['content']).join('\n');
      expect('全文背景独有标记'.allMatches(text).length, 1);
      expect(text, contains('段落80'));
      expect(
        next.estimatedTokens,
        lessThan(settings.contextTokens - settings.maxOutputTokens),
      );
    },
  );
  test(
    'a playback request that cannot fit raw subtitles processes every segment and keeps current evidence',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'playback_background_',
      );
      final video = _video(characters: 300);
      final transport = _Transport();
      final store = AiConversationStore(root: root);
      final controller = AiChatController(
        video: VideoItem(
          id: video.videoId,
          path: 'lesson.mp4',
          title: video.title,
          durationMs: 6000000,
          lastUpdated: 1,
        ),
        transport: transport,
        conversationStore: store,
        contextLoader: _Loader(video),
        initialSettings: const AiChatSettings(
          contextTokens: 16000,
          maxOutputTokens: 1000,
          titlePrompt: '',
          optimizeTokens: true,
        ),
      );
      try {
        await controller.initialize();
        await controller.send('现在在讲啥');
        expect(controller.error, isNull);
        expect(
          controller.active!.messages.last.responseInfo!['context_mode'],
          '全文背景与当前原文',
        );
        expect(controller.lastRequest!.contextText, contains('全局记录'));
        expect(controller.lastRequest!.contextText, contains('段落50'));
        expect(controller.lastRequest!.selectedChunks, isNotEmpty);
        final processed = transport.requests
            .where(
              (messages) =>
                  messages.first['content'] ==
                  controller.settings.transcriptPrompt,
            )
            .map((messages) => messages.last['content'])
            .join('\n');
        for (final cue in video.tracks.first.cues) {
          expect(processed, contains(cue.text));
        }
      } finally {
        controller.dispose();
        await store.load(video.videoId);
        await root.delete(recursive: true);
      }
    },
  );
}
