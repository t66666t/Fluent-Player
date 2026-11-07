import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';

BatchSubtitleTaskView task(int index) => BatchSubtitleTaskView(
  mediaKey: 'task-$index',
  videoPath: '$index.mp4',
  videoName: 'Video $index',
  videoDuration: '01:23',
  isExternal: false,
  status: TranscriptionStatus.idle,
  progress: 0,
  statusMessage: '',
  createdAt: index,
);

void main() {
  for (final platform in TargetPlatform.values) {
    for (final width in [320.0, 768.0, 1280.0]) {
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        testWidgets('$platform $width $kind holds any row area to reorder', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final tasks = List.generate(8, task);
          var clicks = 0;
          var selected = <String>{};
          final moves = <String>[];
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    return TaskQueueTable(
                      tasks: tasks,
                      selectedKeys: selected,
                      onSelectionChanged: (keys) =>
                          setState(() => selected = keys),
                      autoDeletedKeys: const {},
                      onStart: (_) => clicks++,
                      onRetry: (_) => clicks++,
                      onRestart: (_) => clicks++,
                      onDelete: (_) => clicks++,
                      onReorder: (key, index) => setState(() {
                        final old = tasks.indexWhere(
                          (task) => task.mediaKey == key,
                        );
                        tasks.insert(index, tasks.removeAt(old));
                        moves.add('$key:$index');
                      }),
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byIcon(Icons.drag_handle), findsNothing);
          expect(find.byTooltip('任务操作'), findsNothing);

          // Short presses must keep their normal action.
          await tester.tap(find.byTooltip('从头开始').first, kind: kind);
          await tester.tap(find.byTooltip('删除').first, kind: kind);
          await tester.tap(find.byTooltip('开始').first, kind: kind);
          await tester.pumpAndSettle();
          expect(clicks, 3);
          expect(moves, isEmpty);

          // The first hold selects; it must not start a drag or activate an action.
          await tester.longPress(find.text('Video 0'));
          await tester.pumpAndSettle();
          expect(selected, {'task-0'});
          expect(moves, isEmpty);
          expect(clicks, 3);

          // Title, status, action buttons and the row's padded edge all work.
          for (final area in [
            'title',
            'status',
            'start',
            'restart',
            'delete',
            'edge',
          ]) {
            final source = find.byKey(const ValueKey('task-0'));
            final target = find.byKey(ValueKey(tasks[2].mediaKey));
            final row = tester.getRect(source);
            final finder = switch (area) {
              'title' => find.text('Video 0'),
              'status' => find.descendant(
                of: source,
                matching: find.text(width < 720 ? '待开始' : '排队中'),
              ),
              'start' => find.descendant(
                of: source,
                matching: find.byTooltip('开始'),
              ),
              'restart' => find.descendant(
                of: source,
                matching: find.byTooltip('从头开始'),
              ),
              'delete' => find.descendant(
                of: source,
                matching: find.byTooltip('删除'),
              ),
              _ => source,
            };
            final start = area == 'edge'
                ? Offset(row.right - 2, row.center.dy)
                : tester.getCenter(finder);
            final destination = tester.getRect(target);
            final gesture = await tester.createGesture(kind: kind);
            if (kind == PointerDeviceKind.mouse && area == 'title') {
              await gesture.moveTo(start);
              await tester.pump(const Duration(milliseconds: 800));
            }
            await gesture.down(start);
            await tester.pump(const Duration(milliseconds: 150));
            await gesture.moveBy(const Offset(3, 2));
            await tester.pump(const Duration(milliseconds: 220));
            if (area == 'title') {
              await tester.pump(const Duration(seconds: 1));
            }
            final drop = Offset(start.dx, start.dy + destination.top - row.top);
            for (var step = 1; step <= 12; step++) {
              await gesture.moveTo(Offset.lerp(start, drop, step / 12)!);
              await tester.pump(const Duration(milliseconds: 30));
            }
            await tester.pump(const Duration(milliseconds: 300));
            await gesture.up();
            await tester.pumpAndSettle();
            expect(moves.last, 'task-0:2', reason: area);
            expect(clicks, 3, reason: 'a hold on $area must not click');
            expect(tasks[2].mediaKey, 'task-0');
            // Reset through the same state callback using an actual upward drag.
            final moved = tester.getCenter(find.text('Video 0'));
            final top = tester.getRect(
              find.byKey(ValueKey(tasks.first.mediaKey)),
            );
            final up = await tester.startGesture(moved, kind: kind);
            await tester.pump(const Duration(milliseconds: 370));
            await up.moveTo(Offset(moved.dx, top.center.dy));
            await tester.pump(const Duration(milliseconds: 300));
            await up.up();
            await tester.pumpAndSettle();
            expect(tasks.first.mediaKey, 'task-0');
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets(
    'swipe scrolls, cancelled hold does not reorder, edge drag autoscrolls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final moves = <int>[];
      var selected = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => TaskQueueTable(
                tasks: List.generate(40, task),
                selectedKeys: selected,
                onSelectionChanged: (keys) => setState(() => selected = keys),
                autoDeletedKeys: const {},
                onStart: (_) {},
                onRetry: (_) {},
                onRestart: (_) {},
                onDelete: (_) {},
                onReorder: (_, index) => moves.add(index),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      await tester.drag(find.text('Video 3'), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(list.scrollController!.offset, greaterThan(0));
      expect(moves, isEmpty);
      list.scrollController!.jumpTo(0);
      await tester.pumpAndSettle();
      final cancelled = await tester.startGesture(
        tester.getCenter(find.text('Video 0')),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(moves, isEmpty);
      await tester.longPress(find.text('Video 0'));
      await tester.pumpAndSettle();
      expect(selected, {'task-0'});
      final interrupted = await tester.startGesture(
        tester.getCenter(find.text('Video 0')),
      );
      await tester.pump(const Duration(milliseconds: 370));
      await interrupted.moveBy(const Offset(0, 80));
      await tester.pump(const Duration(milliseconds: 50));
      await interrupted.cancel();
      await tester.pumpAndSettle();
      expect(moves, isEmpty);
      expect(tester.takeException(), isNull);
      final drag = await tester.startGesture(
        tester.getCenter(find.text('Video 0')),
      );
      await tester.pump(const Duration(milliseconds: 370));
      await drag.moveTo(const Offset(100, 595));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(list.scrollController!.offset, greaterThan(0));
      await drag.up();
      await tester.pumpAndSettle();
      expect(moves.single, greaterThan(5));
      expect(tester.takeException(), isNull);
    },
  );
}
