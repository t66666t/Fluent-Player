import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/recommended_subtitle_defaults.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/video_compose/video_compose_ass_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_precise_renderer.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';
import 'package:video_player_app/utils/subtitle_layout.dart';

const _primary = '风起时，我们再次相遇，沿着记忆中的街道慢慢走回从前，路灯照亮熟悉的街角，故事也从这里重新开始。';
const _secondary =
    'When the wind rises, we return to the old station where we first met and take the familiar road home together.';
const _style = SubtitleStyle(
  textStyle: RecommendedSubtitleDefaults.textStyle,
  // An old imported preference must not impose screen-size limits on export.
  layoutStyle: SubtitleLayoutStyle(
    adaptiveSizing: true,
    fontSize: 40,
    secondaryFontSize: 26,
  ),
);

Rect _paintedBounds(Uint8List rgba, int width, int height) {
  var left = width, top = height, right = -1, bottom = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (rgba[(y * width + x) * 4 + 3] < 16) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  return Rect.fromLTRB(left.toDouble(), top.toDouble(), right + 1, bottom + 1);
}

void main() {
  for (final balanced in [false, true]) {
    testWidgets(
      'precise export matches proportional preview pixels, balanced=$balanced',
      (tester) async {
        final sourceStyle = balanced
            ? const SubtitleStyle(
                textStyle: RecommendedSubtitleDefaults.textStyle,
                layoutStyle: RecommendedSubtitleDefaults.layout,
              )
            : _style;
        final previewStyle = SubtitleLayout.forVideoExport(sourceStyle);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(() async {
          await (FontLoader('Swei Gothic CJK SC')..addFont(
                rootBundle.load('assets/fonts/SweiGothicCJKsc-Bold.ttf'),
              ))
              .load();
        });
        for (final size in [
          const Size(640, 360),
          const Size(1280, 720),
          const Size(1920, 1080),
          const Size(360, 640),
          const Size(720, 1280),
        ]) {
          final canvasPreviewStyle = balanced && size.shortestSide == 720
              ? sourceStyle
              : previewStyle;
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
                    entries: const [
                      SubtitleOverlayEntry(
                        text: _primary,
                        secondaryText: _secondary,
                      ),
                    ],
                    style: canvasPreviewStyle,
                    alignment: const Alignment(0, .82),
                    enableDebugPreview: false,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(key),
            );
            final playback = await boundary.toImage(pixelRatio: 1);
            final playbackRaw = (await playback.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final dir = Directory(
              'build/subtitle-layout-export/${balanced ? 'balanced' : 'legacy'}/${size.width.toInt()}x${size.height.toInt()}',
            ).absolute;
            await VideoComposePreciseRenderer().render(
              outputDirectory: dir,
              width: size.width.toInt(),
              height: size.height.toInt(),
              duration: const Duration(seconds: 1),
              primary: [
                SubtitleItem(
                  index: 0,
                  startTime: Duration.zero,
                  endTime: const Duration(seconds: 1),
                  text: _primary,
                ),
              ],
              secondary: [
                SubtitleItem(
                  index: 0,
                  startTime: Duration.zero,
                  endTime: const Duration(seconds: 1),
                  text: _secondary,
                ),
              ],
              style: sourceStyle,
              alignment: const Alignment(0, .82),
              splitSubtitleByLine: true,
              itemGap: 6,
              onProgress: (_) {},
              onArtifact: (_) {},
            );
            await File('${dir.path}/captions.ass').writeAsString(
              VideoComposeAssRenderer(
                VideoComposeFontService(),
              ).buildAssContent(
                width: size.width.toInt(),
                height: size.height.toInt(),
                primary: [
                  SubtitleItem(
                    index: 0,
                    startTime: Duration.zero,
                    endTime: const Duration(seconds: 1),
                    text: _primary,
                  ),
                ],
                secondary: [
                  SubtitleItem(
                    index: 0,
                    startTime: Duration.zero,
                    endTime: const Duration(seconds: 1),
                    text: _secondary,
                  ),
                ],
                style: sourceStyle,
                alignment: const Alignment(0, .82),
              ),
            );
            final codec = await ui.instantiateImageCodec(
              await File('${dir.path}/frame_000000.png').readAsBytes(),
            );
            final exported = (await codec.getNextFrame()).image;
            final exportedRaw = (await exported.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            expect(
              listEquals(playbackRaw, exportedRaw),
              isTrue,
              reason: 'preview and export pixels at $size',
            );
            final bounds = _paintedBounds(
              exportedRaw,
              size.width.toInt(),
              size.height.toInt(),
            );
            expect(bounds.isEmpty, isFalse);
            expect(bounds.left, greaterThan(size.width * .06));
            expect(bounds.right, lessThan(size.width * .94));
            playback.dispose();
            exported.dispose();
            codec.dispose();
          });
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}
