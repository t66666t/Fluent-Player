import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/playback_mode.dart';
import '../widgets/playback_mode_icon.dart';

/// Windows HICON pixels, drawn by the same painter as every in-app mode button.
/// Render once per process; never rasterize icons on playback position ticks.
Future<Map<String, Uint8List>>? _modeIcons;
Future<Map<String, Uint8List>> desktopPlaybackModeIcons() =>
    _modeIcons ??= _renderModeIcons();

Future<Map<String, Uint8List>> _renderModeIcons() async {
  final result = <String, Uint8List>{};
  for (final mode in PlaybackMode.values) {
    final recorder = ui.PictureRecorder();
    PlaybackModeIconPainter(
      mode: mode,
      color: const ui.Color(0xffe6e6e6),
    ).paint(ui.Canvas(recorder), const ui.Size.square(32));
    final picture = recorder.endRecording();
    final ui.Image image;
    try {
      image = await picture.toImage(32, 32);
    } finally {
      picture.dispose();
    }
    try {
      final rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final pixels = rgba.buffer.asUint8List(
        rgba.offsetInBytes,
        rgba.lengthInBytes,
      );
      // Flutter and Windows both use premultiplied alpha; DIB channel order is BGRA.
      final bgra = Uint8List(pixels.length);
      for (var i = 0; i < pixels.length; i += 4) {
        bgra[i] = pixels[i + 2];
        bgra[i + 1] = pixels[i + 1];
        bgra[i + 2] = pixels[i];
        bgra[i + 3] = pixels[i + 3];
      }
      result[mode.name] = bgra;
    } finally {
      image.dispose();
    }
  }
  return result;
}
