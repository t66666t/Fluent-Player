import 'dart:math' as math;

import '../features/model_center/device_resource_snapshot.dart';
import '../features/model_center/inference_resource_governor.dart';

/// A worker can request a new native session while it owns a compute permit.
/// Charge pending allocations to that permit so two workers cannot both spend
/// the same free-memory snapshot before either model appears in process RSS.
class OcrWorkerAllocationGuard {
  OcrWorkerAllocationGuard(this.resources);
  final InferenceResourceSession resources;
  InferenceComputePermit? _permit;

  Future<T> run<T>(
    InferenceComputePermit permit,
    Future<T> Function() work,
  ) async {
    if (_permit != null) throw StateError('OCR 工作线程已有正在处理的帧');
    _permit = permit;
    try {
      return await work();
    } finally {
      _permit = null;
    }
  }

  Future<void> checkAllocation(int bytes) {
    final permit = _permit;
    if (permit == null) throw StateError('OCR 模型加载缺少资源预约');
    return resources.checkAllocation(
      bytes,
      permit: permit,
      modelLabel: 'OCR 模型与推理缓冲',
    );
  }
}

List<int> ocrCpuThreadCandidates(int current, int maximum, List<int> tested) {
  final values =
      <int>{1, 2, 4, 6, 8, 12, maximum}
          .where(
            (value) =>
                value >= 1 &&
                value <= maximum &&
                value != current &&
                !tested.contains(value),
          )
          .toList()
        ..sort();
  return [
    ...values.where((value) => value > current),
    ...values.where((value) => value < current).toList().reversed,
  ];
}

int ocrThreadsPerWorker(InferenceBudgetDecision budget, int workers) =>
    math.max(
      1,
      (budget.totalThreads - (budget.pipeline ? 1 : 0)) ~/ math.max(1, workers),
    );

/// UI/thermal pressure calls for less compute, not repeated model loading.
/// Keep native sessions when memory is healthy; new allocations still pass the
/// existing admission check. Missing/stale memory data keeps one resident model.
bool ocrRetainModels(
  DeviceResourceSnapshot snapshot,
  InferenceBudgetDecision budget,
) =>
    snapshot.fresh(DateTime.now()) &&
    snapshot.memoryKnown &&
    snapshot.workerMemoryComplete &&
    budget.reasonCode != InferenceLimitReason.memory &&
    snapshot.memoryPressure != ResourceMemoryPressure.warning &&
    snapshot.memoryPressure != ResourceMemoryPressure.critical &&
    snapshot.availableMemoryBytes! >=
        (snapshot.mobile ? 512 : 1024) * 1024 * 1024;

/// Regions stay chronological within their assigned worker. A serial worker
/// finishes a region in the current bounded chunk before switching models;
/// independent workers can each advance one frame without sharing a session.
class OcrRegionWorkQueue<T> {
  OcrRegionWorkQueue(Iterable<T> values, int workers, int Function(T) workerFor)
    : _queues = List.generate(math.max(1, workers), (_) => <T>[]),
      _next = List.filled(math.max(1, workers), 0) {
    for (final value in values) {
      _queues[workerFor(value)].add(value);
    }
  }
  final List<List<T>> _queues;
  final List<int> _next;

  List<T> take({required bool parallel}) {
    final result = <T>[];
    for (var i = 0; i < _queues.length; i++) {
      if (_next[i] >= _queues[i].length) continue;
      result.add(_queues[i][_next[i]++]);
      if (!parallel) break;
    }
    return result;
  }
}

/// Parallel regions duplicate native sessions, so spare CPU alone is not an
/// admission criterion. Keep small jobs and uncertain/pressured devices serial.
int ocrWorkerCount({
  required DeviceResourceSnapshot snapshot,
  required InferenceBudgetDecision budget,
  required int regions,
  required int mediaMs,
  required int modelBytes,
}) {
  if (regions < 2 ||
      mediaMs < 30000 ||
      !snapshot.fresh(DateTime.now()) ||
      !snapshot.memoryKnown ||
      !snapshot.workerMemoryComplete ||
      !budget.retainModels ||
      budget.level != InferencePressureLevel.normal ||
      ocrThreadsPerWorker(budget, 2) < 2) {
    return 1;
  }
  final reserve = (snapshot.mobile ? 512 : 1024) * 1024 * 1024;
  return snapshot.availableMemoryBytes! >= modelBytes * 2 + reserve ? 2 : 1;
}
