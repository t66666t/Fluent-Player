import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

/// Ink-box centering of a descender-heavy English sentence is the wrong
/// visual target. These samples cover the body that actually reads as
/// "the letters" against the plate.
const _cjkSample = '风起时，我们再次相遇。';
const _capSample = 'WHEN THE WIND RISES';
const _xSample = 'eleven seasons seem even';
const _wrapSample = 'HAMBURGEFONTSIV twelve letters remain visible tonight';

void main() {
  testWidgets('preset optical offsets keep glyph bodies in the plate', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2000, 1200);
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
      'Inter': ['Inter-Regular.otf', 'Inter-Medium.otf', 'Inter-SemiBold.otf'],
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

    expect(subtitlePresetOpticalOffsetEm('Inter', _cjkSample), -.068);
    expect(
      subtitlePresetOpticalOffsetEm('Noto Serif CJK SC', _cjkSample),
      -.104,
    );
    expect(subtitlePresetOpticalOffsetEm('Inter', _capSample), -.012);
    expect(subtitlePresetOpticalOffsetEm('Roboto', _xSample), 0);

    Directory('build/subtitle-optical-review').createSync(recursive: true);

    for (final font in fonts.keys) {
      for (final size in [24.0, 48.0, 72.0]) {
        for (final reference in [360.0, 720.0]) {
          await _expectBodyCentered(
            tester,
            font: font,
            text: _cjkSample,
            size: size,
            reference: reference,
            // Ideographs fill most of the em square; tight ink is the target.
            maxBias: 1.6,
            label: 'cjk',
          );
          await _expectBodyCentered(
            tester,
            font: font,
            text: _capSample,
            size: size,
            reference: reference,
            maxBias: 2.2,
            label: 'caps',
          );
          await _expectBodyCentered(
            tester,
            font: font,
            text: _xSample,
            size: size,
            reference: reference,
            maxBias: 2.4,
            label: 'xheight',
          );
        }
      }

      // Wrapped Latin still has unused descent on the last line, so the
      // full-ink midpoint is not the visual target. Capture the plate and
      // keep the first-line gap close to the single-line cap sample.
      if (font == 'Inter' ||
          font == 'Roboto' ||
          font == 'Comic Relief' ||
          font == 'Brawler') {
        final wrap = await _renderPreset(
          tester,
          font: font,
          text: _wrapSample,
          size: 48,
          reference: 720,
          maxWidth: 420,
        );
        File(
          'build/subtitle-optical-review/$font-wrap-48.0-720.0.png',
        ).writeAsBytesSync(wrap.png);
        final single = await _renderPreset(
          tester,
          font: font,
          text: _capSample,
          size: 48,
          reference: 720,
          maxWidth: 1800,
        );
        expect(
          (wrap.topGap - single.topGap).abs(),
          lessThanOrEqualTo(2.5),
          reason: '$font wrap top gap ${wrap.topGap} vs ${single.topGap}',
        );
      }
    }

    await _expectBilingualPair(tester);
  });
}

Future<void> _expectBodyCentered(
  WidgetTester tester, {
  required String font,
  required String text,
  required double size,
  required double reference,
  required double maxBias,
  required String label,
  double maxWidth = 1800,
}) async {
  final shot = await _renderPreset(
    tester,
    font: font,
    text: text,
    size: size,
    reference: reference,
    maxWidth: maxWidth,
  );
  expect(
    shot.bias.abs(),
    lessThanOrEqualTo(maxBias),
    reason: '$font $label size=$size reference=$reference bias=${shot.bias}',
  );
  File(
    'build/subtitle-optical-review/$font-$label-$size-$reference.png',
  ).writeAsBytesSync(shot.png);
}

Future<void> _expectBilingualPair(WidgetTester tester) async {
  final key = GlobalKey();
  final preset = subtitleDebugPresets.firstWhere((p) => p.id == '夜读标准');
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: 900,
          child: RepaintBoundary(
            key: key,
            child: SubtitlePresetContent(
              entry: const SubtitleOverlayEntry(
                text: _cjkSample,
                secondaryText: 'When the wind rises, we meet again.',
              ),
              preset: preset.copyWith(box: 0.7),
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
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      'build/subtitle-optical-review/bilingual-night-read.png',
    ).writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
}

class _Shot {
  final double bias;
  final double topGap;
  final Uint8List png;
  const _Shot(this.bias, this.topGap, this.png);
}

Future<_Shot> _renderPreset(
  WidgetTester tester, {
  required String font,
  required String text,
  required double size,
  required double reference,
  required double maxWidth,
}) async {
  final preset = SubtitleDebugPreset(
    id: 'test',
    name: 'test',
    category: 'test',
    description: '',
    primaryFont: font,
    primaryWeight: 500,
    size: size,
    box: 1,
    backgroundColor: const Color(0xFF004080),
    color: Colors.white,
    outline: 0,
    shadowEnabled: false,
  );
  final key = GlobalKey();
  late _Shot shot;
  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: maxWidth,
          child: RepaintBoundary(
            key: key,
            child: SubtitlePresetContent(
              entry: SubtitleOverlayEntry(text: text),
              preset: preset,
              referenceHeight: reference,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
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
    final bias = (top + bottom - (image.height - 1)) / 4;
    final topGap = top / 2;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    shot = _Shot(bias, topGap, png!.buffer.asUint8List());
    image.dispose();
  });
  return shot;
}
