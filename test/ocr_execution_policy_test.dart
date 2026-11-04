import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/services/ocr_execution_policy.dart';

void main() {
  test('serial chunks finish regions without switching models every frame', () {
    final queue = OcrRegionWorkQueue<String>(
      ['r1:0', 'r1:1', 'r1:2', 'r2:0', 'r2:1'],
      1,
      (_) => 0,
    );
    final sequence = <String>[];
    while (true) {
      final next = queue.take(parallel: false);
      if (next.isEmpty) break;
      sequence.addAll(next);
    }
    expect(sequence, ['r1:0', 'r1:1', 'r1:2', 'r2:0', 'r2:1']);
  });

  test(
    'parallel workers remain ordered and can drain serially under pressure',
    () {
      final queue = OcrRegionWorkQueue<String>(
        ['r1:0', 'r1:1', 'r1:2', 'r2:0', 'r2:1', 'r3:0'],
        2,
        (frame) => frame.startsWith('r2') ? 1 : 0,
      );
      expect(queue.take(parallel: true), ['r1:0', 'r2:0']);
      expect(queue.take(parallel: false), ['r1:1']);
      expect(queue.take(parallel: false), ['r1:2']);
      expect(queue.take(parallel: false), ['r3:0']);
      expect(queue.take(parallel: true), ['r2:1']);
      expect(queue.take(parallel: true), isEmpty);
    },
  );

  for (final platform in ['android', 'windows', 'ios', 'macos', 'linux']) {
    test(
      '$platform: compute pressure does not discard healthy resident models',
      () {
        DeviceResourceSnapshot snapshot({
          int freeMiB = 6144,
          ResourceThermalState thermal = ResourceThermalState.normal,
          ResourceMemoryPressure pressure = ResourceMemoryPressure.normal,
          bool complete = true,
        }) => DeviceResourceSnapshot(
          platform: platform,
          processors: 8,
          capturedAt: DateTime.now(),
          memoryBytes: 12 * 1073741824,
          availableMemoryBytes: freeMiB * 1024 * 1024,
          thermal: thermal,
          memoryPressure: pressure,
          workerMemoryComplete: complete,
        );
        final hot = snapshot(thermal: ResourceThermalState.severe);
        final limited = InferenceResourceGovernor(hot).decide();
        expect(limited.totalThreads, 1);
        expect(limited.retainModels, isFalse);
        expect(ocrRetainModels(hot, limited), isTrue);
        final memory = snapshot(pressure: ResourceMemoryPressure.warning);
        expect(
          ocrRetainModels(memory, InferenceResourceGovernor(memory).decide()),
          isFalse,
        );
        for (final scarce in [
          snapshot(freeMiB: 400),
          snapshot(complete: false),
        ]) {
          expect(
            ocrRetainModels(scarce, InferenceResourceGovernor(scarce).decide()),
            isFalse,
          );
        }
      },
    );
  }
  test(
    'parallel worker allocations cannot spend the same memory headroom twice',
    () async {
      const mib = 1024 * 1024;
      final resources = InferenceResourceSession(
        InferenceResourceGovernor(
          DeviceResourceSnapshot(
            platform: 'android',
            processors: 8,
            capturedAt: DateTime.now(),
            memoryBytes: 12 * 1073741824,
            availableMemoryBytes: 700 * mib,
          ),
        ),
      );
      final first = await resources.acquire(InferenceLane.ocr, requested: 2);
      final second = await resources.acquire(InferenceLane.ocr, requested: 2);
      final a = OcrWorkerAllocationGuard(resources),
          b = OcrWorkerAllocationGuard(resources);
      await a.run(first, () => a.checkAllocation(300 * mib));
      await expectLater(
        b.run(second, () => b.checkAllocation(300 * mib)),
        throwsA(isA<InferenceMemoryPressure>()),
      );
      first.release();
      await b.run(second, () => b.checkAllocation(300 * mib));
      second.release();
      await expectLater(
        Future<void>.sync(() => a.checkAllocation(1)),
        throwsStateError,
      );
      await resources.close();
    },
  );
  test(
    'CPU tuning can explore the full permit and preserves tested choices',
    () {
      expect(ocrCpuThreadCandidates(2, 11, []), [4, 6, 8, 11, 1]);
      expect(ocrCpuThreadCandidates(4, 6, [1, 2]), [6]);
      expect(ocrCpuThreadCandidates(2, 2, [1]), isEmpty);
      expect(ocrCpuThreadCandidates(1, 1, []), isEmpty);
    },
  );
  for (final platform in ['windows', 'android', 'linux', 'macos', 'ios']) {
    test(
      '$platform: parallel regions require CPU and real memory headroom',
      () {
        DeviceResourceSnapshot snapshot({
          int cores = 8,
          int? available = 6 * 1073741824,
          ResourceMemoryPressure pressure = ResourceMemoryPressure.normal,
          bool complete = true,
          bool stale = false,
        }) => DeviceResourceSnapshot(
          platform: platform,
          processors: cores,
          capturedAt: DateTime.now().subtract(
            Duration(seconds: stale ? 30 : 0),
          ),
          memoryBytes: 12 * 1073741824,
          availableMemoryBytes: available,
          memoryPressure: pressure,
          workerMemoryComplete: complete,
        );
        int count(
          DeviceResourceSnapshot sample, {
          int regions = 2,
          int span = 60000,
        }) => ocrWorkerCount(
          snapshot: sample,
          budget: InferenceResourceGovernor(sample).decide(),
          regions: regions,
          mediaMs: span,
          modelBytes: 256 * 1024 * 1024,
        );
        final normal = snapshot();
        final budget = InferenceResourceGovernor(normal).decide();
        expect(count(normal), 2);
        expect(
          ocrThreadsPerWorker(budget, 2) * 2 + 1,
          lessThanOrEqualTo(budget.totalThreads),
        );
        expect(count(normal, regions: 1), 1);
        expect(count(normal, span: 5000), 1);
        expect(count(snapshot(cores: 2)), 1);
        expect(count(snapshot(available: null)), 1);
        expect(count(snapshot(available: 600 * 1024 * 1024)), 1);
        expect(count(snapshot(pressure: ResourceMemoryPressure.critical)), 1);
        expect(count(snapshot(complete: false)), 1);
        expect(count(snapshot(stale: true)), 1);
      },
    );
  }
}
