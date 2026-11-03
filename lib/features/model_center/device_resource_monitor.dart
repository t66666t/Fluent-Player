import 'dart:async';
import 'dart:io';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'device_resource_platform.dart';
import 'device_resource_snapshot.dart';
import 'inference_resource_governor.dart';
import '../../utils/ui_interaction_budget.dart';

/// Route-independent, reference-counted monitor. It owns no model and never
/// generates frames merely to measure FPS. No polling remains after release.
class DeviceResourceMonitor with WidgetsBindingObserver {
  DeviceResourceMonitor({ResourcePlatformProbe Function()? createProbe})
    : _createProbe = createProbe ?? ResourcePlatformProbe.create;
  static final instance = DeviceResourceMonitor();
  final ResourcePlatformProbe Function() _createProbe;
  ResourcePlatformProbe? _probe;
  InferenceResourceGovernor? _governor;
  StreamSubscription<Map<dynamic, dynamic>>? _urgent;
  Timer? _timer;
  WidgetsBinding? _binding;
  int _leases = 0, _generation = 0, _frames = 0, _slow = 0, _window = 0;
  bool _foreground = true;
  Completer<void>? _sampling;
  double _lastFraction = 0;
  int _lastFrames = 0;
  DateTime? _pressureUntil;
  ResourceMemoryPressure? _pressure;
  Future<void>? _starting;
  int get activeLeases => _leases;

  /// Settings can show a recommendation without starting polling or loading
  /// models. Active work and idle recommendations use the same native probe.
  Future<DeviceResourceSnapshot> readOnce() async {
    final active = _governor?.snapshot;
    if (active != null && active.fresh(DateTime.now())) return active;
    final probe = _createProbe();
    try {
      return (await probe.read(
        InferenceProcessRegistry.instance.pids,
      )).experience(
        foreground: true,
        playing: InferencePlaybackActivity.playing?.call() ?? false,
        slowFrameFraction: 0,
        frameCount: 0,
        frameWindow: 0,
      );
    } catch (_) {
      return DeviceResourceSnapshot(
        platform: Platform.operatingSystem,
        processors: Platform.numberOfProcessors,
        capturedAt: DateTime.now(),
      );
    } finally {
      await probe.close();
    }
  }

  final budget = ValueNotifier<InferenceBudgetDecision?>(null);
  Timer? _displayTimer;
  InferenceBudgetDecision? _pendingDisplay;
  DateTime? _displayedAt;
  void reportBudget(InferenceBudgetDecision value) {
    _pendingDisplay = value;
    if (_displayTimer != null) return;
    final elapsed = _displayedAt == null
        ? 1000
        : DateTime.now().difference(_displayedAt!).inMilliseconds;
    void publish() {
      _displayTimer = null;
      _displayedAt = DateTime.now();
      budget.value = _pendingDisplay;
    }

    if (elapsed >= 1000) {
      if (_binding?.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        // A reading viewport can release/acquire an interaction lease during
        // layout. Apply policy now, but notify dashboard widgets after build
        // so a sibling ValueListenableBuilder is never dirtied mid-frame.
        _displayTimer = Timer(Duration.zero, publish);
      } else {
        publish();
      }
    } else {
      _displayTimer = Timer(Duration(milliseconds: 1000 - elapsed), publish);
    }
  }

  Future<InferenceResourceSession> openSession() async {
    _leases++;
    try {
      await (_starting ??= _start());
      return InferenceResourceSession(
        _governor!,
        onClose: _release,
        refreshSnapshot: () => _sample(_generation, force: true),
        onBudget: reportBudget,
      );
    } catch (_) {
      await _release();
      rethrow;
    }
  }

  Future<void> _start() async {
    final generation = ++_generation;
    _probe = _createProbe();
    try {
      _binding = WidgetsBinding.instance;
    } catch (_) {
      _binding = null;
    }
    _foreground =
        _binding?.lifecycleState == null ||
        _binding?.lifecycleState == AppLifecycleState.resumed;
    _binding?.addObserver(this);
    _binding?.addTimingsCallback(_timings);
    UiInteractionBudget.instance.addListener(_interactionChanged);
    try {
      await _probe!.start();
      _urgent = _probe!.urgent.listen(
        (event) {
          if (generation != _generation) return;
          final pressure = ResourceMemoryPressure.values
              .where((p) => p.name == event['memoryPressure'])
              .firstOrNull;
          if (pressure != null && pressure != ResourceMemoryPressure.normal) {
            _pressure = pressure;
            _pressureUntil = DateTime.now().add(const Duration(seconds: 10));
            final old = _governor?.snapshot;
            if (old != null) _governor?.update(_experience(old));
          }
          unawaited(_sample(generation, force: true));
        },
        onError: (Object _) {
          /* Missing/older platform keeps polling. */
        },
      );
    } catch (_) {
      /* Snapshot reading may still work on older hosts. */
    }
    await _sample(generation);
    _governor ??= InferenceResourceGovernor(_unknown());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _lastFrames = _frames;
      _lastFraction = _frames == 0 ? 0 : _slow / _frames;
      _frames = _slow = 0;
      _window++;
      unawaited(_sample(generation));
    });
  }

  DeviceResourceSnapshot _unknown() => DeviceResourceSnapshot(
    platform: Platform.operatingSystem,
    processors: Platform.numberOfProcessors,
    capturedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
  DeviceResourceSnapshot _experience(DeviceResourceSnapshot s) => s.experience(
    foreground: _foreground,
    playing: InferencePlaybackActivity.playing?.call() ?? false,
    interacting: UiInteractionBudget.instance.isActive,
    slowFrameFraction: _lastFraction,
    frameCount: _lastFrames,
    frameWindow: _window,
    pressure: _pressureUntil?.isAfter(DateTime.now()) == true
        ? _pressure
        : null,
  );

  void _interactionChanged() {
    final current = _governor?.snapshot;
    if (current != null) _governor?.update(_experience(current));
  }

  Future<void> _sample(int generation, {bool force = false}) async {
    if (generation != _generation) return;
    if (_sampling != null) {
      await _sampling!.future;
      if (force && generation == _generation) await _sample(generation);
      return;
    }
    final sampling = _sampling = Completer<void>();
    try {
      DeviceResourceSnapshot snapshot;
      try {
        snapshot = await _probe!.read(InferenceProcessRegistry.instance.pids);
      } catch (_) {
        snapshot = _governor?.snapshot ?? _unknown();
      }
      if (generation != _generation) return;
      snapshot = _experience(snapshot);
      if (_governor == null) {
        _governor = InferenceResourceGovernor(snapshot);
      } else {
        _governor!.update(snapshot);
      }
    } finally {
      if (identical(_sampling, sampling)) _sampling = null;
      sampling.complete();
    }
  }

  void _timings(List<FrameTiming> frames) {
    final rate =
        _binding?.platformDispatcher.views.firstOrNull?.display.refreshRate ??
        60;
    final micros = 1000000 / (rate > 0 ? rate : 60);
    for (final frame in frames) {
      _frames++;
      if (frame.buildDuration.inMicroseconds > micros ||
          frame.rasterDuration.inMicroseconds > micros) {
        _slow++;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    final s = _governor?.snapshot;
    if (s != null) _governor?.update(_experience(s));
  }

  @override
  void didHaveMemoryPressure() {
    _pressure = ResourceMemoryPressure.critical;
    _pressureUntil = DateTime.now().add(const Duration(seconds: 10));
    final s = _governor?.snapshot;
    if (s != null) _governor?.update(_experience(s));
  }

  Future<void> _release() async {
    if (_leases == 0 || --_leases != 0) return;
    _generation++;
    _displayTimer?.cancel();
    _displayTimer = null;
    _pendingDisplay = null;
    budget.value = null;
    _timer?.cancel();
    _timer = null;
    _binding?.removeTimingsCallback(_timings);
    UiInteractionBudget.instance.removeListener(_interactionChanged);
    _binding?.removeObserver(this);
    _binding = null;
    await _urgent?.cancel();
    _urgent = null;
    await _probe?.close();
    _probe = null;
    _governor = null;
    _starting = null;
    _pressure = null;
    _pressureUntil = null;
    _frames = _slow = _lastFrames = _window = 0;
    _lastFraction = 0;
  }
}
