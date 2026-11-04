import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

class _Loader extends AiVideoContextLoader {
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async => AiVideoContext(
    videoId: video.id,
    title: video.title,
    metadata: const {'author': 'source-author'},
    tracks: [
      AiSubtitleTrack(
        id: 'p',
        label: '完整主字幕',
        role: 'primary',
        cues: List.generate(
          60,
          (i) => SubtitleItem(
            index: i,
            startTime: Duration(seconds: i * 10),
            endTime: Duration(seconds: i * 10 + 9),
            text: '独有证据编号$i ${'事实' * 100}',
          ),
        ),
      ),
    ],
  );
}

class _Transport extends AiChatTransport {
  final preparations = <String>[];
  final answers = <List<Map<String, String>>>[];
  bool failPreparation = false;
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (messages.first['content'] == settings.transcriptPrompt) {
      preparations.add(messages.last['content']!);
      if (failPreparation) throw const AiChatException('分段服务失败');
      yield const AiChatDelta(
        content: '分段记录 [00:10] 事实与示例。',
        usage: {'prompt_tokens': 100, 'completion_tokens': 20},
        finishReason: 'stop',
      );
    } else {
      answers.add(messages);
      yield const AiChatDelta(
        content: '根据全文处理的记录作答。',
        usage: {
          'prompt_tokens': 200,
          'completion_tokens': 30,
          'prompt_cache_hit_tokens': 160,
        },
        finishReason: 'stop',
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AiConversationStore store;
  late AiChatController controller;
  late _Transport transport;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ai_full_controller_');
    store = AiConversationStore(root: root);
    transport = _Transport();
    controller = AiChatController(
      video: VideoItem(
        id: 'v',
        path: 'v.mp4',
        title: '长文稿',
        durationMs: 600000,
        lastUpdated: 1,
      ),
      contextLoader: _Loader(),
      transport: transport,
      conversationStore: store,
      initialSettings: const AiChatSettings(
        backend: AiBackend.codex,
        titlePrompt: '',
        contextTokens: 6000,
        maxOutputTokens: 1500,
      ),
    );
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await store.load('v');
    await root.delete(recursive: true);
  });
  test(
    'long summary reaches final answer only after full processing, then reuses cached work',
    () async {
      await controller.send('总结整个视频');
      expect(controller.error, isNull);
      for (var i = 0; i < 60; i++) {
        expect(transport.preparations.join('\n'), contains('独有证据编号$i '));
      }
      expect(transport.answers.single.toString(), contains('已完整处理所选字幕'));
      expect(transport.answers.single.toString(), contains('source-author'));
      expect(transport.answers.single.toString(), isNot(contains('全片分布抽样')));
      final answer = controller.active!.messages.last;
      expect(
        answer.responseInfo?['processed_segments'],
        answer.responseInfo?['total_segments'],
      );
      expect(
        answer.responseInfo?['preparation_usage']['calls'],
        transport.preparations.length,
      );
      expect(answer.usage?['prompt_cache_hit_tokens'], 160);
      final originalCalls = transport.preparations.length;
      await controller.send('概括全片的主要内容');
      expect(transport.preparations.length, originalCalls);
      expect(
        controller
            .active!
            .messages
            .last
            .responseInfo?['preparation_usage']['calls'],
        0,
      );
      final saved = await store.load('v');
      expect(
        saved.single.messages
            .firstWhere((message) => message.id == answer.id)
            .responseInfo,
        answer.responseInfo,
      );
      expect(controller.preparationStatus, isNull);
    },
  );
  test(
    'failed preprocessing leaves a failed reply and never silently samples',
    () async {
      transport.failPreparation = true;
      await controller.send('总结全片');
      expect(transport.answers, isEmpty);
      expect(controller.active!.messages.last.status, 'error');
      expect(
        controller
            .active!
            .messages
            .last
            .responseInfo?['preparation_usage']['calls'],
        1,
      );
      expect(controller.busy, isFalse);
      expect(controller.preparationStatus, isNull);
    },
  );
}
