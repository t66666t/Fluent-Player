import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_draft_binding.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

class _Loader extends AiVideoContextLoader {
  Completer<void>? gate;
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async {
    await gate?.future;
    return AiVideoContext(videoId: video.id, title: video.title);
  }
}

class _Transport extends AiChatTransport {
  Completer<void>? gate;
  Completer<void>? started;
  bool fail = false;
  Completer<void>? titleStarted;
  Completer<void>? titleGate;
  final questions = <String>[];

  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (settings.titlePrompt.isNotEmpty &&
        messages.first['content'] == settings.titlePrompt) {
      titleStarted?.complete();
      await titleGate?.future;
      yield const AiChatDelta(content: '自动生成的正式标题');
      return;
    }
    questions.add(messages.last['content']!);
    started?.complete();
    if (gate != null) {
      await Future.any([gate!.future, cancellation.whenCancelled]);
    }
    if (cancellation.isCancelled) return;
    if (fail) throw const AiChatException('模拟网络失败');
    yield const AiChatDelta(content: '回答', finishReason: 'stop');
  }
}

class _MemoryStore extends AiConversationStore {
  final records = <String, AiConversation>{};
  int writes = 0;
  @override
  Future<List<AiConversation>> load(String videoId) async =>
      records.values.where((item) => item.videoId == videoId).toList();
  @override
  Future<void> save(AiConversation conversation) async {
    writes++;
    records[conversation.id] = conversation;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final video = VideoItem(
    id: 'draft-video',
    path: 'test.mp4',
    title: '草稿测试',
    durationMs: 1000,
    lastUpdated: 1,
  );
  AiChatController makeController(
    AiConversationStore store, {
    _Transport? transport,
    _Loader? loader,
    VideoItem? source,
  }) => AiChatController(
    video: source ?? video,
    contextLoader: loader ?? _Loader(),
    conversationStore: store,
    transport: transport ?? _Transport(),
    initialSettings: const AiChatSettings(
      backend: AiBackend.codex,
      titlePrompt: '',
    ),
  );

  group('durable task drafts', () {
    late Directory directory;
    late AiConversationStore store;
    late AiChatController controller;
    late _Transport transport;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('ai_drafts_');
      store = AiConversationStore(root: directory);
      transport = _Transport();
      controller = makeController(store, transport: transport);
      await controller.initialize();
    });
    tearDown(() async {
      controller.dispose();
      await store.load(video.id);
      await directory.delete(recursive: true);
    });

    test(
      'new task drafts survive old-task visits and a fresh controller',
      () async {
        await controller.send('旧任务的问题');
        final oldId = controller.active!.id;
        await controller.createConversation();
        final newId = controller.active!.id;
        const exact = '  新任务的草稿\n第二行 😀  ';
        controller.updateDraft(exact);
        await controller.selectConversation(oldId);
        expect(controller.active!.draftText, isEmpty);
        controller.updateDraft('旧任务自己的草稿');
        await controller.selectConversation(newId);
        expect(controller.active!.draftText, exact);
        expect(controller.active!.displayTitle, '新任务的草稿');
        expect(controller.active!.messages, isEmpty);
        // Switching flushes immediately, before the debounce deadline.
        final saved = await store.load(video.id);
        expect(saved.singleWhere((item) => item.id == newId).draftText, exact);
        final restored = makeController(store);
        await restored.initialize();
        await restored.selectConversation(newId);
        expect(restored.active!.draftText, exact);
        await restored.selectConversation(oldId);
        expect(restored.active!.draftText, '旧任务自己的草稿');
        restored.dispose();
      },
    );

    test('reuse only unnamed tasks with neither messages nor draft', () async {
      final initialId = controller.active!.id;
      await controller.createConversation();
      expect(controller.active!.id, initialId);
      expect(controller.conversations, hasLength(1));
      controller.updateDraft('未发送的新任务');
      await controller.createConversation();
      final emptyId = controller.active!.id;
      expect(emptyId, isNot(initialId));
      expect(controller.conversations, hasLength(2));
      await controller.selectConversation(initialId);
      await controller.createConversation();
      expect(controller.active!.id, emptyId);
      expect(controller.active!.draftText, isEmpty);
      await controller.renameConversation(emptyId, '手动命名的空任务');
      await controller.createConversation();
      expect(controller.conversations, hasLength(3));
      expect(controller.active!.id, isNot(emptyId));
    });

    test(
      'draft names never replace manual titles, exports, or request history',
      () async {
        const firstLine = '😀一二三四五六七八九十一二三四五六七八九十';
        controller.updateDraft('$firstLine\n不能进入上下文的草稿内容');
        expect(
          controller.active!.displayTitle,
          '${String.fromCharCodes(firstLine.runes.take(20))}…',
        );
        expect(controller.active!.title, '新对话');
        expect(controller.exportMarkdown(), isNot(contains(firstLine)));
        expect(
          controller.preview('正式提问').messages.toString(),
          isNot(contains('不能进入上下文的草稿内容')),
        );
        controller.updateDraft('');
        expect(controller.active!.displayTitle, '新对话');
        await controller.renameConversation(controller.active!.id, '学习笔记');
        controller.updateDraft('新草稿');
        expect(controller.active!.displayTitle, '学习笔记');
        await controller.send('新草稿', submittedDraft: '新草稿');
        expect(controller.active!.title, '学习笔记');
        expect(controller.active!.hasDraft, isFalse);
      },
    );

    test('draft changes preserve history order and timestamps', () async {
      await controller.send('旧任务');
      final old = controller.active!;
      await controller.createConversation();
      final ids = controller.conversations.map((item) => item.id).toList();
      await controller.selectConversation(old.id);
      controller.updateDraft('新的未发送内容');
      expect(controller.active!.updatedAt, old.updatedAt);
      expect(controller.conversations.map((item) => item.id), ids);
      expect(controller.active!.displayTitle, old.title);
      await controller.flushDrafts();
      final loaded = await store.load(video.id);
      expect(loaded.map((item) => item.id), ids);
    });

    test(
      'first-reply title generation preserves the next draft on disk',
      () async {
        controller.settings = controller.settings.copyWith(
          backend: AiBackend.api,
          titlePrompt: '生成标题',
        );
        transport.titleStarted = Completer<void>();
        transport.titleGate = Completer<void>();
        controller.updateDraft('首轮问题');
        await controller.send('首轮问题', submittedDraft: '首轮问题');
        await transport.titleStarted!.future;
        controller.updateDraft('标题生成时写的下一条草稿');
        transport.titleGate!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(controller.active!.title, '自动生成的正式标题');
        expect(controller.active!.draftText, '标题生成时写的下一条草稿');
        final saved = (await store.load(video.id)).single;
        expect(saved.title, '自动生成的正式标题');
        expect(saved.draftText, '标题生成时写的下一条草稿');
      },
    );

    test(
      'rejected submission preserves exact input and has no history turn',
      () async {
        final exact = '  ${List.filled(10000, '很长的问题').join()}\n';
        controller.settings = controller.settings.copyWith(
          contextTokens: 1024,
          maxOutputTokens: 512,
        );
        controller.updateDraft(exact);
        await controller.send(exact.trim(), submittedDraft: exact);
        expect(controller.error, isNotNull);
        expect(controller.active!.messages, isEmpty);
        expect(controller.active!.draftText, exact);
        expect(transport.questions, isEmpty);
      },
    );

    test(
      'accepted sends clear only the submitted draft; failures retain next draft',
      () async {
        final input = TextEditingController();
        final binding = AiChatDraftBinding.retain(controller, input);
        transport.gate = Completer<void>();
        transport.started = Completer<void>();
        transport.fail = true;
        input.text = '  第一条提问\n';
        final originalId = controller.active!.id;
        final pending = controller.send(
          input.text.trim(),
          submittedDraft: input.text,
        );
        expect(input.text, isEmpty);
        await transport.started!.future;
        input.text = '下一条草稿';
        await controller.createConversation();
        final nextId = controller.active!.id;
        input.text = '另一个任务的草稿';
        transport.gate!.complete();
        await pending;
        expect(input.text, '另一个任务的草稿');
        expect(controller.active!.id, nextId);
        await controller.selectConversation(originalId);
        expect(input.text, '下一条草稿');
        expect(controller.active!.messages.last.status, 'error');
        expect(controller.active!.messages.first.content, '第一条提问');
        binding.release();
        input.dispose();
      },
    );

    test(
      'a stale submission and a direct followup cannot erase a newer draft',
      () async {
        controller.updateDraft('刚改好的草稿');
        await controller.send('此前准备发送的问题', submittedDraft: '旧草稿');
        expect(controller.active!.draftText, '刚改好的草稿');
        await controller.send('快捷提问');
        expect(controller.active!.draftText, '刚改好的草稿');
      },
    );

    test(
      'typing after a background withdrawal supersedes its pending input command',
      () async {
        await controller.send('撤回的问题');
        final input = TextEditingController();
        final binding = AiChatDraftBinding.retain(controller, input);
        await controller.withdraw(controller.active!.messages.first.id);
        expect(input.text, '撤回的问题');
        input.text = '撤回后继续改写的新草稿';
        expect(controller.takeDraft(), isNull);
        binding.release();
        input.dispose();
        await controller.flushDrafts();
        expect((await store.load(video.id)).single.draftText, '撤回后继续改写的新草稿');
      },
    );

    test(
      'clearing and deleting pending drafts cannot resurrect them',
      () async {
        controller.updateDraft('删除前的草稿');
        final deletedId = controller.active!.id;
        await controller.deleteConversation(deletedId);
        await Future<void>.delayed(const Duration(milliseconds: 550));
        expect(
          (await store.load(video.id)).any((item) => item.id == deletedId),
          isFalse,
        );
        controller.updateDraft('随后写的草稿');
        await controller.flushDrafts();
        controller.updateDraft('');
        controller.dispose();
        // Replace the disposed instance so teardown retains ownership.
        controller = makeController(store);
        await controller.initialize();
        expect(controller.active!.draftText, isEmpty);
        expect(controller.active!.displayTitle, '新对话');
      },
    );

    test('draft storage is isolated by video as well as task', () async {
      controller.updateDraft('视频一草稿');
      await controller.flushDrafts();
      final otherVideo = VideoItem(
        id: 'other-video',
        path: 'other.mp4',
        title: '视频二',
        durationMs: 1000,
        lastUpdated: 1,
      );
      final other = makeController(store, source: otherVideo);
      await other.initialize();
      expect(other.active!.draftText, isEmpty);
      other.updateDraft('视频二草稿');
      await other.flushDrafts();
      expect((await store.load(video.id)).single.draftText, '视频一草稿');
      expect((await store.load(otherVideo.id)).single.draftText, '视频二草稿');
      other.dispose();
    });
  });

  testWidgets('debounces typing, preserves IME, and flushes on background', (
    tester,
  ) async {
    final store = _MemoryStore();
    final controller = makeController(store);
    await controller.initialize();
    final input = TextEditingController();
    final binding = AiChatDraftBinding.retain(controller, input);
    final fullscreenBinding = AiChatDraftBinding.retain(controller, input);
    expect(identical(binding, fullscreenBinding), isTrue);
    final baseline = store.writes;
    input.value = const TextEditingValue(
      text: '中文输入',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump(const Duration(milliseconds: 300));
    input.text = '中文输入完成';
    await tester.pump(const Duration(milliseconds: 499));
    expect(store.writes, baseline);
    await tester.pump(const Duration(milliseconds: 1));
    expect(store.writes, baseline + 1);
    input.value = const TextEditingValue(
      text: '继续输入',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    controller.adoptSettings(controller.settings);
    expect(input.value.composing, const TextRange(start: 0, end: 2));
    binding.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(store.records[controller.active!.id]!.draftText, '继续输入');
    fullscreenBinding.release();
    input.text = '全屏关闭后仍可写';
    expect(controller.active!.draftText, '全屏关闭后仍可写');
    binding.release();
    input.dispose();
    controller.dispose();
  });

  testWidgets(
    'history and fullscreen restore a new task draft without clearing it',
    (tester) async {
      debugAiChatDesktopAutofocus = false;
      addTearDown(() => debugAiChatDesktopAutofocus = true);
      final store = _MemoryStore();
      final controller = makeController(store);
      await controller.initialize();
      await controller.renameConversation(controller.active!.id, '旧任务');
      final oldId = controller.active!.id;
      controller.updateDraft('旧任务的草稿');
      await controller.createConversation();
      final newId = controller.active!.id;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiChatPanel(videoItem: video, controller: controller),
          ),
        ),
      );
      final field = find.byKey(const ValueKey('ai-chat-input'));
      await tester.enterText(field, '新任务写到一半');
      await tester.pump();
      expect(find.byTooltip('新任务写到一半 · 草稿'), findsOneWidget);
      await tester.tap(find.byTooltip('对话历史'));
      await tester.pumpAndSettle();
      expect(find.text('新任务写到一半'), findsWidgets);
      await tester.tap(find.text('旧任务'));
      await tester.pumpAndSettle();
      expect(controller.active!.id, oldId);
      expect(tester.widget<TextField>(field).controller!.text, '旧任务的草稿');
      await controller.selectConversation(newId);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '新任务写到一半');
      await tester.tap(find.byTooltip('全屏对话'));
      await tester.pumpAndSettle();
      await tester.enterText(field.last, '全屏继续写');
      await controller.selectConversation(oldId);
      await tester.pump();
      expect(tester.widget<TextField>(field.last).controller!.text, '旧任务的草稿');
      await controller.selectConversation(newId);
      await tester.pump();
      expect(tester.widget<TextField>(field.last).controller!.text, '全屏继续写');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiChatPanel(videoItem: video, controller: controller),
          ),
        ),
      );
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '全屏继续写');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  test('legacy records load with an empty draft', () {
    final original = AiConversation(
      id: 'legacy',
      videoId: video.id,
      title: '旧标题',
    );
    final json = original.toJson()..remove('draftText');
    expect(AiConversation.fromJson(json).draftText, isEmpty);
  });

  testWidgets('switching tasks during send preparation never moves the draft', (
    tester,
  ) async {
    debugAiChatDesktopAutofocus = false;
    addTearDown(() => debugAiChatDesktopAutofocus = true);
    final loader = _Loader();
    final transport = _Transport();
    final controller = makeController(
      _MemoryStore(),
      loader: loader,
      transport: transport,
    );
    await controller.initialize();
    controller.updateDraft('任务 A 的原文\n');
    final a = controller.active!.id;
    await controller.createConversation();
    final b = controller.active!.id;
    controller.updateDraft('任务 B 的草稿');
    await controller.selectConversation(a);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiChatPanel(videoItem: video, controller: controller),
        ),
      ),
    );
    final field = find.byKey(const ValueKey('ai-chat-input'));
    loader.gate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pump();
    await controller.selectConversation(b);
    loader.gate!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '任务 B 的草稿');
    expect(transport.questions, isEmpty);
    await controller.selectConversation(a);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '任务 A 的原文\n');
    expect(controller.active!.messages, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
