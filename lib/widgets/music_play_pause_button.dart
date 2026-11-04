import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Keeps brief connection and buffering changes out of the transport chrome.
class MusicPlayPauseButton extends StatefulWidget {
  const MusicPlayPauseButton({
    super.key,
    required this.isPlaying,
    required this.isLoading,
    required this.iconSize,
    required this.minimumSize,
    this.onPressed,
  });

  final bool isPlaying, isLoading;
  final double iconSize, minimumSize;
  final VoidCallback? onPressed;

  @override
  State<MusicPlayPauseButton> createState() => _MusicPlayPauseButtonState();
}

class _MusicPlayPauseButtonState extends State<MusicPlayPauseButton>
    with SingleTickerProviderStateMixin {
  static const _revealDelay = Duration(seconds: 1);
  static const _cooldown = Duration(seconds: 3);
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );
  Timer? _revealTimer, _cooldownTimer;
  bool _visible = false;
  bool _delayElapsed = false;
  bool _animate = true;

  @override
  void initState() {
    super.initState();
    if (widget.isLoading) _waitToReveal();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant MusicPlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoading == oldWidget.isLoading) return;
    if (widget.isLoading) {
      _waitToReveal();
    } else {
      _revealTimer?.cancel();
      _delayElapsed = false;
      if (_visible) {
        _visible = false;
        _syncRotation();
        _cooldownTimer = Timer(_cooldown, _revealIfNeeded);
      }
    }
  }

  void _waitToReveal() {
    _delayElapsed = false;
    _revealTimer?.cancel();
    _revealTimer = Timer(_revealDelay, () {
      _delayElapsed = true;
      _revealIfNeeded();
    });
  }

  void _revealIfNeeded() {
    if (!mounted ||
        !widget.isLoading ||
        !_delayElapsed ||
        _visible ||
        (_cooldownTimer?.isActive ?? false)) {
      return;
    }
    setState(() => _visible = true);
    _syncRotation();
  }

  void _syncRotation() {
    if (_visible && _animate) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
    }
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _cooldownTimer?.cancel();
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DesktopButtonClickRegion(
    child: IconButton(
      key: const ValueKey('music-play-pause-button'),
      // A second open request must not restart an episode that is connecting.
      onPressed: widget.isLoading ? null : widget.onPressed,
      tooltip: widget.isLoading
          ? '正在加载'
          : widget.isPlaying
          ? '暂停'
          : '播放',
      iconSize: widget.iconSize,
      padding: const EdgeInsets.all(4),
      constraints: BoxConstraints(
        minWidth: widget.minimumSize,
        minHeight: widget.minimumSize,
      ),
      icon: SizedBox.square(
        dimension: widget.iconSize,
        child: AnimatedSwitcher(
          duration: _animate
              ? const Duration(milliseconds: 160)
              : Duration.zero,
          child: _visible
              ? RotationTransition(
                  key: const ValueKey('music-playback-loading'),
                  turns: _rotation,
                  child: const CustomPaint(
                    size: Size.infinite,
                    painter: _LoadingRingPainter(),
                  ),
                )
              : Icon(
                  widget.isPlaying
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  key: ValueKey(widget.isPlaying),
                  color: Colors.white,
                ),
        ),
      ),
    ),
  );
}

class _LoadingRingPainter extends CustomPainter {
  const _LoadingRingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final diameter = size.shortestSide * .8;
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: diameter,
      height: diameter,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (diameter * .065).clamp(1.6, 2.4)
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: .10);
    canvas.drawOval(rect, paint);
    paint.color = Colors.white.withValues(alpha: .88);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 1.35, false, paint);
  }

  @override
  bool shouldRepaint(_LoadingRingPainter oldDelegate) => false;
}
