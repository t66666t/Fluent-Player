import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_app/services/thumbnail_cache_service.dart';
import 'package:video_player_app/widgets/cached_thumbnail_widget.dart';
import 'package:video_player_app/widgets/media_card_preparation.dart';

/// Synthetic native renderer profile. It exercises the actual cover widgets,
/// disk reads and image decodes; it does not measure the whole application.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('large cold grid and scrolling cover profile', (tester) async {
    final root = await Directory.systemTemp.createTemp('cover_native_profile_');
    final scroll = ScrollController();
    final timings = <ui.FrameTiming>[];
    var collecting = false;
    void collect(List<ui.FrameTiming> frames) => timings.addAll(frames);
    try {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 640, 360),
        Paint()
          ..shader = const LinearGradient(
            colors: [Colors.indigo, Colors.teal, Colors.orange],
          ).createShader(const Rect.fromLTWH(0, 0, 640, 360)),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(640, 360);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = data!.buffer.asUint8List();
      for (var i = 0; i < 80; i++) {
        await File('${root.path}/$i.png').writeAsBytes(bytes);
      }
      image.dispose();
      picture.dispose();

      ThumbnailCacheService().clearMemoryCache();
      PaintingBinding.instance.imageCache.clear();
      resetMediaCoverRevealMemory();
      binding.addTimingsCallback(collect);
      collecting = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GridView.builder(
              controller: scroll,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 1.3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: 5000,
              itemBuilder: (_, index) => MediaCoverRevealStamp(
                index: index,
                crossAxisCount: 4,
                child: MediaCardPreparationHost(
                  child: Column(
                    children: [
                      Expanded(
                        child: CachedThumbnailWidget(
                          videoId: 'profile-$index',
                          thumbnailPath: '${root.path}/${index % 80}.png',
                          placeholder: const ColoredBox(color: Colors.black),
                        ),
                      ),
                      Text('Media $index'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final scrollTarget = scroll.position.maxScrollExtent.clamp(0.0, 6000.0);
      await scroll.animateTo(
        scrollTarget,
        duration: const Duration(seconds: 2),
        curve: Curves.linear,
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      binding.removeTimingsCallback(collect);
      collecting = false;
      expect(timings, isNotEmpty);
      expect(tester.takeException(), isNull);
      final hz = tester.view.display.refreshRate;
      final budget = 1000000 / (hz > 0 ? hz : 60);
      final report = {
        'platform': Platform.operatingSystem,
        'items': 5000,
        'distinctCoverFiles': 80,
        'displayHz': hz,
        'frames': timings.length,
        'build': _percentiles(
          timings.map((t) => t.buildDuration.inMicroseconds),
        ),
        'raster': _percentiles(
          timings.map((t) => t.rasterDuration.inMicroseconds),
        ),
        'overBudgetFrames': timings
            .where(
              (t) =>
                  t.buildDuration.inMicroseconds > budget ||
                  t.rasterDuration.inMicroseconds > budget,
            )
            .length,
      };
      binding.reportData = {'coverProfile': report};
      debugPrint('COVER_NATIVE_PROFILE ${jsonEncode(report)}');
    } finally {
      if (collecting) binding.removeTimingsCallback(collect);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      ThumbnailCacheService().clearMemoryCache();
      await root.delete(recursive: true);
    }
  });
}

Map<String, int> _percentiles(Iterable<int> samples) {
  final sorted = samples.toList()..sort();
  int at(double fraction) => sorted[((sorted.length - 1) * fraction).round()];
  return {'p50Us': at(.5), 'p95Us': at(.95), 'p99Us': at(.99)};
}
