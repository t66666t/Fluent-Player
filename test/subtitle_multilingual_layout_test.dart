import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/video_compose/video_compose_ass_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_precise_renderer.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

const _style = SubtitleStyle(
  textStyle: SubtitleTextStyle(
    defaultFontFamily: 'Noto Sans SC',
    languageFonts: {},
    fontFamilyChinese: 'Noto Sans SC',
    fontFamilyEnglish: 'Noto Sans SC',
    fontWeightChinese: FontWeight.w400,
    fontWeightEnglish: FontWeight.w400,
  ),
  layoutStyle: SubtitleLayoutStyle(fontSize: 40, secondaryFontSize: 28),
);
const _cases = {
  'zh': (
    '如果你只是想改变字幕的颜色，可以在设置里调整。',
    'If you only want to change the subtitle color, adjust it in the settings.',
  ),
  'en': (
    'We returned to the old station, where our journey first began.',
    '我们又回到了那座老车站，旅程就是从这里开始的。',
  ),
  'ja': (
    '字幕の色を変えたい場合は、設定画面で調整できます。「コーヒーショップ」で試しましょう。',
    'To change the subtitle color, open the settings and choose a color.',
  ),
  'ko': (
    '자막의 색상을 변경하려면 설정에서 조정할 수 있습니다. 함께 확인해 보세요.',
    'To change the subtitle color, open the settings and choose a color.',
  ),
};

SubtitleItem _cue(String text) => SubtitleItem(
  index: 0,
  startTime: Duration.zero,
  endTime: const Duration(seconds: 1),
  text: text,
);

void main() {
  for (final sample in _cases.entries) {
    testWidgets('multilingual playback and both exports agree: ${sample.key}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await (FontLoader('Noto Sans SC')..addFont(
              rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
            ))
            .load();
      });
      for (final size in [const Size(360, 640), const Size(640, 360)]) {
        await tester.binding.setSurfaceSize(size);
        final key = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: MediaQueryData(size: size),
              child: RepaintBoundary(
                key: key,
                child: SubtitleOverlayGroup(
                  enableDebugPreview: false,
                  entries: [
                    SubtitleOverlayEntry(
                      language: sample.key,
                      text: sample.value.$1,
                      secondaryText: sample.value.$2,
                    ),
                  ],
                  style: _style,
                  alignment: const Alignment(0, .82),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final painted = tester
            .widgetList<RichText>(find.byType(RichText))
            .map((w) => w.text.toPlainText(includeSemanticsLabels: false))
            .toList();
        expect(
          painted,
          hasLength(4),
          reason: 'each track has a fill and outline paragraph',
        );
        expect(
          painted[0],
          painted[2],
          reason: 'primary fill and outline share the cuts',
        );
        expect(
          painted[1],
          painted[3],
          reason: 'secondary fill and outline share the cuts',
        );
        final combined = '${painted[0]}\n${painted[1]}';
        final source = [_cue(sample.value.$1)];
        final secondary = [_cue(sample.value.$2)];
        final ass = VideoComposeAssRenderer(VideoComposeFontService())
            .buildAssContent(
              width: size.width.toInt(),
              height: size.height.toInt(),
              primary: source,
              secondary: secondary,
              style: _style,
              alignment: const Alignment(0, .82),
              primaryLanguage: sample.key,
            );
        final layers = ass.split('\n').where((l) => l.startsWith('Dialogue:'));
        expect(layers, hasLength(4));
        for (final layer in layers) {
          final text = layer
              .split(',')
              .skip(9)
              .join(',')
              .replaceAll(RegExp(r'\{[^}]*\}'), '')
              .replaceAll(r'\N', '\n');
          expect(text, combined);
        }
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(key),
          );
          final playback = await boundary.toImage(pixelRatio: 1);
          final dir = Directory(
            'build/subtitle-multilingual-wrap/'
            '${sample.key}-${size.width.toInt()}x${size.height.toInt()}',
          ).absolute;
          await VideoComposePreciseRenderer().render(
            outputDirectory: dir,
            width: size.width.toInt(),
            height: size.height.toInt(),
            duration: const Duration(seconds: 1),
            primary: source,
            secondary: secondary,
            style: _style,
            alignment: const Alignment(0, .82),
            primaryLanguage: sample.key,
            splitSubtitleByLine: false,
            itemGap: 6,
            onProgress: (_) {},
            onArtifact: (_) {},
          );
          final codec = await ui.instantiateImageCodec(
            await File('${dir.path}/frame_000000.png').readAsBytes(),
          );
          final exported = (await codec.getNextFrame()).image;
          try {
            final a = (await playback.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final b = (await exported.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            expect(
              listEquals(a, b),
              isTrue,
              reason: 'same pixels at $size for ${sample.key}',
            );
          } finally {
            playback.dispose();
            exported.dispose();
            codec.dispose();
          }
        });
        expect(source.single.text, sample.value.$1);
        expect(secondary.single.text, sample.value.$2);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
