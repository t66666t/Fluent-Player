import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:provider/provider.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/music_artwork_backdrop_cache.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('background bounds lyric and control contrast at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await _Fixture.create(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.dispose);
      });
      final captureKey = GlobalKey();

      for (final name in ['white', 'ivory', 'yellow', 'cyan', 'mixed']) {
        await tester.pumpWidget(fixture.player(fixture.paths[name]!));
        await _precache(tester, fixture.paths[name]!);
        await tester.pumpAndSettle();

        // Reuse the background subtree from the actual screen. Capturing it
        // alone includes the real saturation filter, scaling and both scrims,
        // without mistaking the white foreground/album cover for background.
        final background = tester.widget<ClipRect>(
          find.byKey(const ValueKey('music-player-background')),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(key: captureKey, child: background),
          ),
        );
        await tester.pumpAndSettle();
        final pixels = await _capture(tester, captureKey);
        var maxLuminance = 0.0;
        var minPrimaryContrast = double.infinity;
        var minSecondaryContrast = double.infinity;
        for (var i = 0; i < pixels.length; i += 4) {
          final backgroundColor = Color.fromARGB(
            255,
            pixels[i],
            pixels[i + 1],
            pixels[i + 2],
          );
          final luminance = backgroundColor.computeLuminance();
          maxLuminance = math.max(maxLuminance, luminance);
          minPrimaryContrast = math.min(
            minPrimaryContrast,
            1.05 / (luminance + 0.05),
          );
          final secondary = Color.alphaBlend(
            Colors.white.withValues(alpha: 0.7),
            backgroundColor,
          );
          minSecondaryContrast = math.min(
            minSecondaryContrast,
            (secondary.computeLuminance() + 0.05) / (luminance + 0.05),
          );
        }
        debugPrint(
          '$name $size: primary contrast $minPrimaryContrast, '
          'secondary contrast $minSecondaryContrast, '
          'max background luminance $maxLuminance',
        );
        expect(maxLuminance, lessThanOrEqualTo(0.10), reason: name);
        expect(minPrimaryContrast, greaterThanOrEqualTo(7), reason: name);
        expect(minSecondaryContrast, greaterThanOrEqualTo(4.5), reason: name);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  testWidgets('dark-to-white artwork fades never flash a bright background', (
    tester,
  ) async {
    const size = Size(390, 844);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _Fixture.create(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });
    final captureKey = GlobalKey();
    late StateSetter update;
    var path = fixture.paths['dark']!;
    await tester.pumpWidget(
      fixture.host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return RepaintBoundary(
              key: captureKey,
              child: MusicPlayerScreen(title: 'Track', coverImagePath: path),
            );
          },
        ),
      ),
    );
    await _precache(tester, path);
    await tester.pumpAndSettle();

    for (final name in ['white', 'dark', 'ivory']) {
      // Include a cold cache miss, then decode completion during the fade.
      if (name == 'white') MusicArtworkBackdropCache.instance.clearForTest();
      // Begin disk/isolate work outside the widget test's fake async zone,
      // then let the real player subscribe while the request is in flight.
      await tester.runAsync(() async {
        MusicArtworkBackdropCache.instance.warm(fixture.paths[name]!);
      });
      update(() => path = fixture.paths[name]!);
      await tester.pump();
      await _expectDarkEdges(tester, captureKey, size);
      await _precache(tester, path);
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 60));
        await _expectDarkEdges(tester, captureKey, size);
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _expectDarkEdges(
  WidgetTester tester,
  GlobalKey captureKey,
  Size size,
) async {
  final pixels = await _capture(tester, captureKey);
  final width = size.width.toInt();
  for (var y = 0; y < size.height.toInt(); y++) {
    for (final x in [1, width - 2]) {
      final i = (y * width + x) * 4;
      expect(
        Color.fromARGB(
          255,
          pixels[i],
          pixels[i + 1],
          pixels[i + 2],
        ).computeLuminance(),
        lessThanOrEqualTo(0.10),
      );
    }
  }
}

Future<Uint8List> _capture(WidgetTester tester, GlobalKey key) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return bytes!.buffer.asUint8List();
  }))!;
}

Future<void> _precache(WidgetTester tester, String path) async {
  await tester.runAsync(() async {
    final bytes = await MusicArtworkBackdropCache.instance.warm(path);
    expect(bytes, isNotNull);
    await precacheImage(
      MemoryImage(bytes!),
      tester.element(find.byType(Scaffold)),
    );
  });
}

class _Fixture {
  final Directory directory;
  final Map<String, String> paths;
  final playback = MediaPlaybackService.forTesting();
  final settings = SettingsService()..resetForTest();

  _Fixture(this.directory, this.paths);

  static Future<_Fixture> create(WidgetTester tester) async {
    return (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'music_player_backdrop_brightness_',
      );
      final paths = <String, String>{};
      for (final sample in <String, List<int>>{
        'white': [255, 255, 255],
        'ivory': [255, 252, 240],
        'yellow': [255, 255, 0],
        'cyan': [0, 255, 255],
        'mixed': [255, 255, 255],
        'dark': [24, 30, 45],
      }.entries) {
        final rgb = sample.value;
        final source = image_lib.fill(
          image_lib.Image(width: 64, height: 64),
          color: image_lib.ColorRgb8(rgb[0], rgb[1], rgb[2]),
        );
        if (sample.key == 'mixed') {
          for (var y = 0; y < 64; y++) {
            for (var x = 0; x < 24; x++) {
              source.setPixelRgb(x, y, 25, 100, 160);
            }
          }
        }
        final path = '${directory.path}/${sample.key}.png';
        await File(path).writeAsBytes(image_lib.encodePng(source));
        await MusicArtworkBackdropCache.instance.warm(path);
        paths[sample.key] = path;
      }
      return _Fixture(directory, paths);
    }))!;
  }

  Widget host(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsService>.value(value: settings),
      ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
    ],
    child: MaterialApp(home: child),
  );

  Widget player(String path) =>
      host(MusicPlayerScreen(title: 'Track', coverImagePath: path));

  Future<void> dispose() async {
    playback.dispose();
    MusicArtworkBackdropCache.instance.clearForTest();
    await directory.delete(recursive: true);
  }
}
