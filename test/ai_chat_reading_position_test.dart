import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_reading_state.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_session.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_message_navigation.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

final _video = VideoItem(
  id: 'reading-video',
  path: 'reading.mp4',
  title: '阅读位置',
  durationMs: 1000,
  lastUpdated: 1,
);

class _Store extends AiConversationStore {
  final records = <String, AiConversation>{};
  @override
  Future<List<AiConversation>> load(String videoId) async =>
      records.values.toList();
  @override
  Future<void> save(AiConversation conversation) async =>
      records[conversation.id] = conversation;
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
  }) async => AiVideoContext(videoId: video.id, title: video.title);
}

class _Transport extends AiChatTransport {
  StreamController<AiChatDelta>? updates;
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (updates != null) {
      yield* updates!.stream;
    } else {
      yield const AiChatDelta(content: '新的完整回答。', finishReason: 'stop');
    }
  }
}

void main() {
  late AiChatController controller;
  late AiChatSessions sessions;
  late _Transport transport;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugAiChatDesktopAutofocus = false;
    final store = _Store();
    store.records['history'] = AiConversation(
      id: 'history',
      videoId: _video.id,
      title: '历史任务',
      messages: [
        for (var i = 0; i < 30; i++) ...[
          AiChatMessage(id: 'q$i', role: 'user', content: '问题 $i'),
          AiChatMessage(
            id: 'a$i',
            role: 'assistant',
            content: List.generate(
              70,
              (line) => '第 $i 轮，第 $line 段长回答。',
            ).join('\n\n'),
          ),
        ],
      ],
    );
    transport = _Transport();
    controller = AiChatController(
      video: _video,
      contextLoader: _Loader(),
      conversationStore: store,
      transport: transport,
      initialSettings: const AiChatSettings(
        backend: AiBackend.codex,
        titlePrompt: '',
        autoCompact: false,
      ),
    );
    await controller.initialize();
    sessions = AiChatSessions()..holdForTesting(controller);
  });
  tearDown(() async {
    if (transport.updates != null && !transport.updates!.isClosed) {
      await transport.updates!.close();
    }
    sessions.shutdown();
    debugAiChatDesktopAutofocus = true;
  });

  Future<void> mount(
    WidgetTester tester, {
    double width = 420,
    bool fullscreen = false,
    bool visible = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: 580,
            child: AiChatPanel(
              videoItem: _video,
              sessions: sessions,
              isFullscreen: fullscreen,
              isVisible: visible,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  AiMessageViewportController viewport(WidgetTester tester) => tester
      .widget<AiMessageViewport>(find.byType(AiMessageViewport))
      .controller;

  void expectAtEnd(WidgetTester tester) {
    final list = tester.widget<ScrollablePositionedList>(
      find.byType(ScrollablePositionedList),
    );
    final tail = list.itemPositionsNotifier!.itemPositions.value.where(
      (p) => p.index == controller.active!.messages.length,
    );
    expect(tail, hasLength(1));
    expect(tail.single.itemTrailingEdge, lessThanOrEqualTo(1.01));
    final beginning = list.itemPositionsNotifier!.itemPositions.value.where(
      (p) => p.index == 0 && p.itemLeadingEdge >= 0,
    );
    if (beginning.isEmpty) {
      expect(tail.single.itemTrailingEdge, greaterThan(.9));
    }
  }

  Future<void> readInsideAnswer(WidgetTester tester) async {
    tester
        .widget<AiMessageViewport>(find.byType(AiMessageViewport))
        .onNavigate();
    viewport(tester).restore(const AiMessageBookmark('a10', 0, .45));
    await tester.pumpAndSettle();
    expect(viewport(tester).bookmark!.messageId, 'a10');
    expect(viewport(tester).bookmark!.fraction, closeTo(.45, .01));
  }

  for (final width in [320.0, 420.0]) {
    for (final tail in ['following', 'paused', 'scrolled']) {
      testWidgets(
        'overflow menu preserves tail reading pixels at width=$width, tail=$tail',
        (tester) async {
          await mount(tester, width: width);
          if (tail == 'paused') {
            tester
                .widget<AiMessageViewport>(find.byType(AiMessageViewport))
                .onNavigate();
          } else if (tail == 'scrolled') {
            await tester.drag(
              find.byKey(const ValueKey('ai-chat-messages')),
              const Offset(0, 70),
            );
            await tester.pumpAndSettle();
          }
          final answer = find.byKey(const PageStorageKey('a29'));
          final top = tester.getTopLeft(answer).dy;
          final more = tester.getCenter(find.byTooltip('更多对话操作'));
          for (var cycle = 0; cycle < 5; cycle++) {
            await tester.tapAt(more);
            await tester.pumpAndSettle();
            await tester.tapAt(more);
            await tester.pumpAndSettle();
            expect(
              tester.getTopLeft(answer).dy,
              closeTo(top, .5),
              reason: 'cycle $cycle',
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
    for (final bookmark in [
      const AiMessageBookmark('q0', 0, 0),
      const AiMessageBookmark('q10', 0, 0),
      const AiMessageBookmark('a10', 0, .45),
    ]) {
      testWidgets(
        'overflow menu round trips preserve exact reading pixels at width=$width, message=${bookmark.messageId}',
        (tester) async {
          await mount(tester, width: width);
          tester
              .widget<AiMessageViewport>(find.byType(AiMessageViewport))
              .onNavigate();
          viewport(tester).restore(bookmark);
          await tester.pumpAndSettle();
          final answer = find.byKey(PageStorageKey(bookmark.messageId));
          final top = tester.getTopLeft(answer).dy;
          final more = tester.getCenter(find.byTooltip('更多对话操作'));
          for (var cycle = 0; cycle < 5; cycle++) {
            await tester.tapAt(more);
            await tester.pumpAndSettle();
            expect(find.text('阅读设置 · 字体大小'), findsOneWidget);
            await tester.tapAt(more);
            await tester.pumpAndSettle();
            expect(find.text('阅读设置 · 字体大小'), findsNothing);
            expect(
              tester.getTopLeft(answer).dy,
              closeTo(top, .5),
              reason: 'cycle $cycle must not accumulate a scroll correction',
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  Future<void> openMenuChoice(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('更多对话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  for (final layout in [
    (width: 320.0, fullscreen: false),
    (width: 420.0, fullscreen: false),
    (width: 420.0, fullscreen: true),
  ]) {
    for (final action in [
      'settings',
      'history',
      'context',
      'budget',
      'usage',
      'reading',
      'compact',
      'prompts',
      'developer',
    ]) {
      testWidgets('$action overlay preserves paused tail pixels in $layout', (
        tester,
      ) async {
        await mount(tester, width: layout.width, fullscreen: layout.fullscreen);
        tester
            .widget<AiMessageViewport>(find.byType(AiMessageViewport))
            .onNavigate();
        final answer = find.byKey(const PageStorageKey('a29'));
        final top = tester.getTopLeft(answer).dy;
        for (var cycle = 0; cycle < 3; cycle++) {
          switch (action) {
            case 'settings':
              await tester.tap(find.byTooltip('AI 设置'));
            case 'history':
              await tester.tap(find.byTooltip('对话历史'));
            case 'context':
              await tester.tap(find.byKey(const ValueKey('ai-chat-context')));
            case 'budget':
              await tester.tap(find.byKey(const ValueKey('ai-context-meter')));
            case 'usage':
              await tester.tap(
                find.byKey(const ValueKey('ai-response-usage-a29')),
              );
            case 'reading':
              await openMenuChoice(tester, '阅读设置 · 字体大小');
            case 'compact':
              await openMenuChoice(tester, '压缩上下文');
            case 'prompts':
              await openMenuChoice(tester, '管理提示词');
            case 'developer':
              await openMenuChoice(tester, '开发者模式');
          }
          await tester.pumpAndSettle();
          final navigator = tester.state<NavigatorState>(
            find.byType(Navigator).first,
          );
          expect(navigator.canPop(), isTrue);
          navigator.pop();
          for (var frame = 0; frame < 15; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              tester.getTopLeft(answer).dy,
              closeTo(top, .5),
              reason: 'cycle $cycle, frame $frame',
            );
          }
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(answer).dy, closeTo(top, .5));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final transition in ['menu', 'hidden']) {
    for (final following in [false, true]) {
      testWidgets(
        '$transition preserves reading intent when an answer grows, following=$following',
        (tester) async {
          final updates = StreamController<AiChatDelta>();
          transport.updates = updates;
          late Future<void> sending;
          await tester.runAsync(() async {
            sending = controller.send('生成一条长回答');
            updates.add(
              AiChatDelta(
                content: List.generate(50, (i) => '回答第 $i 段。').join('\n\n'),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await mount(tester);
          if (!following) {
            await tester.drag(
              find.byKey(const ValueKey('ai-chat-messages')),
              const Offset(0, 100),
            );
            await tester.pumpAndSettle();
          }
          final answer = find.byKey(
            PageStorageKey(controller.active!.messages.last.id),
          );
          final top = tester.getTopLeft(answer).dy;
          final more = tester.getCenter(find.byTooltip('更多对话操作'));
          if (transition == 'menu') {
            await tester.tapAt(more);
            await tester.pumpAndSettle();
          } else {
            await mount(tester, visible: false);
          }
          await tester.runAsync(() async {
            updates.add(
              AiChatDelta(
                content: List.generate(12, (i) => '\n\n新增第 $i 段。').join(),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          if (transition == 'menu') {
            await tester.tapAt(more);
            await tester.pumpAndSettle();
          } else {
            await mount(tester, visible: true);
          }
          final newTop = tester.getTopLeft(answer).dy;
          if (following) expectAtEnd(tester);
          await tester.runAsync(() async {
            await updates.close();
            await sending;
          });
          await tester.pumpAndSettle();
          if (!following) expect(newTop, closeTo(top, .5));
          expect(
            controller.active!.messages.last.content,
            contains('新增第 11 段'),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final transition in ['remount', 'fullscreen', 'nested-history']) {
    testWidgets(
      '$transition round trips preserve physical tail reading position',
      (tester) async {
        await mount(tester);
        await tester.drag(
          find.byKey(const ValueKey('ai-chat-messages')),
          const Offset(0, 70),
        );
        await tester.pumpAndSettle();
        final answer = find.byKey(const PageStorageKey('a29'));
        final top = tester.getTopLeft(answer).dy;
        for (var cycle = 0; cycle < 3; cycle++) {
          switch (transition) {
            case 'remount':
              await tester.pumpWidget(const SizedBox.shrink());
              await mount(tester);
            case 'fullscreen':
              await tester.tap(find.byTooltip('全屏对话'));
              await tester.pumpAndSettle();
              await tester.tap(find.byTooltip('退出全屏'));
              await tester.pumpAndSettle();
            case 'nested-history':
              await tester.tap(find.byTooltip('对话历史'));
              await tester.pumpAndSettle();
              await tester.tap(find.byTooltip('对话操作'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('重命名'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('取消'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('关闭'));
              await tester.pumpAndSettle();
          }
          expect(
            tester.getTopLeft(answer).dy,
            closeTo(top, 1),
            reason: 'cycle $cycle',
          );
        }
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'first entry and explicit history visits jump to the tail without animation',
    (tester) async {
      await mount(tester);
      expectAtEnd(tester);
      expect(find.text('问题 0'), findsNothing); // Long history stays lazy.
      await readInsideAnswer(tester);
      await tester.runAsync(() => controller.selectConversation('history'));
      // Observe the frames instead of allowing an animated scroll to settle.
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        for (final scroll in tester.stateList<ScrollableState>(
          find.byType(Scrollable),
        )) {
          expect(scroll.position.isScrollingNotifier.value, isFalse);
        }
      }
      expectAtEnd(tester);
      await tester.runAsync(() => controller.createConversation());
      await tester.pumpAndSettle();
      await tester.runAsync(() => controller.send('新任务'));
      await tester.pumpAndSettle();
      expectAtEnd(tester);
      await tester.runAsync(() => controller.selectConversation('history'));
      await tester.pumpAndSettle();
      expectAtEnd(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final questionIndex in [0, 10, 29]) {
    testWidgets(
      'editing question $questionIndex follows the replacement turn and its streamed answer',
      (tester) async {
        await mount(tester);
        final view = tester.widget<AiMessageViewport>(
          find.byType(AiMessageViewport),
        );
        view.onNavigate();
        viewport(tester).restore(AiMessageBookmark('q$questionIndex', 0, 0));
        await tester.pumpAndSettle();
        final edit = find.descendant(
          of: find.byKey(PageStorageKey('q$questionIndex')),
          matching: find.byTooltip('编辑提问'),
        );
        await tester.tap(edit);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).last,
          '编辑后的问题 $questionIndex',
        );
        final updates = StreamController<AiChatDelta>();
        transport.updates = updates;
        await tester.tap(find.text('保存并发送'));
        await tester.pumpAndSettle();
        expect(updates.hasListener, isTrue);
        expect(controller.active!.id, 'history');
        expect(controller.active!.messages, hasLength(questionIndex * 2 + 2));
        expect(
          controller.active!.messages[questionIndex * 2].content,
          '编辑后的问题 $questionIndex',
        );
        expectAtEnd(tester);
        final question = find.byKey(
          PageStorageKey(controller.active!.messages[questionIndex * 2].id),
        );
        final list = find.byKey(const ValueKey('ai-chat-messages'));
        expect(tester.getRect(question).overlaps(tester.getRect(list)), isTrue);
        updates.add(
          AiChatDelta(
            content: List.generate(40, (i) => '编辑后回答的第 $i 段。').join('\n\n'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(
          controller.active!.messages.last.content,
          contains('编辑后回答的第 39 段'),
        );
        expectAtEnd(tester);
        updates.add(
          const AiChatDelta(content: '\n\n回答完成。', finishReason: 'stop'),
        );
        unawaited(updates.close());
        await tester.pumpAndSettle();
        expectAtEnd(tester);
        expect(controller.generating, isFalse);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('canceling an edit preserves the historical reading position', (
    tester,
  ) async {
    await mount(tester);
    tester
        .widget<AiMessageViewport>(find.byType(AiMessageViewport))
        .onNavigate();
    viewport(tester).restore(const AiMessageBookmark('q10', 0, 0));
    await tester.pumpAndSettle();
    final before = viewport(tester).bookmark!;
    await tester.tap(
      find.descendant(
        of: find.byKey(const PageStorageKey('q10')),
        matching: find.byTooltip('编辑提问'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(viewport(tester).bookmark!.messageId, before.messageId);
    expect(viewport(tester).bookmark!.fraction, closeTo(before.fraction, .01));
    expect(controller.active!.messages, hasLength(60));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'session restores an interior anchor and draft after full panel unmount and resize',
    (tester) async {
      await mount(tester);
      await readInsideAnswer(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        '未发送草稿',
      );
      final before = viewport(tester).bookmark!;
      for (var i = 0; i < 3; i++) {
        await tester.pumpWidget(const SizedBox.shrink());
        await mount(tester, width: i.isEven ? 320 : 420);
        expect(viewport(tester).bookmark!.messageId, before.messageId);
        expect(
          viewport(tester).bookmark!.fraction,
          closeTo(before.fraction, .02),
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
              .controller!
              .text,
          '未发送草稿',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background output does not overwrite an unmounted historical reading anchor',
    (tester) async {
      await mount(tester);
      await readInsideAnswer(tester);
      final before = viewport(tester).bookmark!;
      await tester.pumpWidget(const SizedBox.shrink());
      final updates = StreamController<AiChatDelta>();
      transport.updates = updates;
      late Future<void> sending;
      await tester.runAsync(() async {
        sending = controller.send('后台新问题');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        updates.add(const AiChatDelta(content: '后台回复正在增长。'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await mount(tester);
      expect(viewport(tester).bookmark!.messageId, before.messageId);
      expect(
        viewport(tester).bookmark!.fraction,
        closeTo(before.fraction, .02),
      );
      await tester.runAsync(() async {
        updates.add(
          const AiChatDelta(content: '仍然继续生成。', finishReason: 'stop'),
        );
        await updates.close();
        await sending;
      });
      await tester.pumpAndSettle();
      expect(viewport(tester).bookmark!.messageId, before.messageId);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'player collapse button and rapid reopen preserve the long-answer anchor',
    (tester) async {
      var visible = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => SizedBox(
                width: 420,
                child: Column(
                  children: [
                    TextButton(
                      key: const ValueKey('toggle-chat'),
                      onPressed: () => update(() => visible = !visible),
                      child: Text(visible ? '收起 AI 对话' : '打开 AI 对话'),
                    ),
                    Expanded(
                      child: visible
                          ? AiChatPanel(videoItem: _video, sessions: sessions)
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await readInsideAnswer(tester);
      final before = viewport(tester).bookmark!;
      final toggle = find.byKey(const ValueKey('toggle-chat'));
      for (var i = 0; i < 4; i++) {
        await tester.tap(toggle);
        await tester.pump();
        await tester.tap(toggle);
        // Repeated rapid toggles also cover hiding before restoration settles.
        if (i.isOdd) {
          await tester.pump();
          await tester.tap(toggle);
          await tester.pump();
          await tester.tap(toggle);
        }
        await tester.pumpAndSettle();
        expect(viewport(tester).bookmark!.messageId, before.messageId);
        expect(
          viewport(tester).bookmark!.fraction,
          closeTo(before.fraction, .02),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a collapsed bottom-following view reopens at the latest tail', (
    tester,
  ) async {
    await mount(tester);
    expectAtEnd(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.send('收起时追加的新问题'));
    await mount(tester);
    expectAtEnd(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'late writes from old views or conversation visits cannot overwrite reading state',
    () {
      final reading = controller.readingState;
      final oldOwner = Object();
      final newOwner = Object();
      final oldVisit = reading.visit;
      final historical = AiChatReadingPosition(
        bookmark: const AiMessageBookmark('a10', 0, .45),
        atEnd: false,
        followOutput: false,
        expandedReasoning: {},
      );
      final bottom = AiChatReadingPosition(
        bookmark: null,
        atEnd: true,
        followOutput: true,
        expandedReasoning: {},
      );
      reading.claim(oldOwner);
      reading.save(oldOwner, oldVisit, historical);
      reading.claim(newOwner);
      reading.save(newOwner, oldVisit, bottom);
      reading.save(oldOwner, oldVisit, historical);
      expect(reading.position, same(bottom));
      reading.openConversation('other');
      reading.save(newOwner, oldVisit, historical);
      expect(reading.position, isNull);
    },
  );
}
