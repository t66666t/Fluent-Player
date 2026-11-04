import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_filter_bar.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';

const labels = {
  'all': '全部',
  'unplayed': '未听',
  'inProgress': '进行中',
  'played': '已听',
  'favorite': '收藏',
  'downloaded': '已下载',
  'hidden': '已隐藏',
};

void main() {
  for (final width in [320.0, 360.0, 390.0, 430.0]) {
    for (final scale in [1.0, 1.7, 2.0]) {
      testWidgets('compact filters fit $width at $scale', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width - 16,
                    child: PodcastFilterBar(
                      compact: true,
                      labels: labels,
                      counts: const {},
                      selected: 'all',
                      onSelected: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rects = [
          for (final id in labels.keys)
            tester.getRect(find.byKey(ValueKey('podcast-filter-$id'))),
        ];
        for (final rect in rects) {
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width - 16));
        }
        if (scale == 1) {
          expect(rects.map((r) => r.top).toSet(), hasLength(1));
          expect(rects.first.height, lessThanOrEqualTo(38));
        } else {
          expect(rects.last.top, greaterThan(rects.first.top));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final scale in [1.0, 1.7, 2.0]) {
    testWidgets('filter geometry stays fixed at text scale $scale', (
      tester,
    ) async {
      var selected = 'all';
      var counts = {for (final id in labels.keys) id: 9};
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: appInteractionTheme(ThemeData.dark()),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      update = setState;
                      return PodcastFilterBar(
                        labels: labels,
                        counts: counts,
                        selected: selected,
                        onSelected: (id) => setState(() => selected = id),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder filter(String id) => find.byKey(ValueKey('podcast-filter-$id'));
      Map<String, Rect> geometry() => {
        for (final id in labels.keys) id: tester.getRect(filter(id)),
      };
      final initial = geometry();
      for (final label in labels.values) {
        final text = tester.widget<Text>(find.text(label));
        expect(text.maxLines, 1);
        expect(text.softWrap, isFalse);
        expect(tester.getSize(find.text(label)).height, lessThan(30 * scale));
      }
      for (final id in labels.keys) {
        update(() => selected = id);
        await tester.pump(const Duration(milliseconds: 90));
        expect(
          geometry(),
          initial,
          reason:
              'Selection must not move any segment, including during animation',
        );
        await tester.pumpAndSettle();
        expect(geometry(), initial);
      }
      update(() => counts = {for (final id in labels.keys) id: 12345});
      await tester.pumpAndSettle();
      expect(
        geometry(),
        initial,
        reason: 'Digit changes must not alter the layout',
      );
      await tester.ensureVisible(filter('hidden'));
      await tester.tap(filter('hidden'));
      await tester.pumpAndSettle();
      expect(selected, 'hidden');
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('已隐藏，12345 集'), findsOneWidget);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    });
  }
}
