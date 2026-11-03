import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

void main() {
  testWidgets(
    'actual overlay follows the window, preserves manual zoom and restores legacy size',
    (tester) async {
      late Directory directory;
      late File file;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'default_danmaku_font_',
        );
        file = File('${directory.path}/comments.ass');
        await file.writeAsString(r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:01:00.00,Medium,,0,0,0,,{\an8\pos(960,0)}Default size
''');
      });
      final position = ValueNotifier(const Duration(seconds: 2));
      addTearDown(() async {
        position.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      });

      Future<double> font({
        Size screen = const Size(1920, 1080),
        Size stage = const Size(800, 600),
        bool readable = true,
        double scale = 1,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: screen),
              child: Center(
                child: SizedBox.fromSize(
                  size: stage,
                  child: DanmakuOverlay(
                    path: file.path,
                    position: position,
                    displayArea: .25,
                    opacity: .95,
                    fontScale: scale,
                    useReadableFontDefaults: readable,
                    speed: .5,
                    fontFamily: null,
                    fontWeight: 600,
                    outlineType: DanmakuOutlineType.standard,
                    playerHeight: stage.height,
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
          if (find
              .descendant(
                of: find.byType(DanmakuOverlay),
                matching: find.byType(CustomPaint),
              )
              .evaluate()
                  .isNotEmpty) {
            break;
          }
        }
        final dynamic painter = tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(DanmakuOverlay),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!;
        expect(tester.takeException(), isNull);
        return painter.requestedFontSize as double;
      }

      final desktop = await font();
      expect(desktop, closeTo(20, .01));
      expect(await font(stage: const Size(500, 200)), desktop);
      expect(await font(screen: const Size(1080, 1920)), desktop);
      expect(await font(scale: 1.5), closeTo(desktop * 1.5, 1e-8));
      expect(await font(screen: const Size(390, 844)), 14);
      expect(await font(screen: const Size(844, 390)), 14);
      expect(await font(screen: const Size(3840, 2160)), 22);
      expect(
        await font(readable: false, stage: const Size(800, 1080), scale: .8),
        32,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
