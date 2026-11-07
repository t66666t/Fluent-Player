import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_settings_list.dart';

void main() {
  testWidgets(
    'changing one cell height keeps the divider across the whole row',
    (tester) async {
      var expanded = false;
      late StateSetter updateCell;
      const capture = ValueKey('settings-list-paint');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: RepaintBoundary(
                  key: capture,
                  child: MediaLibrarySettingsList(
                    columns: 2,
                    items: [
                      const SizedBox(key: ValueKey('short-cell'), height: 60),
                      StatefulBuilder(
                        key: const ValueKey('tall-cell'),
                        builder: (context, update) {
                          updateCell = update;
                          return SizedBox(height: expanded ? 240 : 160);
                        },
                      ),
                      const SizedBox(key: ValueKey('next-left'), height: 60),
                      const SizedBox(key: ValueKey('next-right'), height: 60),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (final expand in [false, true, false]) {
        updateCell(() => expanded = expand);
        await tester.pumpAndSettle();
        final bottom = expanded ? 240.0 : 160.0;
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('next-left'))).dy,
          bottom,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('next-right'))).dy,
          bottom,
        );
        final colors = await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(capture),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final result = <Color>[];
          for (final point in [
            Offset(20, 59),
            Offset(20, bottom - 1),
            Offset(380, bottom - 1),
            Offset(20, bottom + 10),
          ]) {
            final offset =
                (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
            result.add(
              Color.fromARGB(
                bytes.getUint8(offset + 3),
                bytes.getUint8(offset),
                bytes.getUint8(offset + 1),
                bytes.getUint8(offset + 2),
              ),
            );
          }
          image.dispose();
          return result;
        });
        expect(
          colors![0],
          colors[3],
          reason: 'A short cell must not draw an early divider.',
        );
        expect(
          colors[1],
          colors[2],
          reason: 'Both columns share the same divider.',
        );
        expect(colors[1], isNot(colors[0]));
        expect(tester.takeException(), isNull);
      }
    },
  );
}
