import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/services/danmaku_collision_layout.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

Future<Uint8List> _pixels(
  WidgetTester tester,
  CustomPainter painter, {
  Size size = const Size(800, 600),
}) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await tester.runAsync(
    () => picture.toImage(size.width.round(), size.height.round()),
  );
  final data = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final pixels = data!.buffer.asUint8List();
  image!.dispose();
  picture.dispose();
  return pixels;
}

int _maximumAlpha(Uint8List pixels) {
  var maximum = 0;
  for (var i = 3; i < pixels.length; i += 4) {
    if (pixels[i] > maximum) maximum = pixels[i];
  }
  return maximum;
}

class _Scene {
  _Scene(this.file, this.position);
  final File file;
  final ValueNotifier<Duration> position;

  Widget build({double opacity = 1}) => MaterialApp(
    home: DanmakuOverlay(
      path: file.path,
      position: position,
      displayArea: 1,
      opacity: opacity,
      fontScale: 1,
      speed: 1,
      fontFamily: null,
      fontWeight: 600,
      outlineType: DanmakuOutlineType.standard,
      playerHeight: 600,
    ),
  );

  CustomPainter painter(WidgetTester tester) => tester
      .widget<CustomPaint>(
        find.descendant(
          of: find.byType(DanmakuOverlay),
          matching: find.byType(CustomPaint),
        ),
      )
      .painter!;
}

Future<_Scene> _load(
  WidgetTester tester,
  List<String> events, {
  Duration position = const Duration(seconds: 2),
  double opacity = 1,
}) async {
  late Directory directory;
  late File file;
  await tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('danmaku_frames_');
    file = File('${directory.path}/comments.ass');
    await file.writeAsString('''
[Script Info]
PlayResX: 800
PlayResY: 600
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
${events.join('\n')}
''');
  });
  final notifier = ValueNotifier(position);
  addTearDown(() async {
    notifier.dispose();
    await tester.runAsync(() => directory.delete(recursive: true));
  });
  final scene = _Scene(file, notifier);
  await tester.pumpWidget(scene.build(opacity: opacity));
  await _warm(tester);
  return scene;
}

Future<void> _warm(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('cached geometry matches a fresh painter across motion and resize', (
    tester,
  ) async {
    final scene = await _load(tester, [
      r'Dialogue: 0,0:00:00.00,0:01:00.00,Medium,,0,0,0,,{\move(800,0,-200,0)}Moving',
      r'Dialogue: 0,0:00:00.00,0:01:00.00,Medium,,0,0,0,,{\pos(400,80)}Fixed',
      r'Dialogue: 0,0:00:00.00,0:01:00.00,Medium,,0,0,0,,{\pos(400,560)}Bottom',
    ]);
    var cached = scene.painter(tester);
    for (final size in [
      const Size(800, 600),
      const Size(480, 600),
      const Size(800, 400),
      const Size(800, 600),
    ]) {
      scene.position.value += const Duration(milliseconds: 125);
      final before = await _pixels(tester, cached, size: size);
      expect(_maximumAlpha(before), greaterThan(0));
      await tester.pumpWidget(scene.build());
      final fresh = scene.painter(tester);
      final after = await _pixels(tester, fresh, size: size);
      expect(sha256.convert(before), sha256.convert(after));
      cached = fresh;
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('an upload invalidates an empty cached frame while paused', (
    tester,
  ) async {
    final scene = await _load(tester, [
      r'Dialogue: 0,0:00:30.00,0:01:30.00,Medium,,0,0,0,,{\pos(400,0)}Future',
    ]);
    final painter = scene.painter(tester);
    scene.position.value = const Duration(seconds: 34);
    final waiting = await _pixels(tester, painter);
    expect(_maximumAlpha(waiting), 0);
    await _warm(tester);
    final prepared = await _pixels(tester, painter);
    expect(_maximumAlpha(prepared), greaterThan(0));
    expect(scene.position.value, const Duration(seconds: 34));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('lane repacking and changing opacity do not retain stale sprites', (
    tester,
  ) async {
    final scene = await _load(
      tester,
      [
        r'Dialogue: 0,0:00:00.00,0:00:20.00,Medium,,0,0,0,,{\pos(400,0)}Same',
        for (var i = 0; i < 64; i++)
          r'Dialogue: 0,0:00:01.00,0:00:03.00,Medium,,0,0,0,,{\pos(400,0)}Same',
        for (var i = 0; i < 64; i++)
          r'Dialogue: 0,0:00:02.00,0:00:04.00,Medium,,0,0,0,,{\pos(400,0)}Same',
      ],
      position: const Duration(milliseconds: 500),
      opacity: .4,
    );
    final painter = scene.painter(tester);
    final initialPixels = sha256.convert(await _pixels(tester, painter));
    for (final milliseconds in [500, 1500, 2500, 3500, 4500]) {
      scene.position.value = Duration(milliseconds: milliseconds);
      await _warm(tester);
      final pixels = await _pixels(tester, painter);
      final dynamic measured = painter;
      final boxes = (measured.collisionGate as DanmakuCollisionGate).placements
          .toList();
      final base = boxes.firstWhere((box) => box.index == 0);
      final centerRow = (base.y + base.height / 2).floor();
      // Neighboring outlines may overlap, while the center of the original
      // glyph must retain its per-comment opacity. Bursts now fill free rows.
      expect(
        _maximumAlpha(
          Uint8List.sublistView(
            pixels,
            centerRow * 800 * 4,
            (centerRow + 1) * 800 * 4,
          ),
        ),
        inInclusiveRange(100, 103),
      );
      if (milliseconds == 1500 || milliseconds == 2500) {
        expect(boxes.length, greaterThan(1));
      }
      if (milliseconds == 4500) {
        expect(boxes, hasLength(1));
        expect(sha256.convert(pixels), initialPixels);
      }
    }
    for (final opacity in [1.0, .25, .95, .4]) {
      await tester.pumpWidget(scene.build(opacity: opacity));
      final alpha = _maximumAlpha(await _pixels(tester, scene.painter(tester)));
      expect(alpha, closeTo((opacity * 255).round(), 1));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
