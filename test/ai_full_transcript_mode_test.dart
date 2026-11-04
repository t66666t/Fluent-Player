import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_turn_plan.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_prompt_composer.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

final _context = AiVideoContext(
  videoId: 'v',
  title: '58分钟字幕',
  tracks: [
    AiSubtitleTrack(
      id: 'srt',
      label: '中文',
      role: 'primary',
      cues: List.generate(
        1937,
        (i) => SubtitleItem(
          index: i,
          startTime: Duration(milliseconds: i * 1800),
          endTime: Duration(milliseconds: (i + 1) * 1800),
          text: '内容编号$i，经济发展及其影响。',
        ),
      ),
    ),
  ],
);

class _Loader extends AiVideoContextLoader {
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async => _context;
}

class _Transport extends AiChatTransport {
  final requests = <List<Map<String, String>>>[];
  final configs = <AiChatSettings>[];
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (messages.first['content'] == AiTurnPlanner.prompt) {
      yield const AiChatDelta(
        content:
            '{"source":"whole","relation":"new","query":"视频核心内容和结论","task":"summary"}',
        finishReason: 'stop',
      );
      return;
    }
    requests.add(messages);
    configs.add(settings);
    yield const AiChatDelta(
      content: '完整回答 [00:10]。',
      usage: {'prompt_tokens': 100, 'completion_tokens': 20},
      finishReason: 'stop',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final composer = AiPromptComposer();
  test(
    'automatic full background can use a known larger window without exceeding it',
    () {
      final long = AiVideoContext(
        videoId: 'long',
        title: '超长字幕',
        tracks: [
          AiSubtitleTrack(
            id: 'srt',
            label: '中文',
            cues: List.generate(
              400,
              (i) => SubtitleItem(
                index: i,
                startTime: Duration(seconds: i * 10),
                endTime: Duration(seconds: i * 10 + 9),
                text: '事实$i ${'中文全文内容' * 45}',
              ),
            ),
          ),
        ],
      );
      const config = AiChatSettings(
        baseUrl: 'https://large.example/v1',
        model: 'large',
        contextTokens: 64000,
        maxOutputTokens: 1000,
        optimizeTokens: false,
        modelCatalogBaseUrl: 'https://large.example/v1',
        savedModels: [AiModelInfo(id: 'large', contextWindow: 256000)],
      );
      final result = composer.build(
        settings: config,
        video: long,
        question: '总结整个视频',
        selectedTrackIds: {'srt'},
      );
      expect(
        result.rawSourceComplete,
        isTrue,
        reason:
            'limit=${result.contextLimit} estimate=${result.estimatedTokens} budget=${result.contextBudget} warnings=${result.warnings}',
      );
      expect(result.contextLimit, greaterThan(128000));
      expect(result.contextLimit, lessThanOrEqualTo(256000));
      for (final cue in long.tracks.first.cues) {
        expect(result.contextText, contains(cue.text));
      }
      final unknown = composer.build(
        settings: config.copyWith(savedModels: []),
        video: long,
        question: '总结整个视频',
        selectedTrackIds: {'srt'},
      );
      expect(unknown.rawSourceComplete, isFalse);
      expect(unknown.contextLimit, 64000);
    },
  );
  AiRequestPreview preview(
    AiChatSettings settings, {
    String question = '总结这个视频的核心内容和结论',
  }) => composer.build(
    settings: settings,
    video: _context,
    question: question,
    selectedTrackIds: {'srt'},
  );

  test(
    'automatic mode prefers the complete transcript and temporarily expands only if needed',
    () {
      const settings = AiChatSettings();
      final result = preview(settings);
      expect(result.contextComplete, isTrue);
      expect(result.contextLimit, greaterThan(settings.contextTokens));
      expect(result.contextLimit, lessThanOrEqualTo(128000));
      expect(settings.contextTokens, 64000);
      for (final cue in _context.tracks.first.cues) {
        expect(result.contextText, contains(cue.text));
      }
      expect(result.requestParameters?['thinking'], {'type': 'enabled'});
      final restored = AiRequestPreview.fromJson(result.toJson());
      expect(restored.contextLimit, result.contextLimit);
    },
  );
  test(
    'full mode never silently changes to excerpts when a model cannot fit the input',
    () {
      expect(
        () => preview(
          const AiChatSettings(
            baseUrl: 'https://unknown.example/v1',
            model: 'small',
            contextTokens: 6000,
            maxOutputTokens: 1000,
            contextMode: AiContextMode.full,
          ),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'economical mode uses fewer tokens and explicitly reports partial coverage',
    () {
      final full = preview(const AiChatSettings());
      final cheap = preview(
        const AiChatSettings(contextMode: AiContextMode.economical),
      );
      expect(cheap.contextComplete, isFalse);
      expect(cheap.contextBudget, lessThanOrEqualTo(6000));
      expect(cheap.estimatedTokens, lessThan(full.estimatedTokens ~/ 2));
      expect(cheap.warnings.join(), contains('省 token 模式'));
    },
  );
  test(
    'fast summaries can be turned off and smart ordinary questions avoid unnecessary reasoning',
    () {
      expect(
        preview(
          const AiChatSettings(fastSummaries: false),
        ).requestParameters?['thinking'],
        {'type': 'enabled'},
      );
      expect(
        preview(
          const AiChatSettings(optimizeTokens: true),
          question: '经济发展有哪些原因？',
        ).requestParameters?['thinking'],
        {'type': 'disabled'},
      );
    },
  );
  test(
    'mode and speed preferences persist and malformed old fields recover',
    () {
      const settings = AiChatSettings(
        contextMode: AiContextMode.economical,
        fastSummaries: false,
      );
      final restored = AiChatSettings.fromJson(settings.toJson());
      expect(restored.contextMode, AiContextMode.economical);
      expect(restored.fastSummaries, isFalse);
      final old = settings.toJson()
        ..remove('contextMode')
        ..remove('fastSummaries');
      expect(AiChatSettings.fromJson(old).contextMode, AiContextMode.automatic);
      expect(
        AiChatSettings.fromJson({
          ...old,
          'fastSummaries': 'invalid',
        }).fastSummaries,
        isFalse,
      );
    },
  );

  for (final mode in AiContextMode.values) {
    test(
      '${mode.name} sends its chosen data with the correct effective budget',
      () async {
        final root = await Directory.systemTemp.createTemp('ai_mode_');
        final store = AiConversationStore(root: root);
        final transport = _Transport();
        final controller = AiChatController(
          video: VideoItem(
            id: 'v',
            path: 'v.mp4',
            title: '58分钟字幕',
            durationMs: 3480000,
            lastUpdated: 1,
          ),
          contextLoader: _Loader(),
          transport: transport,
          conversationStore: store,
          initialSettings: AiChatSettings(contextMode: mode, titlePrompt: ''),
        );
        try {
          await controller.initialize();
          await controller.send('总结这个视频的核心内容和结论');
          expect(controller.error, isNull);
          final info = controller.active!.messages.last.responseInfo!;
          if (mode == AiContextMode.segmented) {
            expect(transport.requests.length, greaterThan(1));
            expect(info['context_mode'], '全文分段摘要');
          } else {
            expect(transport.requests.length, 1);
            expect(
              info['context_mode'],
              mode == AiContextMode.economical ? '相关原文检索' : '完整原文',
            );
            expect(
              transport.configs.last.contextTokens,
              controller.lastRequest!.contextLimit,
            );
            expect(
              info['context_budget'],
              controller.lastRequest!.contextLimit,
            );
          }
        } finally {
          controller.dispose();
          await store.load('v');
          await root.delete(recursive: true);
        }
      },
    );
  }
}
