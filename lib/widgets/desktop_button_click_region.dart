import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Gives ordinary desktop buttons release-inside click semantics. The native
/// button still owns activation, keyboard input, semantics and disabled state.
/// Do not use this for sliders, draggable items or selectable text.
class DesktopButtonClickRegion extends StatelessWidget {
  const DesktopButtonClickRegion({
    super.key,
    required this.child,
    this.enabled,
  });

  final Widget child;
  final bool? enabled;

  // Keep keyed buttons stable in lists without registering their GlobalKey
  // twice or moving that key away from the original button.
  @override
  Key? get key =>
      super.key ?? (child.key == null ? null : ValueKey<Key>(child.key!));

  static final _pressedButtons = <int, Object>{};

  /// A drag source must not claim presses that started on a child button.
  static bool ownsPointer(int pointer) => _pressedButtons.containsKey(pointer);

  bool get _enabled {
    if (enabled != null) return enabled!;
    if (child is ButtonStyleButton) return (child as ButtonStyleButton).enabled;
    if (child is IconButton) return (child as IconButton).onPressed != null;
    if (child is SimpleDialogOption) {
      return (child as SimpleDialogOption).onPressed != null;
    }
    if (child is DropdownButton<dynamic>) {
      // Reading a contravariant callback through DropdownButton<dynamic>
      // inserts a runtime cast that rejects callbacks such as (int?) => void.
      // Only inspect nullness; never invoke or widen the typed callback.
      final dynamic dropdown = child;
      return dropdown.onChanged != null &&
          (dropdown.items?.isNotEmpty ?? false);
    }
    if (child is InkResponse) {
      final ink = child as InkResponse;
      return ink.onTap != null ||
          ink.onDoubleTap != null ||
          ink.onLongPress != null;
    }
    if (child is PopupMenuButton<dynamic>) {
      return (child as PopupMenuButton<dynamic>).enabled;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // A control with its own long-press action keeps native arbitration.
    if (child is ButtonStyleButton &&
            (child as ButtonStyleButton).onLongPress != null ||
        child is InkResponse &&
            ((child as InkResponse).onLongPress != null ||
                (child as InkResponse).onDoubleTap != null)) {
      final original = _OriginalButtonGestureSettings.maybeOf(context);
      return original == null
          ? child
          : MediaQuery(
              data: MediaQuery.of(context).copyWith(gestureSettings: original),
              child: child,
            );
    }
    return switch (Theme.of(context).platform) {
      TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux =>
        _DesktopButtonBoundary(enabled: _enabled, child: child),
      _ => child,
    };
  }
}

class _DesktopButtonBoundary extends StatefulWidget {
  const _DesktopButtonBoundary({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_DesktopButtonBoundary> createState() => _DesktopButtonBoundaryState();
}

class _DesktopButtonBoundaryState extends State<_DesktopButtonBoundary> {
  late final _ButtonBoundaryRecognizer _boundary = _ButtonBoundaryRecognizer();
  int? _pointer;
  bool _pressedEnabled = false;

  void _down(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton ||
        _pointer != null ||
        DesktopButtonClickRegion.ownsPointer(event.pointer)) {
      return;
    }
    _pointer = event.pointer;
    _pressedEnabled = widget.enabled;
    DesktopButtonClickRegion._pressedButtons[event.pointer] = this;
    _boundary
      ..touchSlop =
          _OriginalButtonGestureSettings.maybeOf(context)?.touchSlop ??
          MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ??
          kTouchSlop
      ..addPointer(event);
  }

  void _up(PointerUpEvent event) {
    if (_pointer != event.pointer) return;
    var inputAllowed = ModalRoute.of(context)?.isCurrent ?? true;
    context.visitAncestorElements((element) {
      final ancestor = element.widget;
      if (ancestor is IgnorePointer && ancestor.ignoring ||
          ancestor is AbsorbPointer && ancestor.absorbing ||
          ancestor is Offstage && ancestor.offstage) {
        inputAllowed = false;
        return false;
      }
      return true;
    });
    final box = context.findRenderObject() as RenderBox?;
    final inside =
        inputAllowed &&
        mounted &&
        box != null &&
        box.hasSize &&
        (Offset.zero & box.size).contains(box.globalToLocal(event.position));
    // Listener runs before native recognizers see pointer-up. Rejecting a
    // release outside here cannot race their onTap or fire another callback.
    _boundary.finish(
      event,
      inside: inside && _pressedEnabled && widget.enabled,
    );
    _clear();
  }

  void _cancel(PointerCancelEvent event) {
    if (_pointer == event.pointer) _clear();
  }

  void _clear() {
    final pointer = _pointer;
    if (pointer != null &&
        identical(DesktopButtonClickRegion._pressedButtons[pointer], this)) {
      DesktopButtonClickRegion._pressedButtons.remove(pointer);
    }
    _pointer = null;
    _pressedEnabled = false;
  }

  @override
  void didUpdateWidget(covariant _DesktopButtonBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child.runtimeType != widget.child.runtimeType ||
        oldWidget.child.key != widget.child.key ||
        oldWidget.enabled && !widget.enabled) {
      _boundary.cancelPress();
      _clear();
    }
  }

  @override
  void dispose() {
    _boundary.cancelPress();
    _clear();
    _boundary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final original =
        _OriginalButtonGestureSettings.maybeOf(context) ??
        media.gestureSettings;
    return _OriginalButtonGestureSettings(
      settings: original,
      child: MediaQuery(
        data: media.copyWith(
          gestureSettings: const DeviceGestureSettings(
            touchSlop: double.infinity,
          ),
        ),
        child: Listener(
          onPointerDown: _down,
          onPointerUp: _up,
          onPointerCancel: _cancel,
          child: widget.child,
        ),
      ),
    );
  }
}

class _OriginalButtonGestureSettings extends InheritedWidget {
  const _OriginalButtonGestureSettings({
    required this.settings,
    required super.child,
  });

  final DeviceGestureSettings settings;

  static DeviceGestureSettings? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_OriginalButtonGestureSettings>()
      ?.settings;

  @override
  bool updateShouldNotify(_OriginalButtonGestureSettings oldWidget) =>
      settings != oldWidget.settings;
}

/// Only vetoes invalid clicks. It never invokes the button's action and gives
/// up when scrolling, dragging or a long press wins the native gesture arena.
class _ButtonBoundaryRecognizer extends OneSequenceGestureRecognizer {
  int? _pointer;
  Offset _origin = Offset.zero;
  double touchSlop = kTouchSlop;
  double _maxTravel = 0;
  bool _lost = false;

  void cancelPress() {
    final pointer = _pointer;
    if (pointer == null) return;
    if (!_lost) resolve(GestureDisposition.accepted);
    stopTrackingPointer(pointer);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointer = event.pointer;
    _origin = event.position;
    _maxTravel = 0;
    _lost = false;
    startTrackingPointer(event.pointer, event.transform);
  }

  void finish(PointerUpEvent event, {required bool inside}) {
    if (_lost || _pointer != event.pointer) return;
    final moved =
        _maxTravel > touchSlop ||
        (event.position - _origin).distance > touchSlop;
    resolve(
      !inside || event.kind != PointerDeviceKind.mouse && moved
          ? GestureDisposition.accepted
          : GestureDisposition.rejected,
    );
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      final travel = (event.position - _origin).distance;
      if (travel > _maxTravel) _maxTravel = travel;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    if (_pointer == pointer) _lost = true;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    resolve(GestureDisposition.rejected);
    _pointer = null;
  }

  @override
  String get debugDescription => 'desktop button boundary';
}
