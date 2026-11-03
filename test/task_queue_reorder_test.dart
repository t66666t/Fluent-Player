import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';

void main() {
  group('batch subtitle queue index conversion', () {
    final displayedTasks = <BatchSubtitleTaskView>[
      _task('active', TranscriptionStatus.transcribing),
      _task('a', TranscriptionStatus.idle),
      _task('b', TranscriptionStatus.idle),
      _task('c', TranscriptionStatus.idle),
      _task('done', TranscriptionStatus.completed),
    ];

    test('moving down ignores active and completed display rows', () {
      expect(
        calculateBatchSubtitleQueueIndex(
          displayedTasks: displayedTasks,
          oldIndex: 1,
          newIndex: 3,
          isDescending: false,
        ),
        2,
      );
    });

    test('moving up produces the exact final queue position', () {
      expect(
        calculateBatchSubtitleQueueIndex(
          displayedTasks: displayedTasks,
          oldIndex: 3,
          newIndex: 1,
          isDescending: false,
        ),
        0,
      );
    });

    test('dropping after the final display row still means queue end', () {
      expect(
        calculateBatchSubtitleQueueIndex(
          displayedTasks: displayedTasks,
          oldIndex: 1,
          newIndex: displayedTasks.length - 1,
          isDescending: false,
        ),
        2,
      );
    });

    test('descending display maps back to the underlying queue order', () {
      expect(
        calculateBatchSubtitleQueueIndex(
          displayedTasks: displayedTasks.reversed.toList(),
          oldIndex: 1,
          newIndex: 3,
          isDescending: true,
        ),
        0,
      );
    });
  });

  for (final descending in [false, true]) {
    test(
      'dragging within and across priority groups: descending=$descending',
      () {
        final tasks = orderBatchSubtitleTasks([
          _task('paused-a', TranscriptionStatus.idle),
          _task('ready-a', TranscriptionStatus.idle).copyWith(isStarted: true),
          _task('active', TranscriptionStatus.translating),
          _task('done', TranscriptionStatus.completed),
          _task('paused-b', TranscriptionStatus.idle),
          _task('ready-b', TranscriptionStatus.idle).copyWith(isStarted: true),
        ], descending: descending);
        for (final key in ['ready-a', 'ready-b', 'paused-a', 'paused-b']) {
          for (var destination = 0; destination < tasks.length; destination++) {
            final oldIndex = tasks.indexWhere((task) => task.mediaKey == key);
            final reordered = [...tasks];
            final dragged = reordered.removeAt(oldIndex);
            reordered.insert(destination, dragged);
            final canonical = orderBatchSubtitleTasks(
              descending ? reordered.reversed : reordered,
            ).where((task) => task.status == TranscriptionStatus.idle).toList();
            expect(
              calculateBatchSubtitleQueueIndex(
                displayedTasks: tasks,
                oldIndex: oldIndex,
                newIndex: destination,
                isDescending: descending,
              ),
              canonical.indexWhere((task) => task.mediaKey == key),
              reason: '$key to $destination',
            );
          }
        }
        expect(
          calculateBatchSubtitleQueueIndex(
            displayedTasks: tasks,
            oldIndex: 0,
            newIndex: 2,
            isDescending: descending,
          ),
          -1,
          reason: 'the active task cannot be dragged',
        );
      },
    );

    testWidgets(
      'active and scheduled rows stay ahead of history: descending=$descending',
      (tester) async {
        final tasks = [
          _task('paused', TranscriptionStatus.idle),
          _task('ready', TranscriptionStatus.idle).copyWith(isStarted: true),
          _task('active', TranscriptionStatus.transcribing),
          _task('done', TranscriptionStatus.completed),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TaskQueueTable(
                tasks: tasks,
                autoDeletedKeys: const {},
                onStart: (_) {},
                onRetry: (_) {},
                onDelete: (_) {},
                onReorder: (_, _) {},
              ),
            ),
          ),
        );
        if (descending) {
          await tester.tap(
            find.byKey(const ValueKey('task-queue-display-order')),
          );
          await tester.pumpAndSettle();
        }
        final expected = descending
            ? ['active', 'ready', 'done', 'paused']
            : ['active', 'ready', 'paused', 'done'];
        for (var i = 1; i < expected.length; i++) {
          expect(
            tester.getTopLeft(find.byKey(ValueKey(expected[i - 1]))).dy,
            lessThan(tester.getTopLeft(find.byKey(ValueKey(expected[i]))).dy),
          );
        }
        final activeRow = find.byKey(const ValueKey('active'));
        expect(
          find.descendant(of: activeRow, matching: find.text('1')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'manager treats destination as final index in both directions',
    () async {
      final manager = TranscriptionManager();
      addTearDown(manager.dispose);

      for (final key in ['a', 'b', 'c', 'd']) {
        await manager.startTranscription(
          '$key.mp4',
          videoId: key,
          videoTitle: key,
        );
      }

      expect(manager.reorderTask('id:a', 3), isTrue);
      expect(_queueKeys(manager), ['id:b', 'id:c', 'id:d', 'id:a']);

      expect(manager.reorderTask('id:a', 1), isTrue);
      expect(_queueKeys(manager), ['id:b', 'id:a', 'id:c', 'id:d']);
    },
  );
}

BatchSubtitleTaskView _task(String key, TranscriptionStatus status) {
  return BatchSubtitleTaskView(
    mediaKey: key,
    videoPath: '$key.mp4',
    videoName: key,
    videoDuration: '',
    isExternal: false,
    status: status,
    progress: 0,
    statusMessage: '',
    createdAt: 0,
  );
}

List<String> _queueKeys(TranscriptionManager manager) {
  return manager
      .getQueueSnapshot()
      .where((task) => task.status == TranscriptionStatus.idle)
      .map((task) => task.mediaKey)
      .toList();
}
