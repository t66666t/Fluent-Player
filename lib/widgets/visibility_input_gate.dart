import 'package:flutter/widgets.dart';

/// Hides input together with a surface without changing layout or painting.
class VisibilityInputGate extends StatelessWidget {
  const VisibilityInputGate({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !enabled,
    child: ExcludeFocus(
      excluding: !enabled,
      child: ExcludeSemantics(excluding: !enabled, child: child),
    ),
  );
}

/// Opacity alone does not disable hit testing or keyboard focus. Listen only
/// for changes between zero and nonzero painted alpha, retaining the child
/// throughout the fade instead of rebuilding it on every animation frame.
class FadeInputGate extends StatefulWidget {
  const FadeInputGate({
    super.key,
    required this.opacity,
    required this.child,
    this.enabled = true,
  });

  final Animation<double> opacity;
  final bool enabled;
  final Widget child;

  @override
  State<FadeInputGate> createState() => _FadeInputGateState();
}

class _FadeInputGateState extends State<FadeInputGate> {
  late bool _painted;
  bool get _hasPaint => (widget.opacity.value * 255).round() > 0;

  @override
  void initState() {
    super.initState();
    _painted = _hasPaint;
    widget.opacity.addListener(_updatePaint);
  }

  @override
  void didUpdateWidget(FadeInputGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.opacity != widget.opacity) {
      oldWidget.opacity.removeListener(_updatePaint);
      widget.opacity.addListener(_updatePaint);
    }
    _painted = _hasPaint;
  }

  void _updatePaint() {
    final painted = _hasPaint;
    if (painted != _painted) setState(() => _painted = painted);
  }

  @override
  void dispose() {
    widget.opacity.removeListener(_updatePaint);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => VisibilityInputGate(
    enabled: widget.enabled && _painted,
    child: widget.child,
  );
}
