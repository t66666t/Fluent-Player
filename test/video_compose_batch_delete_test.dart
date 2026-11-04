import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/video_compose_manager.dart';

import 'support/compose_queue_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'batch deletion reserves selected jobs and joins the active task unwind',
    () async {
      final store = MemoryComposeStore();
      final cleaner = RecordingComposeCleaner();
      final runner = ControlledComposeOrchestrator();
      final manager = VideoComposeManager(
        taskStore: store,
        artifactCleaner: cleaner,
        orchestrator: runner,
      );
      await manager.ready;
      final first = await enqueueCompose(manager, 'first');
      final second = await enqueueCompose(manager, 'second');
      final third = await enqueueCompose(manager, 'third');
      expect(runner.started, [first.taskId]);
      final deletion = manager.deleteTasksAndFiles([
        first.taskId,
        second.taskId,
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(runner.cancelled, [first.taskId]);
      expect(cleaner.deletions, isEmpty);
      expect(manager.queuedTasks.map((task) => task.taskId), [third.taskId]);
      runner.running[first.taskId]!.complete();
      final result = await deletion;
      expect(result.deletedTaskIds, [first.taskId, second.taskId]);
      expect(result.failedTaskIds, isEmpty);
      expect(runner.started, [first.taskId, third.taskId]);
      expect(manager.allTasks.map((task) => task.taskId), [third.taskId]);
      runner.running[third.taskId]!.complete();
      await Future<void>.delayed(Duration.zero);
      manager.dispose();
    },
  );

  test('clear cancels the whole queue before another task can start', () async {
    final runner = ControlledComposeOrchestrator();
    final cleaner = RecordingComposeCleaner();
    final manager = VideoComposeManager(
      taskStore: MemoryComposeStore(),
      orchestrator: runner,
      artifactCleaner: cleaner,
    );
    await manager.ready;
    final first = await enqueueCompose(manager, 'first');
    final second = await enqueueCompose(manager, 'second');
    final clearing = manager.clearTasksAndFiles(deleteOutput: false);
    await Future<void>.delayed(Duration.zero);
    runner.running[first.taskId]!.complete();
    final result = await clearing;
    expect(
      result.deletedTaskIds,
      unorderedEquals([first.taskId, second.taskId]),
    );
    expect(runner.started, [first.taskId]);
    expect(cleaner.deletions.every((d) => !d.output), isTrue);
    expect(manager.allTasks, isEmpty);
    manager.dispose();
  });

  test(
    'failed file deletion retains its record and does not undo successes',
    () async {
      final store = MemoryComposeStore([
        composeRecord('1'),
        composeRecord('2'),
        composeRecord('3'),
      ]);
      final cleaner = RecordingComposeCleaner()..failedIds.add('2');
      final manager = VideoComposeManager(
        taskStore: store,
        artifactCleaner: cleaner,
      );
      final result = await manager.deleteTasksAndFiles(['1', '2']);
      expect(result.deletedTaskIds, ['1']);
      expect(result.failedTaskIds, ['2']);
      expect(manager.allTasks.map((t) => t.taskId), ['2', '3']);
      expect(store.saved, hasLength(1));
      expect(store.records.map((t) => t.taskId), ['2', '3']);
      manager.dispose();
    },
  );

  test(
    'overlapping deletes serialize file access and deduplicate IDs',
    () async {
      final store = MemoryComposeStore([
        composeRecord('1'),
        composeRecord('2'),
      ]);
      final cleaner = RecordingComposeCleaner()..gate = Completer<void>();
      final manager = VideoComposeManager(
        taskStore: store,
        artifactCleaner: cleaner,
      );
      final first = manager.deleteTasksAndFiles(['1', '1']);
      final second = manager.deleteTasksAndFiles([
        '1',
        '2',
      ], deleteOutput: false);
      await Future<void>.delayed(Duration.zero);
      expect(cleaner.deletions, [(id: '1', output: true)]);
      cleaner.gate!.complete();
      await Future.wait([first, second]);
      expect(cleaner.deletions, [
        (id: '1', output: true),
        (id: '2', output: false),
      ]);
      expect(manager.allTasks, isEmpty);
      manager.dispose();
    },
  );
}
