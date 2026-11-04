import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/ocr_subtitle_models.dart';

/// Displays exactly the source-video pixels selected by [region].
///
/// The selected crop is fitted without stretching, so the preview uses the
/// same normalized coordinate system as the FFmpeg OCR crop.
class OcrRegionPreview extends StatefulWidget {
  final String imagePath;
  final NormalizedOcrRegion region;
  final double height;

  const OcrRegionPreview({
    super.key,
    required this.imagePath,
    required this.region,
    this.height = 112,
  });

  @override
  State<OcrRegionPreview> createState() => _OcrRegionPreviewState();
}

class _OcrRegionPreviewState extends State<OcrRegionPreview> {
  ui.Image? _image;
  Object? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OcrRegionPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted || generation != _loadGeneration) {
        frame.image.dispose();
        return;
      }
      final previous = _image;
      setState(() {
        _image = frame.image;
        _error = null;
      });
      previous?.dispose();
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return SizedBox(
      height: widget.height,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Colors.black),
        child: image == null
            ? Center(
                child: _error == null
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white38,
                      ),
              )
            : RepaintBoundary(
                key: const ValueKey('ocr-region-preview-canvas'),
                child: CustomPaint(
                  painter: OcrRegionPreviewPainter(image, widget.region),
                  child: const SizedBox.expand(),
                ),
              ),
      ),
    );
  }
}

@visibleForTesting
class OcrRegionPreviewPainter extends CustomPainter {
  final ui.Image image;
  final NormalizedOcrRegion region;

  const OcrRegionPreviewPainter(this.image, this.region);

  @override
  void paint(Canvas canvas, Size size) {
    final source = region.normalized().toPixelRect(
      Size(image.width.toDouble(), image.height.toDouble()),
    );
    if (source.isEmpty || size.isEmpty) return;
    final fitted = applyBoxFit(BoxFit.contain, source.size, size);
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.drawImageRect(
      image,
      source,
      destination,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant OcrRegionPreviewPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.region.left != region.left ||
      oldDelegate.region.top != region.top ||
      oldDelegate.region.right != region.right ||
      oldDelegate.region.bottom != region.bottom;
}
