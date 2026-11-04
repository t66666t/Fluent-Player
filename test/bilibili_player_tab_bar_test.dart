import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/widgets/bilibili_portrait_tabs.dart';

void main() {
  for (final landscape in [false, true]) {
    testWidgets(
      'tab hover explains shortcuts for selected and inactive labels; '
      'landscape=$landscape',
      (tester) async {
        var tab = PortraitBilibiliTab.details;
        var closed = 0;
        final prefix = landscape ? 'bilibili-landscape' : 'bilibili-portrait';
        final label = landscape ? '哔哩哔哩' : '详情';
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 320,
                  child: StatefulBuilder(
                    builder: (context, update) {
                      return BilibiliPortraitTabBar(
                        tab: tab,
                        detailsLabel: label,
                        keyPrefix: prefix,
                        onSelect: (value) => update(() => tab = value),
                        onClose: landscape ? () => closed++ : null,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );

        final details = find.byKey(ValueKey('$prefix-tab-details'));
        final subtitles = find.byKey(ValueKey('$prefix-tab-subtitles'));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(600, 400));
        addTearDown(mouse.removePointer);
        Future<void> hover(Finder label) async {
          await mouse.moveTo(tester.getCenter(label));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pumpAndSettle();
        }

        await hover(details);
        expect(find.text('切换到$label (Alt+←)'), findsOneWidget);
        expect(tab, PortraitBilibiliTab.details);
        await hover(subtitles);
        expect(find.text('切换到字幕 (Alt+→)'), findsOneWidget);
        await tester.tap(subtitles);
        await tester.pumpAndSettle();
        expect(tab, PortraitBilibiliTab.subtitles);
        if (landscape) {
          expect(
            tester.getCenter(find.text(label)).dy,
            tester.getCenter(find.byIcon(Icons.close)).dy,
          );
          await tester.tap(find.byKey(ValueKey('$prefix-close')));
          expect(closed, 1);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
