import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, TileMode, lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../services/media_playback_service.dart';
import '../services/settings_service.dart';
import 'music_cover_video_frame.dart';

/// `2×` for a whole rate, `1.5×` when the configured rate has a fraction.
String musicLongPressSpeedLabel(double speed) {
  if (!speed.isFinite || speed <= 0) return '';
  final nearest = speed.roundToDouble();
  final digits = (speed - nearest).abs() < 0.05
      ? nearest.toStringAsFixed(0)
      : speed.toStringAsFixed(1);
  return '$digits×';
}

/// Landscape cover that can turn over into the shared playback picture.
///
/// The card height stays [coverSize] for the whole gesture, handoff and
/// resize. Width is the only layout value that moves, and it stays inside
/// [maxFrameWidth].
class MusicCoverVideoStage extends StatefulWidget {
  const MusicCoverVideoStage({
    super.key,
    required this.cover,
    required this.coverSize,
    required this.maxFrameWidth,
    required this.borderRadius,
    required this.itemId,
    required this.isVideo,
    required this.gestureEnabled,
    this.controller,
    this.debugFramesReady = false,
    this.debugAspectRatio,
    this.onTemporarySpeedChanged,
  });

  final Widget cover;
  final double coverSize;
  final double maxFrameWidth;
  final double borderRadius;
  final String itemId;
  final bool isVideo;

  /// True only for a real landscape viewport showing video.
  final bool gestureEnabled;
  final VideoPlayerController? controller;

  /// Skips the decoder in tests and paints a stand-in surface.
  final bool debugFramesReady;
  final double? debugAspectRatio;

  /// Reports the `2×` label while a press is holding the temporary rate.
  final ValueChanged<String?>? onTemporarySpeedChanged;

  @override
  State<MusicCoverVideoStage> createState() => _MusicCoverVideoStageState();
}

class _MusicCoverVideoStageState extends State<MusicCoverVideoStage>
    with TickerProviderStateMixin {
  static const Duration _flipDuration = Duration(milliseconds: 560);
  static const Duration _widthDuration = Duration(milliseconds: 280);
  static const Duration _fadeDuration = Duration(milliseconds: 240);
  static const Duration _sheenDelay = Duration(milliseconds: 300);
  static const Duration _loadingDelay = Duration(milliseconds: 400);

  late final AnimationController _flip;
  late final AnimationController _width;
  late final AnimationController _fade;
  late final AnimationController _sheen;

  VideoPlayerController? _bound;
  Timer? _sheenTimer;
  Timer? _loadingTimer;
  int _revealGeneration = 0;
  int _handoffGeneration = 0;
  bool _preparing = false;
  bool _revealed = false;
  bool _handoff = false;
  bool _mountVideo = false;
  bool _showSheen = false;
  bool _showLoading = false;
  bool _surfaceClaimed = false;
  bool _disposed = false;
  double _widthFrom = 0;
  double _widthTo = 0;
  double? _settledAspect;
  int? _boostPointer;
  Offset? _boostOrigin;
  Timer? _boostTimer;
  bool _boosting = false;

  @override
  void initState() {
    super.initState();
    _flip = AnimationController(vsync: this, duration: _flipDuration);
    _width = AnimationController(vsync: this, duration: _widthDuration)
      ..value = 1;
    _fade = AnimationController(vsync: this, duration: _fadeDuration)
      ..value = 1;
    _sheen = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _widthFrom = widget.coverSize;
    _widthTo = widget.coverSize;
    _bindController(widget.controller);
    MediaPlaybackService().addListener(_onSurfaceOwnershipChanged);
  }

  /// The floating player inside the fullscreen AI chat borrows the same output.
  /// media_kit keeps one view, so lose the claim and fall back to artwork
  /// instead of fighting over the texture.
  void _onSurfaceOwnershipChanged() {
    if (!_surfaceClaimed || _disposed) return;
    if (MediaPlaybackService().ownsVideoSurface(this)) return;
    _runOutsideBuild(_snapCover);
  }

  @override
  void didUpdateWidget(MusicCoverVideoStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bindController(widget.controller);
    final itemChanged = widget.itemId != oldWidget.itemId;
    final showing = _revealed || _preparing || _flip.value > 0;
    // Losing the video track flips back. Losing landscape (the gesture)
    // drops the picture immediately, because the portrait layout has no slot.
    if (itemChanged && showing && !widget.isVideo) {
      if (_revealed || _flip.value > 0) {
        _flipBack();
      } else {
        _cancelPrepare();
      }
      return;
    }
    if (!widget.gestureEnabled && showing) {
      _snapCover();
      return;
    }
    if (itemChanged && (_revealed || _preparing)) {
      if (!widget.isVideo) {
        _flipBack();
        return;
      }
      if (_preparing && !_revealed) {
        _revealGeneration++;
        _startPrepare(_revealGeneration);
        return;
      }
      _beginHandoff();
      return;
    }
    if (_revealed &&
        (widget.coverSize != oldWidget.coverSize ||
            widget.maxFrameWidth != oldWidget.maxFrameWidth ||
            widget.debugAspectRatio != oldWidget.debugAspectRatio ||
            widget.debugFramesReady != oldWidget.debugFramesReady)) {
      if (_handoff && _hasPicture()) {
        _showArrivedFrame(_handoffGeneration);
      } else if (!_handoff) {
        _retargetWidth(animate: true);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    MediaPlaybackService().removeListener(_onSurfaceOwnershipChanged);
    _sheenTimer?.cancel();
    _loadingTimer?.cancel();
    _boostTimer?.cancel();
    _endBoost();
    _bound?.removeListener(_onController);
    _flip.dispose();
    _width.dispose();
    _fade.dispose();
    _sheen.dispose();
    _releaseSurface();
    super.dispose();
  }

  void _bindController(VideoPlayerController? controller) {
    if (identical(_bound, controller)) return;
    _bound?.removeListener(_onController);
    _bound = controller;
    _bound?.addListener(_onController);
  }

  void _onController() {
    if (!mounted || _disposed) return;
    if (_preparing && _hasPicture()) {
      _beginFlip(_revealGeneration);
      return;
    }
    if (_handoff && _hasPicture()) {
      _showArrivedFrame(_handoffGeneration);
    }
  }

  bool _hasPicture() {
    if (widget.debugFramesReady) return true;
    final controller = widget.controller;
    if (controller == null) return false;
    try {
      final value = controller.value;
      return value.isInitialized &&
          !value.hasError &&
          value.size.width > 0 &&
          value.size.height > 0;
    } catch (_) {
      return false;
    }
  }

  double get _aspect {
    if (widget.debugFramesReady &&
        widget.debugAspectRatio != null &&
        widget.debugAspectRatio!.isFinite &&
        widget.debugAspectRatio! > 0) {
      return widget.debugAspectRatio!;
    }
    final controller = widget.controller;
    if (controller != null) {
      try {
        final aspect = controller.value.aspectRatio;
        if (aspect.isFinite && aspect > 0) return aspect;
      } catch (_) {}
    }
    return _settledAspect ?? 1;
  }

  MusicCoverVideoFrame _frame() {
    final aspect = _handoff && !_hasPicture()
        ? (_settledAspect ?? _aspect)
        : _aspect;
    return layoutMusicCoverVideoFrame(
      coverSize: widget.coverSize,
      maxWidth: widget.maxFrameWidth,
      aspectRatio: aspect,
    );
  }

  double _displayedWidth() {
    final widthT = Curves.easeOutCubic.transform(_width.value.clamp(0.0, 1.0));
    final settled = _width.value >= 1 && !_width.isAnimating
        ? _widthTo
        : lerpDouble(_widthFrom, _widthTo, widthT)!;
    final flipT = Curves.easeInOutCubic.transform(_flip.value.clamp(0.0, 1.0));
    return lerpDouble(widget.coverSize, settled, flipT)!;
  }

  void _retargetWidth({required bool animate}) {
    final target = _frame().width;
    final current = _displayedWidth();
    if (!animate || (current - target).abs() < 0.5) {
      _widthFrom = target;
      _widthTo = target;
      _width.value = 1;
      return;
    }
    _widthFrom = current;
    _widthTo = target;
    _width.forward(from: 0);
  }

  void _toggle() {
    if (!widget.gestureEnabled || _flip.isAnimating) return;
    if (_revealed) {
      _flipBack();
      return;
    }
    if (_preparing) {
      _cancelPrepare();
      return;
    }
    _revealGeneration++;
    _startPrepare(_revealGeneration);
  }

  void _startPrepare(int generation) {
    _preparing = true;
    _showSheen = false;
    _sheen.stop();
    _sheenTimer?.cancel();
    _sheenTimer = Timer(_sheenDelay, () {
      if (!mounted || _disposed || generation != _revealGeneration) return;
      if (!_preparing) return;
      _sheen.repeat();
      setState(() => _showSheen = true);
    });
    if (mounted) setState(() {});
    if (widget.debugFramesReady || _hasPicture()) {
      _beginFlip(generation);
      return;
    }
    MediaPlaybackService()
        .prepareMusicCoverVideo(widget.itemId)
        .then(
          (_) {
            if (!mounted || _disposed || generation != _revealGeneration) {
              return;
            }
            if (_hasPicture()) _beginFlip(generation);
          },
          onError: (_) {
            if (!mounted || _disposed || generation != _revealGeneration) {
              return;
            }
            _cancelPrepare();
          },
        );
  }

  void _cancelPrepare() {
    _revealGeneration++;
    _preparing = false;
    _showSheen = false;
    _sheen.stop();
    _sheenTimer?.cancel();
    _releaseSurface();
    if (mounted && !_disposed) setState(() {});
  }

  /// Claims the shared texture, then mounts it on the next frame so the
  /// playback page underneath can detach its [Video] view first.
  void _beginFlip(int generation) {
    if (!mounted || _disposed || generation != _revealGeneration || _revealed) {
      return;
    }
    _preparing = false;
    _showSheen = false;
    _sheen.stop();
    _sheenTimer?.cancel();
    _settledAspect = _aspect;
    _runOutsideBuild(() {
      if (!mounted ||
          _disposed ||
          generation != _revealGeneration ||
          _revealed) {
        return;
      }
      MediaPlaybackService().setMusicCoverVideoSurfaceOwner(this, true);
      _surfaceClaimed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _disposed || generation != _revealGeneration) {
          _releaseSurface();
          return;
        }
        _widthFrom = widget.coverSize;
        _widthTo = _frame().width;
        _width.value = 1;
        _fade.value = 1;
        _mountVideo = true;
        _revealed = true;
        setState(() {});
        _flip.forward(from: 0);
      });
    });
  }

  void _beginHandoff() {
    _revealGeneration++;
    final generation = ++_handoffGeneration;
    _preparing = false;
    _handoff = true;
    _mountVideo = false;
    _showSheen = false;
    _showLoading = false;
    _sheen.stop();
    _sheenTimer?.cancel();
    _fade.value = 0;
    if (_flip.value < 1) _flip.value = 1;
    _loadingTimer?.cancel();
    _loadingTimer = Timer(_loadingDelay, () {
      if (!mounted || _disposed || generation != _handoffGeneration) return;
      if (!_handoff) return;
      setState(() => _showLoading = true);
    });
    if (_hasPicture()) {
      _showArrivedFrame(generation);
      return;
    }
    // The new episode may have been opened without a texture. Ask for one
    // without turning the music page into a playback page.
    if (!widget.debugFramesReady) {
      MediaPlaybackService().prepareMusicCoverVideo(widget.itemId);
    }
    if (mounted) setState(() {});
  }

  void _showArrivedFrame(int generation) {
    if (!mounted || _disposed || generation != _handoffGeneration) return;
    _settledAspect = _aspect;
    _loadingTimer?.cancel();
    _showLoading = false;
    _handoff = false;
    _mountVideo = true;
    _retargetWidth(animate: true);
    setState(() {});
    _fade.forward(from: 0);
  }

  void _flipBack() {
    _revealGeneration++;
    _handoffGeneration++;
    _preparing = false;
    _handoff = false;
    _showLoading = false;
    _showSheen = false;
    _sheen.stop();
    _sheenTimer?.cancel();
    _loadingTimer?.cancel();
    if (_flip.value == 0) {
      _mountVideo = false;
      _revealed = false;
      _releaseSurface();
      if (mounted && !_disposed) setState(() {});
      return;
    }
    _flip.reverse().whenComplete(() {
      if (_disposed) {
        _releaseSurface();
        return;
      }
      _mountVideo = false;
      _revealed = false;
      _releaseSurface();
      if (mounted) setState(() {});
    });
  }

  void _snapCover() {
    _revealGeneration++;
    _handoffGeneration++;
    _flip.stop();
    _flip.value = 0;
    _width.stop();
    _preparing = false;
    _revealed = false;
    _handoff = false;
    _mountVideo = false;
    _showSheen = false;
    _showLoading = false;
    _sheen.stop();
    _sheenTimer?.cancel();
    _loadingTimer?.cancel();
    _widthFrom = widget.coverSize;
    _widthTo = widget.coverSize;
    _width.value = 1;
    _releaseSurface();
    if (mounted && !_disposed) setState(() {});
  }

  void _releaseSurface() {
    _runOutsideBuild(_detachSurface);
  }

  void _detachSurface() {
    if (_surfaceClaimed) {
      _surfaceClaimed = false;
      MediaPlaybackService().setMusicCoverVideoSurfaceOwner(this, false);
      return;
    }
    MediaPlaybackService().cancelMusicCoverVideoRequest();
  }

  /// Service listeners rebuild the playback page. That setState is illegal
  /// while this card is itself inside a build, so defer across that phase.
  void _runOutsideBuild(void Function() action) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => action());
      return;
    }
    action();
  }

  double _configuredLongPressSpeed() {
    try {
      return Provider.of<SettingsService>(
        context,
        listen: false,
      ).longPressSpeed;
    } catch (_) {
      return 2;
    }
  }

  void _onBoostPointerDown(PointerDownEvent event) {
    if (_boostPointer != null) return;
    _boostPointer = event.pointer;
    _boostOrigin = event.localPosition;
    _boostTimer?.cancel();
    _boostTimer = Timer(kLongPressTimeout, () {
      if (!mounted || _disposed || _boostPointer != event.pointer) return;
      _startBoost();
    });
  }

  void _onBoostPointerMove(PointerMoveEvent event) {
    if (event.pointer != _boostPointer || _boostOrigin == null || _boosting) {
      return;
    }
    // A real drag belongs to the surrounding scroller, not to the boost.
    if ((event.localPosition - _boostOrigin!).distance > kTouchSlop) {
      _boostTimer?.cancel();
      _boostPointer = null;
      _boostOrigin = null;
    }
  }

  void _onBoostPointerEnd(PointerEvent event) {
    if (event.pointer != _boostPointer) return;
    _boostTimer?.cancel();
    _boostPointer = null;
    _boostOrigin = null;
    _endBoost();
  }

  void _startBoost() {
    if (_boosting || _disposed) return;
    _boosting = true;
    final speed = _configuredLongPressSpeed();
    MediaPlaybackService().beginTemporaryPlaybackSpeed(speed);
    widget.onTemporarySpeedChanged?.call(musicLongPressSpeedLabel(speed));
  }

  void _endBoost() {
    if (!_boosting) return;
    _boosting = false;
    MediaPlaybackService().endTemporaryPlaybackSpeed();
    widget.onTemporarySpeedChanged?.call(null);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_flip, _width, _fade, _sheen]),
      builder: (context, _) {
        final frame = _frame();
        final width = _displayedWidth();
        final flipT = Curves.easeInOutCubic.transform(
          _flip.value.clamp(0.0, 1.0),
        );
        final angle = flipT * math.pi;
        final showBack = flipT >= 0.5;
        final displayAngle = showBack ? math.pi - angle : angle;
        // The hit target is the axis-aligned card, outside the flip, and
        // nothing inside it participates. Letterbox, artwork and the
        // picture are therefore the same press region.
        return SizedBox(
          key: const ValueKey('music-cover-video-stage'),
          width: width,
          height: widget.coverSize,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: widget.gestureEnabled ? _toggle : null,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onBoostPointerDown,
              onPointerMove: _onBoostPointerMove,
              onPointerUp: _onBoostPointerEnd,
              onPointerCancel: _onBoostPointerEnd,
              child: IgnorePointer(
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.0012)
                    ..rotateY(displayAngle),
                  child: Container(
                    width: width,
                    height: widget.coverSize,
                    decoration: BoxDecoration(
                      color: showBack ? Colors.black : const Color(0xFFE8E8ED),
                      borderRadius: BorderRadius.circular(widget.borderRadius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: widget.coverSize * 0.12,
                          offset: Offset(0, widget.coverSize * 0.03),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (showBack && frame.usesBackdrop) _backdrop(),
                        // Artwork stays above the backdrop and under the
                        // picture so a new episode can fade in without a gap.
                        if (!showBack || _handoff || _fade.value < 1)
                          _artwork(),
                        if (_mountVideo)
                          Offstage(
                            offstage: !showBack,
                            child: FadeTransition(
                              opacity: _fade,
                              child: _video(frame),
                            ),
                          ),
                        if (_handoff)
                          const SizedBox(
                            key: ValueKey('music-cover-video-poster'),
                          ),
                        if (_showSheen) _sheenOverlay(),
                        if (_showLoading) const _CoverLoadingHairline(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _artwork() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[...previous, ?current],
      ),
      child: KeyedSubtree(
        key: ValueKey<String>('music-cover-art-${widget.itemId}'),
        child: _fittedCover(),
      ),
    );
  }

  Widget _fittedCover() {
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: widget.coverSize,
        height: widget.coverSize,
        child: widget.cover,
      ),
    );
  }

  Widget _backdrop() {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: 16,
              sigmaY: 16,
              tileMode: TileMode.clamp,
            ),
            child: _fittedCover(),
          ),
          const ColoredBox(color: Color(0x48000000)),
        ],
      ),
    );
  }

  Widget _video(MusicCoverVideoFrame frame) {
    if (widget.debugFramesReady) {
      return const ColoredBox(
        key: ValueKey('music-cover-video-surface'),
        color: Color(0xFF101010),
      );
    }
    final controller = widget.controller;
    if (controller == null || !_safeVideo(controller)) {
      return const SizedBox.shrink();
    }
    final aspect = _aspect.clamp(0.2, 8.0);
    return FittedBox(
      fit: frame.fit,
      child: SizedBox(
        width: aspect,
        height: 1,
        child: VideoPlayer(
          controller,
          key: const ValueKey('music-cover-video-surface'),
        ),
      ),
    );
  }

  bool _safeVideo(VideoPlayerController controller) {
    try {
      return controller.value.isInitialized && !controller.value.hasError;
    } catch (_) {
      return false;
    }
  }

  Widget _sheenOverlay() {
    final travel = (_sheen.value * 2) - 1;
    return IgnorePointer(
      key: const ValueKey('music-cover-video-sheen'),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(travel - 0.8, -0.4),
            end: Alignment(travel + 0.2, 0.8),
            colors: [
              const Color(0x00FFFFFF),
              const Color(0x2EFFFFFF),
              const Color(0x00FFFFFF),
            ],
          ),
        ),
      ),
    );
  }
}

/// A hairline inside the rounded card. It does not participate in layout.
class _CoverLoadingHairline extends StatelessWidget {
  const _CoverLoadingHairline();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        key: ValueKey('music-cover-video-loading'),
        height: 2,
        width: double.infinity,
        child: LinearProgressIndicator(
          minHeight: 2,
          backgroundColor: Color(0x00000000),
          color: Color(0xB3FFFFFF),
        ),
      ),
    );
  }
}
