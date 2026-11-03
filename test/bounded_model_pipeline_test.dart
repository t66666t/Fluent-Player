import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_execution_plan.dart';
import 'package:video_player_app/features/model_center/bounded_model_pipeline.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';

void main() {
  test(
    'local translation drains both native stages and blocks new native calls until released',
    () async {
      final gate = ModelStageBarrier();
      final first = Completer<void>(),
          second = Completer<void>(),
          translation = Completer<void>();
      final events = <String>[];
      final nativeA = gate.shared(() async {
        events.add('asr');
        await first.future;
      });
      final nativeB = gate.shared(() async {
        events.add('enhancement');
        await second.future;
      });
      final consumer = gate.exclusive(() async {
        events.add('translation');
        await translation.future;
      });
      await Future<void>.delayed(Duration.zero);
      final next = gate.shared(() async {
        events.add('next');
      });
      first.complete();
      await nativeA;
      expect(events, ['asr', 'enhancement']);
      second.complete();
      await nativeB;
      await Future<void>.delayed(Duration.zero);
      expect(events, ['asr', 'enhancement', 'translation']);
      translation.complete();
      await Future.wait([consumer, next]);
      expect(events.last, 'next');
      await expectLater(
        gate.exclusive(() async => throw StateError('stopped')),
        throwsStateError,
      );
      await gate.shared(() async {
        events.add('recovered');
      });
      expect(events.last, 'recovered');
    },
  );

  test('mobile residency budgets ASR and alignment as alternate stages', () {
    const gib = 1073741824;
    const base = AsrExecutionPlan(
      pipeline: true,
      reuseModels: true,
      asrThreads: 2,
      enhancementThreads: 2,
      reason: 'test',
    );
    AsrExecutionPlan choose(
      int available, {
      AsrExecutionMode mode = AsrExecutionMode.auto,
    }) => base.withLocalTranslation(
      device: ModelDeviceInfo(
        memoryBytes: 8 * gib,
        availableMemoryBytes: available,
        processors: 8,
      ),
      platform: 'android',
      modelBytes: gib ~/ 4,
      translationBytes: gib,
      alignmentBytes: gib ~/ 4,
      lightweightBytes: 0,
      mode: mode,
    );
    final serial = choose(4 * gib);
    expect(serial.pipeline, isTrue);
    expect(serial.reuseModels, isTrue);
    expect(choose(6 * gib).pipeline, isTrue);
    expect(choose(2 * gib).reuseModels, isTrue);
    expect(choose(2 * gib).retainTranslation, isFalse);
    expect(choose(6 * gib).retainTranslation, isTrue);
    expect(
      choose(6 * gib, mode: AsrExecutionMode.lowMemory).reuseModels,
      isFalse,
    );
  });

  test(
    'preparation prefetch owns only one unclaimed item and drains it on close',
    () async {
      final prepared = <int>[], disposed = <int>[];
      final secondEntered = Completer<void>(), release = Completer<void>();
      final prefetch = ModelStagePrefetcher<int, int>(
        inputs: [0, 1, 2],
        prepare: (id) async {
          prepared.add(id);
          if (id == 1) {
            secondEntered.complete();
            await release.future;
          }
          return id;
        },
        dispose: (value) async {
          disposed.add(value);
        },
      );
      expect(await prefetch.take(0), 0);
      await secondEntered.future;
      expect(prepared, [0, 1]);
      var closed = false;
      final closing = prefetch.close().then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      release.complete();
      await closing;
      expect(disposed, [1]);
      expect(prepared, [0, 1]);
    },
  );

  test(
    'prefetch captures early errors, and queued native calls remain serial after a failure',
    () async {
      final queue = ModelStageQueue();
      final calls = <int>[];
      final prefetch = ModelStagePrefetcher<int, int>(
        inputs: [0, 1],
        prepare: (id) => queue.run(() async {
          calls.add(id);
          if (id == 1) throw StateError('preparation failed');
          return id;
        }),
        dispose: (_) async {},
      );
      expect(await prefetch.take(0), 0);
      await queue.run(() async {
        calls.add(2);
      });
      await expectLater(prefetch.take(1), throwsStateError);
      await prefetch.close();
      await queue.drained;
      expect(calls, [0, 1, 2]);
    },
  );

  test(
    'stage one advances while stage two is blocked, with bounded backlog and ordered output',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final produced = <int>[], disposed = <int>[];
      final run = runBoundedModelPipeline(
        inputs: [0, 1, 2, 3],
        produce: (int id) async {
          produced.add(id);
          return id * 2;
        },
        consume: (int id, int value) async {
          if (id == 0) {
            entered.complete();
            await release.future;
          }
          return value + 1;
        },
        dispose: (int id, int value) async {
          disposed.add(id);
        },
        abort: () {},
      );
      await entered.future;
      await Future<void>.delayed(Duration.zero);
      expect(produced, [0, 1]);
      release.complete();
      expect(await run, [1, 3, 5, 7]);
      expect(disposed, [0, 1, 2, 3]);
    },
  );

  test(
    'failed consumers abort once, drain peers and release every produced item',
    () async {
      final produced = <int>[], disposed = <int>[];
      var aborts = 0;
      await expectLater(
        runBoundedModelPipeline(
          inputs: [0, 1, 2],
          produce: (int id) async {
            produced.add(id);
            return id;
          },
          consume: (int id, int _) async {
            throw StateError('failed $id');
          },
          dispose: (int id, int _) async {
            disposed.add(id);
          },
          abort: () {
            aborts++;
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'original error',
            'failed 0',
          ),
        ),
      );
      expect(aborts, 1);
      expect(disposed, produced);
    },
  );

  test(
    'workflow topology survives low headroom; the runtime admits each actual model load',
    () {
      const gib = 1073741824;
      AsrExecutionPlan plan(
        String platform,
        int? available, {
        int processors = 8,
        AsrExecutionMode mode = AsrExecutionMode.auto,
      }) => AsrExecutionPlan.choose(
        device: ModelDeviceInfo(
          memoryBytes: 16 * gib,
          availableMemoryBytes: available,
          processors: processors,
        ),
        platform: platform,
        requestedThreads: 4,
        modelBytes: 700000000,
        enhancementBytes: 450000000,
        mode: mode,
      );
      for (final platform in ['android', 'ios', 'windows', 'macos', 'linux']) {
        final admitted = plan(platform, 10 * gib);
        expect(admitted.pipeline, isTrue);
        expect(
          admitted.asrThreads + admitted.enhancementThreads,
          // The manual limit caps ASR; the auxiliary stage has one thread.
          lessThanOrEqualTo(5),
        );
        expect(
          plan(platform, gib, mode: AsrExecutionMode.pipeline).pipeline,
          isTrue,
        );
        expect(
          plan(platform, 10 * gib, mode: AsrExecutionMode.lowMemory).pipeline,
          isFalse,
        );
        expect(plan(platform, 10 * gib, processors: 2).pipeline, isTrue);
      }
      expect(plan('ios', null).pipeline, isTrue);
      expect(plan('android', null).pipeline, isTrue);
      expect(plan('macos', null).pipeline, isTrue);
      final small = AsrExecutionPlan.choose(
        device: const ModelDeviceInfo(
          memoryBytes: 6 * gib,
          availableMemoryBytes: 3 * gib,
          processors: 8,
        ),
        platform: 'android',
        requestedThreads: 2,
        modelBytes: 50 * 1024 * 1024,
        enhancementBytes: 150 * 1024 * 1024,
      );
      expect(small.pipeline, isTrue);
      final serialReuse = AsrExecutionPlan.choose(
        device: const ModelDeviceInfo(
          memoryBytes: 8 * gib,
          availableMemoryBytes: 4 * gib,
          processors: 2,
        ),
        platform: 'android',
        requestedThreads: 2,
        modelBytes: 600 * 1024 * 1024,
        enhancementBytes: 400 * 1024 * 1024,
        alignmentBytes: 300 * 1024 * 1024,
        lightweightEnhancementBytes: 60 * 1024 * 1024,
      );
      expect(serialReuse.pipeline, isTrue);
      expect(serialReuse.reuseModels, isTrue);
      expect(serialReuse.chunkDuration, const Duration(seconds: 60));
      for (final platform in ['android', 'ios', 'macos', 'windows', 'linux']) {
        final plan = AsrExecutionPlan.choose(
          device: const ModelDeviceInfo(
            memoryBytes: 8 * gib,
            availableMemoryBytes: 4 * gib,
            processors: 6,
          ),
          platform: platform,
          requestedThreads: 2,
          modelBytes: 100 * 1024 * 1024,
          enhancementBytes: 200 * 1024 * 1024,
        );
        expect(plan.pipeline, isTrue);
        expect(plan.asrThreads + plan.enhancementThreads, lessThanOrEqualTo(3));
        final denoiseOnly = AsrExecutionPlan.choose(
          device: const ModelDeviceInfo(
            memoryBytes: 8 * gib,
            availableMemoryBytes: 6 * gib,
            processors: 8,
          ),
          platform: platform,
          requestedThreads: 2,
          modelBytes: 100 * 1024 * 1024,
          enhancementBytes: 60 * 1024 * 1024,
          alignmentBytes: 0,
          hasPostProcessing: false,
          hasDenoising: true,
        );
        expect(denoiseOnly.preprocessAhead, isTrue);
        expect(
          denoiseOnly.asrThreads + denoiseOnly.enhancementThreads,
          lessThanOrEqualTo(4),
        );
        final singleAsrThread = AsrExecutionPlan.choose(
          device: const ModelDeviceInfo(
            memoryBytes: 8 * gib,
            availableMemoryBytes: 6 * gib,
            processors: 8,
          ),
          platform: platform,
          requestedThreads: 1,
          modelBytes: 100 * 1024 * 1024,
          enhancementBytes: 60 * 1024 * 1024,
          hasDenoising: true,
        );
        expect(singleAsrThread.asrThreads, 1);
        expect(
          singleAsrThread.preprocessAhead,
          isTrue,
          reason:
              'one ASR calculation thread is not a one-stage concurrency limit',
        );
      }
    },
  );
}
