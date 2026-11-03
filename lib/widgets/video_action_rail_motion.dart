import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// One bounded, non-bouncing motion for the rail, arrow, surface, and caption.
class VideoActionRailMotion extends AnimationController {
  VideoActionRailMotion({required super.vsync, required bool expanded})
    : _expanded = expanded,
      super(
        value: expanded ? 1 : 0,
        animationBehavior: AnimationBehavior.preserve,
        debugLabel: 'video action rail',
      );

  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 900,
    damping: 60,
  );

  bool _expanded;

  void setExpanded(bool expanded, {bool animate = true}) {
    final target = expanded ? 1.0 : 0.0;
    if (!animate) {
      _expanded = expanded;
      stop();
      if (value != target) value = target;
      return;
    }
    if (_expanded == expanded) return;
    _expanded = expanded;
    // Preserve velocity during interruption, instead of restarting an easing
    // curve. A small initial impulse makes a fresh tap respond immediately.
    final initialVelocity = isAnimating ? velocity : (expanded ? 7.0 : -7.0);
    final simulation = SpringSimulation(
      _spring,
      value,
      target,
      initialVelocity,
      snapToEnd: true,
      tolerance: const Tolerance(distance: 0.001, velocity: 0.02),
    );
    if (expanded) {
      animateWith(simulation);
    } else {
      animateBackWith(simulation);
    }
  }
}

/// Rebuilds at input/endpoints only; consumers listen directly for paint ticks.
class VideoActionRailMotionBuilder extends StatefulWidget {
  const VideoActionRailMotionBuilder({
    super.key,
    required this.collapsed,
    required this.builder,
  });

  final bool collapsed;
  final Widget Function(
    BuildContext context,
    Animation<double> progress,
    bool retainActions,
  )
  builder;

  @override
  State<VideoActionRailMotionBuilder> createState() =>
      _VideoActionRailMotionBuilderState();
}

class _VideoActionRailMotionBuilderState
    extends State<VideoActionRailMotionBuilder>
    with SingleTickerProviderStateMixin {
  late final VideoActionRailMotion _motion;
  late bool _retainActions;
  bool _animate = true;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _retainActions = !widget.collapsed;
    _motion = VideoActionRailMotion(vsync: this, expanded: !widget.collapsed)
      ..addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed ||
        !widget.collapsed ||
        !_retainActions) {
      return;
    }
    if (_syncing) {
      _retainActions = false;
    } else {
      setState(() => _retainActions = false);
    }
  }

  void _sync() {
    _syncing = true;
    if (!widget.collapsed) _retainActions = true;
    _motion.setExpanded(!widget.collapsed, animate: _animate);
    if (!_animate) _retainActions = !widget.collapsed;
    _syncing = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(VideoActionRailMotionBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.collapsed != oldWidget.collapsed) _sync();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _motion, _retainActions);

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }
}
