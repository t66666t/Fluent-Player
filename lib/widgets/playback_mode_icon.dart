import 'package:flutter/rendering.dart';

import '../models/playback_mode.dart';

/// One icon family: the same grid, stroke, arrowheads and optical bounds in
/// every state. The small "1" is a path so it shares the arrows' line weight.
class PlaybackModeIconPainter extends CustomPainter {
  const PlaybackModeIconPainter({required this.mode, required this.color});

  final PlaybackMode mode;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final paths = Path();
    switch (mode) {
      case PlaybackMode.shuffle:
        paths
          ..moveTo(3, 6)
          ..lineTo(6, 6)
          ..cubicTo(11, 6, 13, 18, 18, 18)
          ..lineTo(21, 18)
          ..moveTo(3, 18)
          ..lineTo(6, 18)
          ..cubicTo(11, 18, 13, 6, 18, 6)
          ..lineTo(21, 6);
      case PlaybackMode.sequential:
      case PlaybackMode.repeatOne:
        paths
          ..moveTo(3, 10)
          ..lineTo(3, 9)
          ..cubicTo(3, 7.34, 4.34, 6, 6, 6)
          ..lineTo(21, 6)
          ..moveTo(21, 14)
          ..lineTo(21, 15)
          ..cubicTo(21, 16.66, 19.66, 18, 18, 18)
          ..lineTo(3, 18);
        if (mode == PlaybackMode.repeatOne) {
          paths
            ..moveTo(10.5, 11)
            ..lineTo(12, 9.5)
            ..lineTo(12, 14.5)
            ..moveTo(10.5, 14.5)
            ..lineTo(13.5, 14.5);
        }
    }

    paths
      ..moveTo(17.75, 2.75)
      ..lineTo(21, 6)
      ..lineTo(17.75, 9.25);
    if (mode != PlaybackMode.shuffle) {
      paths
        ..moveTo(6.25, 14.75)
        ..lineTo(3, 18)
        ..lineTo(6.25, 21.25);
    } else {
      paths
        ..moveTo(17.75, 14.75)
        ..lineTo(21, 18)
        ..lineTo(17.75, 21.25);
    }
    canvas.drawPath(paths, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(PlaybackModeIconPainter oldDelegate) =>
      mode != oldDelegate.mode || color != oldDelegate.color;
}
