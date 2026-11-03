import 'package:flutter/material.dart';

const livePageTransitionDuration = Duration(milliseconds: 260);
const livePageReverseTransitionDuration = Duration(milliseconds: 200);
const livePageOpacityEnd = 0.32;

/// The live fade and subtle scale used by video playback and page navigation.
/// No page capture, translation or layout animation is involved.
class LivePageTransition extends StatefulWidget {
  const LivePageTransition({
    super.key,
    required this.animation,
    required this.child,
    this.backgroundColor,
    this.filterQuality,
  });

  final Animation<double> animation;
  final Widget child;

  /// Folder navigation can stop painting the previous grid once this stationary
  /// full-viewport background is opaque, including the scaled page's edges.
  /// Players keep their existing live texture composition without this fill.
  final Color? backgroundColor;

  /// Complex grids may reuse a live bitmap layer while scaling. Flutter drops
  /// this filter when motion ends; child updates still invalidate its contents.
  /// Keep null for native video textures and platform views.
  final FilterQuality? filterQuality;

  @override
  State<LivePageTransition> createState() => _LivePageTransitionState();
}

class _LivePageTransitionState extends State<LivePageTransition> {
  late CurvedAnimation _progress;
  late CurvedAnimation _opacity;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _createAnimations();
  }

  void _createAnimations() {
    // Retain the displayed curve when Back interrupts entry.
    _progress = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    // This is the playback curve: alpha blending ends after the first 83 ms,
    // avoiding a translucent offscreen layer for the whole transition.
    _opacity = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, livePageOpacityEnd, curve: Curves.easeOutCubic),
      reverseCurve: Curves.easeInCubic,
    );
    _scale = Tween<double>(begin: 0.985, end: 1).animate(_progress);
  }

  @override
  void didUpdateWidget(LivePageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _progress.dispose();
      _opacity.dispose();
      _createAnimations();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    const settled = AlwaysStoppedAnimation<double>(1);
    final page = ScaleTransition(
      scale: reduced ? settled : _scale,
      filterQuality: reduced ? null : widget.filterQuality,
      child: RepaintBoundary(child: widget.child),
    );
    // Keep the same subtree when the system motion preference changes.
    return FadeTransition(
      opacity: reduced ? settled : _opacity,
      child: widget.backgroundColor == null
          ? page
          : ColoredBox(color: widget.backgroundColor!, child: page),
    );
  }
}
