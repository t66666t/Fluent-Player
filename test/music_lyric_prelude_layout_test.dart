import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

void main() {
  setUpAll(() async {
    for (final entry in {
      'Inter': 'assets/fonts/Inter-ExtraBold.otf',
      'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Medium.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
    for (final size in [
      const Size(390, 844),
      const Size(844, 390),
      const Size(1000, 600),
    ]) {
      testWidgets(
        '$platform $size prelude dots stay above the first lyric and disappear at its start',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final clock = ValueNotifier(const Duration(seconds: 3));
          addTearDown(clock.dispose);
          final seeks = <Duration>[];
          final previewKey = GlobalKey();
          const firstText = '首行歌词换行\nFirst lyric wraps here';
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark().copyWith(platform: platform),
              home: Scaffold(
                body: RepaintBoundary(
                  key: previewKey,
                  child: ColoredBox(
                    color: const Color(0xff241d2e),
                    child: MusicLyricView(
                      subtitles: [
                        SubtitleItem(
                          index: 0,
                          startTime: const Duration(seconds: 10),
                          endTime: const Duration(seconds: 15),
                          text: firstText,
                        ),
                        SubtitleItem(
                          index: 1,
                          startTime: const Duration(seconds: 15),
                          endTime: const Duration(seconds: 20),
                          text: 'Next lyric',
                        ),
                      ],
                      positionListenable: clock,
                      isPlaying: false,
                      lyricFontSizeScale: 1.4,
                      anchorFraction: size.width < size.height ? 0.215 : 0.3,
                      applyEdgeFade: false,
                      onSeek: (position) {
                        seeks.add(position);
                        clock.value = position;
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final prelude = find.byKey(const ValueKey('music-lyric-prelude'));
          final lyric = find.text(firstText);
          final firstTop = tester.getTopLeft(lyric).dy;
          expect(
            tester.getRect(prelude).bottom,
            lessThanOrEqualTo(firstTop - 4),
          );
          expect(tester.getRect(prelude).top, greaterThanOrEqualTo(0));
          if (const bool.fromEnvironment('CAPTURE_PRELUDE_LAYOUT') &&
              platform == TargetPlatform.windows &&
              size.width == 1000) {
            await tester.runAsync(() async {
              final boundary =
                  previewKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory(
                r'D:\2Document\Codex\2026-10-14\ai-music-player-screen-apple-music\outputs',
              );
              await directory.create(recursive: true);
              await File(
                '${directory.path}/prelude-spacing.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          clock.value = const Duration(milliseconds: 9999);
          await tester.pump();
          expect(
            tester.getRect(prelude).bottom,
            lessThanOrEqualTo(tester.getTopLeft(lyric).dy - 4),
          );
          clock.value = const Duration(seconds: 10);
          await tester.pumpAndSettle();
          expect(prelude, findsNothing);
          expect(tester.getTopLeft(lyric).dy, closeTo(firstTop, 0.2));
          // Seeking back restores the separate indicator; it cannot cover the
          // first lyric's pointer hit region.
          clock.value = const Duration(seconds: 3);
          await tester.pumpAndSettle();
          expect(prelude, findsOneWidget);
          await tester.tap(lyric);
          await tester.pumpAndSettle();
          expect(seeks, [const Duration(seconds: 10)]);
          expect(prelude, findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
