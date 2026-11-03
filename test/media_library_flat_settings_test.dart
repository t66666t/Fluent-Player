import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/categorized_settings_page.dart';
import 'package:video_player_app/widgets/experimental_layout_widgets.dart';

void main() {
  testWidgets('expanded settings do not leave gaps in adjacent columns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var expanded = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return CategorizedSettingsPage(
              items: [
                for (var i = 0; i < 6; i++) ...[
                  SettingsCategoryBoundary(
                    ExperimentalSettingsCategory.general,
                    label: '设置$i',
                  ),
                  ConstrainedBox(
                    key: ValueKey('tile-$i'),
                    constraints: BoxConstraints.tightFor(
                      height: i == 2 ? (expanded ? 480 : 260) : 60,
                    ),
                    child: Text('设置$i'),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
    for (final expand in [false, true]) {
      update(() => expanded = expand);
      await tester.pump();
      final first = tester.getRect(find.byKey(const ValueKey('tile-0')));
      final next = tester.getRect(find.byKey(const ValueKey('tile-3')));
      expect(next.left, first.left);
      expect(next.top - first.bottom, 12);
      expect(
        next.top,
        lessThan(
          tester.getBottomRight(find.byKey(const ValueKey('tile-2'))).dy,
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });

  for (final width in [390.0, 1024.0, 1440.0]) {
    testWidgets('all settings retain source order at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: CategorizedSettingsPage(
            items: [
              SettingsCategoryBoundary(
                ExperimentalSettingsCategory.storage,
                label: '优先设置',
              ),
              ListTile(title: Text('优先设置')),
              SettingsCategoryBoundary(
                ExperimentalSettingsCategory.playback,
                label: '第二设置',
              ),
              ListTile(title: Text('第二设置')),
              SettingsCategoryBoundary(
                ExperimentalSettingsCategory.general,
                label: '第三设置',
              ),
              ListTile(title: Text('第三设置')),
            ],
          ),
        ),
      );
      for (final title in ['优先设置', '第二设置', '第三设置']) {
        expect(find.text(title).hitTestable(), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('settings-category-general')),
        findsNothing,
      );
      final first = tester.getTopLeft(find.text('优先设置'));
      final second = tester.getTopLeft(find.text('第二设置'));
      final third = tester.getTopLeft(find.text('第三设置'));
      if (width < 900) {
        expect(first.dy, lessThan(second.dy));
        expect(second.dy, lessThan(third.dy));
      } else {
        expect(first.dy, second.dy);
        expect(first.dx, lessThan(second.dx));
        if (width > 1400) {
          expect(second.dy, third.dy);
          expect(second.dx, lessThan(third.dx));
        } else {
          expect(third.dy, greaterThan(second.dy));
        }
      }
      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        '第二',
      );
      await tester.pumpAndSettle();
      expect(find.text('第二设置'), findsOneWidget);
      expect(find.text('优先设置'), findsNothing);
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(find.text('优先设置'), findsOneWidget);
      expect(find.text('第三设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
