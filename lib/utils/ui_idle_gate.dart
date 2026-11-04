import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Allows optional warmup work between frames, after gestures and animations.
/// It observes existing frames instead of polling or requesting extra frames.
class UiIdleGate with WidgetsBindingObserver {
  UiIdleGate({this.quietPeriod = const Duration(milliseconds: 120)}) {
    _binding.addObserver(this);
    _binding.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  final Duration quietPeriod;
  final WidgetsBinding _binding = WidgetsBinding.instance;
  final Set<int> _pointers = {};
  final List<Completer<bool>> _waiting = [];
  Timer? _quiet;
  bool _scheduled = false;
  bool _waitingForFrame = false;
  bool _disposed = false;

  bool get _blocked =>
      _disposed ||
      _pointers.isNotEmpty ||
      _quiet != null ||
      (_binding.lifecycleState != null &&
          _binding.lifecycleState != AppLifecycleState.resumed);

  /// False means the owner was disposed. Callers can abandon the remaining
  /// warmup without touching a removed overlay or a stale widget context.
  Future<bool> waitUntilIdle() {
    if (_disposed) return Future.value(false);
    final done = Completer<bool>();
    _waiting.add(done);
    _schedule();
    return done.future;
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent || event is PointerPanZoomStartEvent) {
      _pointers.add(event.pointer);
    } else if (event is PointerUpEvent ||
        event is PointerCancelEvent ||
        event is PointerPanZoomEndEvent ||
        event is PointerRemovedEvent) {
      _pointers.remove(event.pointer);
    }
    _markInteraction();
  }

  bool _onKey(KeyEvent event) {
    _markInteraction();
    return false;
  }

  void _markInteraction() {
    _quiet?.cancel();
    _quiet = Timer(quietPeriod, () {
      _quiet = null;
      _schedule();
    });
  }

  void _schedule() {
    if (_blocked || _scheduled || _waiting.isEmpty) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_blocked || _waiting.isEmpty) return;
      if (_binding.hasScheduledFrame ||
          _binding.schedulerPhase != SchedulerPhase.idle ||
          _binding.transientCallbackCount != 0) {
        if (!_waitingForFrame) {
          _waitingForFrame = true;
          _binding.addPostFrameCallback((_) {
            _waitingForFrame = false;
            _schedule();
          });
        }
        return;
      }
      final pending = List<Completer<bool>>.of(_waiting);
      _waiting.clear();
      for (final done in pending) {
        done.complete(true);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _pointers.clear();
    _schedule();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _quiet?.cancel();
    _quiet = null;
    _binding.removeObserver(this);
    _binding.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    for (final done in _waiting) {
      done.complete(false);
    }
    _waiting.clear();
  }
}
