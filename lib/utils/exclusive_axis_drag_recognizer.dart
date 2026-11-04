import 'package:flutter/gestures.dart';

/// Horizontal drag that cannot keep an unfinished contact alive.
///
/// [HorizontalDragGestureRecognizer] immediately accepts every later pointer
/// once one drag has won. If that first pointer's up/cancel is dropped — a
/// second finger, palm rejection, or a system gesture — the recognizer stays
/// accepted and wins every future tap, so the player can neither seek nor
/// reveal its controls. A new contact therefore closes the previous one first.
class ExclusiveHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  ExclusiveHorizontalDragGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
  });

  int? _exclusivePointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _exclusivePointer = _releaseStalePointer(
      recognizer: this,
      tracked: _exclusivePointer,
      next: event.pointer,
    );
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    _clearExclusivePointer(event);
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    if (pointer == _exclusivePointer) {
      _exclusivePointer = null;
    }
  }

  void _clearExclusivePointer(PointerEvent event) {
    if (event.pointer == _exclusivePointer &&
        (event is PointerUpEvent || event is PointerCancelEvent)) {
      _exclusivePointer = null;
    }
  }
}

/// Vertical counterpart of [ExclusiveHorizontalDragGestureRecognizer].
class ExclusiveVerticalDragGestureRecognizer
    extends VerticalDragGestureRecognizer {
  ExclusiveVerticalDragGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
  });

  int? _exclusivePointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _exclusivePointer = _releaseStalePointer(
      recognizer: this,
      tracked: _exclusivePointer,
      next: event.pointer,
    );
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (event.pointer == _exclusivePointer &&
        (event is PointerUpEvent || event is PointerCancelEvent)) {
      _exclusivePointer = null;
    }
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    if (pointer == _exclusivePointer) {
      _exclusivePointer = null;
    }
  }
}

/// Closes [tracked] before [next] joins, and returns the pointer that should
/// now own the recognizer.
///
/// A synthetic up runs the normal end/cancel path, including clearing the
/// accepted-pointer list. [GestureRecognizer.stopTrackingPointer] alone leaves
/// that list behind, and the next reused pointer id asserts in debug.
int _releaseStalePointer({
  required DragGestureRecognizer recognizer,
  required int? tracked,
  required int next,
}) {
  if (tracked != null && tracked != next) {
    recognizer.handleEvent(
      PointerUpEvent(pointer: tracked, kind: PointerDeviceKind.touch),
    );
  }
  return next;
}
