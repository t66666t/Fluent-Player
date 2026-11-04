import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

void main() {
  setUpAll(() async {
    for (final entry in {
      'Inter': 'assets/fonts/Inter-ExtraBold.otf',
      'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    for (final index in [0, 1]) {
      testWidgets(
        '$platform wrapped lyric $index and guide share the safe anchor',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          const paragraph =
              'We walk through the city, taking time to listen. Every street tells a story.';
          const translation = '慢慢走过这座城市，听听街道里的故事，重新认识身边的世界。';
          final subtitles = [
            if (index == 1)
              SubtitleItem(
                index: 0,
                startTime: Duration.zero,
                endTime: const Duration(seconds: 10),
                text: 'Opening line',
              ),
            SubtitleItem(
              index: index,
              startTime: Duration(seconds: index * 10),
              endTime: const Duration(minutes: 1),
              text: paragraph,
              lyricTranslation: translation,
            ),
          ];
          final anchor = ValueNotifier(0.28);
          final clock = ValueNotifier(Duration(seconds: index * 10));
          addTearDown(anchor.dispose);
          addTearDown(clock.dispose);
          Offset? guide;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: ValueListenableBuilder<double>(
                  valueListenable: anchor,
                  builder: (context, value, _) => MusicLyricView(
                    subtitles: subtitles,
                    positionListenable: clock,
                    isPlaying: false,
                    anchorFraction: value,
                    focusInsets: const EdgeInsets.only(top: 40, bottom: 150),
                    showAnchorGuide: true,
                    onAnchorGuidePositionChanged: (position) =>
                        guide = position,
                    applyEdgeFade: false,
                  ),
                ),
              ),
            ),
          );
          for (final value in [0.28, 0.7, 0.1, 0.42]) {
            anchor.value = value;
            await tester.pumpAndSettle();
            expect(guide, isNotNull);
            expect(
              guide!.dy,
              closeTo(tester.getTopLeft(find.text(paragraph)).dy, 1.5),
            );
            expect(guide!.dy, greaterThanOrEqualTo(40));
            expect(
              tester.getBottomLeft(find.text(translation)).dy,
              lessThanOrEqualTo(451),
            );
            if (value == 0.7) expect(guide!.dy, lessThan(600 * value - 10));
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
