import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_precise_renderer.dart';

class _Paths extends PathProviderPlatform {
  final String path;
  _Paths(this.path);
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late SubtitleFontAsset imported;
  late SubtitleStyle style;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('subtitle_font_render_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    imported = await SubtitleFontService.instance.importFile(
      'assets/fonts/Brawler-Regular.otf',
    );
    style = SubtitleStyle(
      textStyle: SubtitleTextStyle(
        defaultFontFamily: imported.id,
        languageFonts: const {},
        backgroundEnabled: false,
        hasBorder: false,
        hasShadow: false,
      ),
      layoutStyle: const SubtitleLayoutStyle(fontSize: 46, overallScale: 1.25),
    );
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });
  testWidgets('imported fonts paint during offscreen precise composition', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final result = await VideoComposePreciseRenderer().render(
        outputDirectory: Directory('${directory.path}/frames'),
        width: 640,
        height: 360,
        duration: const Duration(seconds: 2),
        primary: [
          SubtitleItem(
            index: 0,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 2),
            text: 'Imported font preview',
          ),
        ],
        secondary: [],
        style: style,
        alignment: Alignment.bottomCenter,
        splitSubtitleByLine: false,
        itemGap: 6,
        onProgress: (_) {},
        onArtifact: (_) {},
      );
      expect(File(result.concatPath).existsSync(), isTrue);
      final frame = await directory
          .list(recursive: true)
          .where((f) => f.path.endsWith('.png'))
          .first;
      final codec = await ui.instantiateImageCodec(
        await File(frame.path).readAsBytes(),
      );
      final image = (await codec.getNextFrame()).image;
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      var opaquePixels = 0;
      for (var i = 3; i < pixels.length; i += 4) {
        if (pixels[i] > 80) opaquePixels++;
      }
      expect(
        opaquePixels,
        greaterThan(100),
        reason: 'A completed font load must paint in the first offscreen frame',
      );
      image.dispose();
      codec.dispose();
    });
  });
  testWidgets(
    'ASS composition gets an isolated folder and actual font family name',
    (tester) async {
      await tester.runAsync(() async {
        final fonts = VideoComposeFontService();
        final first = await fonts.prepareAssFonts(
          style,
          usedFamilies: {imported.id},
        );
        final second = await fonts.prepareAssFonts(
          style,
          usedFamilies: {imported.id},
        );
        expect(first, isNot(second));
        expect(
          Directory(first).listSync().any((f) => f.path.endsWith('.otf')),
          isTrue,
        );
        expect(fonts.resolveSystemFont(imported.id), imported.internalFamily);
        expect(imported.internalFamily, contains('Brawler'));
      });
    },
  );
}
