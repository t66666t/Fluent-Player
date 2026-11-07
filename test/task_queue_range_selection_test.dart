import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';

BatchSubtitleTaskView _task(int i) => BatchSubtitleTaskView(
  mediaKey: 'task-$i',
  videoPath: 'local-$i.mp4',
  videoName: 'Local lesson $i',
  videoDuration: '12:30',
  isExternal: true,
  status: TranscriptionStatus.idle,
  progress: 0,
  createdAt: i,
);

Set<String> _keys(int from, int to) => {
  for (var i = from; i <= to; i++) 'task-$i',
};

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.count = 12, this.selected = const {}});
  final int count;
  final Set<String> selected;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final tasks = List.generate(widget.count, _task);
  late var selected = Set<String>.of(widget.selected);
  final expiring = <String, bool>{};
  int actions = 0, reorders = 0;
  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TaskQueueTable(
      tasks: tasks,
      selectedKeys: selected,
      autoDeletedKeys: expiring,
      onSelectionChanged: (keys) => setState(() => selected = keys),
      onStart: (_) => actions++,
      onRetry: (_) => actions++,
      onRestart: (_) => actions++,
      onDelete: (_) => actions++,
      onTapCompleted: (_) => actions++,
      onReorder: (_, _) => reorders++,
    ),
  );
}

void main() {
  Future<_HarnessState> pump(
    WidgetTester tester, {
    double width = 360,
    double height = 900,
    int count = 12,
    double scale = 1,
    Set<String> selected = const {},
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: _Harness(key: key, count: count, selected: selected),
      ),
    );
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  Offset checkbox(WidgetTester tester, int index) =>
      tester.getCenter(find.byKey(ValueKey('task-select-task-$index')));

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('$kind checkbox click toggles once without a hold', (
      tester,
    ) async {
      final state = await pump(tester);
      await tester.tapAt(checkbox(tester, 0), kind: kind);
      await tester.pumpAndSettle();
      expect(state.selected, {'task-0'});
      await tester.tapAt(checkbox(tester, 0), kind: kind);
      await tester.pumpAndSettle();
      expect(state.selected, isEmpty);
      expect(state.actions, 0);
      expect(state.reorders, 0);
      expect(tester.takeException(), isNull);
    });

    for (final width in [320.0, 768.0, 1280.0]) {
      testWidgets(
        '$kind $width selects a range, shrinks and deselects without reordering',
        (tester) async {
          final state = await pump(
            tester,
            width: width,
            selected: {'task-1', 'task-8'},
          );
          final gesture = await tester.startGesture(
            checkbox(tester, 2),
            kind: kind,
          );
          await tester.pump();
          expect(state.selected, {'task-1', 'task-2', 'task-8'});
          await gesture.moveTo(checkbox(tester, 5) + const Offset(130, 0));
          await tester.pump();
          expect(state.selected, {..._keys(1, 5), 'task-8'});
          await gesture.moveTo(checkbox(tester, 3));
          await tester.pump();
          expect(state.selected, {'task-1', 'task-2', 'task-3', 'task-8'});
          await gesture.moveTo(checkbox(tester, 0));
          await tester.pump();
          expect(state.selected, {..._keys(0, 2), 'task-8'});
          await gesture.moveTo(checkbox(tester, 4));
          await tester.pump();
          await gesture.up();
          await tester.pumpAndSettle();
          expect(state.selected, {..._keys(1, 4), 'task-8'});

          final deselect = await tester.startGesture(
            checkbox(tester, 2),
            kind: kind,
          );
          await tester.pump();
          await deselect.moveTo(checkbox(tester, 4));
          await tester.pump();
          expect(state.selected, {'task-1', 'task-8'});
          await deselect.moveTo(checkbox(tester, 3));
          await tester.pump();
          expect(state.selected, {'task-1', 'task-4', 'task-8'});
          await deselect.up();
          await tester.pumpAndSettle();
          expect(state.reorders, 0);
          expect(state.actions, 0);
          expect(
            state.tasks.map((t) => t.mediaKey),
            List.generate(12, (i) => 'task-$i'),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final width in [360.0, 1280.0]) {
      testWidgets(
        '$kind $width edge scroll survives recycled start row and stops on release',
        (tester) async {
          final state = await pump(
            tester,
            width: width,
            height: 500,
            count: 200,
          );
          final list = tester.widget<ReorderableListView>(
            find.byType(ReorderableListView),
          );
          final bounds = tester.getRect(find.byType(ReorderableListView));
          final gesture = await tester.startGesture(
            checkbox(tester, 0),
            kind: kind,
          );
          await tester.pump();
          await gesture.moveTo(Offset(20, bounds.bottom + 4000));
          await tester.pump();
          expect(state.selected.length, lessThan(20));
          for (var i = 0; i < 80; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(list.scrollController!.offset, greaterThan(1000));
          expect(
            find.byKey(const ValueKey('task-select-task-0')),
            findsNothing,
          );
          expect(state.selected.length, greaterThan(20));
          expect(state.selected.length, lessThan(100));
          final lastSelected = state.selected
              .map((id) => int.parse(id.substring(5)))
              .reduce((a, b) => a > b ? a : b);
          expect(state.selected, _keys(0, lastSelected));

          await gesture.moveTo(Offset(20, bounds.center.dy));
          await tester.pump();
          final stopped = list.scrollController!.offset;
          await tester.pump(const Duration(milliseconds: 200));
          expect(list.scrollController!.offset, stopped);
          await gesture.moveTo(Offset(20, bounds.top - 4000));
          for (var i = 0; i < 85; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(list.scrollController!.offset, 0);
          expect(state.selected, {'task-0'});
          await gesture.up();
          await tester.pumpAndSettle();
          final released = list.scrollController!.offset;
          await tester.pump(const Duration(milliseconds: 200));
          expect(list.scrollController!.offset, released);
          expect(state.reorders, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('$kind cancellation stops edge scroll after source unmounts', (
      tester,
    ) async {
      final state = await pump(tester, height: 500, count: 100);
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      final bounds = tester.getRect(find.byType(ReorderableListView));
      final gesture = await tester.startGesture(
        checkbox(tester, 0),
        kind: kind,
      );
      await gesture.moveTo(Offset(20, bounds.bottom + 30));
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.cancel();
      await tester.pumpAndSettle();
      final offset = list.scrollController!.offset;
      final selection = Set.of(state.selected);
      await tester.pump(const Duration(milliseconds: 300));
      expect(list.scrollController!.offset, offset);
      expect(state.selected, selection);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('descending and variable-height rows use displayed geometry', (
    tester,
  ) async {
    final state = await pump(
      tester,
      width: 1280,
      height: 1200,
      scale: 2,
      count: 10,
    );
    state.update(() {
      state.tasks[6] = state.tasks[6].copyWith(
        status: TranscriptionStatus.error,
        statusMessage:
            'SocketException: a long failure detail for a variable height row',
      );
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-queue-display-order')));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(checkbox(tester, 8));
    await tester.pump();
    await gesture.moveTo(checkbox(tester, 5));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.selected, _keys(5, 8));
    expect(state.reorders, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expiring rows are skipped and queue changes cancel the held range',
    (tester) async {
      final state = await pump(tester, count: 100, height: 500);
      state.update(() => state.expiring['task-2'] = true);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(checkbox(tester, 0));
      await tester.pump();
      await gesture.moveTo(checkbox(tester, 4));
      await tester.pump();
      expect(state.selected, {'task-0', 'task-1', 'task-3', 'task-4'});
      await gesture.moveTo(const Offset(20, 600));
      await tester.pump(const Duration(milliseconds: 32));
      state.update(() {
        state.tasks.removeAt(0);
        state.selected.remove('task-0');
      });
      await tester.pumpAndSettle();
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      final offset = list.scrollController!.offset;
      final selection = Set.of(state.selected);
      await tester.pump(const Duration(milliseconds: 300));
      expect(list.scrollController!.offset, offset);
      expect(state.selected, selection);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a second finger and secondary mouse button cannot hijack a range',
    (tester) async {
      final state = await pump(tester);
      final gesture = await tester.startGesture(
        checkbox(tester, 0),
        pointer: 10,
      );
      await tester.pump();
      final second = await tester.startGesture(
        checkbox(tester, 4),
        pointer: 11,
      );
      await second.up();
      await tester.pump();
      await gesture.moveTo(checkbox(tester, 3));
      await tester.pump();
      expect(state.selected, _keys(0, 3));
      await gesture.up();
      final right = await tester.startGesture(
        checkbox(tester, 5),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.moveTo(checkbox(tester, 7));
      await right.up();
      await tester.pumpAndSettle();
      expect(state.selected, _keys(0, 3));
      expect(state.reorders, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'external cancellation and app inactivity stop a held selection',
    (tester) async {
      final state = await pump(tester, count: 100, height: 500);
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      final gesture = await tester.startGesture(checkbox(tester, 0));
      await tester.pump();
      await gesture.moveTo(checkbox(tester, 4));
      await tester.pump();
      state.update(() => state.selected = {});
      await tester.pump();
      await gesture.moveTo(const Offset(20, 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.selected, isEmpty);
      expect(list.scrollController!.offset, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      final active = await tester.startGesture(checkbox(tester, 0));
      await active.moveTo(const Offset(20, 600));
      await tester.pump(const Duration(milliseconds: 32));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      final offset = list.scrollController!.offset;
      final selection = Set.of(state.selected);
      await tester.pump(const Duration(milliseconds: 300));
      expect(list.scrollController!.offset, offset);
      expect(state.selected, selection);
      await active.up();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resuming without the old pointer-up accepts a new range', (
    tester,
  ) async {
    final state = await pump(tester, count: 100, height: 500);
    final lost = await tester.startGesture(checkbox(tester, 0), pointer: 30);
    await lost.moveTo(const Offset(20, 600));
    await tester.pump(const Duration(milliseconds: 32));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.scrollController!.jumpTo(0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(state.selected, contains('task-0'));
    final next = await tester.startGesture(checkbox(tester, 0), pointer: 31);
    await tester.pump();
    expect(state.selected, isNot(contains('task-0')));
    await next.moveTo(checkbox(tester, 3));
    await tester.pump();
    expect(state.selected.intersection(_keys(0, 3)), isEmpty);
    await next.up();
    await lost.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing a held edge selection leaves no scrolling timer', (
    tester,
  ) async {
    await pump(tester, height: 500, count: 100);
    final gesture = await tester.startGesture(checkbox(tester, 0));
    await gesture.moveTo(const Offset(20, 600));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    expect(tester.takeException(), isNull);
  });
}
