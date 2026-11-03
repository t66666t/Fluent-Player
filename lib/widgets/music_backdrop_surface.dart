import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Retains the final, static backdrop pixels as one bounded texture. Impeller
/// retains display lists but disables its surface raster cache; a repaint
/// boundary alone still replays the artwork and full-screen gradients.
class MusicBackdropSurface extends StatefulWidget {
  const MusicBackdropSurface({
    super.key,
    required this.contentKey,
    required this.child,
    this.ready,
    this.captureDelay = const Duration(milliseconds: 700),
  });

  final Object contentKey;
  final Widget child;
  final ValueListenable<Object?>? ready;
  final Duration captureDelay;

  @override
  State<MusicBackdropSurface> createState() => _MusicBackdropSurfaceState();
}

class _MusicBackdropSurfaceState extends State<MusicBackdropSurface> {
  final _captureKey = GlobalKey();
  ui.Image? _snapshot;
  Size? _size;
  double _pixelRatio = 1;
  Timer? _timer;
  int _generation = 0;
  int? _failedGeneration;
  bool _capturing = false;
  bool _visible = true;

  bool get _ready =>
      widget.ready == null || widget.ready!.value == widget.contentKey;

  @override
  void initState() {
    super.initState();
    widget.ready?.addListener(_onReady);
  }

  @override
  void didUpdateWidget(MusicBackdropSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ready != widget.ready) {
      oldWidget.ready?.removeListener(_onReady);
      widget.ready?.addListener(_onReady);
    }
    if (oldWidget.contentKey != widget.contentKey ||
        oldWidget.ready != widget.ready) {
      _invalidate();
    }
  }

  void _invalidate() {
    _generation++;
    _failedGeneration = null;
    _timer?.cancel();
    _timer = null;
    _snapshot?.dispose();
    _snapshot = null;
  }

  void _onReady() {
    if (!mounted) return;
    if (!_ready) setState(_invalidate);
    _schedule();
  }

  void _schedule() {
    if (!mounted ||
        !_visible ||
        !_ready ||
        _size == null ||
        _snapshot != null ||
        _timer != null ||
        _capturing ||
        _failedGeneration == _generation) {
      return;
    }
    _timer = Timer(widget.captureDelay, _capture);
  }

  Future<void> _capture() async {
    _timer = null;
    if (!mounted || !_visible || !_ready || _snapshot != null) return;
    final boundary = _captureKey.currentContext?.findRenderObject();
    final size = _size;
    if (boundary is! RenderRepaintBoundary ||
        !boundary.attached ||
        !boundary.hasSize ||
        size == null ||
        size.isEmpty) {
      return;
    }
    final generation = _generation;
    _capturing = true;
    try {
      // Preserve physical-pixel gradient dithering. Capturing at logical
      // resolution magnifies that dither on high-density displays. Keep just
      // one image, bounded to roughly 32 MiB even on very large desktops.
      final ratio = math.min(
        _pixelRatio,
        math.min(
          4096 / math.max(size.width, size.height),
          math.sqrt(8400000 / (size.width * size.height)),
        ),
      );
      final image = await boundary.toImage(pixelRatio: ratio);
      if (!mounted || generation != _generation || !_ready) {
        image.dispose();
        return;
      }
      setState(() => _snapshot = image);
    } catch (_) {
      // The live composition remains authoritative if capture is unavailable.
      // Do not repeatedly schedule failed GPU work in this content generation.
      if (generation == _generation) _failedGeneration = generation;
    } finally {
      _capturing = false;
      if (mounted && generation != _generation) _schedule();
    }
  }

  @override
  void dispose() {
    widget.ready?.removeListener(_onReady);
    _invalidate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pixelRatio =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.of(context).devicePixelRatio;
    if (_pixelRatio != pixelRatio) {
      _invalidate();
      _pixelRatio = pixelRatio;
    }
    _visible = TickerMode.valuesOf(context).enabled;
    if (!_visible) {
      _timer?.cancel();
      _timer = null;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (_size != size) {
          _invalidate();
          _size = size;
        }
        if (size.isFinite && !size.isEmpty) _schedule();
        return Stack(
          fit: StackFit.expand,
          children: [
            Offstage(
              offstage: _snapshot != null,
              child: RepaintBoundary(key: _captureKey, child: widget.child),
            ),
            if (_snapshot != null)
              RawImage(
                key: const ValueKey('music-backdrop-snapshot'),
                image: _snapshot,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.low,
              ),
          ],
        );
      },
    );
  }
}
