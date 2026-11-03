import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Source rectangle of one Bilibili seek-preview cell inside a sprite sheet.
///
/// The sheet is a uniform grid. Cropping in image pixels keeps the cell aligned
/// when the preview is later scaled, including on Windows where a translated
/// full-sheet [Image] drifts off the cell boundaries at fractional scale.
Rect bilibiliSpriteCellRect({
  required int imageWidth,
  required int imageHeight,
  required int columns,
  required int rows,
  required int column,
  required int row,
}) {
  final safeColumns = columns <= 0 ? 1 : columns;
  final safeRows = rows <= 0 ? 1 : rows;
  final cellWidth = imageWidth / safeColumns;
  final cellHeight = imageHeight / safeRows;
  var source = Rect.fromLTWH(
    column * cellWidth,
    row * cellHeight,
    cellWidth,
    cellHeight,
  );
  // Inset so bilinear sampling does not pull in the neighboring cell.
  if (cellWidth > 2 && cellHeight > 2) {
    source = source.deflate(0.5);
  }
  return source;
}

/// Paints a single cell from a local Bilibili videoshot sprite.
class BilibiliSpritePreview extends StatefulWidget {
  final String path;
  final int column;
  final int row;
  final int columns;
  final int rows;

  /// Stable identity for tests. Kept off this widget's own key so scrubbing
  /// within one sprite sheet does not reload the image.
  final Key cellKey;

  const BilibiliSpritePreview({
    super.key,
    required this.path,
    required this.column,
    required this.row,
    required this.columns,
    required this.rows,
    required this.cellKey,
  });

  @override
  State<BilibiliSpritePreview> createState() => _BilibiliSpritePreviewState();
}

class _BilibiliSpritePreviewState extends State<BilibiliSpritePreview> {
  ImageStream? _imageStream;
  ImageStreamListener? _listener;
  ui.Image? _image;
  bool _failed = false;
  String? _resolvedPath;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_resolvedPath != widget.path) {
      _resolveImage();
    }
  }

  @override
  void didUpdateWidget(BilibiliSpritePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _resolveImage();
    }
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  void _resolveImage() {
    _stopListening();
    _resolvedPath = widget.path;
    _failed = false;
    _image = null;
    final stream = FileImage(
      File(widget.path),
    ).resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() {
          _image = info.image;
          _failed = false;
        });
      },
      onError: (_, _) {
        if (!mounted) return;
        setState(() {
          _image = null;
          _failed = true;
        });
      },
    );
    _imageStream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _stopListening() {
    final listener = _listener;
    if (listener != null) {
      _imageStream?.removeListener(listener);
    }
    _listener = null;
    _imageStream = null;
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return SizedBox.expand(
      key: widget.cellKey,
      child: image == null || _failed
          ? const ColoredBox(color: Color(0xFF202020))
          : CustomPaint(
              painter: _BilibiliSpriteCellPainter(
                image: image,
                column: widget.column,
                row: widget.row,
                columns: widget.columns,
                rows: widget.rows,
              ),
              child: const SizedBox.expand(),
            ),
    );
  }
}

class _BilibiliSpriteCellPainter extends CustomPainter {
  final ui.Image image;
  final int column;
  final int row;
  final int columns;
  final int rows;

  const _BilibiliSpriteCellPainter({
    required this.image,
    required this.column,
    required this.row,
    required this.columns,
    required this.rows,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || image.width <= 0 || image.height <= 0) return;
    final source = bilibiliSpriteCellRect(
      imageWidth: image.width,
      imageHeight: image.height,
      columns: columns,
      rows: rows,
      column: column,
      row: row,
    );
    canvas.drawImageRect(
      image,
      source,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_BilibiliSpriteCellPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.column != column ||
        oldDelegate.row != row ||
        oldDelegate.columns != columns ||
        oldDelegate.rows != rows;
  }
}
