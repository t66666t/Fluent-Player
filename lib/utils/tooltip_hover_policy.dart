import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// App-wide hover-tooltip timing. Material 3 defaults to zero delay, which
/// makes labels pop the instant a pointer crosses a button.
const Duration kAppTooltipWaitDuration = Duration(milliseconds: 700);

/// Tracks whether a finger/stylus is currently down so leftover mouse hover
/// cannot keep driving Tooltips or the Android synthetic-hover fallback.
class TooltipHoverPolicy {
  TooltipHoverPolicy._();

  /// A parked cursor keeps reporting the same point. Ignore that until the
  /// mouse actually travels, so a finger gesture is not undone by leftover hover.
  static const double hoverResumeSlop = 8;

  static final Set<int> _touchPointers = <int>{};
  static Offset? _lastHoverPosition;
  static bool _deferHoverUntilMove = false;

  static bool get suppressSyntheticHover =>
      _touchPointers.isNotEmpty || _deferHoverUntilMove;

  static bool isTouchLike(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch ||
        kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  /// False while a finger is down, and afterwards until the cursor leaves the
  /// position it had when the finger took over.
  static bool acceptHover(Offset position) {
    if (_touchPointers.isNotEmpty) {
      _lastHoverPosition = position;
      return false;
    }
    if (_deferHoverUntilMove) {
      final last = _lastHoverPosition;
      if (last != null && (last - position).distance <= hoverResumeSlop) {
        return false;
      }
      _deferHoverUntilMove = false;
    }
    _lastHoverPosition = position;
    return true;
  }

  static void observe(PointerEvent event) {
    if (!isTouchLike(event.kind)) return;
    if (event is PointerDownEvent) {
      _touchPointers.add(event.pointer);
      _deferHoverUntilMove = true;
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _touchPointers.remove(event.pointer);
    }
  }

  static void clear() {
    _touchPointers.clear();
    _lastHoverPosition = null;
    _deferHoverUntilMove = false;
  }

  @visibleForTesting
  static void resetForTesting() => clear();
}
