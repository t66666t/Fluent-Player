import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_chat_sidebar.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  for (final mode in ['list', 'paragraph', 'continuous']) {
    for (final following in [false, true]) {
      for (final playing in [false, true]) {
        testWidgets(
          '$mode return honors following=$following, playing=$playing',
          (tester) async {
            SharedPreferences.setMockInitialValues({
              'autoScrollSubtitles': !following,
              'subtitleViewMode': mode == 'list' ? 0 : 1,
              'subtitleArticleParagraphModeEnabled': mode != 'continuous',
              'subtitleArticleSentencesPerParagraph': 1,
            });
            final settings = SettingsService();
            settings.resetForTest();
            await settings.init();
            final player = VideoPlayerController.networkUrl(
              Uri.parse('https://example.invalid/shared-sidebar.mp4'),
            );
            player.value = VideoPlayerValue(
              duration: const Duration(minutes: 10),
              position: const Duration(seconds: 180),
              isInitialized: true,
              isPlaying: playing,
            );
            final cues = List.generate(
              180,
              (i) => SubtitleItem(
                index: i,
                startTime: Duration(seconds: i * 3),
                endTime: Duration(seconds: i * 3 + 3),
                text: '字幕 $i：这是一段供阅读和讨论的视频文稿。',
              ),
            );
            final subtitleKey = GlobalKey<SubtitleSidebarState>();
            final input = TextEditingController();
            final chatScroll = ScrollController();
            var showChat = false;
            var height = 500.0;
            late StateSetter update;
            void switchTo(bool chat) => update(() => showChat = chat);

            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: StatefulBuilder(
                    builder: (context, setState) {
                      update = setState;
                      return SizedBox(
                        width: 320,
                        height: height,
                        child: SubtitleChatSidebar(
                          showChat: showChat,
                          subtitles: SubtitleSidebar(
                            key: subtitleKey,
                            subtitles: cues,
                            controller: player,
                            isCompact: true,
                            isVisible: !showChat,
                            preserveReadingPositionWhenNotFollowing: true,
                            onOpenAiChat: () => switchTo(true),
                          ),
                          chat: Column(
                            children: [
                              TextButton(
                                onPressed: () => switchTo(false),
                                child: const Text('返回字幕'),
                              ),
                              Expanded(
                                child: ListView.builder(
                                  key: const ValueKey('chat-list'),
                                  controller: chatScroll,
                                  itemCount: 100,
                                  itemBuilder: (_, i) => SizedBox(
                                    height: 60,
                                    child: Text('对话 $i'),
                                  ),
                                ),
                              ),
                              TextField(controller: input),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
            for (var i = 0; i < 20; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(find.byType(TextField), findsNothing); // Chat is lazy.
            final originalState = subtitleKey.currentState;
            final ai = find.byTooltip('AI 对话 (W)');
            expect(
              tester.getTopLeft(ai).dx,
              lessThan(tester.getTopLeft(find.byTooltip('切换列表/文章视图')).dx),
            );
            final list = find.byType(ScrollablePositionedList);
            expect(list, findsOneWidget);
            await tester.drag(list, const Offset(0, -650));
            await tester.pumpAndSettle();
            final positions = tester
                .widget<ScrollablePositionedList>(list)
                .itemPositionsNotifier!;
            ItemPosition anchor() =>
                (positions.itemPositions.value
                        .where(
                          (p) =>
                              p.itemLeadingEdge >= 0 && p.itemLeadingEdge < 1,
                        )
                        .toList()
                      ..sort((a, b) => a.index.compareTo(b.index)))
                    .first;
            final before = anchor();

            await tester.tap(ai);
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField), '保留这段草稿');
            chatScroll.jumpTo(1400);
            await tester.pumpAndSettle();
            update(
              () => height = 260,
            ); // Composer keyboard compresses the surface.
            player.value = player.value.copyWith(
              position: const Duration(seconds: 360),
            );
            await tester.pumpAndSettle();
            // Returning must use the latest switch, even if it changed in chat.
            await settings.updateSetting('autoScrollSubtitles', following);
            update(() => height = 500);
            await tester.pumpAndSettle();
            for (var visit = 0; visit < 3; visit++) {
              await tester.tap(find.text('返回字幕'));
              await tester.pumpAndSettle();
              expect(subtitleKey.currentState, same(originalState));
              if (following) {
                final targetIndex = mode == 'continuous'
                    ? tester
                          .widget<ContinuousArticleView>(
                            find.byType(ContinuousArticleView),
                          )
                          .layout
                          .lineForSentence(120)
                    : 120;
                final current = positions.itemPositions.value.where(
                  (p) => p.index == targetIndex,
                );
                expect(current, hasLength(1));
                expect(current.single.itemLeadingEdge, closeTo(.3, .01));
              } else {
                expect(anchor().index, before.index);
                expect(
                  anchor().itemLeadingEdge,
                  closeTo(before.itemLeadingEdge, .002),
                );
              }
              expect(find.byType(TextField), findsNothing);
              await tester.tap(ai);
              await tester.pumpAndSettle();
              expect(input.text, '保留这段草稿');
              expect(chatScroll.offset, closeTo(1400, .01));
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            input.dispose();
            chatScroll.dispose();
            await player.dispose();
          },
        );
      }
    }
  }
}
