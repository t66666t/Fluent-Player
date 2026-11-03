import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/app_text_input_focus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_typography.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_layout.dart';
import 'package:video_player_app/features/ai_chat/ai_message_navigation.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'package:video_player_app/features/ai_chat/ai_math.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/features/ai_chat/ai_usage_widgets.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/widgets/subtitle_chat_sidebar.dart';

final _previewDirectory =
    Platform.environment['AI_CHAT_PREVIEW_DIR'] ?? '.artifacts/ai-chat';

class _Loader extends AiVideoContextLoader {
  Duration lastPosition = Duration.zero;
  bool withSecondary = false;
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async {
    lastPosition = position;
    return AiVideoContext(
      videoId: video.id,
      title: video.title,
      position: position,
      tracks: [
        AiSubtitleTrack(
          id: 'primary',
          label: '中文文稿',
          role: 'primary',
          cues: [
            SubtitleItem(
              index: 1,
              startTime: const Duration(seconds: 12),
              endTime: const Duration(seconds: 28),
              text: '视频介绍了知识管理与主动学习。',
            ),
          ],
        ),
        AiSubtitleTrack(
          id: 'other',
          label: '英文翻译',
          role: withSecondary ? 'secondary' : 'other',
          cues: [
            SubtitleItem(
              index: 1,
              startTime: const Duration(seconds: 12),
              endTime: const Duration(seconds: 28),
              text: 'The video explains active learning.',
            ),
          ],
        ),
        const AiSubtitleTrack(id: 'missing', label: '缺失字幕', error: '字幕文件无法读取'),
      ],
    );
  }
}

class _Transport extends AiChatTransport {
  final List<List<Map<String, String>>> requests = [];
  String finishReason = 'stop';
  StreamController<AiChatDelta>? updates;
  StreamController<AiChatDelta>? planningUpdates;
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    requests.add(messages);
    if (requests.length == 1 && planningUpdates != null) {
      yield* planningUpdates!.stream;
      return;
    }
    if (updates != null) {
      yield* updates!.stream;
      return;
    }
    yield const AiChatDelta(reasoning: '根据中文文稿，视频重点是主动学习与知识管理。');
    yield AiChatDelta(
      content:
          '## 核心内容（[00:12]–[00:28]）\n\n视频提出了 **主动学习** 的方法。'
          '参考中文文稿 [00:12]–[00:28]。\n\n| 方法 | 用途 |\n| --- | --- |\n| 复述 | 检查理解 |\n'
          '| 提问 | 深入思考 |\n\n```python\nprint("active learning")\n```\n\n'
          '> 文稿只是节选，请结合完整视频。',
      finishReason: finishReason,
    );
  }
}

class _MemoryStore extends AiConversationStore {
  final records = <String, AiConversation>{};
  @override
  Future<List<AiConversation>> load(String videoId) async =>
      records.values.where((c) => c.videoId == videoId).toList();
  @override
  Future<void> save(AiConversation conversation) async {
    records[conversation.id] = conversation;
  }

  @override
  Future<void> delete(String videoId, String id) async {
    records.remove(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AiChatController controller;
  late _Loader loader;
  late _Transport transport;
  final video = VideoItem(
    id: 'panel-video',
    path: 'test.mp4',
    title: '如何建立自己的知识体系',
    durationMs: 120000,
    lastUpdated: 1,
  );

  setUp(() async {
    debugAiChatDesktopAutofocus = false;
    loader = _Loader();
    transport = _Transport();
    controller = AiChatController(
      video: video,
      contextLoader: loader,
      transport: transport,
      // Disk roundtrips are covered by ai_chat_drafts_test. Keep widget tests
      // independent of OS I/O futures crossing Flutter's fake async clock.
      conversationStore: _MemoryStore(),
      initialSettings: const AiChatSettings(
        backend: AiBackend.codex,
        titlePrompt: '',
      ),
    );
    await controller.initialize();
  });
  tearDown(() async {
    debugAiChatDesktopAutofocus = true;
    controller.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(440, 760),
    ValueNotifier<Duration>? position,
    GlobalKey? captureKey,
    String? font,
    ValueChanged<Duration>? onSeek,
    VoidCallback? onBackToSubtitles,
    double keyboard = 0,
    double textScale = 1,
    bool fullscreen = false,
    Size? screen,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: font),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: screen ?? size,
            viewInsets: EdgeInsets.only(bottom: keyboard),
            textScaler: TextScaler.linear(textScale),
          ),
          child: AppTextInputFocus(child: child!),
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: captureKey,
            child: AiChatPanel(
              videoItem: video,
              controller: controller,
              positionListenable: position,
              onSeek: onSeek,
              onBackToSubtitles: onBackToSubtitles,
              isFullscreen: fullscreen,
              onExitFullscreen: fullscreen ? () {} : null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'haptics: AI prompt, send, copy and new conversation pulse once',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final calls = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              calls.add(call.arguments);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await mount(tester);
      expect(calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
      await tester.pump();
      expect(calls, isEmpty, reason: 'Empty send is disabled');
      final prompt = find.byKey(const ValueKey('ai-quick-prompt-summary'));
      await tester.tap(prompt);
      await tester.pump();
      expect(calls, ['HapticFeedbackType.selectionClick']);
      calls.clear();
      await tester.tap(prompt);
      await tester.pump();
      expect(
        calls,
        isEmpty,
        reason: 'The same draft does not change selection',
      );
      await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
      await tester.pumpAndSettle();
      expect(calls, ['HapticFeedbackType.lightImpact']);
      calls.clear();
      await tester.tap(find.byTooltip('复制内容').last);
      await tester.pump();
      expect(calls, ['HapticFeedbackType.lightImpact']);
      calls.clear();
      await tester.tap(find.byTooltip('新建对话'));
      await tester.pumpAndSettle();
      expect(calls, ['HapticFeedbackType.lightImpact']);
      calls.clear();
      await tester.tap(find.byKey(const ValueKey('ai-chat-context')));
      await tester.pumpAndSettle();
      expect(calls, ['HapticFeedbackType.lightImpact']);
      calls.clear();
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(calls, ['HapticFeedbackType.selectionClick']);
      calls.clear();
      await tester.tap(find.byKey(const ValueKey('ai-context-recommend')));
      await tester.pumpAndSettle();
      expect(calls, ['HapticFeedbackType.selectionClick']);
      calls.clear();
      await tester.tap(find.byKey(const ValueKey('ai-context-recommend')));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await settings.saveEnableHapticFeedback(false);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '取消').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多对话操作'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'haptics: AI toolbar and overflow navigation have the same single pulse',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final calls = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              calls.add(call.arguments);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await mount(tester, size: const Size(440, 760));
      await tester.tap(find.byTooltip('对话历史'));
      await tester.pumpAndSettle();
      expect(calls, ['HapticFeedbackType.lightImpact']);
      await tester.tap(find.widgetWithText(TextButton, '关闭').last);
      await tester.pumpAndSettle();
      await mount(tester, size: const Size(280, 760));
      calls.clear();
      await tester.tap(find.byTooltip('更多对话操作'));
      await tester.pumpAndSettle();
      expect(calls, ['HapticFeedbackType.lightImpact']);
      expect(find.text('对话历史'), findsNothing);
      expect(find.text('新建对话'), findsNothing);
      await tester.tap(find.text('AI 设置'));
      await tester.pumpAndSettle();
      expect(calls, [
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.lightImpact',
      ]);
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      calls.clear();
      await tester.tap(find.byTooltip('对话历史'));
      await tester.pumpAndSettle();
      expect(calls, ['HapticFeedbackType.lightImpact']);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'mobile composer retains focus on send but dismisses on content',
    (tester) async {
      await mount(tester);
      final input = find.byKey(const ValueKey('ai-chat-input'));
      await tester.enterText(input, '还没有发送的草稿');
      await tester.pump();
      final field = tester.widget<TextField>(input);
      final send = find.byKey(const ValueKey('ai-chat-send'));
      final gesture = await tester.startGesture(tester.getCenter(send));
      await tester.pump();
      expect(field.focusNode!.hasFocus, isTrue);
      await gesture.cancel();
      await tester.pump();

      tester.testTextInput.hide();
      await tester.tap(find.text('已按字幕选择准备资料，可以直接提问。'));
      await tester.pumpAndSettle();
      expect(field.focusNode!.hasFocus, isFalse);
      expect(field.controller!.text, '还没有发送的草稿');
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'length warning and continue button fit a narrow panel and send a visible followup',
    (tester) async {
      transport.finishReason = 'length';
      await tester.runAsync(() => controller.send('解释知识管理'));
      await mount(tester, size: const Size(240, 640), textScale: 1.3);
      expect(find.text('继续生成'), findsOneWidget);
      expect(find.textContaining('单次输出上限'), findsOneWidget);
      expect(tester.takeException(), isNull);
      transport.finishReason = 'stop';
      await tester.runAsync(() async {
        await tester.tap(find.text('继续生成'));
        for (var i = 0; i < 100 && controller.busy; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();
      expect(controller.active!.messages, hasLength(4));
      expect(
        controller.active!.messages[2].content,
        '继续完成上一条回答，从中断处接着写，不重复已写的内容。',
      );
      expect(
        transport.requests.last.last['content'],
        controller.active!.messages[2].content,
      );
      expect(find.text('继续生成'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared sidebar retains AI bookmark, draft and background output',
    (tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => controller.send('第 $i 轮提问'));
      }
      final updates = StreamController<AiChatDelta>();
      transport.updates = updates;
      var showChat = true;
      late StateSetter update;
      final chatKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return SizedBox(
                  width: 320,
                  height: 600,
                  child: SubtitleChatSidebar(
                    showChat: showChat,
                    subtitles: TextButton(
                      onPressed: () => update(() => showChat = true),
                      child: const Text('打开 AI'),
                    ),
                    chat: AiChatPanel(
                      key: chatKey,
                      videoItem: video,
                      controller: controller,
                      isVisible: showChat,
                      onBackToSubtitles: () => update(() => showChat = false),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final originalState = chatKey.currentState;
      final view = tester.widget<AiMessageViewport>(
        find.byType(AiMessageViewport),
      );
      final question = controller.active!.messages[4];
      view.onNavigate();
      view.controller.restore(AiMessageBookmark(question.id, 0, 0));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '尚未发送的草稿');
      final before = view.controller.bookmark!;
      expect(before.messageId, question.id);
      expect(
        tester.getTopLeft(find.byTooltip('返回字幕')).dx,
        lessThan(tester.getTopLeft(find.text('AI 对话')).dx),
      );
      await tester.tap(find.byTooltip('返回字幕'));
      await tester.pumpAndSettle();
      expect(find.byType(AiMessageViewport), findsNothing);
      late Future<void> sending;
      await tester.runAsync(() async {
        sending = controller.send('后台问题');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        updates.add(const AiChatDelta(content: '切换到字幕后仍然继续生成。'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(controller.generating, isTrue);
      for (var visit = 0; visit < 3; visit++) {
        await tester.tap(find.text('打开 AI'));
        await tester.pumpAndSettle();
        expect(chatKey.currentState, same(originalState));
        expect(view.controller.bookmark!.messageId, before.messageId);
        expect(
          view.controller.bookmark!.alignment,
          closeTo(before.alignment, .01),
        );
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          '尚未发送的草稿',
        );
        await tester.tap(find.byTooltip('返回字幕'));
        await tester.pumpAndSettle();
      }
      var completed = false;
      unawaited(sending.then((_) => completed = true));
      await tester.runAsync(() async {
        updates.add(const AiChatDelta(content: '回答完成。', finishReason: 'stop'));
        unawaited(updates.close());
      });
      // Draft autosaves use the widget-test clock, while the store uses native
      // file IO. Advance both instead of awaiting IO with the test clock frozen.
      for (var i = 0; i < 100 && !completed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(completed, isTrue);
      expect(controller.active!.messages.last.status, 'complete');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('shared sidebar navigation fits the subtitle width range', (
    tester,
  ) async {
    for (final width in [100.0, 160.0, 240.0, 320.0, 440.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              height: 360,
              child: AiChatPanel(
                videoItem: video,
                controller: controller,
                onBackToSubtitles: () {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回字幕'), findsOneWidget);
      expect(find.byTooltip('对话历史'), findsOneWidget);
      expect(find.byTooltip('新建对话'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'user math questions render while preserving their original source',
    (tester) async {
      const question = r'解释 \(x^2+y^2=1\) 的含义';
      await tester.runAsync(() => controller.send(question));
      await mount(tester);
      await tester.drag(
        find.byKey(const ValueKey('ai-chat-messages')),
        const Offset(0, 1000),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<AiMathFormula>(find.byType(AiMathFormula))
            .any((math) => math.source == 'x^2+y^2=1'),
        isTrue,
      );
      expect(controller.active!.messages.first.content, question);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'source choices apply to a new conversation before any message is sent',
    (tester) async {
      loader.withSecondary = true;
      await controller.refreshContext();
      await mount(tester);
      final originalId = controller.active!.id;
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        '尚未发送的问题',
      );
      await tester.tap(find.byKey(const ValueKey('ai-chat-context')));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 条'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 条'), findsOneWidget);
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(controller.selectedTrackIds, {'primary'});

      await tester.tap(find.byTooltip('新建对话'));
      await tester.pumpAndSettle();
      expect(controller.active!.id, isNot(originalId));
      expect(controller.active!.messages, isEmpty);
      expect(controller.active!.draftText, isEmpty);
      expect(controller.selectedTrackIds, {'primary'});
      expect(controller.selectionIsAutomatic, isFalse);
      expect(transport.requests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('ai-chat-context')));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 条'), findsOneWidget);
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(1)).value,
        isFalse,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await controller.selectConversation(originalId);
      await tester.pumpAndSettle();
      expect(controller.active!.draftText, '尚未发送的问题');
      expect(controller.selectedTrackIds, {'primary'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('320px chat, context, settings and developer dialogs fit', (
    tester,
  ) async {
    await mount(tester, size: const Size(320, 640));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('新建对话'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-chat-context')));
    await tester.pumpAndSettle();
    expect(find.textContaining('其他字幕'), findsWidgets);
    expect(find.text('字幕文件无法读取'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('AI 设置'));
    await tester.pumpAndSettle();
    expect(find.text('测试连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多对话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开发者模式'));
    await tester.pumpAndSettle();
    expect(find.text('系统提示词（可编辑）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'streaming keeps settings, sources, branching and new conversation usable',
    (tester) async {
      controller.dispose();
      controller = AiChatController(
        video: video,
        contextLoader: loader,
        transport: transport,
        conversationStore: _MemoryStore(),
        initialSettings: const AiChatSettings(
          backend: AiBackend.codex,
          titlePrompt: '',
        ),
      );
      late Future<void> pending;
      await tester.runAsync(() async {
        await controller.initialize();
        transport.updates = StreamController<AiChatDelta>();
        pending = controller.send('仍在生成的提问');
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      final sourceId = controller.active!.id;
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiChatPanel(videoItem: video, controller: controller),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.generating, isTrue);
      await tester.tap(find.byTooltip('AI 设置'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('改动从下一次发送生效，当前回答继续使用原设置。'), findsOneWidget);
      expect(find.text('测试连接'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('ai-chat-context')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('资料选择从下一次发送生效，当前回答继续使用原资料。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byTooltip('编辑提问'), findsOneWidget);
      expect(find.byTooltip('撤回至输入框'), findsOneWidget);
      await tester.tap(find.byTooltip('新建对话'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.active!.id, isNot(sourceId));
      expect(controller.generating, isFalse);
      expect(controller.isGenerating(sourceId), isTrue);
      expect(find.byKey(const ValueKey('ai-chat-send')), findsOneWidget);
      transport.updates!.add(
        const AiChatDelta(content: '原对话的最终回答', finishReason: 'stop'),
      );
      final closed = transport.updates!.close();
      // Drive the widget's fake clock and the response's real async clock together.
      for (var i = 0; i < 20 && controller.isGenerating(sourceId); i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      expect(controller.isGenerating(sourceId), isFalse);
      await tester.runAsync(() => Future.wait([closed, pending]));
      expect(controller.active!.messages, isEmpty);
      expect(
        controller.conversations
            .firstWhere((c) => c.id == sourceId)
            .messages
            .last
            .content,
        '原对话的最终回答',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'quick prompts fill a draft without focusing or showing the keyboard',
    (tester) async {
      await mount(tester);
      tester.testTextInput.log.clear();
      await tester.tap(find.text('总结这个视频的核心内容和结论'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('ai-chat-input')),
      );
      expect(field.controller!.text, '总结这个视频的核心内容和结论');
      expect(field.focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.show',
        ),
        isEmpty,
      );
      expect(transport.requests, isEmpty);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('ai-chat-send')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('ai-chat-input')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.text('挑出视频中最难理解的一个概念，用例子讲清楚'));
      await tester.pumpAndSettle();
      expect(field.controller!.text, '挑出视频中最难理解的一个概念，用例子讲清楚');
      expect(field.focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'composer centers empty and single-line text and grows with lines',
    (tester) async {
      await mount(tester);
      final input = find.byKey(const ValueKey('ai-chat-input'));
      final composer = find.byKey(const ValueKey('ai-chat-composer'));
      final emptyHeight = tester.getSize(input).height;
      final hint = tester.getRect(find.text('询问这个视频…'));
      expect(hint.center.dy, closeTo(tester.getRect(composer).center.dy, 1));
      expect(
        tester.getRect(find.byKey(const ValueKey('ai-chat-send'))).center.dy,
        closeTo(tester.getRect(composer).center.dy, 1),
      );
      await tester.enterText(input, '字');
      await tester.pumpAndSettle();
      expect(tester.getSize(input).height, closeTo(emptyHeight, 1));
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final caret = editable.getLocalRectForCaret(
        const TextPosition(offset: 0),
      );
      expect(
        editable.localToGlobal(caret.center).dy,
        closeTo(tester.getRect(composer).center.dy, 3),
      );
      await tester.enterText(input, '第一行\n第二行\n第三行');
      await tester.pumpAndSettle();
      expect(tester.getSize(input).height, greaterThan(emptyHeight + 25));
      await tester.enterText(input, '');
      await tester.pumpAndSettle();
      expect(tester.getSize(input).height, closeTo(emptyHeight, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'first streamed exchange starts at the top until its content overflows',
    (tester) async {
      final updates = StreamController<AiChatDelta>();
      transport.updates = updates;
      await mount(tester, size: const Size(440, 760));
      late Future<void> sending;
      await tester.runAsync(() async {
        sending = controller.send('第一句提问');
        await Future<void>.delayed(const Duration(milliseconds: 90));
      });
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('ai-chat-messages'));
      final question = find.byKey(
        PageStorageKey(controller.active!.messages.first.id),
      );
      void expectTop() => expect(
        tester.getTopLeft(question).dy,
        closeTo(tester.getTopLeft(list).dy + 10, 1),
      );
      expectTop();
      for (final text in ['简短回答。', '再补充一句。', '仍然从上方自然增长。']) {
        await tester.runAsync(() async {
          updates.add(AiChatDelta(content: text));
          await Future<void>.delayed(const Duration(milliseconds: 90));
        });
        await tester.pumpAndSettle();
        expectTop();
      }
      await tester.runAsync(() async {
        updates.add(
          AiChatDelta(
            content: List.generate(60, (i) => '\n\n第 $i 段内容。').join(),
            finishReason: 'stop',
          ),
        );
        await updates.close();
        await sending;
      });
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AiMessageViewport>(find.byType(AiMessageViewport))
            .controller
            .awayFromBottom,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final fullscreen in [false, true]) {
    testWidgets(
      'mobile ${fullscreen ? 'fullscreen' : 'playback panel'} keeps planning and streamed content stable through keyboard frames',
      (tester) async {
        controller.dispose();
        controller = AiChatController(
          video: video,
          contextLoader: loader,
          transport: transport,
          conversationStore: _MemoryStore(),
          initialSettings: const AiChatSettings(
            apiKey: 'test-only',
            titlePrompt: '',
          ),
        );
        await controller.initialize();
        final planning = StreamController<AiChatDelta>();
        final output = StreamController<AiChatDelta>();
        transport.planningUpdates = planning;
        transport.updates = output;
        tester.view.physicalSize = const Size(400, 820);
        tester.view.devicePixelRatio = 1;
        tester.view.viewPadding = const FakeViewPadding(bottom: 20);
        tester.view.padding = const FakeViewPadding(bottom: 20);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              resizeToAvoidBottomInset: false,
              body: SafeArea(
                maintainBottomViewPadding: true,
                child: AiKeyboardViewport(
                  reservedBottomInset: 20,
                  child: LayoutBuilder(
                    builder: (_, limits) => Column(
                      children: [
                        if (!fullscreen)
                          SizedBox(height: limits.maxHeight * .3),
                        Expanded(
                          child: AiChatPanel(
                            videoItem: video,
                            controller: controller,
                            isFullscreen: fullscreen,
                            onBackToSubtitles: () {},
                            onExitFullscreen: fullscreen ? () {} : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        late Future<void> sending;
        await tester.runAsync(() async {
          sending = controller.send('第一句问题');
          await Future<void>.delayed(const Duration(milliseconds: 90));
        });
        await tester.pumpAndSettle();
        final list = find.byKey(const ValueKey('ai-chat-messages'));
        final question = find.byKey(
          PageStorageKey(controller.active!.messages.first.id),
        );
        final toolbar = find.byKey(const ValueKey('ai-chat-toolbar'));
        final viewport = tester.widget<AiMessageViewport>(
          find.byType(AiMessageViewport),
        );
        final answer = find.byKey(
          PageStorageKey(controller.active!.messages.last.id),
        );
        void expectTop() {
          final fits =
              tester.getSize(question).height +
                  tester.getSize(answer).height +
                  22 <=
              tester.getSize(list).height;
          if (fits) {
            expect(
              tester.getTopLeft(question).dy,
              closeTo(tester.getTopLeft(list).dy + 10, 1),
            );
          } else {
            expect(
              tester.getBottomLeft(answer).dy + 12,
              closeTo(tester.getBottomLeft(list).dy, 1),
            );
          }
          expect(
            tester.getTopLeft(list).dy,
            closeTo(tester.getBottomLeft(toolbar).dy, 1),
            reason:
                'planning status must not add a moving strip above the question',
          );
        }

        expect(find.text('正在理解本轮问题…'), findsOneWidget);
        expectTop();
        for (final inset in [
          24.0,
          64.0,
          156.0,
          240.0,
          320.0,
          272.0,
          160.0,
          80.0,
          0.0,
        ]) {
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          await tester.pump(const Duration(milliseconds: 16));
          expectTop();
          expect(
            tester
                .getRect(find.byKey(const ValueKey('ai-chat-composer')))
                .bottom,
            closeTo(820 - (inset < 20 ? 20 : inset) - 8, 1),
          );
          expect(tester.takeException(), isNull);
        }
        await tester.runAsync(() async {
          planning.add(
            const AiChatDelta(
              content:
                  '{"source":"none","relation":"new","query":"","task":"answer"}',
              finishReason: 'stop',
            ),
          );
          await planning.close();
          await Future<void>.delayed(const Duration(milliseconds: 90));
          output.add(
            AiChatDelta(
              content: List.generate(35, (i) => '第$i段回答，解释当前问题。\n\n').join(),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 90));
        });
        await tester.pumpAndSettle();
        expect(controller.busy, isTrue);
        expect(find.text('正在理解本轮问题…'), findsNothing);
        for (final inset in [
          24.0,
          80.0,
          160.0,
          240.0,
          320.0,
          240.0,
          160.0,
          80.0,
          0.0,
        ]) {
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          await tester.runAsync(() async {
            output.add(AiChatDelta(content: '新的段落 $inset。\n\n'));
            await Future<void>.delayed(const Duration(milliseconds: 75));
          });
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.getBottomLeft(answer).dy + 12,
            closeTo(tester.getBottomLeft(list).dy, 1),
            reason:
                'stream and keyboard must pin the tail before this frame is painted',
          );
          expect(viewport.controller.awayFromBottom, isFalse);
          expect(tester.takeException(), isNull);
        }
        await tester.runAsync(() async {
          await output.close();
          await sending;
        });
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets('typing does not rebuild rendered conversation Markdown', (
    tester,
  ) async {
    await tester.runAsync(() => controller.send('解释视频'));
    await mount(tester);
    final markdown = find.byWidgetPredicate(
      (widget) => widget is AiMarkdown && widget.data.contains('核心内容'),
    );
    final before = tester.widget<AiMarkdown>(markdown);
    await tester.enterText(find.byKey(const ValueKey('ai-chat-input')), '继续');
    await tester.pumpAndSettle();
    expect(identical(tester.widget<AiMarkdown>(markdown), before), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'failed full processing exposes attempt details in a small usage dialog',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(240, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final message = AiChatMessage(
        id: 'failed-attempt',
        role: 'assistant',
        content: '',
        status: 'error',
        responseInfo: {
          'model': 'deepseek-flash',
          'context_mode': '全文分段处理中',
          'preparation_usage': {
            'calls': 1,
            'reported_calls': 1,
            'prompt_tokens': 8475,
            'completion_tokens': 2048,
            'total_tokens': 10523,
            'attempts': [
              {
                'segment': '字幕第 1/7 段',
                'finish_reason': 'length',
                'input_tokens': 8475,
                'output_tokens': 2048,
                'output_limit': 2048,
              },
            ],
          },
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AiResponseUsage(message: message)),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('ai-response-usage-failed-attempt')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('分段处理记录'));
      await tester.tap(find.text('分段处理记录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('字幕第 1/7 段 · length'), findsOneWidget);
      expect(find.textContaining('输出 2,048 / 上限 2048 token'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'answer footer keeps compact actions below the reply across layouts',
    (tester) async {
      await tester.runAsync(() async {
        for (final entry in {
          'AiFooterPreview': 'C:/Windows/Fonts/msyh.ttc',
          'monospace': 'C:/Windows/Fonts/consola.ttf',
          'MaterialIcons':
              'D:/FlutterSDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          final file = File(entry.value);
          if (!await file.exists()) continue;
          final bytes = await file.readAsBytes();
          await (FontLoader(
            entry.key,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
        await controller.send('解释视频');
      });
      final answer = controller.active!.messages.last;
      for (final (name, size, scale) in [
        ('narrow', const Size(160, 360), 1.0),
        ('phone', const Size(320, 640), 1.0),
        ('sidebar', const Size(440, 760), 1.0),
        ('landscape', const Size(800, 240), 1.0),
        ('desktop', const Size(1280, 800), 1.0),
        ('large-text', const Size(320, 640), 2.0),
      ]) {
        final capture = GlobalKey();
        await mount(
          tester,
          size: size,
          textScale: scale,
          font: 'AiFooterPreview',
          captureKey: capture,
        );
        final actions = find.byKey(ValueKey('ai-answer-actions-${answer.id}'));
        final footer = find.byKey(ValueKey('ai-answer-footer-${answer.id}'));
        final usage = find.byKey(ValueKey('ai-response-usage-${answer.id}'));
        final body = find.byWidgetPredicate(
          (widget) => widget is AiMarkdown && widget.data == answer.content,
        );
        expect(actions, findsOneWidget, reason: name);
        expect(tester.getSize(actions).height, 32, reason: name);
        expect(
          tester.getTopLeft(actions).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(body).dy),
          reason: name,
        );
        for (final label in ['复制内容', '重新生成回答', '从这里创建分支']) {
          final button = find.descendant(
            of: actions,
            matching: find.byTooltip(label),
          );
          expect(button, findsOneWidget, reason: '$name: $label');
          expect(tester.getSize(button), const Size(32, 32));
        }
        if (size.width >= 320 && scale == 1) {
          expect(tester.getSize(footer).height, 34, reason: name);
          expect(
            tester.getCenter(actions).dy,
            closeTo(tester.getCenter(usage).dy, 1),
            reason: name,
          );
        }
        if (name == 'phone') {
          expect(
            find.descendant(
              of: find.byKey(PageStorageKey(answer.id)),
              matching: find.byTooltip('复制内容'),
            ),
            findsNWidgets(2),
          );
        }
        expect(tester.takeException(), isNull, reason: name);
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$_previewDirectory/answer-footer-$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('answer footer copies, retries and branches the matching reply', (
    tester,
  ) async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.runAsync(() => controller.send('解释视频'));
    await mount(tester, size: const Size(320, 640));
    final original = controller.active!;
    final answer = original.messages.last;
    Finder action(String id, String label) => find.descendant(
      of: find.byKey(ValueKey('ai-answer-actions-$id')),
      matching: find.byTooltip(label),
    );
    await tester.tap(action(answer.id, '复制内容'));
    await tester.pumpAndSettle();
    expect(copied, answer.content);
    final requests = transport.requests.length;
    await tester.runAsync(() async {
      await tester.tap(action(answer.id, '重新生成回答'));
      for (var i = 0; i < 100 && controller.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(transport.requests.length, requests + 1);
    expect(controller.active!.id, original.id);
    final retried = controller.active!.messages.last;
    expect(retried.id, isNot(answer.id));
    expect(controller.active!.messages.length, 2);
    await tester.runAsync(() async {
      await tester.tap(action(retried.id, '从这里创建分支'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(controller.active!.parentConversationId, original.id);
    expect(controller.active!.parentMessageId, retried.id);
    expect(controller.active!.messages.last.content, retried.content);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('per-answer usage and context indicator fit a narrow panel', (
    tester,
  ) async {
    await tester.runAsync(() => controller.send('解释视频'));
    await mount(tester, size: const Size(240, 640));
    final answer = controller.active!.messages.last;
    final usage = find.byKey(ValueKey('ai-response-usage-${answer.id}'));
    expect(
      tester
          .getRect(find.byKey(const ValueKey('ai-chat-messages')))
          .contains(tester.getCenter(usage)),
      isTrue,
      reason: 'First entry shows the latest answer tail and its usage action.',
    );
    await tester.tap(usage);
    await tester.pumpAndSettle();
    expect(find.text('答复用量'), findsOneWidget);
    expect(find.textContaining('缓存命中率'), findsNothing);
    expect(find.text('统计来源：Codex CLI'), findsOneWidget);
    expect(find.textContaining('估算不代表账单'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-context-meter')));
    await tester.pumpAndSettle();
    expect(find.text('上下文使用量'), findsOneWidget);
    expect(find.textContaining('模型上下文窗口：服务未声明'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'resizing playback reuses Markdown and conversation changes still update it',
    (tester) async {
      await tester.runAsync(() => controller.send('解释视频'));
      await tester.binding.setSurfaceSize(const Size(440, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Widget page(double reservedHeight) => MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(height: reservedHeight),
              Expanded(
                child: AiChatPanel(videoItem: video, controller: controller),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(page(20));
      await tester.pumpAndSettle();
      final markdown = find.byWidgetPredicate(
        (widget) => widget is AiMarkdown && widget.data.contains('核心内容'),
      );
      final before = tester.widget<AiMarkdown>(markdown);
      for (final height in [40.0, 60.0, 80.0, 100.0]) {
        await tester.pumpWidget(page(height));
        await tester.pumpAndSettle();
        expect(identical(tester.widget<AiMarkdown>(markdown), before), isTrue);
      }
      await tester.runAsync(
        () => controller.renameConversation(controller.active!.id, '更新后的标题'),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('更新后的标题'), findsOneWidget);
      expect(identical(tester.widget<AiMarkdown>(markdown), before), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'horizontal resize reuses Markdown within size bands and preserves draft and reasoning',
    (tester) async {
      await tester.runAsync(() => controller.send('解释视频'));
      final conversationId = controller.active!.id;
      await tester.binding.setSurfaceSize(const Size(1200, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Widget page(double width) => MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const Expanded(child: ColoredBox(color: Colors.black)),
              SizedBox(
                width: width,
                child: AiChatPanel(
                  videoItem: video,
                  controller: controller,
                  onClose: () {},
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(page(420));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('ai-chat-input'));
      await tester.enterText(input, '保留这段尚未发送的草稿');
      await tester.pumpAndSettle();
      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();
      final markdown = find.byWidgetPredicate(
        (widget) => widget is AiMarkdown && widget.data.contains('核心内容'),
      );
      var before = tester.widget<AiMarkdown>(markdown);
      final wideSize = tester.getSize(markdown);
      var previousMetrics = AiChatTextMetrics.resolve(
        panelWidth: 420,
        screen: const Size(1200, 720),
        fullscreen: false,
      );
      for (final width in [410.0, 380.0, 340.0, 300.0]) {
        await tester.pumpWidget(page(width));
        await tester.pump();
        final metrics = AiChatTextMetrics.resolve(
          panelWidth: width,
          screen: const Size(1200, 720),
          fullscreen: false,
        );
        if (metrics == previousMetrics) {
          expect(
            identical(tester.widget<AiMarkdown>(markdown), before),
            isTrue,
          );
        }
        previousMetrics = metrics;
        before = tester.widget<AiMarkdown>(markdown);
        expect(tester.takeException(), isNull);
      }
      final narrowSize = tester.getSize(markdown);
      expect(narrowSize.width, lessThan(wideSize.width));
      expect(narrowSize.height, greaterThan(0));
      expect(tester.widget<TextField>(input).style!.fontSize, 12);
      for (final width in [260.0, 240.0, 280.0, 600.0, 820.0, 420.0]) {
        await tester.pumpWidget(page(width));
        await tester.pumpAndSettle();
        expect(controller.active!.id, conversationId);
        expect(tester.widget<TextField>(input).controller!.text, '保留这段尚未发送的草稿');
        expect(
          find.text('根据中文文稿，视频重点是主动学习与知识管理。'),
          findsOneWidget,
          reason: 'Expanded reasoning survives width $width',
        );
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();
      expect(find.text('根据中文文稿，视频重点是主动学习与知识管理。'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'sending reads live playback position and withdraw restores the draft in place',
    (tester) async {
      final position = ValueNotifier(Duration.zero);
      addTearDown(position.dispose);
      await mount(tester, position: position);
      position.value = const Duration(seconds: 34);
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        '解释当前内容',
      );
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
        for (
          var tries = 0;
          tries < 40 && (transport.requests.isEmpty || controller.busy);
          tries++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      await tester.pumpAndSettle();
      expect(loader.lastPosition, const Duration(seconds: 34));
      expect(transport.requests, isNotEmpty);
      final original = controller.active!;
      expect(original.messages.last.content, contains('主动学习'));
      await tester.drag(
        find.byKey(const ValueKey('ai-chat-messages')),
        const Offset(0, 1000),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('撤回至输入框'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('撤回至输入框'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(controller.conversations.length, 1);
      expect(controller.active!.id, original.id);
      expect(controller.active!.parentConversationId, isNull);
      expect(controller.active!.messages, isEmpty);
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('ai-chat-input')),
      );
      expect(input.controller!.text, '解释当前内容');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'timestamp taps survive streaming Markdown updates between pointer down and up',
    (tester) async {
      Duration? selected;
      Future<void> render(String data) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AiMarkdown(
                data: data,
                isStreaming: true,
                onSeek: (value) => selected = value,
              ),
            ),
          ),
        );
        await tester.pump();
      }

      const source = '对应片段 [00:12]–[00:28]。';
      await render(source);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().contains('对应片段'),
        ),
      );
      final content = paragraph.text.toPlainText();
      final offset = content.indexOf('00:12');
      final box = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: offset, extentOffset: offset + 5),
          )
          .first
          .toRect();
      final down = await tester.startGesture(
        paragraph.localToGlobal(box.center),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 30));
      await render('$source\n\n后续文字正在生成。');
      await down.up();
      await tester.pump();
      expect(selected, const Duration(seconds: 12));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'streaming reply stages are static and timestamp seeking works before completion',
    (tester) async {
      final updates = StreamController<AiChatDelta>();
      transport.updates = updates;
      final sought = <Duration>[];
      await mount(tester, onSeek: sought.add);
      late Future<void> sending;
      Future<void> emit(AiChatDelta delta) async {
        await tester.runAsync(() async {
          updates.add(delta);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
      }

      await tester.runAsync(() async {
        sending = controller.send('解释这个视频');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      final spinning = find.byWidgetPredicate(
        (widget) =>
            widget is CircularProgressIndicator && widget.value == null ||
            widget is LinearProgressIndicator && widget.value == null,
      );
      for (final stage in ['正在连接 Codex…', '正在准备请求…', '正在等待模型回复…']) {
        controller.preparationStatus = '正在读取视频文稿…';
        await emit(AiChatDelta(stage: stage));
        expect(find.text(stage), findsOneWidget);
        expect(spinning, findsNothing);
      }
      controller.preparationStatus = null;
      await emit(const AiChatDelta(reasoning: '正在结合字幕分析内容。'));
      expect(find.text('正在思考…'), findsOneWidget);
      expect(spinning, findsNothing);
      await emit(const AiChatDelta(content: '对应片段[00:12]，说明正在生成。'));
      expect(controller.busy, isTrue);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().contains('对应片段'),
        ),
      );
      expect(paragraph.text.toPlainText(), contains('对应片段 00:12 ，'));
      final offset = paragraph.text.toPlainText().indexOf('00:12');
      final box = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: offset, extentOffset: offset + 5),
          )
          .first
          .toRect();
      final pointer = await tester.startGesture(
        paragraph.localToGlobal(box.center),
        kind: ui.PointerDeviceKind.mouse,
      );
      await emit(const AiChatDelta(content: '\n\n更多解释持续到达。'));
      await pointer.up();
      await tester.pump();
      expect(sought, [const Duration(seconds: 12)]);
      expect(controller.busy, isTrue);
      expect(spinning, findsNothing);
      await tester.runAsync(() async {
        await updates.close();
        await sending;
      });
      await tester.pumpAndSettle();
      expect(controller.busy, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'markdown renders tables, code copy and timestamp seek with safe links',
    (tester) async {
      Duration? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiMarkdown(
                data:
                    '# 内容\n\n00:12 与 [另一个时间](video://seek?ms=34000)\n\n'
                    '## 阶段六：用 GIMP 转换图片（[00:37:29]–[00:42:49]）\n\n'
                    '导入图片 [00:39:08]–[00:39:55]。\n\n'
                    '时间链接 [00:15](video://seek?ms=20000) 与 [00:18][time-ref]。\n\n'
                    '无效时间 [00:99]；代码 `[00:16]`。\n\n'
                    '| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```dart\nfinal answer = 42;\n```\n\n'
                    '[不会执行](javascript:alert(1))\n\n'
                    '[time-ref]: video://seek?ms=25000',
                onSeek: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      expect(find.byTooltip('复制代码'), findsOneWidget);
      TextSpan activateLink(String label) {
        TextSpan? target;
        void visit(InlineSpan span) {
          if (span is TextSpan) {
            if (span.text == label && span.recognizer != null) target = span;
            for (final child in span.children ?? const <InlineSpan>[]) {
              visit(child);
            }
          }
        }

        for (final text in tester.widgetList<SelectableText>(
          find.byType(SelectableText),
        )) {
          if (text.textSpan != null) visit(text.textSpan!);
        }
        for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
          visit(text.text);
        }
        expect(target, isNotNull, reason: label);
        (target!.recognizer! as TapGestureRecognizer).onTap!();
        return target!;
      }

      final timestampLink = activateLink('00:37:29');
      expect(selected, const Duration(minutes: 37, seconds: 29));
      expect(timestampLink.style?.decoration, TextDecoration.none);
      expect(timestampLink.style?.fontWeight, FontWeight.w700);
      activateLink('00:42:49');
      expect(selected, const Duration(minutes: 42, seconds: 49));
      final renderedText = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((widget) => widget.text.toPlainText())
          .join();
      expect(renderedText, contains('（ 00:37:29 – 00:42:49 ）'));
      expect(renderedText, contains('导入图片 00:39:08 – 00:39:55 。'));
      expect(renderedText, contains('无效时间 [00:99]；代码 [00:16]。'));
      activateLink('00:15');
      expect(selected, const Duration(seconds: 20));
      activateLink('00:18');
      expect(selected, const Duration(seconds: 25));
      activateLink('另一个时间');
      expect(selected, const Duration(seconds: 34));
      expect(
        AiMarkdown.timestamp('01:02:03'),
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(AiMarkdown.timestamp('00:99'), isNull);
      activateLink('不会执行');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('320x360 answered panel fits without overflow', (tester) async {
    await tester.runAsync(() => controller.send('概括主要内容'));
    await mount(tester, size: const Size(320, 360));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('ai-chat-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-chat-send')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone conversation opens above the player and returns to it', (
    tester,
  ) async {
    await tester.runAsync(() => controller.send('概括主要内容'));
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(
                key: ValueKey('test-player'),
                height: 260,
                child: Text('视频播放区域'),
              ),
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAiChatPage(
                    context,
                    videoItem: video,
                    controller: controller,
                  ),
                  child: const Text('打开对话'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开对话'));
    await tester.pumpAndSettle();
    final messages = tester.getRect(
      find.byKey(const ValueKey('ai-chat-messages')),
    );
    expect(messages.top, lessThan(130));
    expect(messages.height, greaterThan(450));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    expect(find.byType(AiChatPanel), findsNothing);
    expect(find.byKey(const ValueKey('test-player')), findsOneWidget);
    expect(controller.active!.messages, isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final landscape in [false, true]) {
    testWidgets(
      '${landscape ? 'landscape' : 'portrait'} chat shares playback and keeps draft across fullscreen',
      (tester) async {
        await tester.runAsync(() => controller.send('概括主要内容'));
        await tester.binding.setSurfaceSize(
          landscape ? const Size(800, 360) : const Size(320, 640),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final panel = AiChatPanel(videoItem: video, controller: controller);
        const player = ColoredBox(
          color: Colors.black,
          child: Center(child: Text('视频播放区域', key: ValueKey('test-player'))),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: landscape
                  ? Row(
                      children: [
                        const Expanded(child: player),
                        SizedBox(width: 304, child: panel),
                      ],
                    )
                  : Column(
                      children: [
                        const SizedBox(height: 200, child: player),
                        Expanded(child: panel),
                      ],
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final embedded = tester.getRect(
          find.byKey(const ValueKey('ai-chat-messages')),
        );
        if (landscape) {
          expect(embedded.left, greaterThan(480));
        } else {
          expect(embedded.top, greaterThan(200));
        }
        final originalConversation = controller.active!.id;
        await tester.enterText(
          find.byKey(const ValueKey('ai-chat-input')),
          '尚未发送的草稿',
        );
        await tester.tap(find.byTooltip('全屏对话'));
        await tester.pumpAndSettle();
        final fullscreenPanel = find.byWidgetPredicate(
          (widget) => widget is AiChatPanel && widget.isFullscreen,
        );
        final fullscreenInput = find.descendant(
          of: fullscreenPanel,
          matching: find.byKey(const ValueKey('ai-chat-input')),
        );
        final fullscreen = tester.getRect(
          find.descendant(
            of: fullscreenPanel,
            matching: find.byKey(const ValueKey('ai-chat-messages')),
          ),
        );
        expect(fullscreen.left, lessThan(20));
        expect(fullscreen.top, lessThan(130));
        expect(fullscreen.width, greaterThan(landscape ? 760 : 300));
        expect(
          tester.widget<TextField>(fullscreenInput).controller!.text,
          '尚未发送的草稿',
        );
        await tester.enterText(fullscreenInput, '全屏中修改的草稿');
        if (landscape) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byTooltip('退出全屏'));
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('test-player')), findsOneWidget);
        expect(controller.active!.id, originalConversation);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
              .controller!
              .text,
          '全屏中修改的草稿',
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('ai-chat-messages'))),
          embedded,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final landscape in [false, true]) {
    testWidgets(
      'node reading position survives ${landscape ? 'landscape' : 'portrait'} fullscreen round trip',
      (tester) async {
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(() => controller.send('第 $i 轮提问'));
        }
        await tester.binding.setSurfaceSize(
          landscape ? const Size(844, 390) : const Size(390, 844),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final chat = AiChatPanel(videoItem: video, controller: controller);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: landscape
                  ? Row(
                      children: [
                        const Expanded(child: ColoredBox(color: Colors.black)),
                        SizedBox(width: 320, child: chat),
                      ],
                    )
                  : Column(
                      children: [
                        const SizedBox(height: 200),
                        Expanded(child: chat),
                      ],
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final question = controller.active!.messages[2];
        final viewport = tester.widget<AiMessageViewport>(
          find.byType(AiMessageViewport),
        );
        final rail = find.byKey(const ValueKey('ai-message-navigation'));
        await tester.longPressAt(
          Offset(
            tester.getRect(rail).left + 12,
            tester.getCenter(find.byKey(ValueKey('ai-node-${question.id}'))).dy,
          ),
        );
        await tester.pumpAndSettle();
        final previewQuestion = find.byKey(
          ValueKey('ai-node-preview-${question.id}'),
        );
        await tester.ensureVisible(previewQuestion);
        await tester.tap(previewQuestion);
        await tester.pumpAndSettle();
        expect(viewport.controller.bookmark!.messageId, question.id);
        await tester.tap(find.byTooltip('全屏对话'));
        await tester.pumpAndSettle();
        final fullPanel = find.byWidgetPredicate(
          (w) => w is AiChatPanel && w.isFullscreen,
        );
        final fullView = tester.widget<AiMessageViewport>(
          find.descendant(
            of: fullPanel,
            matching: find.byType(AiMessageViewport),
          ),
        );
        expect(fullView.controller.bookmark!.messageId, question.id);
        final first = controller.active!.messages.first;
        final fullRail = find.descendant(
          of: fullPanel,
          matching: find.byKey(const ValueKey('ai-message-navigation')),
        );
        await tester.tapAt(
          Offset(
            tester.getRect(fullRail).left + 12,
            tester
                .getCenter(
                  find.descendant(
                    of: fullPanel,
                    matching: find.byKey(ValueKey('ai-node-${first.id}')),
                  ),
                )
                .dy,
          ),
        );
        await tester.pumpAndSettle();
        expect(fullView.controller.bookmark!.messageId, first.id);
        await tester.tap(find.byTooltip('退出全屏'));
        await tester.pumpAndSettle();
        expect(viewport.controller.bookmark!.messageId, first.id);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'reconnect status is visible alongside partial text in a narrow panel',
    (tester) async {
      final updates = StreamController<AiChatDelta>();
      transport.updates = updates;
      await mount(tester, size: const Size(240, 640));
      await tester.runAsync(
        () => controller.renameConversation(controller.active!.id, '测试重连'),
      );
      late Future<void> sending;
      await tester.runAsync(() async {
        sending = controller.send('切换网络');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      Future<void> emit(AiChatDelta delta) async {
        await tester.runAsync(() async {
          updates.add(delta);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
      }

      await emit(const AiChatDelta(content: '断线前收到的回答'));
      const stage = '连接暂时中断，正在自动重连（1/8）…';
      await emit(const AiChatDelta(stage: stage, reconnecting: true));
      expect(find.text(stage), findsOneWidget);
      expect(controller.active!.messages.last.content, '断线前收到的回答');
      expect(controller.generating, isTrue);
      expect(controller.error, isNull);
      await emit(
        const AiChatDelta(
          contentSnapshot: '恢复后的完整回答',
          reasoningSnapshot: '',
          reconnecting: false,
          finishReason: 'stop',
        ),
      );
      expect(find.text(stage), findsNothing);
      expect(controller.active!.messages.last.content, '恢复后的完整回答');
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await updates.close();
        await sending;
      });
      await tester.pumpAndSettle();
      expect(controller.active!.messages.last.status, 'complete');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('downward drag near the tail is not interrupted by streaming', (
    tester,
  ) async {
    final updates = StreamController<AiChatDelta>();
    transport.updates = updates;
    await mount(tester);
    late Future<void> sending;
    await tester.runAsync(() async {
      sending = controller.send('检查向下滑动');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      updates.add(
        AiChatDelta(
          content: List.generate(80, (i) => '第 $i 段：手动浏览流式回答。').join('\n\n'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('ai-chat-messages'));
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    await tester.drag(list, const Offset(0, 100));
    await tester.pumpAndSettle();
    position.jumpTo(position.maxScrollExtent - 20);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump(const Duration(milliseconds: 16));
    final before = position.pixels;
    final renderedBefore = tester
        .widgetList<AiMarkdown>(find.byType(AiMarkdown))
        .last
        .data;
    expect(position.isScrollingNotifier.value, isTrue);
    await tester.runAsync(() async {
      updates.add(const AiChatDelta(content: '\n\n这一段先在后台接收。'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.isScrollingNotifier.value, isTrue);
    expect(position.pixels, closeTo(before, 1));
    expect(
      tester.widgetList<AiMarkdown>(find.byType(AiMarkdown)).last.data,
      renderedBefore,
    );
    expect(controller.active!.messages.last.content, contains('这一段先在后台接收。'));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<AiMarkdown>(find.byType(AiMarkdown)).last.data,
      contains('这一段先在后台接收。'),
    );
    position.jumpTo(position.maxScrollExtent - 20);
    await tester.pumpAndSettle();
    final beforeWheel = tester
        .widgetList<AiMarkdown>(find.byType(AiMarkdown))
        .last
        .data;
    for (var tick = 0; tick < 3; tick++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(list),
          scrollDelta: const Offset(0, 8),
        ),
      );
      await tester.runAsync(() async {
        updates.add(AiChatDelta(content: '\n\n连续滚轮期间的第 $tick 次更新。'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.widgetList<AiMarkdown>(find.byType(AiMarkdown)).last.data,
        beforeWheel,
      );
    }
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<AiMarkdown>(find.byType(AiMarkdown)).last.data,
      contains('连续滚轮期间的第 2 次更新。'),
    );
    expect(position.extentAfter, closeTo(0, 1));
    position.jumpTo(position.maxScrollExtent - 1000);
    await tester.pumpAndSettle();
    await tester.fling(list, const Offset(0, -150), 1000);
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.isScrollingNotifier.value, isTrue);
    await tester.tap(find.byTooltip('回到最新'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      updates.add(const AiChatDelta(content: '\n\n点击箭头后仍然追随最新回复。'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(position.extentAfter, closeTo(0, 1));
    await tester.runAsync(() async {
      await updates.close();
      await sending;
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reasoning collapses only from its outer content padding', (
    tester,
  ) async {
    const reasoning = '第一段思考，包含一些文字。\n\n第二段思考，参考 [00:12]。';
    final updates = StreamController<AiChatDelta>();
    transport.updates = updates;
    await tester.runAsync(() async {
      final sending = controller.send('检查思考栏点击范围');
      updates.add(
        const AiChatDelta(
          reasoning: reasoning,
          content: '简短回答。',
          finishReason: 'stop',
        ),
      );
      await updates.close();
      await sending;
    });
    Duration? selected;
    await mount(tester, onSeek: (value) => selected = value);
    final tile = find.byKey(
      ValueKey('ai-reasoning-${controller.active!.messages.last.id}'),
    );
    final header = find.descendant(of: tile, matching: find.byType(ListTile));
    final body = find.descendant(of: tile, matching: find.byType(AiMarkdown));
    await tester.tap(header);
    await tester.pumpAndSettle();

    final first = find.descendant(
      of: body,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().startsWith('第一段思考'),
      ),
    );
    final second = find.descendant(
      of: body,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().startsWith('第二段思考'),
      ),
    );
    final firstRect = tester.getRect(first);
    final secondRect = tester.getRect(second);
    final contentRect = tester.getRect(body);
    expect(secondRect.top, greaterThan(firstRect.bottom));
    for (final point in [
      firstRect.topLeft + const Offset(4, 4),
      Offset(contentRect.right - 2, firstRect.center.dy),
      Offset(contentRect.center.dx, (firstRect.bottom + secondRect.top) / 2),
    ]) {
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(body, findsOneWidget, reason: 'Text and paragraph gaps stay open');
    }
    final paragraph = tester.renderObject<RenderParagraph>(second);
    final timestampOffset = paragraph.text.toPlainText().indexOf('00:12');
    final timestampBox = paragraph
        .getBoxesForSelection(
          TextSelection(
            baseOffset: timestampOffset,
            extentOffset: timestampOffset + 5,
          ),
        )
        .first
        .toRect();
    await tester.tapAt(paragraph.localToGlobal(timestampBox.center));
    await tester.pumpAndSettle();
    expect(selected, const Duration(seconds: 12));
    expect(body, findsOneWidget);

    for (final edge in ['left', 'right', 'bottom']) {
      final rect = tester.getRect(body);
      final point = switch (edge) {
        'left' => Offset(rect.left - 6, rect.center.dy),
        'right' => Offset(rect.right + 6, rect.center.dy),
        _ => Offset(rect.center.dx, rect.bottom + 6),
      };
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(body, findsNothing, reason: '$edge padding collapses reasoning');
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(body, findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reasoning expansion and upward gestures pause stream following', (
    tester,
  ) async {
    final updates = StreamController<AiChatDelta>();
    transport.updates = updates;
    await mount(tester);
    late Future<void> sending;
    Future<void> emit(AiChatDelta delta) async {
      await tester.runAsync(() async {
        updates.add(delta);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
    }

    await tester.runAsync(() async {
      sending = controller.send('检查滚动');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await emit(
      AiChatDelta(
        reasoning: List.generate(
          80,
          (i) => '第 $i 段思考：逐步分析视频中的论点。',
        ).join('\n\n'),
        content: '回答正在生成。',
      ),
    );
    final list = find.byKey(const ValueKey('ai-chat-messages'));
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(position().pixels, lessThan(position().maxScrollExtent - 200));
    await tester.drag(list, const Offset(0, -350));
    await tester.pumpAndSettle();
    final readingOffset = position().pixels;
    await emit(
      const AiChatDelta(reasoning: '\n\n补充思考仍然在流式输出。', content: '\n\n补充回答。'),
    );
    expect(position().pixels, closeTo(readingOffset, 1));
    await tester.drag(list, const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(position().pixels, lessThan(readingOffset));
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<AiMarkdown>(find.byType(AiMarkdown))
          .where((markdown) => markdown.data.startsWith('第 0 段思考')),
      isEmpty,
    );
    await emit(
      AiChatDelta(content: List.generate(60, (i) => '\n\n第 $i 段回答。').join()),
    );
    await tester.tap(find.byTooltip('回到最新'));
    await tester.pumpAndSettle();
    // This stays inside the old 160px threshold and still must pause following.
    await tester.drag(list, const Offset(0, 70));
    await tester.pumpAndSettle();
    final manuallyScrolledOffset = position().pixels;
    await emit(const AiChatDelta(content: '\n\n后续流式回答不应抢走滚动位置。'));
    expect(position().pixels, closeTo(manuallyScrolledOffset, 1));
    await tester.tap(find.byTooltip('回到最新'));
    await tester.pumpAndSettle();
    await emit(const AiChatDelta(content: '\n\n恢复追随后，应跟随新的回答。'));
    expect(position().pixels, closeTo(position().maxScrollExtent, 1));
    await tester.tap(find.byTooltip('全屏对话'));
    await tester.pumpAndSettle();
    expect(controller.busy, isTrue);
    await emit(const AiChatDelta(content: '\n\n全屏期间生成继续。'));
    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    expect(controller.busy, isTrue);
    expect(controller.active!.messages.last.content, contains('全屏期间生成继续。'));
    await tester.runAsync(() async {
      await updates.close();
      await sending;
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('short landscape with keyboard preserves chat and composer', (
    tester,
  ) async {
    await tester.runAsync(() => controller.send('解释内容'));
    await mount(
      tester,
      size: const Size(800, 360),
      keyboard: 180,
      textScale: 1.3,
    );
    final input = tester.getRect(find.byKey(const ValueKey('ai-chat-input')));
    final messages = tester.getRect(
      find.byKey(const ValueKey('ai-chat-messages')),
    );
    expect(input.bottom, lessThanOrEqualTo(180));
    expect(messages.height, greaterThan(40));
    expect(find.byKey(const ValueKey('ai-chat-context')), findsNothing);
    await tester.tap(find.byTooltip('更多对话操作'));
    await tester.pumpAndSettle();
    expect(find.text('视频资料'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'fullscreen composer avoids the keyboard even in a short landscape viewport',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 360);
      addTearDown(tester.view.reset);
      await tester.runAsync(() => controller.send('说明视频内容'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAiChatPage(
                  context,
                  videoItem: video,
                  controller: controller,
                ),
                child: const Text('打开全屏'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开全屏'));
      await tester.pumpAndSettle();
      for (final inset in [180.0, 280.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pumpAndSettle();
        final input = tester.getRect(
          find.byKey(const ValueKey('ai-chat-input')),
        );
        expect(input.bottom, lessThanOrEqualTo(360 - inset));
        expect(
          tester.getSize(find.byKey(const ValueKey('ai-chat-messages'))).height,
          greaterThan(0),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reading size updates sidebar, composer, fullscreen and portrait',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final reading = AiChatReadingSettings.instance;
      reading.value = 1;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        reading.value = 1;
      });
      await tester.runAsync(() => controller.send('解释知识管理'));
      await mount(
        tester,
        size: const Size(320, 360),
        screen: const Size(844, 390),
      );

      double inputSize() => tester
          .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')).last)
          .style!
          .fontSize!;
      expect(inputSize(), 12);
      expect(
        find.byKey(const ValueKey('ai-chat-toolbar-metadata')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('更多对话操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读设置 · 字体大小'));
      await tester.pumpAndSettle();
      expect(find.text('字体大小 · 100%'), findsOneWidget);
      await tester.tap(find.byTooltip('放大字体'));
      await tester.pumpAndSettle();
      expect(find.text('字体大小 · 105%'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(inputSize(), closeTo(12.6, .001));
      expect(tester.takeException(), isNull);

      final restored = AiChatReadingSettings();
      await restored.load();
      expect(restored.value, closeTo(1.05, .001));
      restored.dispose();

      await tester.tap(find.byTooltip('全屏对话'));
      await tester.pumpAndSettle();
      expect(inputSize(), closeTo(13 * 1.05, .001));
      await tester.tap(find.byTooltip('退出全屏'));
      await tester.pumpAndSettle();
      expect(inputSize(), closeTo(12 * 1.05, .001));
      await mount(tester, size: const Size(390, 740));
      expect(inputSize(), closeTo(14 * 1.05, .001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('toolbar adapts across playback panels and fullscreen sizes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final entry in {
        'AiToolbarPreview': 'C:/Windows/Fonts/msyh.ttc',
        'monospace': 'C:/Windows/Fonts/consola.ttf',
        'MaterialIcons':
            'D:/FlutterSDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final file = File(entry.value);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        await (FontLoader(
          entry.key,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    });
    await tester.runAsync(() => controller.send('总结这个视频的核心内容'));
    final cases = [
      ('phone-portrait', const Size(360, 420), 1.0, false),
      ('phone-landscape', const Size(320, 360), 1.0, false),
      ('phone-fullscreen', const Size(390, 780), 1.0, true),
      ('tablet-portrait', const Size(768, 650), 1.0, false),
      ('tablet-landscape', const Size(420, 700), 1.0, false),
      ('desktop-sidebar', const Size(480, 840), 1.0, false),
      ('desktop-fullscreen', const Size(1280, 800), 1.0, true),
      ('narrow-sidebar', const Size(240, 640), 1.3, false),
      ('large-text', const Size(320, 640), 1.8, false),
      ('short-landscape', const Size(800, 180), 1.0, false),
    ];
    final sizes = <String, Object>{};
    for (final (name, size, scale, fullscreen) in cases) {
      final capture = GlobalKey();
      await mount(
        tester,
        size: size,
        textScale: scale,
        captureKey: capture,
        font: 'AiToolbarPreview',
        fullscreen: fullscreen,
        screen: name == 'phone-landscape' ? const Size(844, 390) : null,
        onBackToSubtitles: fullscreen ? null : () {},
      );
      await tester.drag(
        find.byKey(const ValueKey('ai-chat-messages')),
        const Offset(0, 2000),
      );
      await tester.pumpAndSettle();
      final toolbar = find.byKey(const ValueKey('ai-chat-toolbar'));
      expect(tester.takeException(), isNull, reason: name);
      final rect = tester.getRect(toolbar);
      expect(rect.width, size.width, reason: name);
      expect(rect.height, lessThanOrEqualTo(scale > 1 ? 90 : 64), reason: name);
      final history = find.byTooltip('对话历史');
      final newConversation = find.byTooltip('新建对话');
      expect(history, findsOneWidget, reason: name);
      expect(newConversation, findsOneWidget, reason: name);
      expect(
        tester.getRect(history).right,
        tester.getRect(newConversation).left,
        reason: '$name keeps history immediately left of new conversation',
      );
      expect(
        find.descendant(of: toolbar, matching: find.text('新建')),
        findsNothing,
        reason: '$name uses an icon without a label',
      );
      expect(
        find.descendant(
          of: toolbar,
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
      for (final button in tester.widgetList<IconButton>(
        find.descendant(of: toolbar, matching: find.byType(IconButton)),
      )) {
        final buttonRect = tester.getRect(find.byWidget(button));
        expect(buttonRect.width, 32, reason: name);
        expect(buttonRect.height, 32, reason: name);
        expect(buttonRect.left, greaterThanOrEqualTo(0), reason: name);
        expect(buttonRect.right, lessThanOrEqualTo(size.width), reason: name);
      }
      if (fullscreen) {
        expect(find.byTooltip('退出全屏'), findsOneWidget);
        expect(find.byTooltip('关闭 AI 对话'), findsNothing);
      }
      final metadata = find.byKey(const ValueKey('ai-chat-toolbar-metadata'));
      if (tester.any(metadata)) {
        final meta = tester.getRect(metadata);
        final commands = tester.getRect(
          find.byKey(const ValueKey('ai-chat-toolbar-commands')),
        );
        expect(
          meta.left,
          closeTo(commands.left, 1),
          reason: '$name status line shares the command row width',
        );
        expect(
          meta.right,
          closeTo(commands.right, 1),
          reason: '$name status line reaches the button column',
        );
      }
      sizes[name] = {
        'width': size.width,
        'height': size.height,
        'textScale': scale,
        'toolbarHeight': rect.height,
      };
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final picture = await boundary.toImage(pixelRatio: 1.5);
        final data = await picture.toByteData(format: ui.ImageByteFormat.png);
        final output = File('$_previewDirectory/toolbar-$name.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(data!.buffer.asUint8List());
        picture.dispose();
      });
    }
    await tester.runAsync(
      () => File(
        '$_previewDirectory/toolbar-layout-metrics.json',
      ).writeAsString(jsonEncode(sizes)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact latest arrow fits real conversation layouts', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final entry in {
        'AiScrollPreview': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons':
            'D:/FlutterSDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final file = File(entry.value);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        await (FontLoader(
          entry.key,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      final updates = StreamController<AiChatDelta>();
      transport.updates = updates;
      final sending = controller.send('如何在观看视频时更好地理解和记住内容？');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      updates.add(
        AiChatDelta(
          content: List.generate(
            40,
            (i) =>
                '### ${i + 1}. 把观看变成主动学习\n\n'
                '先用自己的话复述刚才的观点，再回到视频检查遗漏。'
                '遇到不理解的地方，记下一个具体问题，结合上下文继续思考。',
          ).join('\n\n'),
        ),
      );
      await updates.close();
      await sending;
    });
    for (final (name, size, scale, fullscreen) in [
      ('phone', const Size(390, 780), 1.0, true),
      ('landscape', const Size(800, 240), 1.0, true),
      ('sidebar', const Size(440, 760), 1.0, false),
      ('narrow', const Size(160, 360), 1.0, false),
      ('large-text', const Size(320, 640), 2.0, false),
      ('tablet', const Size(768, 1024), 1.0, true),
      ('desktop', const Size(1280, 800), 1.0, true),
    ]) {
      final capture = GlobalKey();
      await mount(
        tester,
        size: size,
        textScale: scale,
        captureKey: capture,
        font: 'AiScrollPreview',
        fullscreen: fullscreen,
      );
      final list = find.byKey(const ValueKey('ai-chat-messages'));
      await tester.drag(list, Offset(0, size.height / 3));
      await tester.pumpAndSettle();
      final arrow = find.byKey(const ValueKey('ai-scroll-to-latest'));
      expect(arrow, findsOneWidget, reason: name);
      final bounds = tester.getRect(list);
      final rect = tester.getRect(arrow);
      expect(bounds.contains(rect.topLeft), isTrue, reason: name);
      expect(bounds.contains(rect.bottomRight), isTrue, reason: name);
      expect(rect.size, const Size(44, 44), reason: name);
      expect(find.text('回到最新'), findsNothing);
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$_previewDirectory/scroll-latest-$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(arrow);
      await tester.pumpAndSettle();
      expect(arrow, findsNothing, reason: '$name returns to latest');
      expect(tester.takeException(), isNull, reason: name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('conversation preview screenshot', (tester) async {
    String? font;
    await tester.runAsync(() async {
      for (final entry in <String, String>{
        'MaterialIcons':
            'D:/FlutterSDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        'monospace': 'C:/Windows/Fonts/consola.ttf',
      }.entries) {
        final file = File(entry.value);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final fonts = FontLoader(entry.key)
            ..addFont(Future.value(ByteData.sublistView(bytes)));
          await fonts.load();
        }
      }
    });
    final fontFile = File('C:/Windows/Fonts/msyh.ttc');
    if (await tester.runAsync(fontFile.exists) == true) {
      await tester.runAsync(() async {
        final bytes = await fontFile.readAsBytes();
        final loader = FontLoader('AiChatPreview')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      });
      font = 'AiChatPreview';
    }
    await tester.runAsync(() => controller.send('总结视频重点，并给我一个学习方法的表格'));
    final capture = GlobalKey();
    await mount(
      tester,
      captureKey: capture,
      font: font,
      onSeek: (_) {},
      onBackToSubtitles: () {},
      size: const Size(480, 840),
    );
    // Keep the first message visible for visual review.
    await tester.drag(
      find.byKey(const ValueKey('ai-chat-messages')),
      const Offset(0, 700),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final picture = await boundary.toImage(pixelRatio: 1.5);
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      final output = File('$_previewDirectory/panel-preview.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(png!.buffer.asUint8List());
      await File(
        '$_previewDirectory/unified-sidebar-preview.png',
      ).writeAsBytes(png.buffer.asUint8List());
      picture.dispose();
    });
    Future<void> captureReasoning(String name) async {
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 1.5);
        final png = await picture.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$_previewDirectory/reasoning-$name.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        picture.dispose();
      });
    }

    final reasoning = find.byKey(
      ValueKey('ai-reasoning-${controller.active!.messages.last.id}'),
    );
    final reasoningHeader = find.descendant(
      of: reasoning,
      matching: find.byType(ListTile),
    );
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    await captureReasoning('expanded');
    final expandedPress = await tester.startGesture(
      tester.getTopLeft(reasoningHeader) + const Offset(8, 8),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await captureReasoning('expanded-pressed');
    await expandedPress.up();
    await tester.pumpAndSettle();
    final collapsedPress = await tester.startGesture(
      tester.getTopLeft(reasoningHeader) + const Offset(8, 8),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await captureReasoning('collapsed-pressed');
    await collapsedPress.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();

    final firstQuestion = controller.active!.messages.first;
    final navigation = find.byKey(const ValueKey('ai-message-navigation'));
    await tester.longPressAt(
      Offset(
        tester.getRect(navigation).left + 12,
        tester
            .getCenter(find.byKey(ValueKey('ai-node-${firstQuestion.id}')))
            .dy,
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final picture = await boundary.toImage(pixelRatio: 1.5);
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$_previewDirectory/navigation-panel-preview.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      picture.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
