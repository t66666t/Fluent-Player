import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/ocr_inference_engine.dart';
import 'package:video_player_app/services/ocr_processing_worker.dart';

void main() {
  const main = OcrDetectedBox(80, 50, 500, 90, .9);
  const profile = OcrSubtitleGeometry(height: .4, center: .7);

  test('wide user region rejects a smaller side word on the same baseline', () {
    // Original 1280x720 video, original 835x48 region, production 640x36 crop.
    const subtitle = OcrDetectedBox(99, 11, 548, 32, .94);
    const background = OcrDetectedBox(574, 21, 617, 34, .71);
    expect(
      prepareOcrSubtitleBoxes(
        [subtitle, background],
        36,
        geometry: const OcrSubtitleGeometry(height: 22 / 36, center: 22 / 36),
      ),
      [subtitle],
    );
  });

  test(
    'normal-size words can extend to the right edge of a wide user region',
    () {
      const first = OcrDetectedBox(10, 10, 240, 32, .9);
      const last = OcrDetectedBox(475, 10, 640, 32, .9);
      expect(prepareOcrSubtitleBoxes([first, last], 36), [first, last]);
    },
  );

  test(
    'recognition padding cannot hide a smaller word beside long subtitles',
    () {
      const subtitle = OcrDetectedBox(
        64,
        11,
        583,
        33,
        .94,
        contentBounds: (left: 81, top: 15, right: 566, bottom: 29),
      );
      const background = OcrDetectedBox(
        578,
        22,
        614,
        34,
        .71,
        contentBounds: (left: 584, top: 24, right: 608, bottom: 32),
      );
      expect(prepareOcrSubtitleBoxes([subtitle, background], 36), [subtitle]);
    },
  );

  test('minor glyph height differences preserve separated normal words', () {
    const subtitle = OcrDetectedBox(20, 50, 400, 90, .9);
    const word = OcrDetectedBox(550, 56, 630, 90, .9);
    expect(prepareOcrSubtitleBoxes([subtitle, word], 100), [subtitle, word]);
  });

  test('a tall narrow background fragment cannot reject normal subtitles', () {
    const subtitle = OcrDetectedBox(168, 11, 476, 33, .94);
    const background = OcrDetectedBox(607, 1, 640, 35, .7);
    expect(
      prepareOcrSubtitleBoxes([background, subtitle], 36),
      contains(subtitle),
    );
  });

  test('ambiguous narrow glyphs retain the existing recognition path', () {
    const letter = OcrDetectedBox(551, 66, 569, 90, .9);
    final result = prepareOcrSubtitleBoxes([main, letter], 100);
    expect(result.single.left, main.left);
    expect(result.single.right, letter.right);
    expect(isOcrSubtitleSideLabel(letter, [main, letter], 40), isFalse);
  });

  test('long lines cannot expand into distant small background labels', () {
    // Real device frame: the 466x12 detector component grew by 117 pixels
    // on each side, covering a separate label about 50 pixels to its right.
    expect(ocrDetectionHorizontalPadding(466, 12), 18);
    expect(ocrDetectionHorizontalPadding(900, 12), 18);
    expect(ocrDetectionHorizontalPadding(48, 40), 12);
    expect(ocrDetectionHorizontalPadding(5, 10), 2);
  });

  test('small background words are removed before recognition and merging', () {
    const tiny = OcrDetectedBox(10, 15, 70, 27, .98);
    final result = prepareOcrSubtitleBoxes([tiny, main], 100);
    expect(result, [main]);
  });

  test('a half-height label on another baseline cannot contaminate a line', () {
    // The old merge's 0.5 height ratio and 55% overlap accepted this label.
    const label = OcrDetectedBox(510, 52, 570, 76, .98);
    final result = prepareOcrSubtitleBoxes([main, label], 100);
    expect(result, [main]);
  });

  test(
    'small off-row background text is rejected using the region profile',
    () {
      const label = OcrDetectedBox(5, 0, 150, 26, .98);
      expect(prepareOcrSubtitleBoxes([label], 100, geometry: profile), isEmpty);
      // With no profile, a uniformly small subtitle is still a valid subtitle.
      expect(prepareOcrSubtitleBoxes([label], 100), [label]);
    },
  );

  test('a blank interval cannot promote remaining small background text', () {
    const label = OcrDetectedBox(5, 5, 90, 17, .98);
    expect(prepareOcrSubtitleBoxes([label], 100, geometry: profile), isEmpty);
  });

  test('single-character and short subtitles have no minimum width', () {
    for (final box in [
      const OcrDetectedBox(200, 50, 230, 90, .9),
      const OcrDetectedBox(200, 50, 211, 90, .9),
      const OcrDetectedBox(200, 57, 260, 89, .9),
    ]) {
      expect(prepareOcrSubtitleBoxes([box], 100, geometry: profile), [box]);
    }
  });

  test('mixed case words sharing a baseline are still merged', () {
    const capitals = OcrDetectedBox(20, 50, 100, 90, .9);
    const lowercase = OcrDetectedBox(110, 68, 230, 90, .9);
    final result = prepareOcrSubtitleBoxes([capitals, lowercase], 100);
    expect(result.length, 1);
    expect(result.single.left, 20);
    expect(result.single.right, 230);
  });

  test(
    'small punctuation beside a word or alone at its baseline is retained',
    () {
      const period = OcrDetectedBox(505, 83, 512, 90, .9);
      const ellipsis = OcrDetectedBox(210, 83, 248, 90, .9);
      final result = prepareOcrSubtitleBoxes([main, period], 100);
      expect(result, contains(period));
      expect(prepareOcrSubtitleBoxes([ellipsis], 100, geometry: profile), [
        ellipsis,
      ]);
    },
  );

  test(
    'two rows, left/right movement and uppercase fragments are retained',
    () {
      const top = OcrDetectedBox(5, 0, 405, 40, .9);
      const bottom = OcrDetectedBox(180, 55, 580, 95, .9);
      expect(prepareOcrSubtitleBoxes([top, bottom], 100, geometry: profile), [
        top,
        bottom,
      ]);
      const narrow = OcrDetectedBox(10, 0, 20, 45, .9);
      expect(prepareOcrSubtitleBoxes([narrow], 100), [narrow]);
    },
  );

  test('relative geometry works after resolution changes and tight crops', () {
    for (final scale in [1, 2, 4]) {
      OcrDetectedBox scaled(OcrDetectedBox b) => OcrDetectedBox(
        b.left * scale,
        b.top * scale,
        b.right * scale,
        b.bottom * scale,
        b.score,
      );
      const label = OcrDetectedBox(5, 0, 150, 26, .98);
      final subtitle = scaled(main);
      expect(
        prepareOcrSubtitleBoxes(
          [scaled(label), subtitle],
          100 * scale,
          geometry: profile,
        ),
        [subtitle],
      );
    }
    const tight = OcrDetectedBox(0, 0, 100, 20, .9);
    expect(prepareOcrSubtitleBoxes([tight], 20), [tight]);
  });

  test(
    'a somewhat smaller genuine second row survives an existing profile',
    () {
      const top = OcrDetectedBox(80, 0, 400, 28, .9);
      expect(prepareOcrSubtitleBoxes([top, main], 100, geometry: profile), [
        top,
        main,
      ]);
      const shortTop = OcrDetectedBox(250, 0, 275, 28, .9);
      expect(
        prepareOcrSubtitleBoxes([shortTop, main], 100, geometry: profile),
        [shortTop, main],
      );
      final filter = OcrSubtitleStyleFilter();
      const bottomLine = OcrTextLineResult(
        text: 'bottom',
        confidence: .9,
        left: 80,
        top: 50,
        right: 500,
        bottom: 90,
      );
      const topLine = OcrTextLineResult(
        text: 'top',
        confidence: .9,
        left: 80,
        top: 0,
        right: 400,
        bottom: 28,
      );
      for (var i = 0; i < 4; i++) {
        filter.filter(
          const OcrTextResult('bottom', .9, [bottomLine]),
          640,
          100,
        );
      }
      expect(
        filter
            .filter(
              const OcrTextResult('top\nbottom', .9, [topLine, bottomLine]),
              640,
              100,
            )
            .text,
        'top\nbottom',
      );
    },
  );

  test('missing or invalid geometry uses same-frame evidence', () {
    for (final bad in [
      const OcrSubtitleGeometry(height: 0, center: .5),
      const OcrSubtitleGeometry(height: double.nan, center: .5),
      const OcrSubtitleGeometry(height: .4, center: double.infinity),
    ]) {
      expect(prepareOcrSubtitleBoxes([main], 100, geometry: bad), [main]);
    }
    expect(prepareOcrSubtitleBoxes([], 100), isEmpty);
  });

  test('profile remains per region and does not learn rejected labels', () {
    final primary = OcrSubtitleStyleFilter();
    final secondary = OcrSubtitleStyleFilter();
    const subtitle = OcrTextLineResult(
      text: '字幕 / subtitle',
      confidence: .9,
      left: 80,
      top: 50,
      right: 500,
      bottom: 90,
    );
    const label = OcrTextLineResult(
      text: 'background label',
      confidence: .98,
      left: 5,
      top: 0,
      right: 150,
      bottom: 26,
    );
    for (var i = 0; i < 4; i++) {
      primary.filter(const OcrTextResult('字幕', .9, [subtitle]), 640, 100);
      secondary.filter(const OcrTextResult('small', .9, [label]), 640, 100);
    }
    expect(primary.geometry!.height, .4);
    expect(secondary.geometry!.height, .26);
    for (var i = 0; i < 40; i++) {
      expect(
        primary
            .filter(const OcrTextResult('label', .98, [label]), 640, 100)
            .text,
        isEmpty,
      );
    }
    expect(primary.geometry!.height, .4);
    expect(
      primary.filter(const OcrTextResult('字幕', .9, [subtitle]), 640, 100).text,
      '字幕 / subtitle',
    );
    primary.reset();
    expect(primary.geometry, isNull);
  });

  test(
    'small pre-roll text cannot lock out a larger single-character subtitle',
    () {
      final filter = OcrSubtitleStyleFilter();
      const label = OcrTextLineResult(
        text: 'shop',
        confidence: .95,
        left: 5,
        top: 4,
        right: 65,
        bottom: 16,
      );
      const subtitle = OcrTextLineResult(
        text: '嗯',
        confidence: .9,
        left: 290,
        top: 50,
        right: 325,
        bottom: 90,
      );
      for (var i = 0; i < 4; i++) {
        filter.filter(const OcrTextResult('shop', .95, [label]), 640, 100);
      }
      expect(filter.geometry!.height, .12);
      expect(
        filter.filter(const OcrTextResult('嗯', .9, [subtitle]), 640, 100).text,
        '嗯',
      );
      for (var i = 0; i < 4; i++) {
        filter.filter(const OcrTextResult('嗯', .9, [subtitle]), 640, 100);
      }
      expect(filter.geometry!.height, .4);
      expect(
        filter.filter(const OcrTextResult('shop', .95, [label]), 640, 100).text,
        isEmpty,
      );
    },
  );
}
