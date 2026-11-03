import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

/// Blends the first decoded frame over its placeholder without changing the
/// slot's geometry. Cached frames are immediate; subsequent image frames keep
/// the same animation state instead of restarting the fade.
class BilibiliImageReveal extends StatefulWidget {
  const BilibiliImageReveal({
    super.key,
    required this.ready,
    required this.synchronous,
    required this.placeholder,
    required this.child,
  });

  final bool ready;
  final bool synchronous;
  final Widget placeholder;
  final Widget child;

  @override
  State<BilibiliImageReveal> createState() => _BilibiliImageRevealState();
}

class _BilibiliImageRevealState extends State<BilibiliImageReveal>
    with SingleTickerProviderStateMixin {
  final Duration _startedAt = SchedulerBinding.instance.currentFrameTimeStamp;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.ready ? 1 : 0,
  );
  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = widget.ready ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(BilibiliImageReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.ready) {
      _controller.value = 0;
    } else if (!oldWidget.ready) {
      // ScopedNetworkImage resolves its policy asynchronously even for a
      // memory-cache hit. Frames available in the same frame need no reveal.
      final waited =
          SchedulerBinding.instance.currentFrameTimeStamp - _startedAt;
      if (widget.synchronous ||
          waited <= const Duration(milliseconds: 16) ||
          MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1;
      } else {
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _fade,
    builder: (context, child) => Stack(
      fit: StackFit.expand,
      children: [
        if (!_controller.isCompleted) widget.placeholder,
        Opacity(opacity: _fade.value, child: child),
      ],
    ),
    child: RepaintBoundary(child: widget.child),
  );
}
