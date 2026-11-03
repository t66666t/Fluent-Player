import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_layout.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_typography.dart';
import 'package:video_player_app/features/ai_chat/ai_settings_dialog.dart';

final _previewDirectory = Platform.environment['AI_CHAT_COMPACT_PREVIEW_DIR'];

Future<void> _fonts(WidgetTester tester) async {
  if (_previewDirectory == null) return;
  await tester.runAsync(() async {
    for (final entry in {
      'AiCompactPreview': 'C:/Windows/Fonts/msyh.ttc',
      'App Reading': 'C:/Windows/Fonts/msyh.ttc',
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
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_previewDirectory == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final picture = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    final output = File('$_previewDirectory/$name.png');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}

ThemeData _theme() => ThemeData(
  fontFamily: _previewDirectory == null ? null : 'AiCompactPreview',
  brightness: Brightness.dark,
);

class _ContextLoader extends AiVideoContextLoader {
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async =>
      AiVideoContext(videoId: video.id, title: video.title, tracks: const []);
}

class _ConversationStore extends AiConversationStore {
  _ConversationStore(this.record);
  AiConversation record;

  @override
  Future<List<AiConversation>> load(String videoId) async => [record];

  @override
  Future<void> save(AiConversation conversation) async => record = conversation;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('common API settings fit small phones without scrolling', (
    tester,
  ) async {
    await _fonts(tester);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final size in [const Size(320, 640), const Size(360, 720)]) {
      tester.view.physicalSize = size;
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          const AiSettingsDialog(settings: AiChatSettings()),
                    ),
                    child: const Text('打开设置'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'settings-${size.width.toInt()}');
      final formScroll = find
          .descendant(
            of: find.byType(Form),
            matching: find.byType(SingleChildScrollView),
          )
          .first;
      final scrollable = find
          .descendant(of: formScroll, matching: find.byType(Scrollable))
          .first;
      expect(
        tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
        lessThanOrEqualTo(.5),
        reason: '$size should expose all common settings without a scroll',
      );
      expect(find.text('测试连接').hitTestable(), findsOneWidget);
      final surface = tester.getRect(
        find.byKey(const ValueKey('ai-adaptive-dialog-surface')),
      );
      expect(surface.left, greaterThan(0));
      expect(surface.right, lessThan(size.width));
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('short settings dialogs hug their contents on a phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AiAdaptiveDialog(
                  title: const Text('简短设置'),
                  content: const SingleChildScrollView(
                    child: Text('只有少量内容时，不占满整个屏幕。'),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('ai-adaptive-dialog-surface')))
          .height,
      lessThan(200),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'reading opens from the real overflow menu, previews prose and follows resize',
    (tester) async {
      await _fonts(tester);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 720);
      addTearDown(tester.view.reset);
      debugAiChatDesktopAutofocus = false;
      addTearDown(() => debugAiChatDesktopAutofocus = true);
      final settings = AiChatReadingSettings.instance;
      await settings.load();
      settings.value = 1;
      addTearDown(() async => settings.setScale(1));
      final video = VideoItem(
        id: 'compact-preview',
        path: 'preview.mp4',
        durationMs: 120000,
        title: '把观看变成主动学习',
        lastUpdated: 1,
      );
      final controller = AiChatController(
        video: video,
        initialSettings: const AiChatSettings(backend: AiBackend.codex),
        contextLoader: _ContextLoader(),
        conversationStore: _ConversationStore(
          AiConversation(
            id: 'reading-preview',
            videoId: video.id,
            title: video.title,
            messages: [
              AiChatMessage(
                id: 'question',
                role: 'user',
                content: '怎样才能更好地理解和记住视频内容？',
              ),
              AiChatMessage(
                id: 'answer',
                role: 'assistant',
                content:
                    '## 把观看变成主动学习\n\n'
                    '先理解内容，再用自己的话复述。\n\n'
                    '遇到不理解的地方，记下一个具体问题，结合上下文继续思考。'
                    '回到原文检查遗漏，再整理成自己的学习笔记。\n\n'
                    '调整字号时，可以直接对照这段原文查看阅读效果。',
              ),
            ],
          ),
        ),
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(),
            home: Scaffold(
              body: SafeArea(
                child: AiChatPanel(videoItem: video, controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final markdown = find.byType(AiMarkdown).last;
      final fontBefore = AiChatTypography.of(tester.element(markdown)).fontSize;
      final more = find.byTooltip('更多对话操作');
      final anchor = tester.getRect(more);
      expect(find.byTooltip('字体大小'), findsNothing);
      await tester.tap(more);
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'font-menu-portrait');
      await tester.tap(find.text('阅读设置 · 字体大小'));
      await tester.pumpAndSettle();
      final popover = find.byKey(const ValueKey('ai-chat-font-popover'));
      expect(tester.getRect(popover).top, greaterThanOrEqualTo(anchor.bottom));
      expect(tester.getSize(popover).height, lessThan(110));
      expect(find.text('阅读设置 · 字体大小'), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(
        tester
                .widgetList<ModalBarrier>(find.byType(ModalBarrier))
                .last
                .color
                ?.a ??
            0,
        0,
        reason: 'Reading controls must not dim the original conversation',
      );
      await tester.tap(find.byTooltip('放大字体'));
      await tester.pumpAndSettle();
      expect(
        AiChatTypography.of(tester.element(markdown)).fontSize,
        closeTo(fontBefore * 1.05, .001),
      );
      await _capture(tester, capture, 'font-popover-portrait');
      tester.view.physicalSize = const Size(800, 300);
      tester.view.viewInsets = const FakeViewPadding(bottom: 120);
      await tester.pumpAndSettle();
      final resized = tester.getRect(popover);
      expect(resized.left, greaterThanOrEqualTo(8));
      expect(resized.right, lessThanOrEqualTo(792));
      expect(resized.bottom, lessThanOrEqualTo(172));
      await _capture(tester, capture, 'font-popover-landscape-keyboard');
      await tester.tapAt(const Offset(16, 160));
      await tester.pumpAndSettle();
      expect(popover, findsNothing);
      expect(settings.value, closeTo(1.05, .001));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
