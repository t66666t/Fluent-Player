import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/video_action_caption.dart';

void main() {
  testWidgets(
    'backplate hugs the text and blends into the library background',
    (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(),
            child: Center(
              child: DefaultTextStyle(
                style: TextStyle(fontSize: 14),
                child: VideoActionCaption(label: '生成字幕', fontSize: 11),
              ),
            ),
          ),
        ),
      );
      final back = find.byKey(const ValueKey('action-label-backplate-生成字幕'));
      final text = find.byKey(const ValueKey('action-label-生成字幕'));
      final decoration =
          tester.widget<DecoratedBox>(back).decoration as BoxDecoration;
      expect(decoration.color, AppTokens.bgBase);
      expect(decoration.color!.a, 1);
      expect(decoration.border, isNull);
      expect(decoration.boxShadow, isNull);
      expect(
        tester.getSize(back).width - tester.getSize(text).width,
        closeTo(6, 0.01),
      );
      expect(
        tester.getSize(back).height - tester.getSize(text).height,
        closeTo(1, 0.01),
      );
      expect(
        tester.getCenter(back).dx,
        closeTo(tester.getCenter(text).dx, 0.01),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real MiSans glyphs stay visually centered in short and mixed captions',
    (tester) async {
      await tester.runAsync(() async {
        await (FontLoader(
          'MiSans',
        )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
      });
      for (final fontSize in [10.5, 11.0]) {
        for (final scale in [1.0, 1.5, 2.0]) {
          for (final label in [
            '生成字幕',
            '新建合集',
            '导入媒体',
            'B站下载',
            '通用下载',
            '抖音下载',
            '网页导入',
            '缓存管理',
            '展开',
            '收起',
          ]) {
            final key = GlobalKey();
            await tester.pumpWidget(
              Directionality(
                textDirection: TextDirection.ltr,
                child: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: DefaultTextStyle(
                    style: const TextStyle(fontFamily: 'MiSans', fontSize: 14),
                    child: Center(
                      child: RepaintBoundary(
                        key: key,
                        child: VideoActionCaption(
                          label: label,
                          fontSize: fontSize,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              const pixelRatio = 8.0;
              final bitmap = await boundary.toImage(pixelRatio: pixelRatio);
              final pixels = (await bitmap.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              var minX = bitmap.width,
                  minY = bitmap.height,
                  maxX = -1,
                  maxY = -1;
              for (var y = 0; y < bitmap.height; y++) {
                for (var x = 0; x < bitmap.width; x++) {
                  final index = (y * bitmap.width + x) * 4;
                  if (pixels.getUint8(index) > 140 &&
                      pixels.getUint8(index + 3) > 128) {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                  }
                }
              }
              bitmap.dispose();
              expect(maxX, greaterThan(minX));
              final inkCenter = Offset(
                (minX + maxX + 1) / (2 * pixelRatio),
                (minY + maxY + 1) / (2 * pixelRatio),
              );
              final delta = inkCenter - boundary.size.center(Offset.zero);
              final reason = '$label, $fontSize px, text scale $scale';
              expect(
                delta.dx.abs(),
                lessThanOrEqualTo(0.5 * scale),
                reason: reason,
              );
              expect(
                delta.dy.abs(),
                lessThanOrEqualTo(0.5 * scale),
                reason: reason,
              );
            });
          }
        }
      }
      expect(tester.takeException(), isNull);
    },
  );
}
