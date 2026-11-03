import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_copy.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_quick_prompts.dart';
import 'package:video_player_app/features/ai_chat/ai_quick_prompts_dialog.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

const _first = AiQuickPrompt(id: 'first', name: '完整学习笔记', text: '第一段\n\n第二段');
const _second = AiQuickPrompt(id: 'second', name: '复习', text: '复习这些内容');
const _nameKey = ValueKey('ai-quick-prompt-name');
const _textKey = ValueKey('ai-quick-prompt-text');
const _saveKey = ValueKey('ai-quick-prompt-save');

class _Conversations extends AiConversationStore {
  _Conversations([this.records = const []]);
  final List<AiConversation> records;
  @override
  Future<List<AiConversation>> load(String videoId) async => records;
  @override
  Future<void> save(AiConversation conversation) async {}
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugAiChatDesktopAutofocus = false;
  });
  tearDown(() => debugAiChatDesktopAutofocus = true);

  Future<AiQuickPromptStore> library([List<AiQuickPrompt>? entries]) async {
    final store = AiQuickPromptStore();
    addTearDown(store.dispose);
    await store.load();
    if (entries != null) await store.replace(entries);
    return store;
  }

  Future<void> open(
    WidgetTester tester,
    WidgetBuilder builder, {
    Size size = const Size(480, 800),
    double textScale = 1,
    ValueNotifier<double>? keyboard,
    GlobalKey? captureKey,
    ThemeData? theme,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: (context, child) {
            Widget viewport(double inset) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                viewInsets: EdgeInsets.only(bottom: inset),
                textScaler: TextScaler.linear(textScale),
              ),
              child: child!,
            );
            return keyboard == null
                ? viewport(0)
                : ValueListenableBuilder<double>(
                    valueListenable: keyboard,
                    builder: (_, value, _) => viewport(value),
                  );
          },
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  useSafeArea: false,
                  barrierDismissible: false,
                  builder: builder,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String id, String action) async {
    final button = find.byKey(ValueKey('ai-quick-prompt-menu-$id'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  test('defaults keep the existing media-specific text and full notes', () {
    for (final noun in ['视频', '音频', '播客']) {
      final media = AiChatMediaCopy(noun);
      expect(AiQuickPromptStore.defaults.first.nameFor(media), media.summarize);
      expect(
        AiQuickPromptStore.defaults.last.textFor(media),
        media.completeNotesPrompt,
      );
    }
  });

  test(
    'long multiline text, names, ordering and an empty library survive reload',
    () async {
      final body = '  开头\n\n${List.filled(1200, '中文 😀 多行正文\n').join()}  ';
      final entry = AiQuickPrompt(id: 'long', name: '自定义名称', text: body);
      final store = await library([_second, entry]);
      final reloaded = AiQuickPromptStore();
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.entries.map((e) => e.id), ['second', 'long']);
      expect(reloaded.entries.last.name, '自定义名称');
      expect(reloaded.entries.last.text, body);
      await store.replace([]);
      expect(
        AiQuickPromptStore.decode(
          (await SharedPreferences.getInstance()).getString(
            AiQuickPromptStore.preferenceKey,
          ),
        ),
        isEmpty,
      );
      await store.restoreDefaults();
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          AiQuickPromptStore.preferenceKey,
        ),
        isFalse,
      );
      expect(store.entries, AiQuickPromptStore.defaults);
    },
  );

  test(
    'late loading and queued writes cannot replace a newer saved library',
    () async {
      final ready = Completer<SharedPreferences>();
      final store = AiQuickPromptStore(preferences: () => ready.future);
      addTearDown(store.dispose);
      final loading = store.load();
      final mutable = [_first];
      final firstSave = store.replace(mutable);
      mutable.clear();
      final secondSave = store.replace([_second, _first]);
      ready.complete(await SharedPreferences.getInstance());
      await Future.wait([loading, firstSave, secondSave]);
      expect(store.entries.map((e) => e.id), ['second', 'first']);
      expect(
        AiQuickPromptStore.decode(
          (await ready.future).getString(AiQuickPromptStore.preferenceKey),
        ).first.id,
        'second',
      );
    },
  );

  test(
    'failed reads preserve raw data and failed writes can be retried',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AiQuickPromptStore.preferenceKey, '{damaged');
      var fail = false;
      final store = AiQuickPromptStore(
        preferences: () async {
          if (fail) throw StateError('模拟保存失败');
          return prefs;
        },
      );
      addTearDown(store.dispose);
      await store.load();
      expect(store.loadError, isNotNull);
      expect(prefs.getString(AiQuickPromptStore.preferenceKey), '{damaged');
      await store.restoreDefaults();
      await store.replace([_first]);
      fail = true;
      await expectLater(store.replace([_second]), throwsStateError);
      expect(store.entries.single.id, 'first');
      fail = false;
      await store.replace([_second]);
      expect(store.entries.single.id, 'second');
      expect(
        () => AiQuickPromptStore.decode(
          jsonEncode({
            'version': 1,
            'entries': [_first.toJson(), _first.toJson()],
          }),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'a synchronous preference failure releases the load for retry',
    () async {
      final prefs = await SharedPreferences.getInstance();
      var fail = true;
      final store = AiQuickPromptStore(
        preferences: () {
          if (fail) throw StateError('偏好存储暂不可用');
          return Future.value(prefs);
        },
      );
      addTearDown(store.dispose);
      await store.load();
      expect(store.loadError, isNotNull);
      expect(store.loading, isFalse);
      fail = false;
      await store.load();
      expect(store.loadError, isNull);
      expect(store.entries, AiQuickPromptStore.defaults);
    },
  );

  testWidgets('create, edit, copy, move, delete and restore are persisted', (
    tester,
  ) async {
    final store = await library([_first, _second]);
    await open(
      tester,
      (_) => AiQuickPromptsDialog(
        store: store,
        media: const AiChatMediaCopy('视频'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('ai-quick-prompt-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(_nameKey), '独立名称');
    await tester.enterText(find.byKey(_textKey), '请详细整理\n\n保留空行和结尾\n');
    await tester.tap(find.byKey(_saveKey));
    await tester.pumpAndSettle();
    final id = store.entries.last.id;
    expect(store.entries.last.text, '请详细整理\n\n保留空行和结尾\n');
    await menu(tester, id, '编辑');
    await tester.enterText(find.byKey(_nameKey), '修改后的名称');
    await tester.tap(find.byKey(_saveKey));
    await tester.pumpAndSettle();
    await menu(tester, id, '上移');
    expect(store.entries[1].id, id);
    await menu(tester, id, '复制为新提示词');
    expect(
      tester.widget<TextFormField>(find.byKey(_textKey)).controller!.text,
      store.entries[1].text,
    );
    await tester.tap(find.byKey(_saveKey));
    await tester.pumpAndSettle();
    final copy = store.entries.last;
    expect(copy.id, isNot(id));
    expect(copy.name, '修改后的名称（副本）');
    await menu(tester, copy.id, '删除');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(store.entries.any((e) => e.id == copy.id), isFalse);
    await tester.ensureVisible(find.text('恢复默认'));
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(store.entries.length, 3);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.entries.length, 3);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认').last);
    await tester.pumpAndSettle();
    expect(store.entries, AiQuickPromptStore.defaults);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dragging a handle saves the new order', (tester) async {
    final store = await library([_first, _second]);
    await open(
      tester,
      (_) => AiQuickPromptsDialog(
        store: store,
        media: const AiChatMediaCopy('视频'),
      ),
    );
    final handle = find.descendant(
      of: find.byKey(const ValueKey('first')),
      matching: find.byWidgetPredicate(
        (widget) => widget is ReorderableDragStartListener,
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 160));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(store.entries.map((e) => e.id), ['second', 'first']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unsaved edits require an explicit discard and failed saves retain input',
    (tester) async {
      var fail = true;
      await open(
        tester,
        (_) => AiQuickPromptEditor(
          initial: _first,
          onSave: (_) async {
            if (fail) throw StateError('模拟失败');
          },
        ),
      );
      await tester.enterText(find.byKey(_textKey), '尚未保存\n新内容');
      await tester.tap(find.byTooltip('关闭编辑提示词'));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_saveKey));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前编辑内容已保留'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(find.byKey(_textKey)).controller!.text,
        '尚未保存\n新内容',
      );
      fail = false;
      await tester.tap(find.byKey(_saveKey));
      await tester.pumpAndSettle();
      expect(find.byType(AiQuickPromptEditor), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Enter inserts a newline, IME composition is respected, Ctrl and Cmd S save',
    (tester) async {
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        var saves = 0;
        await open(
          tester,
          (_) => AiQuickPromptEditor(
            initial: _first,
            onSave: (_) async {
              saves++;
            },
          ),
        );
        await tester.tap(find.byKey(_textKey));
        final controller = tester
            .widget<TextFormField>(find.byKey(_textKey))
            .controller!;
        final oldLength = controller.text.length;
        controller.selection = TextSelection.collapsed(offset: oldLength);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(saves, 0);
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(_textKey),
            matching: find.byType(TextField),
          ),
        );
        expect(field.textInputAction, TextInputAction.newline);
        // The platform text input client inserts the newline; a raw key event
        // alone does not emulate Windows/Android's native text input service.
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: '${_first.text}\n',
            selection: TextSelection.collapsed(offset: oldLength + 1),
          ),
        );
        await tester.pump();
        expect(controller.text, '${_first.text}\n');
        controller.value = controller.value.copyWith(
          composing: const TextRange(start: 0, end: 1),
        );
        await tester.pump();
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
        expect(saves, 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('放弃未保存的修改？'), findsNothing);
        controller.value = controller.value.copyWith(
          composing: TextRange.empty,
        );
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
        expect(saves, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'mobile, landscape, narrow and enlarged text layouts keep editors usable',
    (tester) async {
      final keyboard = ValueNotifier<double>(0);
      addTearDown(keyboard.dispose);
      for (final (size, scale, inset) in <(Size, double, double)>[
        (const Size(240, 640), 1, 260),
        (const Size(390, 844), 1, 340),
        (const Size(844, 390), 1, 180),
        (const Size(320, 600), 2, 260),
        (const Size(180, 480), 2, 150),
        (const Size(1280, 900), 1, 0),
      ]) {
        final store = await library([_first, _second]);
        keyboard.value = 0;
        await open(
          tester,
          (_) => AiQuickPromptsDialog(
            store: store,
            media: const AiChatMediaCopy('音频'),
          ),
          size: size,
          textScale: scale,
          keyboard: keyboard,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'manager $size scale $scale',
        );
        await tester.tap(find.byKey(const ValueKey('ai-quick-prompt-add')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(_nameKey), '自定义');
        final longText = List.filled(200, '段落\n换行 😀\n\n').join();
        await tester.enterText(find.byKey(_textKey), longText);
        keyboard.value = inset;
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'editor $size scale $scale',
        );
        final save = find.byKey(_saveKey);
        expect(
          tester.getRect(save).bottom,
          lessThanOrEqualTo(size.height - inset),
        );
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(store.entries.last.text, longText);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'window and keyboard changes retain the draft and text selection',
    (tester) async {
      final keyboard = ValueNotifier<double>(0);
      addTearDown(keyboard.dispose);
      await open(
        tester,
        (_) => AiQuickPromptEditor(initial: _first, onSave: (_) async {}),
        size: const Size(1100, 850),
        keyboard: keyboard,
      );
      final controller = tester
          .widget<TextFormField>(find.byKey(_textKey))
          .controller!;
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 3,
      );
      await tester.binding.setSurfaceSize(const Size(320, 600));
      keyboard.value = 250;
      await tester.pumpAndSettle();
      expect(controller.text, _first.text);
      expect(
        controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 3),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saving waits for storage, blocks duplicate saves and prevents accidental exit',
    (tester) async {
      final saving = Completer<void>();
      var calls = 0;
      await open(
        tester,
        (_) => AiQuickPromptEditor(
          initial: _first,
          onSave: (_) {
            calls++;
            return saving.future;
          },
        ),
      );
      await tester.tap(find.byKey(_saveKey));
      await tester.pump();
      expect(find.text('保存中…'), findsOneWidget);
      final editorContext = tester.element(find.byType(AiQuickPromptEditor));
      await Navigator.of(editorContext).maybePop();
      await tester.pump();
      expect(find.byType(AiQuickPromptEditor), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(_saveKey)).onPressed,
        isNull,
      );
      saving.complete();
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byType(AiQuickPromptEditor), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'system back protects changes and explicit discard closes the editor',
    (tester) async {
      await open(
        tester,
        (_) => AiQuickPromptEditor(initial: _first, onSave: (_) async {}),
      );
      await tester.enterText(find.byKey(_nameKey), '修改了名称');
      await Navigator.of(
        tester.element(find.byType(AiQuickPromptEditor)),
      ).maybePop();
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(AiQuickPromptEditor), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'prompt management is available in the menu of an existing conversation',
    (tester) async {
      final store = await library([_first]);
      final video = VideoItem(
        id: 'history-video',
        path: 'history.mp4',
        title: '已开始的对话',
        durationMs: 60000,
        lastUpdated: 1,
      );
      final controller = AiChatController(
        video: video,
        contextLoader: _Loader(),
        conversationStore: _Conversations([
          AiConversation(
            id: 'history',
            videoId: video.id,
            title: '已有对话',
            messages: [
              AiChatMessage(id: 'message', role: 'user', content: '已经有聊天记录'),
            ],
          ),
        ]),
        initialSettings: const AiChatSettings(titlePrompt: ''),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiChatPanel(
              videoItem: video,
              controller: controller,
              quickPromptStore: store,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ai-quick-prompts-manage')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('更多对话操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('管理提示词'));
      await tester.pumpAndSettle();
      expect(find.byType(AiQuickPromptsDialog), findsOneWidget);
      expect(find.text(_first.name), findsOneWidget);
      expect(controller.active!.messages.single.content, '已经有聊天记录');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'editing from a panel updates every open media panel and inserts the full draft',
    (tester) async {
      final store = await library();
      final controllers = <AiChatController>[];
      for (final type in [MediaType.video, MediaType.audio]) {
        final video = VideoItem(
          id: type.name,
          path: '${type.name}.mp4',
          title: type.name,
          type: type,
          durationMs: 60000,
          lastUpdated: 1,
        );
        final controller = AiChatController(
          video: video,
          contextLoader: _Loader(),
          conversationStore: _Conversations(),
          initialSettings: const AiChatSettings(titlePrompt: ''),
        );
        await controller.initialize();
        controllers.add(controller);
        addTearDown(controller.dispose);
      }
      await tester.binding.setSurfaceSize(const Size(1100, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                for (final controller in controllers)
                  Expanded(
                    child: AiChatPanel(
                      videoItem: controller.video,
                      controller: controller,
                      quickPromptStore: store,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ai-quick-prompts-manage')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-quick-prompt-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(_nameKey), '全局学习');
      await tester.enterText(find.byKey(_textKey), '整理{{媒体}}\n\n请保留段落和结尾\n');
      await tester.tap(find.byKey(_saveKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭管理提示词'));
      await tester.pumpAndSettle();
      expect(find.text('全局学习'), findsNWidgets(2));
      await tester.tap(find.text('全局学习').last);
      await tester.pumpAndSettle();
      final draft = tester.widget<TextField>(
        find.byKey(const ValueKey('ai-chat-input')).last,
      );
      expect(draft.controller!.text, '整理音频\n\n请保留段落和结尾\n');
      expect(draft.focusNode!.hasFocus, isFalse);
      expect(controllers.last.active?.messages ?? [], isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'prompt library and editor visual previews',
    (tester) async {
      await tester.runAsync(() async {
        for (final entry in {
          'QuickPromptPreview': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons':
              'D:/FlutterSDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          final bytes = await File(entry.value).readAsBytes();
          await (FontLoader(
            entry.key,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
      });
      final theme = ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: 'QuickPromptPreview',
      );
      final captureKey = GlobalKey();
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final target = File('.artifacts/ai-quick-prompts/$name.png');
          await target.parent.create(recursive: true);
          await target.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      final store = await library([
        ...AiQuickPromptStore.defaults,
        const AiQuickPrompt(
          id: 'custom',
          name: '论文阅读与复习卡片',
          text: '请从资料中提取研究问题、方法与结论，并整理可供复习的问答卡片。',
        ),
      ]);
      await open(
        tester,
        (_) => AiQuickPromptsDialog(
          store: store,
          media: const AiChatMediaCopy('视频'),
        ),
        size: const Size(1280, 900),
        captureKey: captureKey,
        theme: theme,
      );
      await capture('library-desktop');
      await menu(tester, 'notes', '编辑');
      await capture('editor-desktop');
      await tester.pumpWidget(const SizedBox.shrink());
      await open(
        tester,
        (_) => AiQuickPromptsDialog(
          store: store,
          media: const AiChatMediaCopy('播客'),
        ),
        size: const Size(390, 844),
        captureKey: captureKey,
        theme: theme,
      );
      await capture('library-mobile');
      await tester.tap(
        find.text(
          AiQuickPromptStore.defaults.last.nameFor(const AiChatMediaCopy('播客')),
        ),
      );
      await tester.pumpAndSettle();
      await capture('editor-mobile');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: Platform.environment['AI_QUICK_PROMPTS_PREVIEW'] != 'true',
  );
}
