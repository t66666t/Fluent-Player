import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/model_background_tasks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.video_player_app/model_tasks');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <Map<dynamic, dynamic>>[];
  var interruptions = 0;

  setUp(() {
    ModelBackgroundTasks.resetForTesting();
    ModelBackgroundTasks.debugNativeTasksSupported = true;
    ModelBackgroundTasks.onInterrupted = () => interruptions++;
    calls.clear();
    interruptions = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.arguments as Map<dynamic, dynamic>);
      return null;
    });
  });

  tearDown(() async {
    await ModelBackgroundTasks.settleForTesting();
    ModelBackgroundTasks.resetForTesting();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'current download BACKGROUND_START reaches the existing interruption handler',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.arguments as Map<dynamic, dynamic>);
        throw PlatformException(
          code: 'BACKGROUND_START',
          message: 'system refused foreground start',
        );
      });
      ModelBackgroundTasks.downloads(1);
      await ModelBackgroundTasks.settleForTesting();
      expect(calls, [
        {'downloads': 1, 'inference': 0},
      ]);
      expect(interruptions, 1);
    },
  );

  test(
    'current inference rejection releases actual scheduler work through its interruption callback',
    () async {
      final nativeReply = Completer<void>();
      final requested = Completer<void>();
      final scheduler = InferenceScheduler();
      void Function()? release;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final payload = call.arguments as Map<dynamic, dynamic>;
        calls.add(payload);
        if (payload['inference'] == 1) {
          requested.complete();
          await nativeReply.future;
        }
        return null;
      });
      ModelBackgroundTasks.onInterrupted = () {
        interruptions++;
        release?.call();
      };
      try {
        release = await scheduler.acquire();
        await requested.future;
        expect(scheduler.busy, isTrue);
        nativeReply.completeError(PlatformException(code: 'BACKGROUND_START'));
        await ModelBackgroundTasks.settleForTesting();
        expect(interruptions, 1);
        expect(scheduler.busy, isFalse);
        expect(scheduler.waiting, 0);
        expect(calls.last, {'downloads': 0, 'inference': 0});
      } finally {
        if (!nativeReply.isCompleted) nativeReply.complete();
        release?.call();
        await ModelBackgroundTasks.settleForTesting();
      }
    },
  );

  test(
    'late rejection from a finished download cannot interrupt replacement work with identical counts',
    () async {
      final oldReply = Completer<void>();
      final oldStarted = Completer<void>();
      var first = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.arguments as Map<dynamic, dynamic>);
        if (first) {
          first = false;
          oldStarted.complete();
          await oldReply.future;
        }
        return null;
      });
      ModelBackgroundTasks.downloads(1);
      await oldStarted.future;
      ModelBackgroundTasks.downloads(0);
      ModelBackgroundTasks.downloads(1);
      oldReply.completeError(PlatformException(code: 'BACKGROUND_START'));
      await ModelBackgroundTasks.settleForTesting();
      expect(interruptions, 0);
      expect(calls, [
        {'downloads': 1, 'inference': 0},
        {'downloads': 0, 'inference': 0},
        {'downloads': 1, 'inference': 0},
      ]);
    },
  );

  test(
    'an obsolete rejection is ignored while the latest active rejection still interrupts once',
    () async {
      final oldReply = Completer<void>();
      final newReply = Completer<void>();
      final oldStarted = Completer<void>();
      final newStarted = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        final payload = call.arguments as Map<dynamic, dynamic>;
        calls.add(payload);
        if (payload['downloads'] == 1) {
          oldStarted.complete();
          await oldReply.future;
        } else {
          newStarted.complete();
          await newReply.future;
        }
        return null;
      });
      try {
        ModelBackgroundTasks.downloads(1);
        await oldStarted.future;
        ModelBackgroundTasks.downloads(2);
        oldReply.completeError(PlatformException(code: 'BACKGROUND_START'));
        await newStarted.future;
        expect(interruptions, 0);
        newReply.completeError(PlatformException(code: 'BACKGROUND_START'));
        await ModelBackgroundTasks.settleForTesting();
        expect(interruptions, 1);
        expect(calls.length, 2);
      } finally {
        if (!oldReply.isCompleted) oldReply.complete();
        if (!newReply.isCompleted) newReply.complete();
        await ModelBackgroundTasks.settleForTesting();
      }
    },
  );

  test(
    'a rejected active request that has since stopped cannot interrupt idle tasks',
    () async {
      final oldReply = Completer<void>();
      final started = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        final payload = call.arguments as Map<dynamic, dynamic>;
        calls.add(payload);
        if (payload['downloads'] == 1) {
          started.complete();
          await oldReply.future;
        }
        return null;
      });
      ModelBackgroundTasks.downloads(1);
      await started.future;
      ModelBackgroundTasks.downloads(0);
      oldReply.completeError(PlatformException(code: 'BACKGROUND_START'));
      await ModelBackgroundTasks.settleForTesting();
      expect(interruptions, 0);
      expect(calls.last, {'downloads': 0, 'inference': 0});
    },
  );

  test(
    'zero-task rejection is controlled and never pauses user work',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.arguments as Map<dynamic, dynamic>);
        throw PlatformException(code: 'BACKGROUND_START');
      });
      ModelBackgroundTasks.inference(0);
      await ModelBackgroundTasks.settleForTesting();
      expect(calls, [
        {'downloads': 0, 'inference': 0},
      ]);
      expect(interruptions, 0);
    },
  );

  test(
    'a missing older host remains controlled and does not poison later publications',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.arguments as Map<dynamic, dynamic>);
        throw MissingPluginException('older host');
      });
      ModelBackgroundTasks.downloads(1);
      await ModelBackgroundTasks.settleForTesting();
      expect(interruptions, 0);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.arguments as Map<dynamic, dynamic>);
        return null;
      });
      ModelBackgroundTasks.downloads(2);
      await ModelBackgroundTasks.settleForTesting();
      expect(interruptions, 0);
      expect(calls.last, {'downloads': 2, 'inference': 0});
      expect(calls.length, 2);
    },
  );

  test(
    'unrelated host errors remain controlled without interpreting them as OS refusal',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'UNSUPPORTED_METHOD');
      });
      ModelBackgroundTasks.downloads(1);
      await ModelBackgroundTasks.settleForTesting();
      expect(interruptions, 0);
    },
  );

  test(
    'ordinary successful model publications never signal interruption',
    () async {
      ModelBackgroundTasks.downloads(1);
      ModelBackgroundTasks.inference(1);
      ModelBackgroundTasks.inference(-1);
      ModelBackgroundTasks.downloads(0);
      await ModelBackgroundTasks.settleForTesting();
      expect(interruptions, 0);
      expect(calls, [
        {'downloads': 1, 'inference': 0},
        {'downloads': 1, 'inference': 1},
        {'downloads': 1, 'inference': 0},
        {'downloads': 0, 'inference': 0},
      ]);
    },
  );
}
