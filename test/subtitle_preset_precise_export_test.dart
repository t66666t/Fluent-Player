import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/services/video_compose/video_compose_precise_renderer.dart';

void main() {
  testWidgets('precise export renders full preset snapshots on all canvas ratios', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final entry in {
        'Noto Sans SC': 'NotoSansCJKsc-Bold.otf',
        'Inter': 'Inter-SemiBold.otf',
      }.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(rootBundle.load('assets/fonts/${entry.value}'));
        await loader.load();
      }
      final renderer = VideoComposePreciseRenderer();
      final snapshot = subtitleDebugPresets[18].copyWith(
        box: .5,
        textScale: 1.2,
        shadowBlur: 3,
      );
      for (final size in [
        const Size(640, 360),
        const Size(640, 268),
        const Size(480, 360),
        const Size(360, 360),
        const Size(360, 640),
      ]) {
        final dir = Directory(
          'build/subtitle-preset-export/${size.width.toInt()}x${size.height.toInt()}',
        ).absolute;
        final result = await renderer.render(
          outputDirectory: dir,
          width: size.width.toInt(),
          height: size.height.toInt(),
          duration: const Duration(seconds: 2),
          primary: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
              text: '风起时，我们再次相遇。',
            ),
          ],
          secondary: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
              text: 'When the wind rises, we meet again.',
            ),
          ],
          style: const SubtitleStyle(),
          subtitlePreset: snapshot,
          alignment: Alignment.topLeft,
          splitSubtitleByLine: true,
          itemGap: 6,
          onProgress: (_) {},
          onArtifact: (_) {},
        );
        expect(result.frameCount, 1);
        expect(
          await File(result.concatPath).readAsString(),
          contains('duration 2.0'),
        );
        final bytes = await File('${dir.path}/frame_000000.png').readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        expect(image.width, size.width.toInt());
        expect(image.height, size.height.toInt());
        final raw = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        int count = 0, bottom = 0;
        for (int y = 0; y < image.height; y++) {
          for (int x = 0; x < image.width; x++) {
            if (raw[(y * image.width + x) * 4 + 3] > 10) {
              count++;
              bottom = y;
            }
          }
        }
        expect(count, greaterThan(100));
        expect(
          bottom,
          lessThanOrEqualTo(size.height - snapshot.bottomInset(size) + 2),
        );
        image.dispose();
        codec.dispose();
      }
      // Export never consults a mutable global selection when a snapshot is supplied.
      SubtitleDebugSession.instance.resetForTest();
    });
    expect(tester.takeException(), isNull);
  });
}
