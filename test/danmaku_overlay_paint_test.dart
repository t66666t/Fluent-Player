import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

Future<(int, int)> _paintedPixels(
  WidgetTester tester,
  CustomPainter painter,
) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(800, 600));
  final picture = recorder.endRecording();
  final image = await tester.runAsync(() => picture.toImage(800, 600));
  final pixels = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  var painted = 0;
  var belowArea = 0;
  for (var y = 0; y < 600; y++) {
    for (var x = 0; x < 800; x++) {
      if (pixels!.getUint8((y * 800 + x) * 4 + 3) == 0) continue;
      painted++;
      if (y >= 150) belowArea++;
    }
  }
  image!.dispose();
  picture.dispose();
  return (painted, belowArea);
}

void main() {
  testWidgets('dense atlas paints inside a restricted area without rebuilding', (
    tester,
  ) async {
    late Directory directory;
    late File file;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('danmaku_paint_');
      file = File('${directory.path}/dense.ass');
      final ass = StringBuffer('''
[Script Info]
PlayResX: 1920
PlayResY: 1080
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''');
      for (var i = 0; i < 640; i++) {
        final y = (i % 27) * 40;
        ass.writeln(
          r'Dialogue: 0,0:00:10.00,0:00:40.00,Medium,,0,0,0,,{\move(1920,'
          '$y,-200,$y)}comment $i',
        );
      }
      await file.writeAsString(ass.toString());
    });
    final position = ValueNotifier(const Duration(seconds: 12));
    addTearDown(() async {
      position.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    });
    Widget stage(double area) => MaterialApp(
      home: SizedBox.expand(
        child: DanmakuOverlay(
          path: file.path,
          position: position,
          displayArea: area,
          opacity: .95,
          fontScale: 1,
          speed: 1,
          fontFamily: null,
          fontWeight: 700,
          outlineType: DanmakuOutlineType.standard,
          playerHeight: 600,
        ),
      ),
    );
    await tester.pumpWidget(stage(.25));
    CustomPainter? painter;
    for (var attempt = 0; attempt < 150; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      final paints = tester.widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(DanmakuOverlay),
          matching: find.byType(CustomPaint),
        ),
      );
      if (paints.isNotEmpty) painter = paints.single.painter;
    }
    expect(painter, isNotNull);
    final (paintedPixels, pixelsBelowArea) = await _paintedPixels(
      tester,
      painter!,
    );
    expect(paintedPixels, greaterThan(0));
    expect(pixelsBelowArea, 0);
    final samples = <int>[];
    for (var run = 0; run < 7; run++) {
      final timer = Stopwatch()..start();
      for (var frame = 0; frame < 300; frame++) {
        position.value = Duration(microseconds: 12000000 + frame * 8333);
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), const Size(800, 600));
        recorder.endRecording().dispose();
      }
      samples.add(timer.elapsedMicroseconds);
    }
    samples.sort();
    // Informational timing of a 640-comment document, with normal adaptive
    // admissions. This is not an end-to-end FPS or raster-time measurement.
    debugPrint('DANMAKU_PAINT_CPU 640 comments / 300 frames: ${samples[3]} us');

    // Reveal previously uncached lanes while the position is paused. They must
    // be prepared without needing another position notification or a new page.
    await tester.pumpWidget(stage(1));
    for (var attempt = 0; attempt < 150; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(DanmakuOverlay),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter;
    final (_, revealedPixels) = await _paintedPixels(tester, painter!);
    expect(revealedPixels, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
