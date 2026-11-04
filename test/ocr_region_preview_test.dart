import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/widgets/ocr_region_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('preview painter renders only the selected source region', (
    tester,
  ) async {
    final source = im.Image(width: 100, height: 100);
    im.fill(source, color: im.ColorRgb8(240, 20, 20));
    im.fillRect(
      source,
      x1: 0,
      y1: 50,
      x2: 99,
      y2: 99,
      color: im.ColorRgb8(20, 40, 240),
    );
    final decoded = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(im.encodePng(source));
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    });

    Future<ui.Color> renderCenter(NormalizedOcrRegion region) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      OcrRegionPreviewPainter(
        decoded!,
        region,
      ).paint(canvas, const ui.Size(200, 100));
      final picture = recorder.endRecording();
      final rendered = await tester.runAsync(() => picture.toImage(200, 100));
      picture.dispose();
      final bytes = await tester.runAsync(
        () => rendered!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      const x = 100;
      const y = 50;
      final offset = (y * rendered!.width + x) * 4;
      final data = bytes!.buffer.asUint8List();
      final color = ui.Color.fromARGB(
        data[offset + 3],
        data[offset],
        data[offset + 1],
        data[offset + 2],
      );
      rendered.dispose();
      return color;
    }

    final bottom = await renderCenter(
      const NormalizedOcrRegion(left: 0, top: 0.5, right: 1, bottom: 1),
    );
    expect(bottom.b, greaterThan(0.8));
    expect(bottom.r, lessThan(0.25));

    final top = await renderCenter(
      const NormalizedOcrRegion(left: 0, top: 0, right: 1, bottom: 0.5),
    );
    expect(top.r, greaterThan(0.8));
    expect(top.b, lessThan(0.25));
    decoded!.dispose();
  });
}
