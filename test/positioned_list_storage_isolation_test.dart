import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_message_navigation.dart';
import 'package:video_player_app/features/subtitle_article/article_document.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_engine.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_model.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/subtitle_editor_panel.dart';
import 'package:video_player_app/widgets/landscape_subtitle_editor_sidebar.dart'
    as landscape;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    await SettingsService().init();
  });

  final subtitles = List.generate(
    10,
    (index) => SubtitleItem(
      index: index,
      startTime: Duration(seconds: index * 5),
      endTime: Duration(seconds: index * 5 + 4),
      text: 'Line $index',
    ),
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('$platform 横屏编辑器新挂载的输入行不读取列表位置', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final lines = List.generate(
        120,
        (index) => SubtitleItem(
          index: index,
          startTime: Duration(seconds: index * 5),
          endTime: Duration(seconds: index * 5 + 4),
          text: 'Editable line $index',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: landscape.LandscapeSubtitleEditorSidebar(
              groups: const {'字幕': 'group.srt'},
              activeGroupPath: 'group.srt',
              subtitles: lines,
              currentSubtitleIndex: 0,
              currentPlaybackPosition: Duration.zero,
              onSelectGroupPath: (_) async {},
              onCreateGroup: (_) async {},
              onRenameGroup: (_, _) async {},
              onSubtitlesChanged: (_) async {},
              onSeekTo: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = tester.widget<ScrollablePositionedList>(
        find.byType(ScrollablePositionedList),
      );
      list.itemScrollController!.jumpTo(index: 80);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.text('Editable line 80'), findsOneWidget);
      final editor = find.byKey(
        const PageStorageKey(('subtitle-editor-text-scroll', 400000000)),
      );
      await tester.tap(editor);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<EditableText>(find.byType(EditableText))
            .any(
              (field) =>
                  field.controller.text == 'Editable line 81' &&
                  field.focusNode.hasFocus,
            ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final surface in ['字幕编辑器', '音乐歌词', '连续文章', 'AI 对话']) {
    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      testWidgets('$platform $surface 不会向相邻输入框写入 ItemPosition', (tester) async {
        var showInput = false;
        late StateSetter update;
        final active = ValueNotifier<List<int>>([0]);
        final chat = AiMessageViewportController();
        addTearDown(active.dispose);
        addTearDown(chat.dispose);
        final document = ArticleDocument.fromDisplayTexts(
          generation: 1,
          displayTexts: subtitles.map((item) => item.text).toList(),
        );
        const style = TextStyle(fontSize: 16, height: 1.6);
        final Widget panel = surface == '字幕编辑器'
            ? SubtitleEditorPanel(
                groups: const {'字幕': 'group.srt'},
                activeGroupPath: 'group.srt',
                subtitles: subtitles,
                currentSubtitleIndex: 0,
                currentPlaybackPosition: Duration.zero,
                onSelectGroupPath: (_) async {},
                onCreateGroup: (_) async {},
                onRenameGroup: (_, _) async {},
                onSubtitlesChanged: (_) async {},
                onSeekTo: (_) {},
                onBack: () {},
                isExpanded: false,
                onToggleExpanded: () {},
              )
            : surface == '音乐歌词'
            ? MusicLyricView(
                subtitles: subtitles,
                onSeek: (_) {},
                applyEdgeFade: false,
              )
            : surface == '连续文章'
            ? ContinuousArticleView(
                document: document,
                layout: const ArticleLayoutEngine().layout(
                  document: document,
                  key: const ArticleLayoutKey(
                    documentGeneration: 1,
                    width: 360,
                    style: style,
                    textDirection: TextDirection.ltr,
                    textScaler: TextScaler.noScaling,
                  ),
                ),
                style: style,
                highlightStyle: style.copyWith(color: Colors.blue),
                activeIndices: active,
                itemScrollController: ItemScrollController(),
                itemPositionsListener: ItemPositionsListener.create(),
                onSubtitleTap: (_) {},
                padding: const EdgeInsets.all(20),
              )
            : AiMessageViewport(
                messages: [
                  for (var i = 0; i < 100; i++)
                    AiChatMessage(
                      id: '$i',
                      role: 'user',
                      content: 'Message $i',
                    ),
                ],
                controller: chat,
                itemBuilder: (_, message) => SizedBox(
                  height: 80,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(message.content),
                  ),
                ),
                onNavigate: () {},
                onUserScroll: (_) => false,
              );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return Column(
                    key: const PageStorageKey('shared-player-panel'),
                    children: [
                      Expanded(child: panel),
                      if (showInput)
                        const TextField(
                          key: ValueKey('settings-input'),
                          decoration: InputDecoration(hintText: '数字设置'),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (surface == 'AI 对话') {
          chat.scrollToEnd();
          await tester.pumpAndSettle();
        }
        update(() => showInput = true);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(ErrorWidget), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('settings-input')),
          '30',
        );
        expect(find.text('30'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
