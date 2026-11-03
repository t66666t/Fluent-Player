import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

void main() {
  testWidgets(
    'painted depth follows real row movement without a cue or clock change',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewport = GlobalKey();
      final capture = GlobalKey();
      final top = ValueNotifier(250.0);
      final motion = MusicLyricFollowMotion();
      addTearDown(top.dispose);
      addTearDown(motion.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: RepaintBoundary(
              key: capture,
              child: SizedBox.expand(
                key: viewport,
                child: Stack(
                  children: [
                    ValueListenableBuilder<double>(
                      valueListenable: top,
                      builder: (context, value, _) => Positioned(
                        top: value,
                        left: 30,
                        width: 500,
                        child: MusicLyricDepth(
                          active: false,
                          distance: 0,
                          browsing: false,
                          viewportKey: viewport,
                          anchorFraction: 0.5,
                          motion: motion,
                          rasterFocus: true,
                          child: const MusicTimedLyricText(
                            text: 'MMMM MMMM',
                            spans: [],
                            style: TextStyle(fontSize: 48, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      Future<({int brightness, int edges})> pixels() async =>
          (await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final bytes = data!.buffer.asUint8List();
            var brightness = 0, edges = 0;
            for (var y = 0; y < image.height; y++) {
              var previous = 0;
              for (var x = 0; x < image.width; x++) {
                final red = bytes[(y * image.width + x) * 4];
                brightness += red;
                edges += (red - previous).abs();
                previous = red;
              }
            }
            image.dispose();
            return (brightness: brightness, edges: edges);
          }))!;
      final clear = await pixels();
      var previousEdges = clear.edges;
      for (var distance = 16; distance <= 128; distance += 16) {
        top.value = 250.0 - distance;
        motion.advance(16);
        await tester.pump();
        final blurred = await pixels();
        expect(
          blurred.brightness / clear.brightness,
          closeTo(1, 0.025),
          reason: 'focus blending must not insert a brightness dip',
        );
        expect(blurred.edges, lessThanOrEqualTo(previousEdges * 1.01));
        previousEdges = blurred.edges;
      }
      expect(previousEdges, lessThan(clear.edges * 0.85));
      top.value = 250;
      motion.advance(-128);
      await tester.pump();
      expect((await pixels()).edges, clear.edges);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
