import 'dart:async';

import 'package:flutter/material.dart';

enum _ReadingTransition { idle, fadingOut, settling, fadingIn }

/// A bounded distant transition using one live, selectable reading surface.
/// No viewport raster capture or duplicate interactive document is needed.
class TranscriptViewportMotion extends StatefulWidget {
  const TranscriptViewportMotion({
    super.key,
    required this.child,
    required this.enabled,
    this.onSettle,
    this.onActivityChanged,
    this.backgroundColor = const Color(0xFF1E1E1E),
  });

  final Widget child;
  final bool enabled;
  final VoidCallback? onSettle;
  final ValueChanged<bool>? onActivityChanged;
  final Color backgroundColor;

  @override
  State<TranscriptViewportMotion> createState() =>
      TranscriptViewportMotionState();
}

class TranscriptViewportMotionState extends State<TranscriptViewportMotion>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: 1);
  _ReadingTransition _phase = _ReadingTransition.idle;
  int _request = 0;

  bool get isTransitioning => _phase != _ReadingTransition.idle;

  /// Only the invisible re-anchoring frame has no clickable, visible text.
  bool get obscuresLiveText =>
      _phase == _ReadingTransition.settling || _controller.value == 0;

  void transitionTo({
    required VoidCallback reposition,
    required bool Function() isCurrent,
  }) {
    final request = ++_request;
    _controller.stop();
    if (!isCurrent()) return;
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      _setPhase(_ReadingTransition.settling);
      _controller.value = 0;
      reposition();
      _revealAfterLayout(request, isCurrent, animated: false);
      return;
    }
    _setPhase(_ReadingTransition.fadingOut);
    unawaited(_fadeOutThenReposition(request, reposition, isCurrent));
  }

  Future<void> _fadeOutThenReposition(
    int request,
    VoidCallback reposition,
    bool Function() isCurrent,
  ) async {
    try {
      // Retarget from the current opacity; do not brighten an interrupted
      // transition or restart a full fade when it is almost hidden already.
      await _controller
          .animateTo(
            0,
            duration: Duration(milliseconds: (70 * _controller.value).round()),
            curve: Curves.easeInQuad,
          )
          .orCancel;
      if (!_isCurrent(request, isCurrent)) return;
      _setPhase(_ReadingTransition.settling);
      reposition();
      _revealAfterLayout(request, isCurrent, animated: true);
    } on TickerCanceled {
      // A pointer or a newer destination now owns the reading surface.
    }
  }

  bool _isCurrent(int request, bool Function() isCurrent) =>
      mounted && request == _request && isCurrent();

  void _revealAfterLayout(
    int request,
    bool Function() isCurrent, {
    required bool animated,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrent(request, isCurrent)) return;
      // Reposition queued its boundary correction before this callback.
      _setPhase(_ReadingTransition.fadingIn);
      unawaited(_fadeIn(request, isCurrent, animated: animated));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _fadeIn(
    int request,
    bool Function() isCurrent, {
    required bool animated,
  }) async {
    try {
      await _controller
          .animateTo(
            1,
            duration: animated
                ? const Duration(milliseconds: 110)
                : Duration.zero,
            curve: Curves.easeOutCubic,
          )
          .orCancel;
      if (_isCurrent(request, isCurrent)) _setPhase(_ReadingTransition.idle);
    } on TickerCanceled {
      // The next gesture/transition keeps the current rendered content.
    }
  }

  void _setPhase(_ReadingTransition phase, {bool rebuild = true}) {
    if (_phase == phase) return;
    final wasActive = isTransitioning;
    _phase = phase;
    if (wasActive != isTransitioning) {
      widget.onActivityChanged?.call(isTransitioning);
    }
    if (rebuild && mounted) setState(() {});
  }

  void cancel({bool rebuild = true}) {
    final request = ++_request;
    _controller.stop();
    if (_phase == _ReadingTransition.settling) {
      // A pointer can arrive between jump and layout. Complete the new bounds
      // correction under zero opacity before exposing or dragging that surface.
      widget.onSettle?.call();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || request != _request) return;
        _setPhase(_ReadingTransition.idle);
        _controller.value = 1;
      });
      WidgetsBinding.instance.ensureVisualUpdate();
      return;
    }
    _setPhase(_ReadingTransition.idle, rebuild: rebuild);
    _controller.value = 1;
  }

  @override
  void didUpdateWidget(TranscriptViewportMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) cancel(rebuild: false);
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    // Keep the original ink/background paint order while containing Material
    // feedback in the viewport's existing boundary, instead of the player.
    child: Material(
      type: MaterialType.transparency,
      child: ColoredBox(
        color: widget.backgroundColor,
        child: FadeTransition(
          key: const ValueKey('transcript-location-opacity'),
          opacity: _controller,
          child: IgnorePointer(
            ignoring: _phase == _ReadingTransition.settling,
            child: widget.child,
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _request++;
    _controller.dispose();
    super.dispose();
  }
}
