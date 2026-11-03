import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/subtitle_management_tile.dart';

const _title = 'Example.Movie.2026.中文字幕与英文双语字幕.srt';
const _info = '128.5 KB · 生成中 · 240 条 · 已处理 12:30';

void main() {
  for (final width in [280.0, 320.0, 360.0, 400.0, 480.0, 720.0, 1200.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('subtitle text and actions fit at $width, scale $scale', (
        tester,
      ) async {
        if (const bool.fromEnvironment('SUBTITLE_CARD_PREVIEWS')) {
          await tester.runAsync(() async {
            for (final font in {
              'MiSans': 'assets/fonts/MiSans-Regular.otf',
              'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
              'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
            }.entries) {
              await (FontLoader(
                font.key,
              )..addFont(rootBundle.load(font.value))).load();
            }
          });
        }
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final capture = GlobalKey();
        var selections = 0;
        final actions = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              fontFamily: 'MiSans',
              fontFamilyFallback: const ['Noto Sans SC'],
              useMaterial3: true,
            ),
            home: Scaffold(
              backgroundColor: const Color(0xFF1E1E1E),
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(
                    key: capture,
                    child: ColoredBox(
                      color: const Color(0xFF1E1E1E),
                      child: SizedBox(
                        width: width,
                        child: SubtitleManagementTile(
                          selected: true,
                          leading: const Icon(Icons.subtitles, size: 20),
                          title: const Text(
                            _title,
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: const Text(
                            _info,
                            style: TextStyle(fontSize: 11),
                          ),
                          selectionBadge: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.blueAccent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '主',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                          badges: [
                            for (final label in ['同目录', '名称相似', 'OCR · 中'])
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.blueAccent.withValues(
                                    alpha: 0.2,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  label,
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ),
                          ],
                          actions: [
                            for (final (index, icon) in [
                              Icons.stop_circle_outlined,
                              Icons.download_outlined,
                              Icons.translate,
                              Icons.delete_outline,
                            ].indexed)
                              IconButton(
                                tooltip: 'action-$index',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: Icon(icon, size: 18),
                                onPressed: () => actions.add(index),
                              ),
                          ],
                          onTap: () => selections++,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final tile = tester.getRect(find.byType(SubtitleManagementTile));
        final title = tester.getRect(find.text(_title));
        final info = tester.getRect(find.textContaining(_info));
        final role = tester.getRect(find.text('主'));
        final first = tester.getRect(find.byTooltip('action-0'));
        final last = tester.getRect(find.byTooltip('action-3'));
        expect(title.width, greaterThan(24));
        expect(info.width, greaterThan(title.width));
        expect(role.center.dy, closeTo(title.center.dy, 2));
        expect(tile.height, lessThanOrEqualTo(52 * scale + 8));
        expect(last.right, lessThanOrEqualTo(tile.right));
        expect(first.size, const Size(32, 40));
        expect(last.center.dx - first.center.dx, 96);
        expect(first.left, greaterThan(role.right));
        expect(first.center.dy, tile.center.dy);
        await tester.tap(find.byTooltip('action-2'));
        await tester.pumpAndSettle();
        expect(actions, [2]);
        expect(selections, 0);
        await tester.tap(find.text(_title));
        await tester.pumpAndSettle();
        expect(selections, 1);

        if (const bool.fromEnvironment('SUBTITLE_CARD_PREVIEWS')) {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/subtitle_card_previews/card-$width-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }

  testWidgets(
    'two right actions and the primary badge do not add another line',
    (tester) async {
      Future<void> pump(bool selected) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: SubtitleManagementTile(
                  selected: selected,
                  leading: const Icon(Icons.subtitles, size: 20),
                  title: const Text(
                    '简体中文字幕.srt',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text('已就绪', style: TextStyle(fontSize: 11)),
                  selectionBadge: selected
                      ? const Text('主', style: TextStyle(fontSize: 10))
                      : null,
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.download_outlined),
                      onPressed: () {},
                    ),
                    IconButton(
                      icon: const Icon(Icons.translate),
                      onPressed: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await pump(false);
      await tester.pumpAndSettle();
      final unselected = tester.getSize(find.byType(SubtitleManagementTile));
      await pump(true);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SubtitleManagementTile)), unselected);
      expect(unselected.height, 52);
      expect(
        tester.getRect(find.text('主')).center.dy,
        tester.getRect(find.text('简体中文字幕.srt')).center.dy,
      );
      expect(
        tester.getCenter(find.byIcon(Icons.download_outlined)).dx,
        greaterThan(tester.getRect(find.text('主')).right),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selected fill and pressed ink keep rounded corners', (
    tester,
  ) async {
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: Colors.black,
                child: SizedBox(
                  width: 320,
                  child: SubtitleManagementTile(
                    selected: true,
                    leading: const Icon(Icons.subtitles, size: 20),
                    title: const Text('Selected subtitle'),
                    subtitle: const Text('128 KB'),
                    actions: const [],
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> expectRounded() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final corner = bytes.getUint8(0);
        final topMiddle = bytes.getUint8(160 * 4);
        expect(corner, 0);
        expect(topMiddle, greaterThan(corner));
        image.dispose();
      });
    }

    await tester.pumpAndSettle();
    await expectRounded();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Selected subtitle')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await expectRounded();
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
