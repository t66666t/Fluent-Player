import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/widgets/ocr_region_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<File> createFrame() async {
    final root = await Directory.systemTemp.createTemp('ocr_editor_test_');
    final image = im.Image(width: 640, height: 360);
    im.fill(image, color: im.ColorRgb8(32, 36, 42));
    final file = File('${root.path}${Platform.pathSeparator}frame.jpg');
    await file.writeAsBytes(im.encodeJpg(image));
    return file;
  }

  Future<void> waitForEditorImage(WidgetTester tester) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.byType(RawImage).evaluate().isNotEmpty) return;
    }
    fail('OCR region editor image did not load');
  }

  testWidgets('can merge the selected region with the region below', (
    tester,
  ) async {
    final frame = await tester.runAsync(createFrame);
    addTearDown(
      () => tester.runAsync(() => frame!.parent.delete(recursive: true)),
    );
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: OcrRegionEditor(
          framePath: frame!.path,
          initialRegions: const <NormalizedOcrRegion>[
            NormalizedOcrRegion(left: 0.2, top: 0.62, right: 0.8, bottom: 0.70),
            NormalizedOcrRegion(
              left: 0.22,
              top: 0.74,
              right: 0.78,
              bottom: 0.82,
            ),
          ],
        ),
      ),
    );
    await waitForEditorImage(tester);

    final canvasBottom = tester
        .getBottomLeft(find.byKey(const ValueKey('ocr_region_canvas')))
        .dy;
    final infoBarTop = tester
        .getTopLeft(find.byKey(const ValueKey('ocr_region_info_bar')))
        .dy;
    expect(canvasBottom, lessThanOrEqualTo(infoBarTop));

    await tester.tap(find.byTooltip('与下方区域合并'));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('字幕区域 1/1'), findsOneWidget);
  });

  testWidgets(
    'timeline is touch friendly and does not cover the video canvas',
    (tester) async {
      final frame = await tester.runAsync(createFrame);
      addTearDown(
        () => tester.runAsync(() => frame!.parent.delete(recursive: true)),
      );
      await tester.binding.setSurfaceSize(const Size(430, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requested = <Duration>[];

      await tester.pumpWidget(
        MaterialApp(
          home: OcrRegionEditor(
            framePath: frame!.path,
            initialRegions: const <NormalizedOcrRegion>[
              NormalizedOcrRegion.subtitleDefault(),
            ],
            duration: const Duration(minutes: 2),
            initialPosition: const Duration(seconds: 30),
            loadFrameAt: (position) async {
              requested.add(position);
              return frame.path;
            },
            releaseFrame: (_) async {},
          ),
        ),
      );
      await waitForEditorImage(tester);

      expect(find.byKey(const ValueKey('ocr_timeline_slider')), findsOneWidget);
      expect(find.text('00:30'), findsOneWidget);
      expect(find.text('02:00'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('ocr_timeline_back_10')))
            .shortestSide,
        greaterThanOrEqualTo(48),
      );

      final canvasBottom = tester
          .getBottomLeft(find.byKey(const ValueKey('ocr_region_canvas')))
          .dy;
      final timelineTop = tester
          .getTopLeft(find.byKey(const ValueKey('ocr_region_timeline')))
          .dy;
      expect(canvasBottom, lessThanOrEqualTo(timelineTop));

      await tester.tap(find.byKey(const ValueKey('ocr_timeline_forward_10')));
      for (var attempt = 0; attempt < 10 && requested.isEmpty; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(requested, contains(const Duration(seconds: 40)));
      for (
        var attempt = 0;
        attempt < 20 && find.text('00:40').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.text('00:40'), findsOneWidget);

      requested.clear();
      final hoverRegion = find.byKey(
        const ValueKey('ocr_timeline_hover_region'),
      );
      final hoverRect = tester.getRect(hoverRegion);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(0, 0));
      await mouse.moveTo(
        Offset(hoverRect.left + hoverRect.width * 0.75, hoverRect.center.dy),
      );
      for (var attempt = 0; attempt < 10 && requested.isEmpty; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(requested, isNotEmpty);
      expect(requested.last.inSeconds, inInclusiveRange(85, 95));
    },
  );
}
