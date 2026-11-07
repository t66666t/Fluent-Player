import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../services/app_haptics.dart';
import 'desktop_button_click_region.dart';

/// Buttons inside a draggable card keep their own pointer sequence.
class ButtonAwareDraggable<T extends Object> extends Draggable<T> {
  const ButtonAwareDraggable({
    super.key,
    required super.data,
    required super.feedback,
    required super.child,
    super.childWhenDragging,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDragEnd,
    super.rootOverlay,
    super.feedbackOffset,
    super.allowedButtonsFilter,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      _ButtonAwareImmediateDrag(allowedButtonsFilter: allowedButtonsFilter)
        ..onStart = onStart;
}

class ButtonAwareLongPressDraggable<T extends Object>
    extends LongPressDraggable<T> {
  const ButtonAwareLongPressDraggable({
    super.key,
    required super.data,
    required super.feedback,
    required super.child,
    super.childWhenDragging,
    super.delay,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDragEnd,
    super.rootOverlay,
    super.feedbackOffset,
    super.hapticFeedbackOnStart,
    super.allowedButtonsFilter,
  });

  @override
  DelayedMultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      _ButtonAwareDelayedDrag(
          delay: delay,
          allowedButtonsFilter: allowedButtonsFilter,
        )
        ..onStart = (position) {
          final drag = onStart(position);
          if (drag != null && hapticFeedbackOnStart) {
            AppHaptics.pulse();
          }
          return drag;
        };
}

class ButtonAwareReorderableDragStartListener
    extends ReorderableDragStartListener {
  const ButtonAwareReorderableDragStartListener({
    super.key,
    required super.child,
    required super.index,
    super.enabled,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() => _ButtonAwareImmediateDrag();
}

class ButtonAwareReorderableDelayedDragStartListener
    extends ReorderableDelayedDragStartListener {
  const ButtonAwareReorderableDelayedDragStartListener({
    super.key,
    required super.child,
    required super.index,
    super.enabled,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() => _ButtonAwareDelayedDrag();
}

class _ButtonAwareImmediateDrag extends ImmediateMultiDragGestureRecognizer {
  _ButtonAwareImmediateDrag({super.allowedButtonsFilter});

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      !DesktopButtonClickRegion.ownsPointer(event.pointer) &&
      super.isPointerAllowed(event);
}

class _ButtonAwareDelayedDrag extends DelayedMultiDragGestureRecognizer {
  _ButtonAwareDelayedDrag({super.delay, super.allowedButtonsFilter});

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      !DesktopButtonClickRegion.ownsPointer(event.pointer) &&
      super.isPointerAllowed(event);
}
