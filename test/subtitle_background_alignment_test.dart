import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/utils/subtitle_font_metrics.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

const _fonts = [
  'Swei Gothic CJK SC',
  'Noto Sans SC',
  'Inter',
  'Roboto',
  'Comic Relief',
  'Brawler',
];
const _chinese = '风起时，我们再次相遇。';
const _english = 'When the wind rises, we meet again.';

class _Shot {
  final Uint8List pixels, png;
  final double topGap, bottomGap, baseline, height;
  const _Shot(
    this.pixels,
    this.png,
    this.topGap,
    this.bottomGap,
    this.baseline,
    this.height,
  );
  double get bias => (topGap - bottomGap) / 2;
}

Future<_Shot> _capture(
  WidgetTester tester,
  String family,
  String text, {
  String? secondary,
  double size = 40,
  double reference = 720,
  bool aligned = true,
  double width = 1600,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: width,
          child: RepaintBoundary(
            key: key,
            child: SubtitleOverlay(
              text: text,
              secondaryText: secondary,
              referenceHeight: reference,
              alignLatinBody: aligned,
              fontFamilyFallback: const ['Noto Sans SC'],
              style: SubtitleStyle(
                textStyle: SubtitleTextStyle(
                  defaultFontFamily: family,
                  defaultFontWeight: family == 'Swei Gothic CJK SC' ? 700 : 400,
                  languageFonts: const {},
                  textColor: Colors.white,
                  backgroundColor: const Color(0xff004080),
                  backgroundOpacity: 1,
                  hasBorder: false,
                  hasShadow: false,
                ),
                layoutStyle: SubtitleLayoutStyle(
                  fontSize: size,
                  secondaryFontSize: size * .85,
                  lineSpacing: 2,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final paragraph = tester.renderObject<RenderParagraph>(
    find.byType(RichText).first,
  );
  final rich = tester.widget<RichText>(find.byType(RichText).first);
  final painter = TextPainter(text: rich.text, textDirection: TextDirection.ltr)
    ..layout(maxWidth: width);
  final baseline = paragraph
      .localToGlobal(Offset(0, painter.computeLineMetrics().first.baseline))
      .dy;
  painter.dispose();
  late _Shot shot;
  await tester.runAsync(() async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(find.byKey(key))
        .toImage(pixelRatio: 2);
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    var top = image.height, bottom = -1;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
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
    expect(bottom, greaterThan(top));
    shot = _Shot(
      pixels,
      (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List(),
      top / 2,
      (image.height - 1 - bottom) / 2,
      baseline,
      image.height / 2,
    );
    image.dispose();
  });
  expect(tester.takeException(), isNull);
  return shot;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List manifest;
  setUpAll(() async {
    manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in _fonts) {
      final entry = manifest.singleWhere((e) => e['family'] == family);
      final loader = FontLoader(family);
      for (final face in entry['fonts'] as List) {
        loader.addFont(rootBundle.load(face['asset'] as String));
      }
      await loader.load();
    }
  });

  test('optical metrics match the real bundled font tables', () async {
    for (final family in _fonts) {
      final entry = manifest.singleWhere((e) => e['family'] == family);
      for (final face in entry['fonts'] as List) {
        final data = await rootBundle.load(face['asset'] as String);
        final parsed = parseSubtitleLatinMetrics(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        expect(parsed, isNotNull, reason: '$family ${face['asset']}');
        expect(
          bundledSubtitleLatinBodyCenter(family, parsed!.weight),
          closeTo(parsed.bodyCenter, 1e-6),
        );
      }
    }
  });

  test('font metric reads reject truncated and out-of-bounds tables', () async {
    expect(
      () => parseSubtitleLatinMetrics(Uint8List(8)),
      throwsFormatException,
    );
    final bytes = Uint8List.fromList(
      await File('assets/fonts/Brawler-Regular.otf').readAsBytes(),
    );
    ByteData.sublistView(bytes).setUint32(20, bytes.length + 100);
    expect(() => parseSubtitleLatinMetrics(bytes), throwsFormatException);
  });

  test(
    'imported font metrics are available again after reopening the library',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp(
        'subtitle_optical_font_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final service = SubtitleFontService(
        storageDirectory: dir,
        fontLoader: (_, _) async {},
      );
      final font = await service.importFile('assets/fonts/Brawler-Regular.otf');
      expect(service.latinBodyCenter(font.id, 400), closeTo(.305, 1e-6));
      final reopened = SubtitleFontService(
        storageDirectory: dir,
        fontLoader: (_, _) async {},
      );
      await reopened.ensureLoaded(font.id);
      expect(reopened.latinBodyCenter(font.id, 400), closeTo(.305, 1e-6));
    },
  );

  testWidgets(
    'English body remains balanced without cue-dependent baseline jumps',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = Directory('build/subtitle-background-alignment/verified')
        ..createSync(recursive: true);
      for (final family in _fonts) {
        for (final size in [24.0, 40.0, 72.0]) {
          for (final reference in [360.0, 720.0]) {
            double? baseline, height;
            for (final text in [
              'WHEN THE WIND RISES',
              'seasons seem even',
              'eleven seasons seem even',
              _english,
            ]) {
              final shot = await _capture(
                tester,
                family,
                text,
                size: size,
                reference: reference,
              );
              final effectiveSize = size * reference / 720;
              expect(
                shot.bias.abs(),
                lessThanOrEqualTo(effectiveSize * .09 + .75),
                reason:
                    '$family size=$size reference=$reference text=$text top=${shot.topGap} bottom=${shot.bottomGap}',
              );
              baseline ??= shot.baseline;
              height ??= shot.height;
              expect(shot.baseline, closeTo(baseline, .01));
              expect(shot.height, height);
              if (size == 40 && reference == 720 && text == _english) {
                File(
                  '${dir.path}/${family.replaceAll(' ', '_')}-english.png',
                ).writeAsBytesSync(shot.png);
              }
            }
          }
        }
      }
    },
  );

  testWidgets(
    'bilingual outer leading is balanced and the primary track stays put',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final family in _fonts) {
        final before = await _capture(
          tester,
          family,
          _chinese,
          secondary: _english,
          aligned: false,
        );
        final after = await _capture(
          tester,
          family,
          _chinese,
          secondary: _english,
        );
        expect(after.baseline, closeTo(before.baseline, .01), reason: family);
        expect(
          after.bias.abs(),
          lessThanOrEqualTo(3),
          reason: '$family top=${after.topGap} bottom=${after.bottomGap}',
        );
        final sourceLines = await _capture(
          tester,
          family,
          '$_chinese\n$_english',
        );
        expect(
          sourceLines.bias.abs(),
          // Optical centering preserves a stable baseline; the full ink box
          // can still include taller Latin ascenders/descenders than CJK.
          lessThanOrEqualTo(40 * .09 + .75),
          reason: '$family source lines',
        );
        final reversed = await _capture(
          tester,
          family,
          _english,
          secondary: _chinese,
        );
        expect(
          reversed.bias.abs(),
          lessThanOrEqualTo(40 * .09 + .75),
          reason:
              '$family reversed tracks top=${reversed.topGap} bottom=${reversed.bottomGap}',
        );
      }
    },
  );

  testWidgets(
    'Chinese-only and same-line mixed scripts retain their original pixels',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final text in [_chinese, '字幕 English 2026']) {
        final original = await _capture(
          tester,
          'Swei Gothic CJK SC',
          text,
          aligned: false,
        );
        final aligned = await _capture(tester, 'Swei Gothic CJK SC', text);
        expect(aligned.pixels, orderedEquals(original.pixels));
      }
    },
  );
}
