import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

void main() {
  testWidgets(
    'style refinements repaint a paused overlay without reopening it',
    (tester) async {
      late Directory directory;
      late File file;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('danmaku_style_');
        file = File('${directory.path}/style.ass');
        await file.writeAsString(r'''
[Script Info]
PlayResX: 800
PlayResY: 600
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:01:00.00,Medium,,0,0,0,,{\an8\pos(400,80)}Style preview
''');
      });
      final position = ValueNotifier(const Duration(seconds: 2));
      addTearDown(() async {
        position.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      Future<String> paint(
        DanmakuOutlineType type, {
        double outline = 1,
        double shadow = 1,
        double spacing = 0,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: DanmakuOverlay(
              path: file.path,
              position: position,
              displayArea: 1,
              opacity: 1,
              fontScale: 1,
              speed: 1,
              fontFamily: null,
              fontWeight: 600,
              outlineType: type,
              outlineScale: outline,
              shadowScale: shadow,
              letterSpacing: spacing,
              playerHeight: 600,
            ),
          ),
        );
        for (var i = 0; i < 60; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        final painter = tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(DanmakuOverlay),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!;
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), const Size(800, 600));
        final picture = recorder.endRecording();
        final image = await tester.runAsync(() => picture.toImage(800, 600));
        final bytes = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        expect(bytes!.buffer.asUint8List().any((value) => value != 0), isTrue);
        final digest = sha256.convert(bytes.buffer.asUint8List()).toString();
        image!.dispose();
        picture.dispose();
        return digest;
      }

      final normal = await paint(DanmakuOutlineType.standard);
      expect(
        await paint(DanmakuOutlineType.standard, outline: 2),
        isNot(normal),
      );
      expect(
        await paint(DanmakuOutlineType.standard, spacing: .2),
        isNot(normal),
      );
      final plain = await paint(DanmakuOutlineType.none);
      expect(plain, isNot(normal));
      final projected = await paint(DanmakuOutlineType.shadow);
      expect(projected, isNot(plain));
      expect(
        await paint(DanmakuOutlineType.shadow, shadow: 2),
        isNot(projected),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
