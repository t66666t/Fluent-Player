import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

Future<void> _loadRealFont() async {
  final ByteData fontData = await rootBundle.load(
    'assets/fonts/MiSans-Semibold.otf',
  );
  final FontLoader loader = FontLoader('MiSans')
    ..addFont(Future<ByteData>.value(fontData));
  await loader.load();
}

Widget _buildApp({required Key screenKey, required Key offKey}) {
  Widget layer({required Key key}) => RepaintBoundary(
    key: key,
    child: SizedBox(
      width: 1920,
      height: 1080,
      child: SubtitleOverlayGroup(
        entries: const [
          SubtitleOverlayEntry(text: 'Test字幕', secondaryText: 'Secondary line'),
        ],
        style: const SubtitleStyle(),
        referenceHeight: 1080,
        alignment: const Alignment(0, 0.8),
        isVisualOnly: true,
      ),
    ),
  );
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(3840, 2160), devicePixelRatio: 2.0),
      child: Stack(
        children: [
          layer(key: screenKey),
          Positioned(left: 1920, top: 0, child: layer(key: offKey)),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('same DPR: offscreen supersample render == screen render', (
    tester,
  ) async {
    await tester.binding.runAsync(() async {
      await _loadRealFont();
    });
    tester.view.physicalSize = const Size(3840, 2160);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final Key screenKey = UniqueKey();
    final Key offKey = UniqueKey();
    await tester.pumpWidget(_buildApp(screenKey: screenKey, offKey: offKey));
    await tester.pump();
    final RenderRepaintBoundary screenBoundary = tester.renderObject(
      find.byKey(screenKey),
    );
    final RenderRepaintBoundary offBoundary = tester.renderObject(
      find.byKey(offKey),
    );

    await tester.binding.runAsync(() async {
      final Uint8List screenPng = await _snapshot(screenBoundary, 2.0);
      final Uint8List offPng = await _snapshot(offBoundary, 2.0);
      File(r'd:\1spbfq\_verify_screen.png').writeAsBytesSync(screenPng);
      File(r'd:\1spbfq\_verify_offscreen.png').writeAsBytesSync(offPng);
      expect(offPng, screenPng);
    });
  });
}

Future<Uint8List> _snapshot(
  RenderRepaintBoundary boundary,
  double pixelRatio,
) async {
  final ui.Image image = boundary.toImageSync(pixelRatio: pixelRatio);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) throw StateError('no data');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
