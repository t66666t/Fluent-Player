import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/services/danmaku_collision_layout.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

void main() {
  testWidgets(
    'real portrait painter shares the region across types and applies density while paused',
    (tester) async {
      await tester.runAsync(() async {
        await (FontLoader(kDanmakuDefaultFontFamily)
              ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Bold.otf')))
            .load();
      });
      late Directory directory;
      late File file;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('danmaku_collision_');
        file = File('${directory.path}/comments.ass');
        final ass = StringBuffer('''
[Script Info]
PlayResX: 1920
PlayResY: 1080
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''');
        for (var index = 0; index < 96; index++) {
          final y = (index % 6) * 40;
          final effect = index % 5 == 0
              ? r'\an8\pos(960,'
                    '$y)'
              : r'\move(1920,'
                    '$y,-300,$y)';
          ass.writeln(
            'Dialogue: 0,0:00:00.00,0:00:08.00,Danmaku,,0,0,0,,{$effect}弹幕 comment $index',
          );
        }
        await file.writeAsString(ass.toString());
      });
      final position = ValueNotifier(const Duration(seconds: 2));
      addTearDown(() async {
        position.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      Widget scene(
        double density, {
        double scale = 1,
        double pixelRatio = 1,
        bool landscape = false,
      }) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: landscape ? const Size(844, 390) : const Size(390, 844),
            devicePixelRatio: pixelRatio,
          ),
          child: Center(
            child: SizedBox(
              width: landscape ? 700 : 390,
              height: 220,
              child: DanmakuOverlay(
                path: file.path,
                position: position,
                presentationMode: landscape
                    ? DanmakuPresentationMode.landscape
                    : DanmakuPresentationMode.portrait,
                displayArea: .5,
                opacity: 1,
                density: density,
                fontScale: scale,
                speed: .8,
                fontFamily: kDanmakuDefaultFontFamily,
                fontWeight: 700,
                outlineType: DanmakuOutlineType.standard,
                playerHeight: 220,
              ),
            ),
          ),
        ),
      );
      Future<dynamic> settlePainter() async {
        for (var attempt = 0; attempt < 40; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        return tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(DanmakuOverlay),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!;
      }

      List<DanmakuCollisionBox> boxes(dynamic painter) =>
          (painter.collisionGate as DanmakuCollisionGate).placements.toList();
      void expectSeparated(List<DanmakuCollisionBox> bounds) {
        expect(bounds.length, greaterThan(1));
        expect(bounds.length, lessThan(96));
        for (var first = 0; first < bounds.length; first++) {
          for (var second = first + 1; second < bounds.length; second++) {
            expect(
              bounds[first].conflictsWith(
                bounds[second],
                positionUs: position.value.inMicroseconds,
              ),
              isFalse,
            );
          }
        }
      }

      await tester.pumpWidget(scene(1));
      final initial = await settlePainter();
      expect(initial.requestedFontSize, 15);
      void expectFixedVelocity(dynamic painter) {
        final scrolling = boxes(
          painter,
        ).where((box) => box.type == DanmakuType.scroll);
        expect(scrolling, isNotEmpty);
        for (final box in scrolling) {
          expect(
            box.xAt(box.startUs) - box.xAt(box.startUs + 1000000),
            closeTo(48, 0.0001),
          );
        }
      }

      expectFixedVelocity(initial);
      expectSeparated(boxes(initial));
      expect(boxes(initial).any((box) => box.width > 60), isTrue);

      // The video remains paused while density and glyph metrics change.
      await tester.pumpWidget(scene(.25, scale: 1.25, pixelRatio: 3));
      final changed = await settlePainter();
      expect(changed.requestedFontSize, 18.75);
      expectFixedVelocity(changed);
      expectSeparated(boxes(changed));
      final items = changed.document.items;
      for (final box in boxes(changed)) {
        final item = items.firstWhere((item) => item.index == box.index);
        expect(danmakuPassesDensity(item, .25), isTrue);
      }
      position.value = const Duration(seconds: 1);
      await tester.pump();
      expectSeparated(boxes(changed));
      await tester.pumpWidget(scene(1, landscape: true));
      expectFixedVelocity(await settlePainter());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('100% density fills a portrait quarter-area from lower source tracks', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await (FontLoader(kDanmakuDefaultFontFamily)
            ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Bold.otf')))
          .load();
    });
    late Directory directory;
    late File file;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp(
        'danmaku_phone_density_',
      );
      file = File('${directory.path}/stream.ass');
      final ass = StringBuffer('''
[Script Info]
PlayResX: 1920
PlayResY: 1080
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''');
      for (var index = 0; index < 40; index++) {
        final start = index * 12; // A comment every 0.12 seconds, across 4.68s.
        final startTime =
            '0:00:0${start ~/ 100}.${(start % 100).toString().padLeft(2, '0')}';
        final endTime =
            '0:00:${(start ~/ 100 + 8).toString().padLeft(2, '0')}.${(start % 100).toString().padLeft(2, '0')}';
        // All of these used to be discarded: lane 12 cannot fit in a phone's
        // 25% region. The renderer must repack them into its available rows.
        ass.writeln(
          'Dialogue: 0,$startTime,$endTime,Danmaku,,0,0,0,,{\\move(1920,480,-100,480)}弹幕 $index',
        );
      }
      ass.writeln(
        r'Dialogue: 0,0:00:00.00,0:00:08.00,Danmaku,,0,0,0,,{\an8\pos(960,0)}置顶',
      );
      ass.writeln(
        r'Dialogue: 0,0:00:00.00,0:00:08.00,Danmaku,,0,0,0,,{\an8\pos(960,1040)}置底',
      );
      await file.writeAsString(ass.toString());
    });
    final position = ValueNotifier(const Duration(seconds: 5));
    addTearDown(() async {
      position.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    });
    for (final width in [320.0, 390.0, 430.0]) {
      final height = width * 9 / 16;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(width, width * 2.1)),
            child: Center(
              child: SizedBox(
                width: width,
                height: height,
                child: DanmakuOverlay(
                  key: ValueKey(width),
                  path: file.path,
                  position: position,
                  presentationMode: DanmakuPresentationMode.portrait,
                  displayArea: .25,
                  opacity: 1,
                  density: 1,
                  fontScale: 1,
                  speed: .8,
                  fontFamily: kDanmakuDefaultFontFamily,
                  fontWeight: 700,
                  outlineType: DanmakuOutlineType.standard,
                  playerHeight: height,
                ),
              ),
            ),
          ),
        ),
      );
      for (var warm = 0; warm < 60; warm++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      final dynamic painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(DanmakuOverlay),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter!;
      List<DanmakuCollisionBox> placements() =>
          (painter.collisionGate as DanmakuCollisionGate).placements.toList();
      final boxes = placements();
      final rolling = boxes
          .where((box) => box.type == DanmakuType.scroll)
          .toList();
      expect(rolling.length, greaterThanOrEqualTo(width == 320 ? 5 : 9));
      expect(rolling.map((box) => box.y).toSet().length, width == 320 ? 2 : 3);
      expect(boxes.where((box) => box.type == DanmakuType.top), hasLength(1));
      expect(
        boxes.where((box) => box.type == DanmakuType.bottom),
        hasLength(1),
      );
      expect(
        boxes.every((box) => box.y >= 0 && box.y + box.height <= height * .25),
        isTrue,
      );
      debugPrint(
        'DANMAKU_PHONE_DENSITY width=$width scroll=${rolling.length} total=${boxes.length}',
      );
      if (width == 390 && const bool.fromEnvironment('DANMAKU_PREVIEWS')) {
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)
            ..drawColor(const Color(0xff17222e), BlendMode.src);
          painter.paint(canvas, Size(width, height));
          final picture = recorder.endRecording();
          final image = await picture.toImage(width.round(), height.round());
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/danmaku_previews').create(recursive: true);
          await File(
            'build/danmaku_previews/phone-density-390.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        });
      }

      // A paused rebuild/upload must not reshuffle comments already on screen.
      final originalRows = {for (final box in boxes) box.index: box.y};
      await tester.pump();
      expect({for (final box in placements()) box.index: box.y}, originalRows);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
