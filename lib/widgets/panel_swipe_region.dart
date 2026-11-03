import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Supplies one panel navigation gesture to its reading regions. A region
/// inside SelectionArea can recognize an unselected horizontal touch before
/// Flutter's touch-selection drag, while long presses and child controls keep
/// their normal gesture arena priority. Without a scope, regions are inert.
class PanelSwipeScope extends InheritedWidget {
  const PanelSwipeScope({
    super.key,
    required this.enabled,
    required this.canStart,
    required this.canContinue,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    required super.child,
  });

  final bool enabled;
  final bool Function(Offset globalPosition) canStart;
  final bool Function() canContinue;
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final ValueChanged<double> onEnd;
  final VoidCallback onCancel;

  @override
  bool updateShouldNotify(PanelSwipeScope oldWidget) => true;
}

class PanelSwipeRegion extends StatelessWidget {
  const PanelSwipeRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PanelSwipeScope>();
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        if (scope != null && scope.enabled)
          _PanelSwipeRecognizer:
              GestureRecognizerFactoryWithHandlers<_PanelSwipeRecognizer>(
                _PanelSwipeRecognizer.new,
                (recognizer) {
                  recognizer
                    ..canStart = scope.canStart
                    ..canContinue = scope.canContinue
                    ..onStart = scope.onStart
                    ..onUpdate = scope.onUpdate
                    ..onEnd = scope.onEnd
                    ..onCancel = scope.onCancel;
                },
              ),
      },
      child: child,
    );
  }
}

/// Only a single, clearly horizontal touch may page. Keep observing rejected
/// pointers until they all lift so a second finger cannot restart the gesture.
class _PanelSwipeRecognizer extends OneSequenceGestureRecognizer {
  _PanelSwipeRecognizer()
    : super(supportedDevices: const {PointerDeviceKind.touch});

  late bool Function(Offset globalPosition) canStart;
  late bool Function() canContinue;
  late VoidCallback onStart;
  late ValueChanged<double> onUpdate;
  late ValueChanged<double> onEnd;
  late VoidCallback onCancel;

  final Set<int> _pointers = {};
  PointerDownEvent? _down;
  VelocityTracker? _velocity;
  bool _eligible = false;
  bool _horizontal = false;
  bool _won = false;
  bool _started = false;
  double _reportedDx = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointers.add(event.pointer);
    super.addAllowedPointer(event);
    if (_pointers.length > 1) {
      _cancel();
      return;
    }
    _down = event;
    _eligible = canStart(event.position);
    _velocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    if (!_eligible) resolve(GestureDisposition.rejected);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _down;
    if (_eligible && down != null && event.pointer == down.pointer) {
      if (!canContinue()) {
        _cancel();
      } else if (event is PointerMoveEvent) {
        _velocity!.addPosition(event.timeStamp, event.position);
        final delta = event.position - down.position;
        if (!_horizontal) {
          final slop = computeHitSlop(event.kind, gestureSettings);
          if (event.timeStamp - down.timeStamp >= kLongPressTimeout ||
              delta.distance >= slop && delta.dx.abs() < delta.dy.abs() * 1.5) {
            _cancel();
          } else if (delta.dx.abs() > slop) {
            _horizontal = true;
            resolve(GestureDisposition.accepted);
          }
        }
        if (_eligible && _horizontal && _won) {
          if (!_started) {
            _started = true;
            onStart();
          }
          onUpdate(delta.dx - _reportedDx);
          _reportedDx = delta.dx;
        }
      } else if (event is PointerUpEvent && _started) {
        _velocity!.addPosition(event.timeStamp, event.position);
        _started = false;
        onEnd(_velocity!.getVelocity().pixelsPerSecond.dx);
      } else if (event is PointerCancelEvent) {
        _cancel();
      }
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointers.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  void _cancel() {
    _eligible = false;
    final started = _started;
    _started = false;
    resolve(GestureDisposition.rejected);
    if (started) onCancel();
  }

  @override
  void acceptGesture(int pointer) => _won = true;

  @override
  void rejectGesture(int pointer) => _cancel();

  @override
  void didStopTrackingLastPointer(int pointer) {
    resolve(GestureDisposition.rejected);
    _down = null;
    _velocity = null;
    _eligible = _horizontal = _won = _started = false;
    _reportedDx = 0;
  }

  @override
  String get debugDescription => 'panel swipe';
}
