import 'dart:async';
import 'dart:math' as math;

import 'device_resource_snapshot.dart';

bool isTransientInferencePressure(Object error) {
  final message = '$error'.toLowerCase();
  return message.contains('out of memory') ||
      message.contains('outofmemory') ||
      message.contains('bad_alloc') ||
      message.contains('allocation fail') ||
      message.contains('内存不足') ||
      message.contains('resource exhausted');
}

class InferenceMemoryPressure extends StateError {
  InferenceMemoryPressure({
    required this.requestedBytes,
    required this.availableBytes,
    required this.reserveBytes,
    this.totalBytes,
    this.modelLabel = '本地模型',
  }) : super(
         '$modelLabel 内存不足：预计新增 ${_memorySize(requestedBytes)}，'
         '系统可用 ${_memorySize(availableBytes)}，'
         '需预留 ${_memorySize(reserveBytes)}'
         '${totalBytes == null ? '' : '（设备总内存 ${_memorySize(totalBytes)}）'}。'
         '已保留进度；请关闭其他应用释放内存，或在“模型中心 → 本地模型”选择更小模型后继续。'
         '总内存不等于当前可用内存。',
       );
  final int requestedBytes, availableBytes, reserveBytes;
  final int? totalBytes;
  final String modelLabel;
}

String _memorySize(int bytes) => bytes >= 1073741824
    ? '${(bytes / 1073741824).toStringAsFixed(2)} GB'
    : '${(bytes / 1048576).ceil()} MB';

enum InferencePressureLevel { normal, constrained, protective }

enum InferenceLane {
  recognition,
  auxiliary,
  translation,
  tuning,
  compilation,
  ocr,
  videoDecode,
  alignment,
}

enum InferenceLimitReason {
  none,
  manual,
  signals,
  memory,
  thermal,
  responsiveness,
  powerSaving,
  playback,
  cpu,
}

class InferencePlaybackActivity {
  static bool Function()? playing;
}

class InferenceBudgetDecision {
  const InferenceBudgetDecision({
    required this.totalThreads,
    required this.asrThreads,
    required this.auxiliaryThreads,
    required this.translationThreads,
    required this.promptThreads,
    required this.translationBatchLimit,
    required this.pipeline,
    required this.retainModels,
    required this.allowTuning,
    required this.level,
    required this.reason,
    this.reasonCode = InferenceLimitReason.none,
    this.pipelineRequested = true,
    this.activeAsrThreads = 0,
    this.activeAuxiliaryThreads = 0,
    this.activeTranslationThreads = 0,
    this.yieldDuration = Duration.zero,
  });
  final int totalThreads,
      asrThreads,
      auxiliaryThreads,
      translationThreads,
      promptThreads,
      translationBatchLimit;
  final bool pipeline, retainModels, allowTuning;
  final InferencePressureLevel level;
  final String reason;
  final InferenceLimitReason reasonCode;
  final bool pipelineRequested;
  final int activeAsrThreads, activeAuxiliaryThreads, activeTranslationThreads;
  int get pipelineCapacity => pipeline ? 2 : 1;
  bool get allowAudioPrefetch =>
      totalThreads >= 2 &&
      level != InferencePressureLevel.protective &&
      reasonCode != InferenceLimitReason.signals &&
      reasonCode != InferenceLimitReason.memory;
  InferenceBudgetDecision withActivity(
    Map<InferenceLane, int> active, {
    bool memoryLimited = false,
  }) => InferenceBudgetDecision(
    totalThreads: totalThreads,
    asrThreads: asrThreads,
    auxiliaryThreads: auxiliaryThreads,
    translationThreads: translationThreads,
    promptThreads: promptThreads,
    translationBatchLimit: translationBatchLimit,
    pipeline: pipeline && !memoryLimited,
    retainModels: retainModels,
    allowTuning: allowTuning && !memoryLimited,
    level: level,
    reason: memoryLimited ? '内存余量不足，暂时顺序处理' : reason,
    reasonCode: memoryLimited ? InferenceLimitReason.memory : reasonCode,
    pipelineRequested: pipelineRequested,
    yieldDuration: yieldDuration,
    activeAsrThreads: active[InferenceLane.recognition] ?? 0,
    activeAuxiliaryThreads: active[InferenceLane.auxiliary] ?? 0,
    activeTranslationThreads: active[InferenceLane.translation] ?? 0,
  );
  final Duration yieldDuration;
  bool get throttled => level != InferencePressureLevel.normal;
}

/// Pure policy, driven by an injectable clock. Downward changes never wait for
/// hysteresis; recovering one level requires 30 consecutive healthy seconds.
class InferenceResourceGovernor {
  InferenceResourceGovernor(this.snapshot, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _evaluate(initial: true);
  }
  DeviceResourceSnapshot snapshot;
  final DateTime Function() _now;
  final _listeners = <void Function()>[];
  InferencePressureLevel _level = InferencePressureLevel.normal;
  DateTime? _healthySince;
  int _slowWindows = 0, _verySlowWindows = 0, _lastWindow = -1;
  int _ceiling = 1;
  bool _known = false;
  void Function() listen(void Function() callback) {
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }

  void update(DeviceResourceSnapshot value) {
    snapshot = value;
    _evaluate();
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void _evaluate({bool initial = false}) {
    final s = snapshot, now = _now();
    final reliable = s.fresh(now) && s.memoryKnown && s.processors > 0;
    if (!reliable) _healthySince = null;
    if (s.frameWindow != _lastWindow) {
      _lastWindow = s.frameWindow;
      _slowWindows = s.frameCount >= 30 && s.slowFrameFraction > .1
          ? _slowWindows + 1
          : 0;
      _verySlowWindows = s.frameCount >= 30 && s.slowFrameFraction > .25
          ? _verySlowWindows + 1
          : 0;
    }
    final lowMemory =
        s.availableMemoryBytes != null &&
        s.availableMemoryBytes! < (s.mobile ? 256 : 512) * 1024 * 1024;
    final desired =
        lowMemory ||
            s.memoryPressure == ResourceMemoryPressure.critical ||
            s.memoryPressure == ResourceMemoryPressure.warning ||
            s.thermal == ResourceThermalState.severe ||
            _verySlowWindows >= 2
        ? InferencePressureLevel.protective
        : s.powerSaving ||
              s.thermal == ResourceThermalState.moderate ||
              _slowWindows >= 2
        ? InferencePressureLevel.constrained
        : InferencePressureLevel.normal;
    final cores = s.effectiveProcessors;
    var ceiling = (cores - math.max(1, (cores / 4).ceil()))
        .clamp(1, s.mobile ? 6 : 12)
        .toInt();
    if (s.playing) ceiling = math.min(ceiling, math.max(1, cores ~/ 2));
    if (!reliable) ceiling = math.min(ceiling, 2);
    if (initial) {
      _level = desired;
      _ceiling = ceiling;
    } else if (desired.index >= _level.index) {
      _level = desired;
      if (desired != InferencePressureLevel.normal) _healthySince = null;
      _ceiling = math.min(_ceiling, ceiling);
      if (desired == InferencePressureLevel.normal &&
          reliable &&
          ceiling > _ceiling) {
        _healthySince ??= now;
      }
    } else if (!reliable || desired != InferencePressureLevel.normal) {
      _healthySince = null;
    } else {
      _healthySince ??= now;
      if (now.difference(_healthySince!) >= const Duration(seconds: 30)) {
        _level = InferencePressureLevel.values[_level.index - 1];
        _ceiling = ceiling;
        _healthySince = now;
      }
    }
    // Recover an ordinary playback/CPU ceiling with the same dwell time.
    if (_level == InferencePressureLevel.normal &&
        reliable &&
        ceiling > _ceiling) {
      _healthySince ??= now;
      if (now.difference(_healthySince!) >= const Duration(seconds: 30)) {
        _ceiling = ceiling;
        _healthySince = null;
      }
    }
    _ceiling = math.min(_ceiling, ceiling);
    _known = reliable;
  }

  InferenceBudgetDecision decide({
    int asrMaximum = 0,
    int translationMaximum = 0,
    bool pipelineRequested = true,
  }) {
    final s = snapshot;
    final fresh = s.fresh(_now());
    var budget = _ceiling;
    if (_level == InferencePressureLevel.constrained) {
      budget = math.max(1, budget ~/ 2);
    }
    if (_level == InferencePressureLevel.protective) budget = 1;
    if (!fresh) budget = math.min(2, budget);
    // Keep native thread configurations stable across short gestures. Both
    // ASR and translation recreate loaded models when their thread cap changes.
    // Interaction headroom instead comes from bounded batches, launch gaps and
    // serial grants below; sustained thermal/frame pressure still lowers caps.
    final pipeline =
        pipelineRequested &&
        budget >= 2 &&
        _known &&
        fresh &&
        _level != InferencePressureLevel.protective;
    final auxiliary = 1;
    final asrCap = asrMaximum > 0 ? asrMaximum : budget;
    final translationCap = translationMaximum > 0
        ? translationMaximum
        : (s.mobile ? 4 : 6);
    return InferenceBudgetDecision(
      totalThreads: budget,
      asrThreads: math.min(
        asrCap,
        math.max(1, budget - (pipeline ? auxiliary : 0)),
      ),
      auxiliaryThreads: auxiliary,
      translationThreads: math.min(translationCap, budget),
      promptThreads: math.min(
        translationMaximum > 0 ? translationMaximum : budget,
        budget,
      ),
      translationBatchLimit: _level == InferencePressureLevel.protective
          ? 1
          : s.interacting && s.foreground
          ? 2
          : _level == InferencePressureLevel.constrained
          ? 4
          : 8,
      pipeline: pipeline,
      retainModels:
          _known && fresh && _level != InferencePressureLevel.protective,
      allowTuning:
          _known &&
          fresh &&
          s.workerMemoryComplete &&
          _level == InferencePressureLevel.normal &&
          !s.playing &&
          !s.interacting &&
          s.foreground &&
          !s.powerSaving &&
          s.slowFrameFraction <= .1 &&
          s.thermal != ResourceThermalState.warm &&
          (!s.thermalSupported || s.thermal == ResourceThermalState.normal),
      level: _level,
      pipelineRequested: pipelineRequested,
      reasonCode: !fresh || !_known
          ? InferenceLimitReason.signals
          : s.memoryPressure == ResourceMemoryPressure.warning ||
                s.memoryPressure == ResourceMemoryPressure.critical ||
                (s.availableMemoryBytes ?? (1 << 62)) <
                    (s.mobile ? 256 : 512) * 1024 * 1024
          ? InferenceLimitReason.memory
          : s.thermal == ResourceThermalState.severe ||
                s.thermal == ResourceThermalState.moderate
          ? InferenceLimitReason.thermal
          : _verySlowWindows >= 2 || _slowWindows >= 2
          ? InferenceLimitReason.responsiveness
          : s.powerSaving
          ? InferenceLimitReason.powerSaving
          : s.interacting && s.foreground
          ? InferenceLimitReason.responsiveness
          : s.playing
          ? InferenceLimitReason.playback
          : budget < 2
          ? InferenceLimitReason.cpu
          : InferenceLimitReason.none,
      reason: !fresh || !_known
          ? '资源信息不完整，保守分配线程'
          : _level == InferencePressureLevel.protective
          ? s.thermal == ResourceThermalState.severe ||
                    s.thermal == ResourceThermalState.moderate
                ? '设备发热，暂时顺序处理'
                : s.memoryPressure == ResourceMemoryPressure.warning ||
                      s.memoryPressure == ResourceMemoryPressure.critical ||
                      (s.availableMemoryBytes ?? (1 << 62)) <
                          (s.mobile ? 256 : 512) * 1024 * 1024
                ? '内存余量不足，暂时顺序处理'
                : _verySlowWindows >= 2 || _slowWindows >= 2
                ? '检测到持续掉帧，暂时顺序处理'
                : s.powerSaving
                ? '系统处于省电模式，已限制算力'
                : '设备压力已缓解，正在逐步恢复算力'
          : _level == InferencePressureLevel.constrained
          ? s.thermal == ResourceThermalState.moderate
                ? '设备发热，已降低速度'
                : s.powerSaving
                ? '系统处于省电模式，已限制算力'
                : _slowWindows >= 2
                ? '检测到持续掉帧，暂时减少计算并发'
                : '设备压力已缓解，正在逐步恢复算力'
          : s.interacting && s.foreground
          ? '正在操作界面，优先保持流畅'
          : s.playing
          ? '正在播放，已为播放器预留资源'
          : '自动按设备资源分配',
      yieldDuration: _level == InferencePressureLevel.protective
          ? const Duration(milliseconds: 150)
          : s.interacting && s.foreground
          ? const Duration(milliseconds: 16)
          : Duration.zero,
    );
  }
}

/// Only child processes created by inference are registered. Never inspect or
/// change the priority of unrelated processes or of the media player itself.
class InferenceProcessRegistry {
  static final instance = InferenceProcessRegistry();
  final _pids = <int, int>{};
  void Function(List<int>)? onChanged;
  List<int> get pids => _pids.keys.toList(growable: false);
  void Function() retain(int pid) {
    _pids[pid] = (_pids[pid] ?? 0) + 1;
    onChanged?.call(pids);
    var done = false;
    return () {
      if (done) return;
      done = true;
      final count = (_pids[pid] ?? 1) - 1;
      if (count == 0) {
        _pids.remove(pid);
      } else {
        _pids[pid] = count;
      }
      onChanged?.call(pids);
    };
  }
}

class InferenceComputePermit {
  InferenceComputePermit(this.threads, this.decision, this._release);
  final int threads;
  final InferenceBudgetDecision decision;
  final void Function() _release;
  bool _done = false;
  final _cleanups = <void Function()>[];
  void onRelease(void Function() action) {
    if (_done) {
      action();
    } else {
      _cleanups.add(action);
    }
  }

  void release() {
    if (_done) return;
    _done = true;
    for (final action in _cleanups) {
      action();
    }
    _release();
  }
}

class _ComputeWaiter {
  _ComputeWaiter(this.lane, this.requested);
  final InferenceLane lane;
  final int requested;
  final result = Completer<InferenceComputePermit>();
}

/// A reservation owns this arbiter. Grants across ASR, denoising and translation
/// share ONE thread budget. A pressure change never frees a running model.
class InferenceResourceSession {
  InferenceResourceSession(
    this.governor, {
    this.onClose,
    this.refreshSnapshot,
    this.onBudget,
  }) {
    _unlisten = governor.listen(_resourceChanged);
  }
  static final zoneKey = Object();
  static InferenceResourceSession? get current =>
      Zone.current[zoneKey] as InferenceResourceSession?;
  final InferenceResourceGovernor governor;
  final Future<void> Function()? onClose;
  final Future<void> Function()? refreshSnapshot;
  final void Function(InferenceBudgetDecision)? onBudget;
  int peakResidentBytes = 0;
  double peakSlowFrameFraction = 0;
  late final void Function() _unlisten;
  int asrMaximum = 0, translationMaximum = 0;
  bool pipelineRequested = true;
  int? preferredAsrThreads, preferredTranslationThreads, preferredPromptThreads;
  bool _closed = false;
  int _used = 0, _productive = 0, _pendingAllocationBytes = 0;
  bool _exclusive = false;
  final _activeLanes = <InferenceLane, int>{};
  final _productiveWatch = Stopwatch();
  final _waiters = <_ComputeWaiter>[];
  final _lastYieldAt = <InferenceLane, DateTime>{};
  final _idleModels = <Future<void> Function()>[];
  void Function() registerIdleModel(Future<void> Function() release) {
    _idleModels.add(release);
    return () => _idleModels.remove(release);
  }

  Duration get productiveTime => _productiveWatch.elapsed;
  int tuningTimeSpentMs = 0;
  bool _memoryLimited = false;
  int _memoryHandoffs = 0;
  DateTime? _memoryHealthySince, _memoryObservedAt;
  void limitPipelineForMemory() {
    _memoryLimited = true;
    _memoryHealthySince = _memoryObservedAt = governor._now();
    _pump();
  }

  void _resourceChanged() {
    if (_memoryLimited) {
      final now = governor._now();
      // Count recovery alongside the governor rather than adding a second
      // thirty-second delay after its thermal/memory downgrade has recovered.
      final healthy =
          governor._known &&
          governor.snapshot.fresh(now) &&
          (governor.decide().level == InferencePressureLevel.normal ||
              governor._healthySince != null);
      if (!healthy ||
          _memoryObservedAt != null &&
              now.difference(_memoryObservedAt!) > const Duration(seconds: 8)) {
        _memoryHealthySince = null;
      }
      if (healthy) {
        _memoryHealthySince ??= now;
        if (now.difference(_memoryHealthySince!) >=
            const Duration(seconds: 30)) {
          _memoryLimited = false;
        }
      }
      _memoryObservedAt = now;
    }
    _pump();
  }

  /// A pair of large models may need alternate residency without disabling
  /// denoise/ASR overlap for the rest of the task. Call only after draining the
  /// stage barrier; this scope never revokes a permit or releases a model.
  Future<T> memoryHandoff<T>(Future<T> Function() work) async {
    if (_closed || _used != 0) throw StateError('模型交接需要先排空正在运行的计算');
    _memoryHandoffs++;
    _pump();
    try {
      return await work();
    } finally {
      _memoryHandoffs--;
      _pump();
    }
  }

  InferenceBudgetDecision get decision => governor
      .decide(
        asrMaximum: asrMaximum > 0 ? asrMaximum : preferredAsrThreads ?? 0,
        translationMaximum: translationMaximum,
        pipelineRequested: pipelineRequested,
      )
      .withActivity(
        _activeLanes,
        memoryLimited: _memoryLimited || _memoryHandoffs > 0,
      );
  int get activeThreads => _used;
  Future<InferenceComputePermit> acquire(
    InferenceLane lane, {
    int requested = 0,
    Future<void>? cancelSignal,
  }) async {
    if (_closed) throw StateError('推理资源已释放');
    final waiter = _ComputeWaiter(lane, requested);
    _waiters.add(waiter);
    cancelSignal?.then((_) {
      if (_waiters.remove(waiter)) {
        waiter.result.completeError(StateError('任务已取消'));
        _pump();
      }
    });
    _pump();
    return waiter.result.future;
  }

  void _pump() {
    if (_closed) return;
    final d = decision;
    final snapshot = governor.snapshot;
    peakResidentBytes = math.max(
      peakResidentBytes,
      (snapshot.processBytes ?? 0) + snapshot.workerBytes,
    );
    peakSlowFrameFraction = math.max(
      peakSlowFrameFraction,
      snapshot.slowFrameFraction,
    );
    onBudget?.call(d.withActivity(_activeLanes));
    while (_waiters.isNotEmpty) {
      final w = _waiters.first;
      final cap = switch (w.lane) {
        InferenceLane.ocr => math.max(1, d.totalThreads - (d.pipeline ? 1 : 0)),
        InferenceLane.videoDecode => 1,
        InferenceLane.compilation => d.asrThreads,
        InferenceLane.alignment => d.asrThreads,
        InferenceLane.recognition => math.min(
          preferredAsrThreads ?? d.asrThreads,
          d.asrThreads,
        ),
        InferenceLane.auxiliary => d.auxiliaryThreads,
        InferenceLane.translation => d.promptThreads,
        InferenceLane.tuning => d.totalThreads,
      };
      final threads = math
          .min(w.requested > 0 ? w.requested : cap, cap)
          .clamp(1, 12);
      final exclusive =
          w.lane == InferenceLane.translation ||
          w.lane == InferenceLane.tuning ||
          w.lane == InferenceLane.compilation ||
          w.lane == InferenceLane.alignment;
      if (_exclusive ||
          (exclusive ||
                  !d.pipeline ||
                  snapshot.interacting && snapshot.foreground) &&
              _used != 0 ||
          _used + threads > d.totalThreads) {
        break;
      }
      _waiters.removeAt(0);
      _used += threads;
      _activeLanes.update(w.lane, (n) => n + threads, ifAbsent: () => threads);
      onBudget?.call(d.withActivity(_activeLanes));
      if (exclusive) _exclusive = true;
      if (w.lane != InferenceLane.tuning && ++_productive == 1) {
        _productiveWatch.start();
      }
      w.result.complete(
        InferenceComputePermit(threads, d, () {
          _used -= threads;
          _activeLanes.update(w.lane, (n) => n - threads);
          if (exclusive) _exclusive = false;
          if (w.lane != InferenceLane.tuning && --_productive == 0) {
            _productiveWatch.stop();
          }
          _pump();
        }),
      );
    }
  }

  Future<T> run<T>(
    InferenceLane lane,
    Future<T> Function(InferenceComputePermit) action, {
    int requested = 0,
    Duration minimumYieldInterval = Duration.zero,
    Future<void>? cancelSignal,
  }) async {
    var cancelled = false;
    cancelSignal?.then((_) => cancelled = true);
    final permit = await acquire(
      lane,
      requested: requested,
      cancelSignal: cancelSignal,
    );
    try {
      final now = governor._now();
      final previousYield = _lastYieldAt[lane];
      // OCR includes inexpensive unchanged-frame checks. Charging the entire
      // protective pause to every check can dwarf inference itself. Opt-in
      // pacing shares one gap per interval across OCR workers; thread/memory
      // caps, admission checks, cancellation and all other lanes stay intact.
      final yieldDue =
          minimumYieldInterval <= Duration.zero ||
          previousYield == null ||
          now.isBefore(previousYield) ||
          now.difference(previousYield) >= minimumYieldInterval;
      if (permit.decision.yieldDuration > Duration.zero && yieldDue) {
        _lastYieldAt[lane] = now;
        await Future.any<void>([
          Future<void>.delayed(permit.decision.yieldDuration),
          ?cancelSignal,
        ]);
      } else if (permit.decision.yieldDuration == Duration.zero) {
        _lastYieldAt.remove(lane);
      }
      if (cancelled) throw StateError('任务已取消');
      return await action(permit);
    } finally {
      permit.release();
    }
  }

  /// Reclaim idle weights before a new large allocation. Existing allocations
  /// have already reduced OS headroom and must not be charged a second time.
  bool admitsAdditional(int bytes) {
    final s = governor.snapshot;
    final available = s.availableMemoryBytes;
    if (available == null) return false;
    final reserve = s.mobile ? 256 * 1024 * 1024 : 512 * 1024 * 1024;
    return available >= math.max(0, bytes) + reserve + _pendingAllocationBytes;
  }

  Future<void> checkAllocation(
    int bytes, {
    InferenceComputePermit? permit,
    String modelLabel = '本地模型',
  }) async {
    await refreshSnapshot?.call();
    if (!admitsAdditional(bytes)) {
      for (final reclaim in List.of(_idleModels)) {
        await reclaim();
      }
      await refreshSnapshot?.call();
    }
    final s = governor.snapshot;
    if (s.availableMemoryBytes != null && !admitsAdditional(bytes)) {
      throw InferenceMemoryPressure(
        requestedBytes: math.max(0, bytes) + _pendingAllocationBytes,
        availableBytes: s.availableMemoryBytes!,
        reserveBytes: (s.mobile ? 256 : 512) * 1024 * 1024,
        totalBytes: s.memoryBytes,
        modelLabel: modelLabel,
      );
    }
    if (permit != null) {
      _pendingAllocationBytes += bytes;
      permit.onRelease(() => _pendingAllocationBytes -= bytes);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _unlisten();
    for (final waiter in _waiters) {
      waiter.result.completeError(StateError('推理资源已释放'));
    }
    _waiters.clear();
    await onClose?.call();
  }
}
