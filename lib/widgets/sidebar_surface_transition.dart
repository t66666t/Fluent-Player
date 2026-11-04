import 'package:flutter/material.dart';

import 'sidebar_activity.dart';
import 'visibility_input_gate.dart';

/// Fades a stable panel element. A hidden surface keeps its state without
/// painting, ticking, taking focus, or participating in accessibility.
/// Unlike AnimatedSwitcher, reversing a transition never duplicates the child.
class SidebarSurfaceTransition extends StatefulWidget {
  const SidebarSurfaceTransition({
    super.key,
    required this.visible,
    required this.child,
    this.active = true,
    this.animateInitial = false,
    this.onHidden,
    this.opacity,
    this.transitionDuration = const Duration(milliseconds: 120),
  });

  static const duration = Duration(milliseconds: 120);

  final bool visible;
  final bool active;
  final bool animateInitial;
  final Widget child;
  final VoidCallback? onHidden;
  final Animation<double>? opacity;
  final Duration transitionDuration;

  @override
  State<SidebarSurfaceTransition> createState() =>
      _SidebarSurfaceTransitionState();
}

class _SidebarSurfaceTransitionState extends State<SidebarSurfaceTransition>
    with SingleTickerProviderStateMixin {
  AnimationController? _localOpacity;
  AnimationController get _local => _localOpacity ??= AnimationController(
    vsync: this,
    value: widget.visible && !widget.animateInitial ? 1 : 0,
  )..addStatusListener(_onStatus);
  Animation<double> get _opacity => widget.opacity ?? _local;
  bool _disableAnimations = false;
  bool _hiddenScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.opacity?.addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    _drive();
  }

  @override
  void didUpdateWidget(SidebarSurfaceTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.opacity != widget.opacity) {
      oldWidget.opacity?.removeStatusListener(_onStatus);
      widget.opacity?.addStatusListener(_onStatus);
    }
    if (oldWidget.visible != widget.visible ||
        oldWidget.active != widget.active ||
        oldWidget.opacity != widget.opacity) {
      _drive();
    }
  }

  void _drive() {
    final target = widget.visible ? 1.0 : 0.0;
    if (widget.opacity != null) {
      if (!widget.visible && _opacity.value == 0) _scheduleHidden();
      return;
    }
    if (_disableAnimations || !widget.active) {
      _local.value = target;
    } else if (_opacity.value != target) {
      // Continue from the displayed opacity when A -> B -> A is interrupted.
      final animate = widget.visible ? _local.animateTo : _local.animateBack;
      animate(
        target,
        duration: widget.transitionDuration * (_opacity.value - target).abs(),
        curve: Curves.easeOutCubic,
      );
    }
    if (!widget.visible && _opacity.isDismissed) _scheduleHidden();
  }

  void _onStatus(AnimationStatus status) {
    if (_opacity.value != 0 || widget.visible) return;
    setState(() {}); // Offstage only after the outgoing frame has faded.
    _scheduleHidden();
  }

  void _scheduleHidden() {
    if (_hiddenScheduled) return;
    _hiddenScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hiddenScheduled = false;
      if (mounted && !widget.visible && _opacity.isDismissed) {
        widget.onHidden?.call();
      }
    });
  }

  @override
  void dispose() {
    widget.opacity?.removeStatusListener(_onStatus);
    _localOpacity?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.visible && widget.active;
    return Offstage(
      offstage: !widget.visible && _opacity.isDismissed,
      child: FadeInputGate(
        enabled: active,
        opacity: _opacity,
        child: FadeTransition(
          opacity: _opacity,
          // The fade must finish even when the panel's tickers are paused.
          child: TickerMode(
            enabled: active,
            child: SidebarActivity(
              active: active,
              child: SidebarInteractionRegion(
                child: RepaintBoundary(child: widget.child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
