import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_capsule_menu.dart';
import 'package:video_player_app/features/podcasts/podcast_menu.dart';
import 'package:video_player_app/widgets/anchored_menu_layout.dart';
import 'package:video_player_app/widgets/bilibili_filter_picker.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

const _triggerKey = ValueKey('menu-trigger');
const _labels = ['操作一', '操作二', '操作三'];

Widget _trigger(String kind, ValueChanged<String> select, {int count = 3}) {
  final labels = List.generate(
    count,
    (i) => i < 3 ? _labels[i] : '操作 ${i + 1}',
  );
  return switch (kind) {
    'popup' => CapsulePopupMenuButton<String>(
      key: _triggerKey,
      tooltip: '更多操作',
      itemBuilder: (_) => [
        for (final label in labels)
          PopupMenuItem(value: label, child: Text(label)),
      ],
      onSelected: select,
    ),
    'dropdown' => CapsuleDropdownButton<String>(
      key: _triggerKey,
      value: labels.first,
      items: [
        for (final label in labels)
          DropdownMenuItem(value: label, child: Text(label)),
      ],
      onChanged: (value) => select(value!),
    ),
    'podcast' || 'podcast-compact' => PodcastMenuButton(
      key: _triggerKey,
      title: '频道操作',
      compact: kind == 'podcast-compact',
      actions: [
        for (final label in labels)
          PodcastMenuAction(label, label, Icons.edit_outlined),
      ],
      onSelected: select,
    ),
    'ai' => AiCapsuleIconMenu<String>(
      key: _triggerKey,
      tooltip: '更多操作',
      icon: Icons.more_horiz,
      items: () => [
        for (final label in labels) AiCapsuleChoice(value: label, label: label),
      ],
      onSelected: select,
    ),
    _ => BilibiliFilterButton(
      key: _triggerKey,
      label: '筛选',
      tooltip: '更多操作',
      onPressed: (anchor) async {
        final value = await showBilibiliFilterPicker<String>(
          context: anchor,
          anchorContext: anchor,
          title: '筛选',
          selected: labels.first,
          values: labels,
          labelOf: (value) => value,
        );
        if (value != null) select(value);
      },
    ),
  };
}

Finder _panel() => find
    .descendant(
      of: find.byType(AnchoredMenuLayout),
      matching: find.byType(Material),
    )
    .first;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final kind in [
    'popup',
    'dropdown',
    'podcast',
    'podcast-compact',
    'ai',
    'filter',
  ]) {
    for (final size in [
      const Size(320, 568),
      const Size(390, 844),
      const Size(844, 390),
      const Size(768, 1024),
      const Size(1024, 768),
      const Size(1440, 900),
    ]) {
      for (final bottom in [false, true]) {
        testWidgets('$kind follows its trigger at $size, bottom=$bottom', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          String? selected;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Align(
                    alignment: bottom
                        ? Alignment.bottomLeft
                        : Alignment.topRight,
                    child: _trigger(kind, (value) => selected = value),
                  ),
                ),
              ),
            ),
          );
          final trigger = tester.getRect(find.byKey(_triggerKey));
          await tester.tap(find.byKey(_triggerKey));
          await tester.pumpAndSettle();
          final menu = tester.getRect(_panel());
          if (bottom) {
            expect(menu.bottom, closeTo(trigger.top - 6, .01));
          } else {
            expect(menu.top, closeTo(trigger.bottom + 6, .01));
          }
          expect(menu.overlaps(trigger), isFalse);
          expect(menu.left, greaterThanOrEqualTo(8));
          expect(menu.right, lessThanOrEqualTo(size.width - 8));
          expect(menu.top, greaterThanOrEqualTo(8));
          expect(menu.bottom, lessThanOrEqualTo(size.height - 8));
          await tester.tap(find.text(_labels.last));
          await tester.pumpAndSettle();
          expect(selected, _labels.last);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets(
      '$kind follows resize inside a nested navigator and avoids the IME',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 768);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final nested = GlobalKey<NavigatorState>();
        String? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  const SizedBox(width: 80),
                  Expanded(
                    child: Navigator(
                      key: nested,
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          body: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Align(
                              alignment: Alignment.topRight,
                              child: _trigger(
                                kind,
                                (value) => selected = value,
                                count: 24,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(_triggerKey));
        await tester.pumpAndSettle();
        for (final size in [const Size(390, 844), const Size(844, 390)]) {
          tester.view.physicalSize = size;
          tester.view.viewInsets = const FakeViewPadding(bottom: 100);
          await tester.pumpAndSettle();
          final menu = tester.getRect(_panel());
          // The trigger remains laid out in the covered nested route.
          final trigger = tester.getRect(
            find.byKey(_triggerKey, skipOffstage: false),
          );
          expect(menu.top, closeTo(trigger.bottom + 6, .01));
          if (kind == 'filter') {
            expect(
              menu.left,
              closeTo(trigger.left.clamp(8, size.width - menu.width - 8), .01),
            );
          } else {
            expect(
              menu.right,
              closeTo(trigger.right.clamp(menu.width + 8, size.width - 8), .01),
            );
          }
          expect(menu.bottom, lessThanOrEqualTo(size.height - 108));
          expect(menu.overlaps(trigger), isFalse);
          expect(tester.takeException(), isNull);
        }
        await tester.scrollUntilVisible(
          find.text('操作 24'),
          180,
          scrollable: find
              .descendant(
                of: find.byType(AnchoredMenuLayout),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.text('操作 24'));
        await tester.pumpAndSettle();
        expect(selected, '操作 24');
        expect(nested.currentState!.canPop(), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('compact podcast menu dismisses with Escape', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: _trigger('podcast-compact', (_) {}),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(_triggerKey));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AnchoredMenuLayout), findsNothing);
  });
}
