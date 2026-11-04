import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_export_dialog.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/video_item.dart';

class _Store extends AiConversationStore {
  _Store(this.record);
  final AiConversation record;
  @override
  Future<List<AiConversation>> load(String videoId) async => [record];
  @override
  Future<void> save(AiConversation conversation) async {}
}

class _Loader extends AiVideoContextLoader {
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    primarySubtitles = const [],
    secondarySubtitles = const [],
    position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async => AiVideoContext(videoId: video.id, title: video.title);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'more-menu copies the whole active conversation without opening options',
    (tester) async {
      debugAiChatDesktopAutofocus = false;
      addTearDown(() => debugAiChatDesktopAutofocus = true);
      await tester.binding.setSurfaceSize(const Size(720, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final video = VideoItem(
        id: 'media',
        path: '/private.mp4',
        title: '课程',
        durationMs: 1000,
        lastUpdated: 0,
      );
      final record = AiConversation(
        id: 'c',
        videoId: video.id,
        title: '历史对话',
        messages: [
          AiChatMessage(id: 'q', role: 'user', content: '最初的问题'),
          AiChatMessage(
            id: 'a',
            role: 'assistant',
            content: '最后的回答',
            reasoning: '默认不复制的思考',
          ),
        ],
      );
      final controller = AiChatController(
        video: video,
        conversationStore: _Store(record),
        contextLoader: _Loader(),
        initialSettings: const AiChatSettings(titlePrompt: ''),
      );
      addTearDown(controller.dispose);
      await tester.runAsync(controller.initialize);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiChatPanel(videoItem: video, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多对话操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制完整对话'));
      await tester.pumpAndSettle();
      expect(copied, contains('最初的问题'));
      expect(copied, contains('最后的回答'));
      expect(copied, isNot(contains('默认不复制的思考')));
      expect(find.text('保存文件'), findsNothing);
    },
  );

  testWidgets('export stays usable in narrow windows and desktop preview', (
    tester,
  ) async {
    final capture = GlobalKey();
    final previewPath = Platform.environment['AI_EXPORT_PREVIEW_DIR'];
    if (previewPath != null) {
      await tester.runAsync(() async {
        final loader = FontLoader('ExportPreview')
          ..addFont(
            File(
              r'C:\Windows\Fonts\msyh.ttc',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            File(
              r'D:\FlutterSDK\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await icons.load();
      });
    }
    final video = VideoItem(
      id: 'media',
      path: '/private.mp4',
      title: '课程',
      durationMs: 1000,
      lastUpdated: 0,
    );
    final records = [
      AiConversation(
        id: 'c',
        videoId: video.id,
        title: '课程笔记',
        messages: [AiChatMessage(id: 'q', role: 'user', content: '请总结')],
      ),
      AiConversation(
        id: 'branch',
        videoId: video.id,
        title: '扩展问题',
        parentConversationId: 'c',
        messages: [AiChatMessage(id: 'a', role: 'assistant', content: '扩展回答')],
      ),
    ];
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [const Size(320, 480), const Size(1000, 760)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: previewPath == null ? null : 'ExportPreview',
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAiConversationExportDialog(
                    context,
                    video: video,
                    conversations: records,
                    conversationId: 'c',
                    saveDocument: (_, _) async => true,
                  ),
                  child: const Text('打开导出'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开导出'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('保存文件').hitTestable(), findsOneWidget);
      if (previewPath != null && size.width > 600) {
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(previewPath).create(recursive: true);
          await File(
            '$previewPath/export-dialog.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }
  });
  testWidgets(
    'save failure retains export dialog and allows a successful retry',
    (tester) async {
      final video = VideoItem(
        id: 'media',
        path: '/private.mp4',
        title: '课程',
        durationMs: 1000,
        lastUpdated: 0,
      );
      final records = [
        AiConversation(
          id: 'c',
          videoId: video.id,
          title: '我的对话',
          messages: [
            AiChatMessage(id: 'q', role: 'user', content: '第一轮'),
            AiChatMessage(
              id: 'a',
              role: 'assistant',
              content: '最终回复',
              reasoning: '思考文本',
            ),
          ],
        ),
      ];
      var attempts = 0;
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAiConversationExportDialog(
                  context,
                  video: video,
                  conversations: records,
                  conversationId: 'c',
                  saveDocument: (name, contents) async {
                    attempts++;
                    expect(name, endsWith('.md'));
                    if (attempts == 1) throw Exception('disk unavailable');
                    saved = contents;
                    return true;
                  },
                ),
                child: const Text('导出'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('导出'));
      await tester.pumpAndSettle();
      expect(find.textContaining('全部 2 条消息'), findsOneWidget);
      await tester.tap(find.text('保存文件'));
      await tester.pumpAndSettle();
      expect(find.text('导出未完成，原对话已保留，请重试。'), findsOneWidget);
      await tester.tap(find.text('保存文件'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(saved, contains('第一轮'));
      expect(saved, contains('最终回复'));
      expect(saved, isNot(contains('思考文本')));
      expect(find.text('导出完整对话'), findsNothing);
    },
  );
}
