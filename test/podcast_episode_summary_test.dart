import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_episode_summary.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';

void main() {
  testWidgets(
    'fold measurement updates after width, scale and content changes',
    (tester) async {
      var width = 220.0;
      var scale = 1.0;
      var text = 'abcde ' * 20;
      Widget app() => MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: PodcastEpisodeSummary(text: text),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      expect(find.text('展开'), findsOneWidget);
      width = 600;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('展开'), findsNothing);
      scale = 2;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('展开'), findsOneWidget);
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      text = '新的简介';
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsNothing);
      expect(tester.widget<Text>(find.text(text)).maxLines, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (scale, reducedMotion) in [
    (1.0, false),
    (1.7, false),
    (1.0, true),
  ]) {
    testWidgets(
      'summary text opens the row and only the toggle expands at scale $scale, reduced motion $reducedMotion',
      (tester) async {
        var played = 0;
        final description = List.filled(12, '一段完整的节目介绍。').join();
        await tester.pumpWidget(
          MaterialApp(
            theme: appInteractionTheme(ThemeData.dark()),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: reducedMotion,
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 280,
                    child: Material(
                      child: InkWell(
                        onTap: () => played++,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PodcastEpisodeSummary(
                              key: const Key('first'),
                              text: description,
                            ),
                            PodcastEpisodeSummary(
                              key: const Key('second'),
                              text: description,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final first = find.byKey(const Key('first'));
        final initial = tester.getSize(first);
        await tester.tap(
          find.descendant(of: first, matching: find.text(description)),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(first), initial);
        expect(played, 1);
        await tester.tap(find.descendant(of: first, matching: find.text('展开')));
        await tester.pumpAndSettle();
        expect(tester.getSize(first).height, greaterThan(initial.height));
        expect(
          find.descendant(
            of: find.byKey(const Key('second')),
            matching: find.text('展开'),
          ),
          findsOneWidget,
        );
        expect(played, 1);
        final text = tester.widget<Text>(
          find.descendant(of: first, matching: find.text(description)),
        );
        expect(text.maxLines, isNull);
        await tester.tap(find.descendant(of: first, matching: find.text('收起')));
        await tester.pumpAndSettle();
        expect(tester.getSize(first), initial);
        expect(played, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final lines in [1, 2, 3, 4]) {
    testWidgets('only summaries exceeding three lines fold: $lines lines', (
      tester,
    ) async {
      final description = List.filled(lines, '简介').join('\n');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: PodcastEpisodeSummary(text: description),
            ),
          ),
        ),
      );
      final text = tester.widget<Text>(find.text(description));
      if (lines <= 3) {
        expect(find.text('展开'), findsNothing);
        expect(text.maxLines, isNull);
        expect(text.overflow, TextOverflow.visible);
      } else {
        expect(find.text('展开'), findsOneWidget);
        expect(text.maxLines, 3);
        await tester.tap(find.text('展开'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(find.text(description)).maxLines, isNull);
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(find.text(description)).maxLines, 3);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'short summaries need no toggle and selection taps reach the row',
    (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: Material(
                child: InkWell(
                  onTap: () => selected++,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const PodcastEpisodeSummary(text: '简短介绍'),
                      PodcastEpisodeSummary(
                        text: List.filled(10, '很长的简介').join(),
                        enabled: false,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('展开'), findsNothing);
      await tester.tap(find.byType(PodcastEpisodeSummary).last);
      expect(selected, 1);
    },
  );
}
