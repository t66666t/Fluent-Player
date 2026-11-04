import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/recommended_subtitle_defaults.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/utils/subtitle_layout.dart';
import 'package:video_player_app/services/video_compose/video_compose_ass_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';

const _style = SubtitleStyle(
  textStyle: RecommendedSubtitleDefaults.textStyle,
  layoutStyle: RecommendedSubtitleDefaults.layout,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('balanced mode round-trips and manual sizes remain multiplicative', () {
    final original = SubtitleStyle.fromJson(_style.toJson());
    expect(original.layoutStyle.balancedScreenSizing, true);
    final reference = SubtitleLayout.balancedScreenReferenceHeight(
      const Size(1200, 750),
    );
    final base = SubtitleResolvedStyleMetrics.fromStyle(
      original,
      referenceHeight: reference,
    );
    final changed = original.copyWith(
      overallScale: 1.25,
      fontSize: original.fontSize * 1.1,
      secondaryFontSize: original.secondaryFontSize! * .9,
    );
    final actual = SubtitleResolvedStyleMetrics.fromStyle(
      changed,
      referenceHeight: reference,
    );
    expect(actual.fontSize, closeTo(base.fontSize * 1.1 * 1.25, 1e-8));
    expect(
      actual.secondaryFontSize,
      closeTo(base.secondaryFontSize * .9 * 1.25, 1e-8),
    );
    expect(SubtitleLayoutStyle.fromJson({}).balancedScreenSizing, false);
    expect(
      SubtitleLayout.forVideoExport(const SubtitleStyle()),
      same(const SubtitleStyle()),
    );
  });

  test('ordinary ratio stays fixed when rotating or narrowing the video', () {
    const portraitPage = Size(750, 1200);
    const landscapePage = Size(1200, 750);
    final ratios = <double>[];
    for (final sample in [
      (portraitPage, const Size(750, 421.875)),
      (landscapePage, const Size(1200, 675)),
      (landscapePage, const Size(900, 506.25)),
    ]) {
      final resolved = SubtitleResolvedStyleMetrics.fromStyle(
        _style,
        referenceHeight: SubtitleLayout.balancedVideoReferenceHeight(
          sample.$2,
          pageSize: sample.$1,
        ),
      );
      ratios.add(resolved.fontSize / sample.$2.shortestSide);
    }
    expect(ratios[1], closeTo(ratios[0], 1e-10));
    expect(ratios[2], closeTo(ratios[0], 1e-10));
  });

  test(
    'extreme and invalid screen sizes stay bounded and narrow panes fit',
    () {
      for (final size in [
        const Size(200, 300),
        const Size(7680, 4320),
        Size.zero,
        Size.infinite,
      ]) {
        final metrics = SubtitleResolvedStyleMetrics.fromStyle(
          _style,
          referenceHeight: SubtitleLayout.balancedScreenReferenceHeight(size),
        );
        expect(metrics.fontSize, inInclusiveRange(16, 26));
        expect(
          metrics.secondaryFontSize / metrics.fontSize,
          closeTo(.85, 1e-8),
        );
      }
      final narrow = SubtitleResolvedStyleMetrics.fromStyle(
        _style,
        referenceHeight: SubtitleLayout.balancedScreenReferenceHeight(
          const Size(1200, 750),
          viewportWidth: 200,
        ),
      );
      expect(narrow.fontSize * 12, lessThanOrEqualTo(200 * .86 + 1e-8));
    },
  );

  test(
    'ASS exports scale through 4K and portrait with the same 85 percent ratio',
    () {
      final renderer = VideoComposeAssRenderer(VideoComposeFontService());
      final primarySizes = <double>[];
      for (final size in [
        const Size(1280, 720),
        const Size(1920, 1080),
        const Size(3840, 2160),
        const Size(720, 1280),
      ]) {
        final ass = renderer.buildAssContent(
          width: size.width.toInt(),
          height: size.height.toInt(),
          primary: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: Duration(seconds: 1),
              text: '主字幕',
            ),
          ],
          secondary: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: Duration(seconds: 1),
              text: 'Secondary subtitle',
            ),
          ],
          style: _style,
          alignment: const Alignment(0, .82),
        );
        final font = double.parse(
          ass
              .split('\n')
              .firstWhere((line) => line.startsWith('Style: Default,'))
              .split(',')[2],
        );
        primarySizes.add(font);
        expect(font, closeTo(23.098 * size.shortestSide / 720, .02));
        final runSizes =
            RegExp(r'\\fs(\d+(?:\.\d+)?)')
                .allMatches(ass)
                .map((match) => double.parse(match.group(1)!))
                .toSet()
                .toList()
              ..sort();
        expect(runSizes, hasLength(2));
        expect(runSizes.first / runSizes.last, closeTo(.85, .0005));
      }
      expect(primarySizes[2], closeTo(primarySizes[0] * 3, .02));
      expect(primarySizes[3], primarySizes[0]);
    },
  );
}
