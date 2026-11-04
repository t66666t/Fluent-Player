import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/serial_task_queue.dart';

void main() {
  test('queued callers complete only after their own task has run', () async {
    final queue = SerialTaskQueue();
    final firstGate = Completer<void>();
    final events = <String>[];

    final first = queue.enqueue(() async {
      events.add('first-start');
      await firstGate.future;
      events.add('first-end');
    });
    final second = queue.enqueue(() async {
      events.add('second');
    });
    var secondCompleted = false;
    unawaited(second.whenComplete(() => secondCompleted = true));

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events, <String>['first-start']);
    expect(secondCompleted, isFalse);

    firstGate.complete();
    await first;
    await second;
    expect(events, <String>['first-start', 'first-end', 'second']);
  });

  test('a failed task does not prevent a later save', () async {
    final queue = SerialTaskQueue();
    final failed = queue.enqueue<void>(() async {
      throw StateError('disk failure');
    });
    final later = queue.enqueue(() async => 42);

    await expectLater(failed, throwsStateError);
    await expectLater(later, completion(42));
  });
}
