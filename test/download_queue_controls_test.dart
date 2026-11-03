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
          addTearDown(tester.view.reset);
          var starts = 0;
          var removes = 0;
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Column(
                  children: [
                    DownloadQueueToolbar(
                      selectionLabel: '已选 12 项',
                      allSelected: true,
                      onSelectAll: () {},
                      primary: DownloadQueueAction(
                        label: '开始所选 8 项',
                        icon: Icons.download,
                        onPressed: () => starts++,
                      ),
                      secondary: const DownloadQueueAction(
                        label: '暂停所选 4 项',
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
                    const Expanded(child: Text('队列')),
                  ],
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(SingleChildScrollView), findsNothing);
          final start = find.widgetWithText(TextButton, '开始所选 8 项');
          expect(tester.getSize(start).height, greaterThanOrEqualTo(48));
          await tester.tap(start);
          expect(starts, 1);
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
