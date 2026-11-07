import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/download_queue_controls.dart';

void main() {
  for (final width in [320.0, 390.0, 768.0, 1280.0]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        'queue controls stay usable at $width width and $scale text scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(bottom: 24);
          addTearDown(tester.view.reset);
          var starts = 0;
          var removes = 0;
          var selected = true;
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: StatefulBuilder(
                builder: (context, setState) => Scaffold(
                  body: ListView.builder(
                    controller: scroll,
                    itemCount: 40,
                    itemExtent: 72,
                    itemBuilder: (_, index) => ListTile(
                      key: ValueKey('queue-row-$index'),
                      title: Text('任务 $index'),
                    ),
                  ),
                  bottomNavigationBar: DownloadQueueToolbar(
                    selectionLabel: selected ? '已选 12 项' : '全选当前列表',
                    allSelected: selected,
                    onSelectAll: () => setState(() => selected = !selected),
                    primary: DownloadQueueAction(
                      label: selected ? '开始所选 8 项' : '开始当前列表 128 项',
                      icon: Icons.download,
                      onPressed: () => starts++,
                    ),
                    secondary: DownloadQueueAction(
                      label: selected ? '暂停所选 4 项' : '暂停当前列表 64 项',
                      icon: Icons.pause,
                      onPressed: null,
                    ),
                    more: [
                      DownloadQueueAction(
                        label: '移除所选任务',
                        icon: Icons.delete_outline,
                        onPressed: () => removes++,
                        destructive: true,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(SingleChildScrollView), findsNothing);
          final start = find.widgetWithText(TextButton, '开始所选 8 项');
          expect(tester.getSize(start).height, greaterThanOrEqualTo(48));
          final toolbar = find.byType(DownloadQueueToolbar);
          final bounds = tester.getRect(toolbar);
          expect(bounds.bottom, 900);
          expect(bounds.height, 80);
          await tester.tap(start);
          expect(starts, 1);
          scroll.jumpTo(scroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
          final lastRow = find.byKey(const ValueKey('queue-row-39'));
          final rowBefore = tester.getRect(lastRow);
          final offsetBefore = scroll.offset;
          for (final label in ['已选 12 项', '全选当前列表']) {
            await tester.tap(find.widgetWithText(TextButton, label));
            await tester.pumpAndSettle();
            expect(tester.getRect(toolbar), bounds);
            expect(tester.getRect(lastRow), rowBefore);
            expect(scroll.offset, offsetBefore);
          }
          await tester.tap(find.byTooltip('队列操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('移除所选任务'));
          await tester.pumpAndSettle();
          expect(removes, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
