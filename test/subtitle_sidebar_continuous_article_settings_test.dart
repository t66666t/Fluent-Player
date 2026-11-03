import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'paragraph mode is backward-compatible and included in layout export',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'subtitleArticleSentencesPerParagraph': 9,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();

      expect(settings.subtitleArticleParagraphModeEnabled, isTrue);
      expect(settings.subtitleArticleSentencesPerParagraph, 9);
      final layout =
          settings.exportSettingsSnapshot()['layout'] as Map<String, dynamic>;
      expect(layout['subtitleArticleParagraphModeEnabled'], isTrue);
      expect(layout['subtitleArticleSentencesPerParagraph'], 9);
    },
  );

  testWidgets('continuous mode persists and disables paragraph size editor', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'subtitleViewMode': 1,
      'subtitleArticleParagraphModeEnabled': false,
      'subtitleArticleSentencesPerParagraph': 7,
    });
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/continuous.mp4'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 420,
            child: SubtitleSidebar(
              subtitles: List<SubtitleItem>.generate(
                8,
                (index) => SubtitleItem(
                  index: index + 1,
                  startTime: Duration(seconds: index),
                  endTime: Duration(seconds: index + 1),
                  text: 'sentence $index',
                ),
              ),
              controller: controller,
              isCompact: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('subtitle-continuous-article-view')),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.format_size));
    await tester.pump();
    final switchFinder = find.byKey(
      const ValueKey('subtitle-paragraph-mode-switch'),
    );
    expect(tester.widget<Switch>(switchFinder).value, isFalse);
    expect(
      find.ancestor(
        of: find.byKey(
          const ValueKey('subtitle-sentences-per-paragraph-input'),
        ),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );

    await tester.tap(switchFinder);
    await tester.pump();
    expect(settings.subtitleArticleParagraphModeEnabled, isTrue);
    expect(settings.subtitleArticleSentencesPerParagraph, 7);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('subtitleArticleParagraphModeEnabled'), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });

  testWidgets(
    'turning paragraph mode off responds before a long layout finishes',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'subtitleViewMode': 1,
        'subtitleArticleParagraphModeEnabled': true,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/long-continuous.mp4'),
      );
      final subtitles = List<SubtitleItem>.generate(
        4000,
        (index) => SubtitleItem(
          index: index + 1,
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: 'A reasonably long subtitle sentence number $index.',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 420,
              child: SubtitleSidebar(
                subtitles: subtitles,
                controller: controller,
                isCompact: true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('subtitle-paragraph-mode-control')),
      );
      await tester.pump();

      expect(settings.subtitleArticleParagraphModeEnabled, isFalse);
      expect(
        find.byKey(const ValueKey('subtitle-continuous-article-preparing')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await controller.dispose();
    },
  );

  testWidgets(
    'geometry changes keep the current article instead of the preparing text',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'subtitleViewMode': 1,
        'subtitleArticleParagraphModeEnabled': false,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/article-geometry.mp4'),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.dispose();
        await tester.binding.setSurfaceSize(null);
      });

      const preparingKey = ValueKey<String>(
        'subtitle-continuous-article-preparing',
      );
      const articleKey = ValueKey<String>('subtitle-continuous-article-view');
      final navigatorKey = GlobalKey<NavigatorState>();
      final subtitles = List<SubtitleItem>.generate(
        4000,
        (index) => SubtitleItem(
          index: index + 1,
          startTime: Duration(milliseconds: index * 400),
          endTime: Duration(milliseconds: index * 400 + 300),
          text: 'Sentence $index stays visible while the article is laid out.',
        ),
      );

      Finder preparing({bool skipOffstage = true}) =>
          find.byKey(preparingKey, skipOffstage: skipOffstage);
      Finder article({bool skipOffstage = true}) =>
          find.byKey(articleKey, skipOffstage: skipOffstage);

      void expectArticleStays({bool skipOffstage = true}) {
        expect(preparing(skipOffstage: skipOffstage), findsNothing);
        expect(article(skipOffstage: skipOffstage), findsOneWidget);
      }

      Future<void> show({
        required List<SubtitleItem> items,
        bool isVisible = true,
      }) {
        return tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            home: Builder(
              builder: (context) {
                final Size size = MediaQuery.sizeOf(context);
                return Scaffold(
                  body: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: SubtitleSidebar(
                      key: const ValueKey('continuous-article-sidebar'),
                      subtitles: items,
                      controller: controller,
                      isCompact: true,
                      isPortrait: true,
                      isVisible: isVisible,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }

      Future<void> waitForArticle() async {
        for (var i = 0; i < 400; i++) {
          await tester.pump();
          if (preparing().evaluate().isEmpty &&
              article().evaluate().isNotEmpty) {
            return;
          }
        }
        fail('continuous article did not finish its first layout');
      }

      await tester.binding.setSurfaceSize(const Size(360, 640));
      await show(items: subtitles);
      await waitForArticle();
      expectArticleStays();

      final List<SubtitleItem> sameBody = List<SubtitleItem>.generate(
        subtitles.length,
        (index) => SubtitleItem(
          index: subtitles[index].index,
          startTime: subtitles[index].startTime,
          endTime: subtitles[index].endTime,
          text: subtitles[index].text,
        ),
      );
      await show(items: sameBody);
      await tester.pump();
      expectArticleStays();

      await show(items: sameBody, isVisible: false);
      await tester.pump();
      expectArticleStays();
      await show(items: sameBody, isVisible: true);
      await tester.pump();
      expectArticleStays();

      await tester.binding.setSurfaceSize(const Size(520, 640));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
        expectArticleStays();
      }
      await tester.binding.setSurfaceSize(const Size(360, 640));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
        expectArticleStays();
      }

      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();
      await tester.drag(find.byType(Slider), const Offset(36, 0));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
        expectArticleStays();
      }

      await tester.tap(
        find.byKey(const ValueKey('subtitle-paragraph-mode-control')),
      );
      await tester.pump();
      expect(settings.subtitleArticleParagraphModeEnabled, isTrue);
      expect(article(), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('subtitle-paragraph-mode-control')),
      );
      await tester.pump();
      expect(settings.subtitleArticleParagraphModeEnabled, isFalse);
      expectArticleStays();

      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (context) => const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.binding.setSurfaceSize(const Size(800, 480));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
        expect(preparing(skipOffstage: false), findsNothing);
      }
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.binding.setSurfaceSize(const Size(360, 640));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        expectArticleStays();
      }

      final List<SubtitleItem> edited = List<SubtitleItem>.generate(
        subtitles.length,
        (index) => SubtitleItem(
          index: index + 1,
          startTime: Duration(milliseconds: index * 400),
          endTime: Duration(milliseconds: index * 400 + 300),
          text: 'Rewritten sentence $index.',
        ),
      );
      await show(items: edited);
      await tester.pump();
      expect(preparing(), findsOneWidget);
    },
  );
}
