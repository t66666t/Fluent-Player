import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/subtitle_debug_panel.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

void main() {
  testWidgets('real bundled fonts render in the lab and on the sample viewport', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final entry in {
        'Noto Sans SC': [
          'NotoSansCJKsc-Regular.otf',
          'NotoSansCJKsc-Medium.otf',
          'NotoSansCJKsc-Bold.otf',
        ],
        'Noto Serif CJK SC': [
          'NotoSerifCJKsc-Regular.otf',
          'NotoSerifCJKsc-Bold.otf',
        ],
        'Inter': [
          'Inter-Regular.otf',
          'Inter-Medium.otf',
          'Inter-SemiBold.otf',
        ],
        'Roboto': [
          'Roboto_Condensed-Regular.ttf',
          'Roboto_Condensed-Medium.ttf',
        ],
        'Comic Relief': ['ComicRelief-Regular.ttf', 'ComicRelief-Bold.ttf'],
        'Brawler': ['Brawler-Regular.otf'],
      }.entries) {
        final loader = FontLoader(entry.key);
        for (final file in entry.value) {
          loader.addFont(rootBundle.load('assets/fonts/$file'));
        }
        await loader.load();
      }
    });
    await tester.runAsync(() async {
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    final session = SubtitleDebugSession.instance;
    SharedPreferences.setMockInitialValues({});
    session.resetForTest();
    await session.initialize();
    session.toggle();
    addTearDown(() async {
      session.resetForTest();
    });
    final key = GlobalKey();
    for (final index in [0, 7, 13, 18]) {
      session.select(subtitleDebugPresets[index]);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'Noto Sans SC',
          ),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '全局字幕预设 · ${subtitleDebugPresets[index].name} · 示例画面',
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 16 / 9,
                              child: Stack(
                                children: [
                                  Container(
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Color(0xFF345868),
                                          Color(0xFFAF9F79),
                                          Color(0xFF243C45),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const Center(
                                    child: Icon(
                                      Icons.landscape_outlined,
                                      size: 200,
                                      color: Colors.white24,
                                    ),
                                  ),
                                  const SubtitleOverlayGroup(
                                    entries: [
                                      SubtitleOverlayEntry(
                                        text: '风起时，我们再次相遇。',
                                        secondaryText:
                                            'When the wind rises, we meet again.',
                                      ),
                                    ],
                                    style: SubtitleStyle(),
                                    alignment: Alignment.bottomCenter,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('已全局应用 · 重启保留 · 精确渲染同步'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 320, child: SubtitleDebugPanel()),
                ],
              ),
            ),
          ),
        ),
      );
      if (index == 18) {
        await tester.tap(find.text('微调当前预设'));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final out = File('build/subtitle-lab-review/preset-$index.png');
        out.parent.createSync(recursive: true);
        out.writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
