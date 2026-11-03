import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/music_lyric_typography.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

void main() {
  setUpAll(() async {
    for (final font in {
      'Inter': 'assets/fonts/Inter-ExtraBold.otf',
      'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  test(
    'defaults adapt to screens and spacing follows accessibility text size',
    () {
      final phone = MusicLyricTypography.resolve(
        viewport: const Size(320, 640),
      );
      final desktop = MusicLyricTypography.resolve(
        viewport: const Size(1440, 900),
      );
      expect(phone.primaryFontSize, closeTo(28.8, 0.001));
      expect(desktop.primaryFontSize, closeTo(40.5, 0.001));
      expect(desktop.primaryFontSize, greaterThan(phone.primaryFontSize));
      final accessible = MusicLyricTypography.resolve(
        viewport: const Size(320, 640),
        textScaler: TextScaler.linear(1.8),
      );
      expect(accessible.stanzaGap, closeTo(phone.stanzaGap * 1.8, 0.001));
      expect(accessible.supportGap, closeTo(phone.supportGap * 1.8, 0.001));
      expect(MusicLyricTypography.normalizeFontSizeScale(double.nan), 1);
      expect(MusicLyricTypography.normalizeSpacingScale(double.infinity), 1);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      '$platform scales actual lyric gaps and preserves the active anchor',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final clock = ValueNotifier(const Duration(seconds: 50));
        addTearDown(clock.dispose);
        final cues = List.generate(
          40,
          (i) => SubtitleItem(
            index: i,
            startTime: Duration(seconds: i * 5),
            endTime: Duration(seconds: i * 5 + 5),
            text: '$i',
            lyricTranslation: 't$i',
          ),
        );
        var font = 1.0;
        var spacing = 1.0;
        Future<void> show() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: MusicLyricView(
                  subtitles: cues,
                  positionListenable: clock,
                  lyricFontSizeScale: font,
                  lyricSpacingScale: spacing,
                  applyEdgeFade: false,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final current = '${clock.value.inSeconds ~/ 5}';
          expect(tester.getTopLeft(find.text(current)).dy, closeTo(240, 0.2));
          expect(tester.takeException(), isNull);
        }

        double rowStep() =>
            tester.getTopLeft(find.text('11')).dy -
            tester.getTopLeft(find.text('10')).dy;
        double supportGap() =>
            tester.getTopLeft(find.text('t10')).dy -
            tester.getBottomLeft(find.text('10')).dy;
        double fontSize() => tester
            .widget<MusicTimedLyricText>(
              find.byWidgetPredicate(
                (w) => w is MusicTimedLyricText && w.text == '10',
              ),
            )
            .style
            .fontSize!;

        await show();
        final normalStep = rowStep();
        final normalSupportGap = supportGap();
        font = 2;
        await show();
        // Font line boxes can round by a logical pixel when resized.
        expect(rowStep(), closeTo(normalStep * 2, 1.1));
        expect(supportGap(), closeTo(normalSupportGap * 2, 0.2));

        font = 1;
        spacing = 0;
        await show();
        final compactStep = rowStep();
        expect(supportGap(), closeTo(0, 0.2));
        spacing = 4;
        await show();
        expect(
          rowStep() - compactStep,
          closeTo((normalStep - compactStep) * 4, 0.2),
        );
        expect(supportGap(), closeTo(normalSupportGap * 4, 0.2));

        spacing = 1;
        for (final scale in [0.4, 0.401, 2.999, 3.0]) {
          font = scale;
          await show();
          expect(fontSize(), closeTo(36 * scale, 0.001));
        }
        // Row measurements must also place a distant row correctly
        // after large size/spacing changes, on both scroll implementations.
        spacing = 4;
        clock.value = cues.last.startTime;
        await show();
        expect(tester.getTopLeft(find.text('39')).dy, closeTo(240, 0.2));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
