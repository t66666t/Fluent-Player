import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

void main() {
  testWidgets('probe latin optical metrics and screenshots', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2200, 1200);
    addTearDown(tester.view.reset);
    const fonts = {
      'Noto Sans SC': [
        'NotoSansCJKsc-Regular.otf',
        'NotoSansCJKsc-Medium.otf',
        'NotoSansCJKsc-Bold.otf',
      ],
      'Noto Serif CJK SC': [
        'NotoSerifCJKsc-Regular.otf',
        'NotoSerifCJKsc-Bold.otf',
      ],
      'Inter': [
        'Inter-Regular.otf',
        'Inter-Medium.otf',
        'Inter-SemiBold.otf',
      ],
      'Roboto': [
        'Roboto_Condensed-Regular.ttf',
        'Roboto_Condensed-Medium.ttf',
        'Roboto_Condensed-Bold.ttf',
      ],
      'Comic Relief': ['ComicRelief-Regular.ttf', 'ComicRelief-Bold.ttf'],
      'Brawler': ['Brawler-Regular.otf', 'Brawler-Bold.otf'],
    };
    await tester.runAsync(() async {
      for (final e in fonts.entries) {
        final loader = FontLoader(e.key);
        for (final file in e.value) {
          loader.addFont(rootBundle.load('assets/fonts/$file'));
        }
        await loader.load();
      }
    });

    final log = StringBuffer();
    const fontSize = 100.0;
    for (final font in fonts.keys) {
      for (final weight in [400, 500, 600, 700]) {
        final style = TextStyle(
          fontFamily: font,
          fontSize: fontSize,
          fontWeight: FontWeight.values[weight ~/ 100 - 1],
          color: Colors.white,
          height: null,
        );
        _metricLine(log, font, weight, 'H', style);
        _metricLine(log, font, weight, 'x', style);
        _metricLine(log, font, weight, 'Hg', style);
        _metricLine(log, font, weight, 'When the wind rises, we meet again.', style);
      }
    }

    const samples = <String, String>{
      'sentence': 'When the wind rises, we meet again.',
      'xheight': 'eleven seasons seem even',
      'caps': 'WHEN THE WIND RISES',
      'descenders': 'gypqyj going quickly',
      'short': 'OK',
      'wrap':
          'When the wind rises over the long valley we meet again under bright lights tonight.',
    };

    Directory('build/subtitle-optical-review').createSync(recursive: true);
    for (final font in fonts.keys) {
      for (final sample in samples.entries) {
        for (final offsetMode in ['current', 'zero']) {
          final preset = SubtitleDebugPreset(
            id: 'test',
            name: 'test',
            category: 'test',
            description: '',
            primaryFont: font,
            primaryWeight: 500,
            size: 48,
            box: 1,
            backgroundColor: const Color(0xFF004080),
            color: Colors.white,
            outline: 0,
            shadowEnabled: false,
          );
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              home: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: sample.key == 'wrap' ? 420 : 1800,
                  child: RepaintBoundary(
                    key: key,
                    child: offsetMode == 'zero'
                        ? SubtitleOverlay(
                            text: sample.value,
                            style: preset.styleFor(),
                            referenceHeight: 720,
                            opticalOffsetEm: 0,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            isVisualOnly: true,
                          )
                        : SubtitlePresetContent(
                            entry: SubtitleOverlayEntry(text: sample.value),
                            preset: preset,
                            referenceHeight: 720,
                          ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 2);
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            int top = image.height, bottom = -1;
            for (int y = 0; y < image.height; y++) {
              for (int x = 0; x < image.width; x++) {
                final i = (y * image.width + x) * 4;
                if (pixels[i] > 200 &&
                    pixels[i + 1] > 200 &&
                    pixels[i + 2] > 200 &&
                    pixels[i + 3] > 200) {
                  if (y < top) top = y;
                  if (y > bottom) bottom = y;
                }
              }
            }
            final inkMid = (top + bottom) / 2;
            final plateMid = (image.height - 1) / 2;
            // Image is 2x, overlay translate is in logical px.
            final inkBiasLogical = (inkMid - plateMid) / 2;
            log.writeln(
              'shot $font ${sample.key} $offsetMode '
              'h=${image.height} ink=$top..$bottom '
              'biasPx=$inkBiasLogical',
            );
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            File(
              'build/subtitle-optical-review/$font-${sample.key}-$offsetMode.png',
            ).writeAsBytesSync(png!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    }

    final file = File('build/subtitle-english-probe.log');
    file.writeAsStringSync(log.toString(), encoding: utf8);
    // Keep the diagnostic test green; numbers go to the log.
    expect(file.existsSync(), isTrue);
  });
}

void _metricLine(
  StringBuffer log,
  String font,
  int weight,
  String text,
  TextStyle style,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  )..layout();
  final line = painter.computeLineMetrics().single;
  final tight = painter.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
    boxHeightStyle: ui.BoxHeightStyle.tight,
    boxWidthStyle: ui.BoxWidthStyle.tight,
  );
  if (tight.isEmpty) return;
  double tTop = tight.first.top, tBottom = tight.first.bottom;
  for (final b in tight) {
    if (b.top < tTop) tTop = b.top;
    if (b.bottom > tBottom) tBottom = b.bottom;
  }
  final lineCenter = line.height / 2;
  final inkCenter = (tTop + tBottom) / 2;
  final offsetEm = (lineCenter - inkCenter) / style.fontSize!;
  log.writeln(
    'metric $font w$weight "$text" h=${line.height.toStringAsFixed(2)} '
    'ascent=${line.ascent.toStringAsFixed(2)} descent=${line.descent.toStringAsFixed(2)} '
    'base=${line.baseline.toStringAsFixed(2)} tight=${tTop.toStringAsFixed(2)}..${tBottom.toStringAsFixed(2)} '
    'offsetEm=${offsetEm.toStringAsFixed(4)}',
  );
}
