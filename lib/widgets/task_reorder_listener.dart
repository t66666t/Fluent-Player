import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// The entire task, including its actions, can be held to pick it up. Short
/// presses still belong to child buttons and movement before the hold scrolls.
class TaskReorderListener extends ReorderableDragStartListener {
  const TaskReorderListener({
    super.key,
    required super.index,
    required super.child,
    required this.onCancel,
  });

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) =>
      Listener(onPointerCancel: (_) => onCancel(), child: super.build(context));

  @override
  MultiDragGestureRecognizer createRecognizer() => _TaskHoldRecognizer();
}

class _TaskHoldRecognizer extends MultiDragGestureRecognizer {
  _TaskHoldRecognizer()
    : super(
        debugOwner: TaskReorderListener,
        allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
      );

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _TaskHoldPointer(event.position, event.kind, gestureSettings);

  @override
  String get debugDescription => 'task hold to reorder';
}

class _TaskHoldPointer extends MultiDragPointerState {
  _TaskHoldPointer(super.initialPosition, super.kind, super.gestureSettings) {
    _timer = Timer(const Duration(milliseconds: 350), _holdCompleted);
  }

  Timer? _timer;
  GestureMultiDragStartCallback? _starter;
  bool _cancelled = false;

  // Flutter's default delayed mouse drag cancels after just 1 logical pixel.
  // Allow small hand movement while holding; retain platform touch slop so a
  // deliberate swipe continues to scroll before the hold is accepted.
  double get _slop => kind == PointerDeviceKind.mouse
      ? 8
      : computeHitSlop(kind, gestureSettings);

  void _holdCompleted() {
    _timer = null;
    if (_cancelled) return;
    final starter = _starter;
    _starter = null;
    if (starter != null) {
      starter(initialPosition);
    } else {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void checkForResolutionAfterMove() {
    if (_timer == null || pendingDelta!.distance <= _slop) return;
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    _starter = null;
    resolve(GestureDisposition.rejected);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    if (_cancelled) return;
    if (_timer == null) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _starter = null;
    super.dispose();
  }
}
