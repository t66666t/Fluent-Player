import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../utils/android_hardware_input_bridge.dart';
import '../utils/tooltip_hover_policy.dart';

/// Listens to every pointer without participating in hit tests.
///
/// Press dismisses a visible hover tooltip. An active touch also marks hover
/// as suppressed so a parked mouse cursor cannot immediately show it again.
class TooltipInteractionGuard extends StatefulWidget {
  const TooltipInteractionGuard({super.key, required this.child});

  final Widget child;

  @override
  State<TooltipInteractionGuard> createState() =>
      _TooltipInteractionGuardState();
}

class _TooltipInteractionGuardState extends State<TooltipInteractionGuard> {
  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    TooltipHoverPolicy.clear();
    super.dispose();
  }

  void _onPointer(PointerEvent event) {
    TooltipHoverPolicy.observe(event);
    if (event is PointerDownEvent) {
      Tooltip.dismissAllToolTips();
      if (TooltipHoverPolicy.isTouchLike(event.kind)) {
        // After this down event, so a hover-exit cannot hide controls before
        // the finger is recorded as the active pointer.
        scheduleMicrotask(AndroidHardwareInputBridge.releaseParkedNativeMice);
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
