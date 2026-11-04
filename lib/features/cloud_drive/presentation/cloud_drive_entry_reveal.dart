import 'package:flutter/material.dart';

import '../../../widgets/cached_thumbnail_widget.dart';
import '../../../widgets/visibility_input_gate.dart';

/// Reveals complete cells, including folders and covers still being fetched.
class CloudDriveEntryReveal extends StatefulWidget {
  const CloudDriveEntryReveal({
    super.key,
    required this.index,
    required this.columns,
    required this.revealed,
    required this.onRevealed,
    required this.child,
  });

  final int index, columns;
  final bool revealed;
  final VoidCallback onRevealed;
  final Widget child;

  @override
  State<CloudDriveEntryReveal> createState() => _CloudDriveEntryRevealState();
}

class _CloudDriveEntryRevealState extends State<CloudDriveEntryReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late CurvedAnimation _opacity;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // A parked entry can be removed before its entrance ever starts. Creating
    // the ticker in dispose would then look up an already-deactivated context.
    _controller = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onRevealed();
      });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      if (widget.revealed || MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1;
      }
      return;
    }
    if (!TickerMode.valuesOf(context).enabled) return;
    _started = true;
    final delay = mediaCoverRevealDelay(
      index: widget.index,
      crossAxisCount: widget.columns,
    );
    const fade = Duration(milliseconds: 280);
    _controller.duration = delay + fade;
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Interval(
        delay.inMicroseconds / (delay + fade).inMicroseconds,
        1,
        curve: Curves.easeOutCubic,
      ),
    );
    if (widget.revealed || MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    if (_started) _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opacity = _started ? _opacity : const AlwaysStoppedAnimation(0.0);
    return FadeTransition(
      opacity: opacity,
      child: FadeInputGate(
        opacity: opacity,
        child: AnimatedBuilder(
          animation: opacity,
          child: widget.child,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, 6 * (1 - opacity.value)),
            child: child,
          ),
        ),
      ),
    );
  }
}
