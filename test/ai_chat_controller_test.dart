import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_answer_continuation.dart';
import 'package:video_player_app/features/ai_chat/ai_turn_plan.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

class _Loader extends AiVideoContextLoader {
  bool savedOnlineTrack = false;
  bool withSecondary = false;
  bool swapRoles = false;
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
      AiSubtitleTrack(
        id: savedOnlineTrack ? 'bilibili:stable' : 'primary',
        aliases: savedOnlineTrack ? {'primary'} : {},
        label: '中文',
        role: swapRoles ? 'other' : 'primary',
        cues: [
          SubtitleItem(
            index: 0,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 3),
            text: '这是测试视频的文稿',
          ),
        ],
      ),
      if (withSecondary)
        AiSubtitleTrack(
          id: 'secondary',
          label: 'English',
          role: swapRoles ? 'primary' : 'secondary',
          cues: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 3),
              text: 'Video transcript',
            ),
          ],
        ),
      const AiSubtitleTrack(id: 'other', label: '英文', role: 'other'),
    ],
  );
}

class _Transport extends AiChatTransport {
  final List<List<Map<String, String>>> requests = [];
  final List<AiChatSettings> requestSettings = [];
  bool fail = false;
  bool waitForCancel = false;
  bool truncateOnce = false;
  bool thoughtsOnly = false;
  String? finishReason;
  Map<String, dynamic>? usage;
  Completer<void>? titleStarted;
  Completer<void>? titleGate;
  final planningRequests = <List<Map<String, String>>>[];
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (messages.first['content'] == AiTurnPlanner.prompt) {
      planningRequests.add(messages);
      yield AiChatDelta(
        content:
            '{"source":"topic","relation":"${planningRequests.length == 1 ? 'new' : 'followup'}","query":"文稿","task":"answer"}',
        usage: {
          'prompt_tokens': 40,
          'completion_tokens': 20,
          'total_tokens': 60,
        },
        finishReason: 'stop',
      );
      return;
    }
    requests.add(messages);
    requestSettings.add(settings);
    if (messages.length == 2 &&
        messages.first['content'] == settings.titlePrompt) {
      titleStarted?.complete();
      await titleGate?.future;
      yield const AiChatDelta(content: '自动概括的标题');
      return;
    }
    final continuing =
        messages.last['content'] == AiAnswerContinuation.instruction;
    yield AiChatDelta(
      content: thoughtsOnly
          ? ''
          : truncateOnce && continuing
          ? '补全'
          : '回答',
      reasoning: '思考',
      finishReason: truncateOnce
          ? (continuing ? 'stop' : 'length')
          : finishReason,
      usage: usage,
    );
    if (fail) throw const AiChatException('模拟断线');
    if (waitForCancel) await cancellation.whenCancelled;
  }
}

class _DelayedStore extends AiConversationStore {
  _DelayedStore({required super.root});
  Completer<void>? saveGate;
  Completer<void>? deleteGate;
  @override
  Future<void> save(AiConversation conversation) => saveGate == null
      ? super.save(conversation)
      : saveGate!.future.then((_) => super.save(conversation));

  @override
  Future<void> delete(String videoId, String id) => deleteGate == null
      ? super.delete(videoId, id)
      : deleteGate!.future.then((_) => super.delete(videoId, id));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AiChatController controller;
  late _Transport transport;
  late _Loader loader;
  late _DelayedStore store;
  final video = VideoItem(
    id: 'video-one',
    path: 'test.mp4',
    title: '测试视频',
    durationMs: 3000,
    lastUpdated: 1,
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ai_controller_test_');
    store = _DelayedStore(root: directory);
    transport = _Transport();
    loader = _Loader();
    controller = AiChatController(
      video: video,
      transport: transport,
      conversationStore: store,
      contextLoader: loader,
      initialSettings: const AiChatSettings(backend: AiBackend.codex),
    );
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    // Context recommendation changes enqueue saves without blocking the UI.
    // Drain that queue before deleting the test directory on Windows.
    await store.load(video.id);
    await directory.delete(recursive: true);
  });

  test('automatic sources follow primary and secondary assignments', () async {
    loader.withSecondary = true;
    await controller.refreshContext();
    expect(controller.selectedTrackIds, {'primary', 'secondary'});
    expect(controller.selectionIsAutomatic, isTrue);
    loader.swapRoles = true;
    await controller.refreshContext();
    expect(controller.selectedTrackIds, {'secondary'});
    final restored = await store.load(video.id);
    expect(restored.single.selectionIsAutomatic, isTrue);
    expect(restored.single.selectedTrackIds, {'secondary'});
  });

  test('settings only borrow the connection when all conversation requests are idle', () async {
    expect(controller.settingsTransport, same(transport));
    transport.waitForCancel = true;
    final pending = controller.send('普通对话');
    expect(controller.settingsTransport, isNull);
    controller.stop();
    await pending;
    expect(controller.settingsTransport, same(transport));
  });

  test(
    'manual empty sources and branches stay manual until recommended',
    () async {
      controller.setSelectedTracks({});
      loader.withSecondary = true;
      await controller.refreshContext();
      expect(controller.selectedTrackIds, isEmpty);
      expect(controller.selectionIsAutomatic, isFalse);
      await controller.send('普通对话');
      await controller.forkAt(controller.active!.messages.last.id);
      expect(controller.selectionIsAutomatic, isFalse);
      expect(controller.selectedTrackIds, isEmpty);
      controller.setSelectedTracks({'primary', 'secondary'}, automatic: true);
      loader.swapRoles = true;
      await controller.refreshContext();
      expect(controller.selectedTrackIds, {'secondary'});
      expect(controller.selectionIsAutomatic, isTrue);
    },
  );

  test(
    'editing replaces the question in the same saved conversation without a branch',
    () async {
      await controller.send('原来的问题');
      final original = controller.active!;
      await controller.send('后续问题');
      await controller.editMessage(original.messages.first.id, '修改后的问题');
      expect(controller.conversations.length, 1);
      expect(controller.active!.id, original.id);
      expect(controller.active!.parentConversationId, isNull);
      expect(controller.active!.messages.length, 2);
      expect(controller.active!.messages.first.content, '修改后的问题');
      expect(
        transport.requests.last.where(
          (message) =>
              message['content'] == '原来的问题' || message['content'] == '后续问题',
        ),
        isEmpty,
      );
      final restored = await store.load(video.id);
      expect(restored.length, 1);
      expect(
        restored.singleWhere((c) => c.id == original.id).messages.first.content,
        '修改后的问题',
      );
    },
  );
  test(
    'regeneration stays in the current conversation and only explicit fork creates a branch',
    () async {
      await controller.send('第一个问题');
      await controller.send('第二个问题');
      final original = controller.active!;
      await controller.regenerate(original.messages[1].id);
      expect(controller.active!.messages.length, 2);
      expect(controller.active!.messages.first.content, '第一个问题');
      expect(controller.active!.id, original.id);
      expect(controller.conversations.length, 1);
      expect(controller.active!.parentMessageId, isNull);
      final regenerated = controller.active!;
      await controller.forkAt(regenerated.messages[1].id);
      expect(controller.conversations.length, 2);
      expect(controller.active!.id, isNot(original.id));
      expect(controller.active!.parentConversationId, original.id);
      expect(controller.active!.messages.length, 2);
      expect(controller.active!.messages.last.id, regenerated.messages[1].id);
    },
  );
  test(
    'withdraw rewinds the same conversation and clears persisted stale request context',
    () async {
      await controller.send('取回这个问题');
      final original = controller.active!;
      await controller.withdraw(original.messages.first.id);
      expect(controller.active!.id, original.id);
      expect(controller.conversations.length, 1);
      expect(controller.active!.messages, isEmpty);
      expect(controller.lastRequest, isNull);
      expect(controller.active!.lastRequest, isNull);
      expect(controller.takeDraft(), '取回这个问题');
      expect(controller.takeDraft(), isNull);
      expect(
        controller.conversations
            .singleWhere((c) => c.id == original.id)
            .messages
            .length,
        0,
      );
      final saved = (await store.load(video.id)).single;
      expect(saved.id, original.id);
      expect(saved.lastRequest, isNull);
      await controller.send('撤回后重新提问');
      expect(controller.conversations.length, 1);
      expect(
        transport.requests.last.where(
          (message) => message['content'] == '取回这个问题',
        ),
        isEmpty,
      );
    },
  );
  test(
    'middle edits retain earlier turns and choices but reset the API request prefix',
    () async {
      controller.settings = controller.settings.copyWith(
        backend: AiBackend.api,
        titlePrompt: '',
        optimizeTokens: true,
      );
      controller.setSelectedTracks({});
      await controller.renameConversation(controller.active!.id, '学习笔记');
      await controller.send('第一问');
      await controller.send('第二问');
      await controller.send('第三问');
      final original = controller.active!;
      expect(original.lastRequest!.reusedRequestPrefix, isTrue);
      await controller.editMessage(original.messages[2].id, '修改后的第二问');
      expect(controller.active!.id, original.id);
      expect(controller.conversations.length, 1);
      expect(controller.active!.title, '学习笔记');
      expect(controller.active!.titleEdited, isTrue);
      expect(controller.selectionIsAutomatic, isFalse);
      expect(controller.selectedTrackIds, isEmpty);
      expect(controller.active!.messages.length, 4);
      expect(
        controller.active!.messages.take(2).map((m) => m.id),
        original.messages.take(2).map((m) => m.id),
      );
      expect(controller.lastRequest!.reusedRequestPrefix, isFalse);
      final input = transport.requests.last.map((m) => m['content']).toList();
      expect(input, contains('第一问'));
      expect(input, isNot(contains('第二问')));
      expect(input, isNot(contains('第三问')));
      await controller.withdraw(controller.active!.messages[2].id);
      expect(controller.active!.messages.length, 2);
      expect(controller.takeDraft(), '修改后的第二问');
      expect(controller.lastRequest, isNull);
      final saved = (await store.load(video.id)).single;
      expect(saved.id, original.id);
      expect(saved.messages.length, 2);
      expect(saved.lastRequest, isNull);
      expect(saved.title, '学习笔记');
      expect(saved.selectedTrackIds, isEmpty);
      expect(saved.selectionIsAutomatic, isFalse);
    },
  );
  test(
    'editing an explicitly created branch does not create another branch or change its source',
    () async {
      await controller.send('源对话的问题');
      final origin = controller.active!;
      await controller.forkAt(origin.messages.last.id);
      final branch = controller.active!;
      await controller.editMessage(branch.messages.first.id, '修改分支中的问题');
      expect(controller.active!.id, branch.id);
      expect(controller.active!.parentConversationId, origin.id);
      expect(controller.active!.parentMessageId, branch.parentMessageId);
      expect(controller.conversations.length, 2);
      expect(
        controller.conversations
            .singleWhere((c) => c.id == origin.id)
            .messages
            .first
            .content,
        '源对话的问题',
      );
      final saved = await store.load(video.id);
      expect(saved.length, 2);
      expect(
        saved.singleWhere((c) => c.id == branch.id).messages.first.content,
        '修改分支中的问题',
      );
    },
  );
  test(
    'failed partial response persists and is excluded from following model history',
    () async {
      transport.fail = true;
      await controller.send('断线的问题');
      expect(controller.active!.messages.last.content, '回答');
      expect(controller.active!.messages.last.status, 'error');
      transport.fail = false;
      await controller.send('后续问题');
      final request = transport.requests.last;
      expect(request.where((m) => m['role'] == 'assistant'), isEmpty);
      expect(controller.active!.messages.length, 4);
      expect(controller.active!.messages.last.status, 'complete');
    },
  );
  test(
    'stop cancels streaming and persists partial text without allowing a second send',
    () async {
      transport.waitForCancel = true;
      transport.finishReason = 'length';
      final sending = controller.send('等待停止');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.busy, isTrue);
      await controller.send('不能同时发送');
      controller.stop();
      await sending;
      expect(controller.busy, isFalse);
      expect(controller.active!.messages.length, 2);
      expect(controller.active!.messages.last.status, 'cancelled');
      expect(controller.active!.messages.last.content, '回答');
      expect(controller.responseWarning, isNull);
      final restored = await store.load(video.id);
      expect(restored.single.messages.last.status, 'cancelled');
    },
  );
  test(
    'new conversations inherit unsent manual source choices and restore them from disk',
    () async {
      loader.withSecondary = true;
      await controller.refreshContext();
      expect(controller.selectedTrackIds, {'primary', 'secondary'});
      final originalId = controller.active!.id;
      controller.setSelectedTracks({'primary'});
      controller.updateDraft('尚未发送的问题');

      await controller.createConversation();
      final newId = controller.active!.id;
      expect(newId, isNot(originalId));
      expect(controller.active!.messages, isEmpty);
      expect(controller.active!.draftText, isEmpty);
      expect(controller.selectedTrackIds, {'primary'});
      expect(controller.selectionIsAutomatic, isFalse);
      expect(transport.requests, isEmpty);

      final saved = await store.load(video.id);
      expect(saved, hasLength(2));
      for (final record in saved) {
        expect(record.messages, isEmpty);
        expect(record.selectedTrackIds, {'primary'});
        expect(record.selectionIsAutomatic, isFalse);
      }
      final restored = AiChatController(
        video: video,
        transport: transport,
        conversationStore: AiConversationStore(root: directory),
        contextLoader: _Loader()..withSecondary = true,
        initialSettings: controller.settings,
      );
      try {
        await restored.initialize();
        await restored.selectConversation(newId);
        expect(restored.selectedTrackIds, {'primary'});
        expect(restored.selectionIsAutomatic, isFalse);
        await restored.refreshContext();
        expect(restored.selectedTrackIds, {'primary'});
        await restored.selectConversation(originalId);
        expect(restored.active!.draftText, '尚未发送的问题');
        expect(restored.selectedTrackIds, {'primary'});
      } finally {
        restored.dispose();
      }
    },
  );

  test(
    'reused blank conversations inherit the current source choices',
    () async {
      loader.withSecondary = true;
      await controller.refreshContext();
      await controller.send('已有任务的问题');
      final originalId = controller.active!.id;
      await controller.createConversation();
      final emptyId = controller.active!.id;
      expect(controller.selectionIsAutomatic, isTrue);

      await controller.selectConversation(originalId);
      controller.setSelectedTracks({'primary'});
      final requestCount = transport.requests.length;
      await controller.createConversation();
      expect(controller.active!.id, emptyId);
      expect(controller.conversations, hasLength(2));
      expect(controller.selectedTrackIds, {'primary'});
      expect(controller.selectionIsAutomatic, isFalse);
      expect(controller.active!.messages, isEmpty);
      expect(transport.requests, hasLength(requestCount));
      await controller.refreshContext();
      expect(controller.selectedTrackIds, {'primary'});
      await controller.createConversation();
      expect(controller.active!.id, emptyId);
      final saved = (await store.load(
        video.id,
      )).singleWhere((record) => record.id == emptyId);
      expect(saved.selectedTrackIds, {'primary'});
      expect(saved.selectionIsAutomatic, isFalse);
    },
  );

  test(
    'new conversations preserve other blank tasks with manual choices',
    () async {
      loader.withSecondary = true;
      await controller.refreshContext();
      controller.setSelectedTracks({'primary'});
      await controller.send('保留这个任务');
      final originalId = controller.active!.id;
      await controller.createConversation();
      final manualId = controller.active!.id;
      await controller.selectConversation(originalId);
      controller.setSelectedTracks({'secondary'});

      await controller.createConversation();
      expect(controller.active!.id, isNot(manualId));
      expect(controller.selectedTrackIds, {'secondary'});
      expect(controller.selectionIsAutomatic, isFalse);
      expect(controller.conversations, hasLength(3));
      await controller.selectConversation(manualId);
      expect(controller.selectedTrackIds, {'primary'});
      expect(controller.selectionIsAutomatic, isFalse);
      final saved = (await store.load(
        video.id,
      )).singleWhere((record) => record.id == manualId);
      expect(saved.selectedTrackIds, {'primary'});
    },
  );

  test(
    'inherited automatic selection continues following subtitle assignments',
    () async {
      loader.withSecondary = true;
      await controller.refreshContext();
      controller.updateDraft('旧任务的草稿');
      await controller.createConversation();
      expect(controller.selectionIsAutomatic, isTrue);
      expect(controller.selectedTrackIds, {'primary', 'secondary'});

      controller.setSelectedTracks({'primary'});
      controller.updateDraft('手动选择的草稿');
      controller.setSelectedTracks({'primary', 'secondary'}, automatic: true);
      await controller.createConversation();
      expect(controller.selectionIsAutomatic, isTrue);
      loader.swapRoles = true;
      await controller.refreshContext();
      expect(controller.selectedTrackIds, {'secondary'});
      final saved = (await store.load(
        video.id,
      )).singleWhere((record) => record.id == controller.active!.id);
      expect(saved.selectionIsAutomatic, isTrue);
      expect(saved.selectedTrackIds, {'secondary'});
    },
  );

  test(
    'each conversation retains its selected subtitles including an empty selection',
    () async {
      expect(controller.selectedTrackIds, {'primary'});
      final original = controller.active!.id;
      controller.setSelectedTracks({});
      controller.updateDraft('这个任务仍需保留');
      await controller.createConversation();
      expect(controller.selectedTrackIds, isEmpty);
      expect(controller.selectionIsAutomatic, isFalse);
      controller.setSelectedTracks({'primary'}, automatic: true);
      await controller.selectConversation(original);
      expect(controller.selectedTrackIds, isEmpty);
      expect(controller.selectionIsAutomatic, isFalse);
      final restored = await store.load(video.id);
      expect(
        restored.singleWhere((c) => c.id == original).selectedTrackIds,
        isEmpty,
      );
    },
  );
  test(
    'developer previews do not replace actual request and the actual snapshot survives reload',
    () async {
      await controller.send('实际发送的问题');
      final sent = controller.lastRequest!;
      controller.preview('未发送的预览');
      expect(controller.lastRequest, same(sent));
      final saved = (await store.load(video.id)).single;
      expect(saved.lastRequest!.messages.last['content'], '实际发送的问题');
      expect(
        saved.lastRequest!.selectedChunks.length,
        sent.selectedChunks.length,
      );
      expect(saved.lastRequest!.warnings, sent.warnings);
      expect(saved.lastRequest!.cliInput, sent.cliInput);
      expect(saved.lastRequest!.cliInput, contains('实际发送的问题'));
    },
  );
  test(
    'deletion locks concurrent actions until the disk operation finishes',
    () async {
      await controller.send('要删除的对话');
      final deletedId = controller.active!.id;
      final gate = Completer<void>();
      store.deleteGate = gate;
      final deleting = controller.deleteConversation(deletedId);
      expect(controller.busy, isTrue);
      await controller.send('不能复活已删除对话');
      await controller.createConversation();
      expect(transport.requests.length, 1);
      gate.complete();
      await deleting;
      expect(controller.busy, isFalse);
      expect(controller.active!.id, isNot(deletedId));
      expect(controller.active!.messages, isEmpty);
      expect(
        (await store.load(video.id)).any((c) => c.id == deletedId),
        isFalse,
      );
    },
  );
  test(
    'editing locks the current conversation through persistence and rejects a stale message',
    () async {
      await controller.send('原问题');
      final original = controller.active!;
      final gate = Completer<void>();
      store.saveGate = gate;
      final editing = controller.editMessage(
        original.messages.first.id,
        '修改后的问题',
      );
      expect(controller.busy, isTrue);
      final conversationId = controller.active!.id;
      await controller.selectConversation(original.id);
      await controller.send('不应误发');
      expect(controller.active!.id, conversationId);
      expect(conversationId, original.id);
      expect(controller.conversations.length, 1);
      gate.complete();
      await editing;
      expect(controller.active!.messages.first.content, '修改后的问题');
      await controller.createConversation();
      final requests = transport.requests.length;
      await controller.editMessage(original.messages.first.id, '过期编辑');
      expect(controller.active!.messages, isEmpty);
      expect(transport.requests.length, requests);
    },
  );
  test(
    'forking from a question restores it as a draft rather than an unanswered history turn',
    () async {
      await controller.send('待修改的问题');
      final original = controller.active!;
      await controller.forkAt(original.messages.first.id);
      expect(controller.active!.messages, isEmpty);
      expect(controller.takeDraft(), '待修改的问题');
      expect(controller.active!.parentMessageId, original.messages.first.id);
    },
  );
  test(
    'provider interruptions preserve partial answers but exclude them from future history',
    () async {
      transport.finishReason = 'insufficient_system_resource';
      await controller.send('服务器中断的问题');
      final message = controller.active!.messages.last;
      expect(message.status, 'error');
      expect(message.content, '回答');
      expect(message.error, contains('服务中断'));
      transport.finishReason = null;
      await controller.send('重试后的问题');
      expect(
        transport.requests.last.where((m) => m['role'] == 'assistant'),
        isEmpty,
      );
    },
  );
  test(
    'API continuations persist and replay exact requests with task limits and real usage',
    () async {
      const apiSettings = AiChatSettings(
        backend: AiBackend.api,
        titlePrompt: '',
        optimizeTokens: true,
      );
      controller.settings = apiSettings;
      transport.usage = {
        'prompt_tokens': 1000,
        'completion_tokens': 20,
        'prompt_cache_hit_tokens': 640,
        'prompt_cache_miss_tokens': 360,
      };
      await controller.send('解释文稿');
      final first = transport.requests.single;
      final saved = (await store.load(video.id)).single;
      expect(saved.lastRequest!.requestTurnId, saved.messages.first.id);
      expect(saved.messages.last.usage!['prompt_cache_hit_tokens'], 640);
      expect(transport.requestSettings.single.thinkingEnabled, isFalse);
      expect(transport.requestSettings.single.maxOutputTokens, 4096);
      controller.dispose();
      controller = AiChatController(
        video: video,
        transport: transport,
        conversationStore: store,
        contextLoader: loader,
        initialSettings: apiSettings,
      );
      await controller.initialize();
      await controller.send('继续');
      expect(transport.requests.last.take(first.length).toList(), first);
      expect(transport.requests.last.last['content'], '继续');
      expect(controller.lastRequest!.reusedRequestPrefix, isTrue);
      final info = controller.active!.messages.last.responseInfo!;
      expect(info['reused_request_prefix'], isTrue);
      expect(info['reserved_output'], 4096);
      expect(info['configured_output_limit'], 8192);
      expect(info['provider_host'], 'api.deepseek.com');
      expect(transport.requests.length, 2);
    },
  );
  test(
    'automatic length recovery persists one answer and one planning pass',
    () async {
      controller.settings = const AiChatSettings(
        backend: AiBackend.api,
        titlePrompt: '',
        optimizeTokens: true,
      );
      transport.truncateOnce = true;
      transport.usage = {'prompt_tokens': 1000, 'completion_tokens': 20};
      await controller.send('解释文稿');
      expect(controller.active!.messages, hasLength(2));
      final answer = controller.active!.messages.last;
      expect(answer.content, '回答补全');
      expect(answer.status, 'complete');
      expect(answer.finishReason, 'stop');
      expect(controller.responseWarning, isNull);
      expect(transport.requests, hasLength(2));
      expect(transport.planningRequests, hasLength(1));
      expect(
        transport.requests.last.take(transport.requests.first.length),
        transport.requests.first,
      );
      expect(answer.usage!['total_tokens'], 2040);
      expect(answer.responseInfo!['generation_usage']['calls'], 2);
      final saved = (await store.load(video.id)).single;
      expect(saved.messages.last.content, '回答补全');
      expect(saved.messages.last.usage!['total_tokens'], 2040);
      transport.truncateOnce = false;
      await controller.send('继续举例');
      expect(controller.lastRequest!.reusedRequestPrefix, isTrue);
      expect(controller.lastRequest!.estimatedTokens, lessThan(1500));
    },
  );
  test(
    'automatic titles use the editable prompt, disable thinking, and respect a manual title',
    () async {
      controller.dispose();
      controller = AiChatController(
        video: video,
        transport: transport,
        conversationStore: store,
        contextLoader: _Loader(),
        initialSettings: const AiChatSettings(
          backend: AiBackend.api,
          thinkingEnabled: true,
          thinkingBudget: 8192,
          titlePrompt: '这是自定义的标题指令',
        ),
      );
      await controller.initialize();
      transport.titleStarted = Completer<void>();
      transport.titleGate = Completer<void>();
      await controller.send('用于概括标题的问题');
      await transport.titleStarted!.future;
      expect(transport.requests.last.first['content'], '这是自定义的标题指令');
      expect(transport.requestSettings.last.thinkingEnabled, isFalse);
      expect(transport.requestSettings.last.thinkingBudget, 0);
      expect(transport.requestSettings.last.maxOutputTokens, 80);
      await controller.renameConversation(controller.active!.id, '手动标题优先');
      transport.titleGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.active!.title, '手动标题优先');
      expect((await store.load(video.id)).single.title, '手动标题优先');
    },
  );
  test(
    'thought-only length exhaustion reports the actual cause after one recovery',
    () async {
      controller.settings = const AiChatSettings(
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        model: 'glm_5.3_prime',
        titlePrompt: '',
        contextTokens: 64000,
        maxOutputTokens: 8192,
      );
      transport.thoughtsOnly = true;
      transport.finishReason = 'length';
      await controller.send('解释文稿');
      expect(transport.requests, hasLength(2));
      expect(controller.active!.messages.last.status, 'error');
      expect(controller.error, contains('思考阶段达到单次输出上限'));
      expect(controller.error, isNot(contains('上下文')));
      expect(controller.responseWarning, isNull);
    },
  );
  test(
    'a pending title cannot restore removed turns or their request after withdrawal',
    () async {
      controller.settings = controller.settings.copyWith(
        backend: AiBackend.api,
        titlePrompt: '自定义标题请求',
      );
      transport.titleStarted = Completer<void>();
      transport.titleGate = Completer<void>();
      await controller.send('标题生成尚未结束的问题');
      await transport.titleStarted!.future;
      final original = controller.active!;
      await controller.withdraw(original.messages.first.id);
      transport.titleGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.active!.id, original.id);
      expect(controller.active!.messages, isEmpty);
      expect(controller.active!.title, original.title);
      expect(controller.lastRequest, isNull);
      final saved = (await store.load(video.id)).single;
      expect(saved.messages, isEmpty);
      expect(saved.lastRequest, isNull);
      expect(saved.title, original.title);
    },
  );
  test(
    'saved online subtitle aliases migrate the selection without refilling explicit empty choices',
    () async {
      loader.savedOnlineTrack = true;
      await controller.refreshContext();
      expect(controller.selectedTrackIds, {'bilibili:stable'});
      expect(controller.active!.selectedTrackIds, {'bilibili:stable'});
      expect((await store.load(video.id)).single.selectedTrackIds, {
        'bilibili:stable',
      });
      controller.setSelectedTracks({});
      await controller.refreshContext();
      expect(controller.selectedTrackIds, isEmpty);
    },
  );
}
