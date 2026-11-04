import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/android_hardware_input_bridge.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

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

class _Store extends AiConversationStore {
  @override
  Future<List<AiConversation>> load(String videoId) async => [];
  @override
  Future<void> save(AiConversation conversation) async {}
}

class _Transport extends AiChatTransport {
  final questions = <String>[];
  StreamController<AiChatDelta>? updates;

  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    questions.add(messages.last['content']!);
    if (updates != null) {
      yield* updates!.stream;
    } else {
      yield const AiChatDelta(content: '回答', finishReason: 'stop');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final video = VideoItem(
    id: 'shortcut-video',
    path: 'test.mp4',
    title: '键盘测试',
    durationMs: 60000,
    lastUpdated: 1,
  );
  late AiChatController controller;
  late _Transport transport;
  final inputFinder = find.byKey(const ValueKey('ai-chat-input'));

  setUp(() async {
    debugAiChatDesktopAutofocus = false;
    transport = _Transport();
    controller = AiChatController(
      video: video,
      transport: transport,
      contextLoader: _Loader(),
      conversationStore: _Store(),
      initialSettings: const AiChatSettings(
        backend: AiBackend.codex,
        titlePrompt: '',
      ),
    );
    await controller.initialize();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugAiChatDesktopAutofocus = true;
    controller.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    VoidCallback? onBack,
    VoidCallback? onReturn,
    bool visible = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiChatPanel(
            videoItem: video,
            controller: controller,
            isVisible: visible,
            onBackToSubtitles: onBack,
            onBack: onReturn,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.runAsync(() async {
      await tester.sendKeyEvent(key, platform: 'android');
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  testWidgets(
    'Escape and the return button restore the source panel; subtitles '
    'remain a separate action',
    (tester) async {
      var returns = 0;
      var subtitles = 0;
      await mount(tester, onReturn: () => returns++, onBack: () => subtitles++);
      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      expect(returns, 1);
      await tester.tap(inputFinder);
      await press(tester, LogicalKeyboardKey.escape);
      expect(returns, 2);
      expect(subtitles, 0);
      await tester.tap(find.byTooltip('更多对话操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回字幕'));
      await tester.pumpAndSettle();
      expect(subtitles, 1);
      expect(returns, 2);
    },
  );

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '$platform: button send dismisses input before reply completes',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        transport.updates = StreamController<AiChatDelta>();
        await mount(tester);
        await tester.enterText(inputFinder, '点击发送');
        await tester.pump();
        final focus = tester.widget<TextField>(inputFinder).focusNode!;
        expect(focus.hasFocus, isTrue);
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        expect(controller.generating, isTrue);
        expect(focus.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);

        await tester.runAsync(() async {
          transport.updates!.add(const AiChatDelta(content: '回答'));
          await transport.updates!.close();
        });
        await tester.pump();
        expect(focus.hasFocus, isFalse);
        await tester.tap(inputFinder);
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '$platform: Enter and keypad Enter send; Shift inserts one newline',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await mount(tester);
        await tester.enterText(inputFinder, '第一条');
        await press(tester, LogicalKeyboardKey.enter);
        expect(transport.questions, ['第一条']);
        final input = tester.widget<TextField>(inputFinder).controller!;
        expect(input.text, isEmpty);
        expect(
          tester.widget<TextField>(inputFinder).focusNode!.hasFocus,
          isTrue,
        );

        await tester.enterText(inputFinder, '第二条');
        await press(tester, LogicalKeyboardKey.numpadEnter);
        expect(transport.questions, ['第一条', '第二条']);

        await tester.enterText(inputFinder, '前中后');
        input.selection = const TextSelection(baseOffset: 1, extentOffset: 2);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(input.text, '前\n后');
        expect(input.selection, const TextSelection.collapsed(offset: 2));
        expect(transport.questions.length, 2);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftRight);
        await tester.sendKeyEvent(
          LogicalKeyboardKey.numpadEnter,
          platform: 'android',
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftRight);
        await tester.pump();
        expect(input.text, '前\n\n后');
        expect(input.selection, const TextSelection.collapsed(offset: 3));
        expect(transport.questions.length, 2);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('rejected button send preserves focus and draft', (tester) async {
    controller.settings = controller.settings.copyWith(
      contextTokens: 1024,
      maxOutputTokens: 512,
    );
    await mount(tester);
    final draft = List.filled(10000, '很长的问题').join();
    await tester.enterText(inputFinder, draft);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(controller.error, isNotNull);
    expect(transport.questions, isEmpty);
    final field = tester.widget<TextField>(inputFinder);
    expect(field.controller!.text, draft);
    expect(field.focusNode!.hasFocus, isTrue);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    testWidgets('$platform: Shift+Enter participates in native undo', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await mount(tester);
      await tester.enterText(inputFinder, '可撤销的草稿');
      await tester.pump(const Duration(milliseconds: 600));
      final input = tester.widget<TextField>(inputFinder).controller!;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 600));
      expect(input.text, '可撤销的草稿\n');
      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      expect(input.text, '可撤销的草稿');
      expect(transport.questions, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets(
    'IME confirmation, modifier chords and soft keyboard action do not send',
    (tester) async {
      await mount(tester);
      await tester.enterText(inputFinder, '候选');
      final input = tester.widget<TextField>(inputFinder).controller!;
      input.value = const TextEditingValue(
        text: '候选',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      await press(tester, LogicalKeyboardKey.enter);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(input.text, '候选');
      expect(transport.questions, isEmpty);
      input.value = input.value.copyWith(composing: TextRange.empty);
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await press(tester, LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(modifier);
      }
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      expect(transport.questions, isEmpty);
      expect(input.text, '候选');
    },
  );

  testWidgets(
    'empty drafts, Enter repeats and busy generation preserve the next draft',
    (tester) async {
      transport.updates = StreamController<AiChatDelta>();
      await mount(tester);
      await tester.enterText(inputFinder, '   ');
      await press(tester, LogicalKeyboardKey.enter);
      expect(transport.questions, isEmpty);
      await tester.enterText(inputFinder, '正在生成');
      await press(tester, LogicalKeyboardKey.enter);
      expect(transport.questions, ['正在生成']);
      await tester.enterText(inputFinder, '下一条草稿');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(transport.questions.length, 1);
      expect(tester.widget<TextField>(inputFinder).controller!.text, '下一条草稿');
      await tester.runAsync(() async {
        transport.updates!.add(
          const AiChatDelta(content: '回答', finishReason: 'stop'),
        );
        await transport.updates!.close();
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(controller.busy, isFalse);
      transport.updates = null;
      // Repeats must still be consumed after generation finishes.
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await Future<void>.delayed(Duration.zero);
      });
      tester.widget<TextField>(inputFinder).controller!.text = '按住时新填草稿';
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(transport.questions.length, 2);
      expect(tester.widget<TextField>(inputFinder).controller!.text, '按住时新填草稿');
    },
  );

  testWidgets(
    'fullscreen sends once and Escape returns through the correct view',
    (tester) async {
      var returns = 0;
      await mount(tester, onBack: () => returns++);
      await tester.tap(find.byTooltip('全屏对话'));
      await tester.pumpAndSettle();
      expect(find.byType(AiChatPanel), findsNWidgets(2));
      await tester.enterText(inputFinder.last, '全屏提问');
      await press(tester, LogicalKeyboardKey.enter);
      expect(transport.questions, ['全屏提问']);
      await press(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AiChatPanel), findsOneWidget);
      expect(returns, 0);
      await tester.tap(inputFinder);
      await press(tester, LogicalKeyboardKey.escape);
      expect(returns, 1);
    },
  );

  testWidgets('hidden chat and chat under another route cannot submit', (
    tester,
  ) async {
    await mount(tester, visible: false);
    await tester.enterText(inputFinder, '隐藏草稿');
    await press(tester, LogicalKeyboardKey.enter);
    expect(transport.questions, isEmpty);
    await mount(tester);
    await tester.enterText(inputFinder, '后台草稿');
    final context = tester.element(inputFinder);
    unawaited(
      showDialog<void>(
        context: context,
        requestFocus: false,
        builder: (_) => const AlertDialog(content: Text('设置弹窗')),
      ),
    );
    await tester.pump();
    await press(tester, LogicalKeyboardKey.enter);
    expect(transport.questions, isEmpty);
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      '$platform: hovering send displays small platform-specific hints',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await mount(tester);
        final label = platform == TargetPlatform.windows ? 'Enter' : 'Return';
        final message = '$label 发送 · Shift+$label 换行';
        final tooltip = tester.widget<Tooltip>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('ai-chat-send')),
                matching: find.byType(Tooltip),
              )
              .first,
        );
        expect(tooltip.textStyle!.fontSize, 12);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(
          tester.getCenter(find.byKey(const ValueKey('ai-chat-send'))),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text(message), findsOneWidget);
        await mouse.removePointer();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  Future<void> mountPlayer(
    WidgetTester tester, {
    VoidCallback? onChat,
    bool locked = false,
    bool open = false,
    Widget? child,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService()..resetForTest(),
          ),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: MediaPlaybackService(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: VideoControlsOverlay(
                    controller: null,
                    isLocked: locked,
                    onTogglePlay: () {},
                    onBackPressed: () {},
                    onToggleLock: () {},
                    onSpeedUpdate: (_) async {},
                    onOpenAiChat: onChat,
                    aiChatOpen: open,
                    showSubtitles: false,
                    onToggleSubtitles: () {},
                    onMoveSubtitles: () {},
                    isLongPressing: false,
                    longPressFeedbackText: '',
                    onLongPressStart: () => false,
                    onLongPressEnd: () {},
                    subtitleEntries: const [],
                    subtitleStyle: const SubtitleStyle(),
                    subtitleAlignment: Alignment.bottomCenter,
                    onEnterSubtitleDragMode: () {},
                  ),
                ),
                ?child,
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'W uses the AI toggle callback and the open/close tooltips; repeats do not toggle',
    (tester) async {
      var toggles = 0;
      await mountPlayer(tester, onChat: () => toggles++);
      expect(find.byTooltip('AI 对话 (W)'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      expect(toggles, 1);
      await mountPlayer(tester, onChat: () => toggles++, open: true);
      expect(find.byTooltip('收起 AI 对话 (W)'), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 220)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      expect(toggles, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
    },
  );

  testWidgets(
    'W respects text input, Command/Ctrl chords, modal routes and player lock',
    (tester) async {
      var toggles = 0;
      await mountPlayer(
        tester,
        onChat: () => toggles++,
        child: const TextField(),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final state = tester.state<VideoControlsOverlayState>(
        find.byType(VideoControlsOverlay),
      );
      state.handleAndroidHardwareKeyEventForTest(
        AndroidHardwareInputBridge.decodeKeyForTesting({
          'keyCode': 51,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 1,
        })!,
      );
      final node = FocusNode();
      addTearDown(node.dispose);
      expect(
        state.handleKeyEvent(
          node,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyW,
            logicalKey: LogicalKeyboardKey.keyW,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.ignored,
        reason: 'A bridge copy must not consume the text editor key event',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      expect(toggles, 0);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
        await tester.sendKeyUpEvent(modifier);
      }
      expect(toggles, 0);
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(VideoControlsOverlay)),
          builder: (_) => const AlertDialog(content: Text('设置弹窗')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      expect(toggles, 0);
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();
      await mountPlayer(tester, onChat: () => toggles++, locked: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      expect(toggles, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
    },
  );

  testWidgets(
    'Android native bridge and Flutter delivery toggle AI only once',
    (tester) async {
      var toggles = 0;
      await mountPlayer(tester, onChat: () => toggles++);
      final state = tester.state<VideoControlsOverlayState>(
        find.byType(VideoControlsOverlay),
      );
      state.handleAndroidHardwareKeyEventForTest(
        AndroidHardwareInputBridge.decodeKeyForTesting({
          'keyCode': 51,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 1,
        })!,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      expect(toggles, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
    },
  );
}
