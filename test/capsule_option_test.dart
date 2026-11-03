import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/capsule_option.dart';

void main() {
  testWidgets(
    'held presses paint inside the capsule without filling its corners',
    (tester) async {
      const key = ValueKey('capsule-pixels');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.red,
          ),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: CapsuleOption(
                  color: Colors.grey,
                  onTap: () {},
                  child: const SizedBox(width: 160, height: 42),
                ),
              ),
            ),
          ),
        ),
      );
      Future<List<int>> pixel(int x, int y) async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          final offset = (y * image.width + x) * 4;
          final color = bytes.sublist(offset, offset + 4);
          image.dispose();
          return color;
        }))!;
      }

      final corner = await pixel(4, 4);
      final interior = await pixel(80, 5);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(key)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(await pixel(4, 4), corner);
      expect(await pixel(80, 5), isNot(interior));
      await gesture.cancel();
    },
  );
}
