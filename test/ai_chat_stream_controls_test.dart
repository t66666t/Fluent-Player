import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_turn_plan.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

class _SettingsStore extends AiChatSettingsStore {
  AiChatSettings? saved;
  @override
  Future<void> save(AiChatSettings value) async => saved = value;
}

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
    tracks: [
      for (final id in ['primary', 'other'])
        AiSubtitleTrack(
          id: id,
          label: id,
          role: id == 'primary' ? 'primary' : 'other',
          cues: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 5),
              text: id == 'primary' ? '原始资料独有文字' : '下一轮的新资料',
            ),
          ],
        ),
    ],
  );
}

class _Call {
  _Call(this.settings, this.messages, this.cancellation);
  final AiChatSettings settings;
  final List<Map<String, String>> messages;
  final AiChatCancellation cancellation;
  final output = StreamController<AiChatDelta>();
  bool get planner => messages.first['content'] == AiTurnPlanner.prompt;
  Future<void> finish(String text) async {
    output.add(AiChatDelta(content: text, finishReason: 'stop'));
    await output.close();
  }
}

class _Transport extends AiChatTransport {
  final calls = <_Call>[];
  bool holdPlanner = false;
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) {
    final call = _Call(settings, messages, cancellation);
    calls.add(call);
    if (call.planner && !holdPlanner) {
      return Stream.value(
        const AiChatDelta(
          content:
              '{"source":"topic","relation":"new","query":"资料","task":"answer"}',
          finishReason: 'stop',
        ),
      );
    }
    final unlink = cancellation.onCancel(() => unawaited(call.output.close()));
    unawaited(call.output.done.then((_) => unlink()));
    return call.output.stream;
  }

  Future<_Call> answer(int index) async {
    for (var attempt = 0; attempt < 500; attempt++) {
      final answers = calls.where((call) => !call.planner).toList();
      if (answers.length > index) return answers[index];
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    throw StateError('Answer did not start');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AiChatController controller;
  late _Transport transport;
  late _SettingsStore settingsStore;
  late AiConversationStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ai_stream_controls_');
    transport = _Transport();
    settingsStore = _SettingsStore();
    store = AiConversationStore(root: root);
    controller = AiChatController(
      video: VideoItem(
        id: 'v',
        path: 'v.mp4',
        title: '视频',
        lastUpdated: 1,
        durationMs: 5000,
      ),
      transport: transport,
      settingsStore: settingsStore,
      conversationStore: store,
      contextLoader: _Loader(),
      initialSettings: const AiChatSettings(
        titlePrompt: '',
        apiKey: 'test-only-key',
        model: 'original-model',
        baseUrl: 'https://original.example/v1',
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
    'settings and sources saved during intent planning apply only to the next turn',
    () async {
      transport.holdPlanner = true;
      final original = controller.settings;
      final pending = controller.send('解释资料');
      while (transport.calls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final planner = transport.calls.first;
      final changed = original.copyWith(
        model: 'new-model',
        baseUrl: 'https://new.example/v1',
        apiKey: 'new-test-key',
        apiProtocol: AiApiProtocol.gemini,
        systemPrompt: '新的风格',
        maxOutputTokens: 1234,
        thinkingEnabled: false,
      );
      await controller.saveSettings(changed);
      controller.setSelectedTracks({'other'});
      await controller.renameConversation(controller.active!.id, '生成时改名');
      expect(controller.generating, isTrue);
      await planner.finish(
        '{"source":"topic","relation":"new","query":"资料","task":"answer"}',
      );
      final answer = await transport.answer(0);
      expect(answer.settings.model, 'original-model');
      expect(answer.settings.baseUrl, original.baseUrl);
      expect(answer.settings.apiKey, original.apiKey);
      expect(answer.settings.apiProtocol, original.apiProtocol);
      expect(answer.settings.maxOutputTokens, original.maxOutputTokens);
      expect(answer.messages.toString(), contains('原始资料独有文字'));
      expect(answer.messages.toString(), isNot(contains('下一轮的新资料')));
      await answer.finish('原配置生成的回答');
      await pending;
      expect(controller.active!.title, '生成时改名');
      expect(controller.active!.selectedTrackIds, {'other'});
      expect(settingsStore.saved, changed);
      transport.holdPlanner = false;
      final next = controller.send('下一问');
      final nextAnswer = await transport.answer(1);
      expect(nextAnswer.settings.model, 'new-model');
      expect(nextAnswer.settings.apiKey, 'new-test-key');
      expect(nextAnswer.settings.apiProtocol, AiApiProtocol.gemini);
      expect(nextAnswer.messages.toString(), contains('下一轮的新资料'));
      await nextAnswer.finish('新的回答');
      await next;
    },
  );

  test(
    'new and historical conversations can generate independently and stop targets only the visible reply',
    () async {
      final firstId = controller.active!.id;
      final first = controller.send('第一条对话');
      final firstAnswer = await transport.answer(0);
      await controller.createConversation();
      final secondId = controller.active!.id;
      expect(controller.busy, isFalse);
      expect(controller.lastRequest, isNull);
      final second = controller.send('第二条对话');
      final secondAnswer = await transport.answer(1);
      firstAnswer.output.add(
        const AiChatDelta(content: '第一条独有文本', stage: 'first-stage'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.active!.messages.last.content,
        isNot(contains('第一条独有文本')),
      );
      expect(controller.generationStatus, isNot('first-stage'));
      await controller.selectConversation(firstId);
      expect(controller.generating, isTrue);
      controller.stop();
      await first;
      expect(firstAnswer.cancellation.isCancelled, isTrue);
      expect(secondAnswer.cancellation.isCancelled, isFalse);
      await secondAnswer.finish('第二条独有文本');
      await second;
      expect(controller.active!.id, firstId);
      await controller.selectConversation(secondId);
      expect(controller.active!.messages.last.content, '第二条独有文本');
      final saved = await store.load('v');
      expect(
        saved.firstWhere((c) => c.id == firstId).messages.last.status,
        'cancelled',
      );
      expect(
        saved.firstWhere((c) => c.id == secondId).messages.last.status,
        'complete',
      );
    },
  );

  test(
    'a running answer can be branched without stopping or mutating the source',
    () async {
      final sourceId = controller.active!.id;
      final pending = controller.send('原问题');
      final answer = await transport.answer(0);
      answer.output.add(const AiChatDelta(content: '已经生成的部分'));
      await Future<void>.delayed(Duration.zero);
      final answerId = controller.active!.messages.last.id;
      await controller.forkAt(answerId);
      final branchId = controller.active!.id;
      expect(controller.active!.messages.last.status, 'cancelled');
      expect(controller.generating, isFalse);
      expect(answer.cancellation.isCancelled, isFalse);
      await answer.finish('继续生成的部分');
      await pending;
      expect(controller.active!.id, branchId);
      expect(controller.active!.messages.last.content, '已经生成的部分');
      await controller.selectConversation(sourceId);
      expect(controller.active!.messages.last.content, '已经生成的部分继续生成的部分');
    },
  );

  test(
    'editing a question stops its old reply before rewinding and sending the replacement',
    () async {
      final old = controller.send('原问题');
      final oldAnswer = await transport.answer(0);
      final editing = controller.editMessage(
        controller.active!.messages.first.id,
        '改后的问题',
      );
      final newAnswer = await transport.answer(1);
      await old;
      expect(oldAnswer.cancellation.isCancelled, isTrue);
      expect(controller.active!.messages.length, 2);
      expect(controller.active!.messages.first.content, '改后的问题');
      await newAnswer.finish('改后的回答');
      await editing;
      expect(controller.active!.messages.last.content, '改后的回答');
    },
  );

  test(
    'withdraw and delete cannot be undone by late streamed writes',
    () async {
      final pending = controller.send('要撤回的问题');
      final answer = await transport.answer(0);
      await controller.withdraw(controller.active!.messages.first.id);
      await pending;
      expect(answer.cancellation.isCancelled, isTrue);
      expect(controller.active!.messages, isEmpty);
      expect(controller.takeDraft(), '要撤回的问题');
      final deletedId = controller.active!.id;
      final deletingReply = controller.send('要删除的对话');
      await transport.answer(1);
      await controller.deleteConversation(deletedId);
      await deletingReply;
      expect(controller.active!.id, isNot(deletedId));
      expect((await store.load('v')).any((c) => c.id == deletedId), isFalse);
    },
  );
}
