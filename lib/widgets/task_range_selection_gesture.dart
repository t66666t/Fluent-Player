import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Owns a checkbox drag above the scrolling list, so recycling its starting
/// row cannot lose the pointer-up event or leave edge scrolling running.
class TaskRangeSelectionGestureRecognizer extends OneSequenceGestureRecognizer {
  bool Function(Offset position)? canStart;
  ValueChanged<Offset>? onStart;
  ValueChanged<Offset>? onUpdate;
  VoidCallback? onEnd;
  int? _pointer;
  final _extraPointers = <int>{};

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      event.buttons == kPrimaryButton &&
      (_pointer != null || (canStart?.call(event.position) ?? false)) &&
      super.isPointerAllowed(event);

  // A second finger or secondary mouse button must not reject the first drag.
  @override
  void handleNonAllowedPointer(PointerDownEvent event) {}

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) {
      // Consume other fingers inside the viewport without changing the active
      // range or letting their row taps/scroll gestures change its snapshot.
      _extraPointers.add(event.pointer);
      startTrackingPointer(event.pointer, event.transform);
      resolvePointer(event.pointer, GestureDisposition.accepted);
      return;
    }
    _pointer = event.pointer;
    startTrackingPointer(event.pointer, event.transform);
    resolvePointer(event.pointer, GestureDisposition.accepted);
    if (_pointer == event.pointer) onStart?.call(event.position);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) {
      if ((event is PointerUpEvent || event is PointerCancelEvent) &&
          _extraPointers.remove(event.pointer)) {
        stopTrackingPointer(event.pointer);
      }
      return;
    }
    if (event is PointerMoveEvent) {
      onUpdate?.call(event.position);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _finish(event.pointer);
    }
  }

  void _finish(int pointer) {
    if (_pointer != pointer) return;
    _pointer = null;
    stopTrackingPointer(pointer);
    onEnd?.call();
  }

  /// Release input ownership when the host is cancelled or loses activation.
  /// A release outside an inactive window may never arrive at this recognizer.
  void cancelTracking() {
    final pointers = <int>[?_pointer, ..._extraPointers];
    _pointer = null;
    _extraPointers.clear();
    for (final pointer in pointers) {
      stopTrackingPointer(pointer);
    }
    resolve(GestureDisposition.rejected);
  }

  @override
  void rejectGesture(int pointer) {
    if (_extraPointers.remove(pointer)) {
      stopTrackingPointer(pointer);
    } else {
      _finish(pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'task checkbox range selection';
}
