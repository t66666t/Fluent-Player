import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in {
      'Inter': 'assets/fonts/Inter-ExtraBold.otf',
      'Noto Sans SC': 'assets/fonts/NotoSansSC-Variable.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  Future<Uint8List> capture(WidgetTester tester, GlobalKey key) async {
    late Uint8List result;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      result = bytes!.buffer.asUint8List();
      image.dispose();
    });
    return result;
  }

  int brightPixels(Uint8List png) {
    final image = images.decodePng(png)!;
    var count = 0;
    for (final pixel in image) {
      // RepaintBoundary snapshots may have transparent backgrounds. Compare
      // their visible brightness over black, including the glyph alpha.
      final alpha = pixel.a / 255;
      if (pixel.r * alpha > 210 &&
          pixel.g * alpha > 210 &&
          pixel.b * alpha > 210) {
        count++;
      }
    }
    return count;
  }

  testWidgets(
    'word mask advances within one cue, holds during a gap and freezes with the clock',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 220));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final clock = ValueNotifier(Duration.zero);
      addTearDown(clock.dispose);
      final key = GlobalKey();
      final cue = SubtitleParser.parse(
        '[00:01.000]<00:01.000>Hello <00:02.000>world<00:04.000>',
      ).single;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 400,
                  child: MusicTimedLyricText(
                    text: cue.text,
                    spans: cue.timedSpans,
                    position: clock,
                    reduceMotion: true,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final initialSize = tester.getSize(find.text('Hello world'));
      final before = await capture(tester, key);
      clock.value = const Duration(milliseconds: 1500);
      await tester.pump();
      final middle = await capture(tester, key);
      clock.value = const Duration(milliseconds: 3500);
      await tester.pump();
      final later = await capture(tester, key);
      expect(brightPixels(middle), greaterThan(brightPixels(before)));
      expect(brightPixels(later), greaterThan(brightPixels(middle)));
      expect(tester.getSize(find.text('Hello world')), initialSize);
      await tester.pump(const Duration(seconds: 2));
      expect(await capture(tester, key), orderedEquals(later));
      clock.value = const Duration(milliseconds: 1500);
      await tester.pump();
      expect(await capture(tester, key), orderedEquals(middle));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'lit glyphs hold their raised pose through gaps and later words, including pause and seek',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 240));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final clock = ValueNotifier(const Duration(milliseconds: 2500));
      addTearDown(clock.dispose);
      final key = GlobalKey();
      final cue = SubtitleItem(
        index: 1,
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 7),
        text: 'MMMM NNNN',
        timedSpans: [
          SubtitleTimedSpan(
            textStart: 0,
            textEnd: 4,
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 2),
          ),
          SubtitleTimedSpan(
            textStart: 5,
            textEnd: 9,
            startTime: const Duration(seconds: 4),
            endTime: const Duration(seconds: 6),
          ),
        ],
      );
      Future<void> show(bool reduced) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: RepaintBoundary(
                key: key,
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: MusicTimedLyricText(
                    text: cue.text,
                    spans: cue.timedSpans,
                    position: clock,
                    reduceMotion: reduced,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 64,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      Rect ink(Uint8List png) {
        final img = images.decodePng(png)!;
        var left = img.width, right = 0, top = img.height, bottom = 0;
        for (final pixel in img) {
          final alpha = pixel.a / 255;
          if (pixel.r * alpha > 65 &&
              pixel.g * alpha > 65 &&
              pixel.b * alpha > 65) {
            if (pixel.x < left) left = pixel.x;
            if (pixel.x > right) right = pixel.x;
            if (pixel.y < top) top = pixel.y;
            if (pixel.y > bottom) bottom = pixel.y;
          }
        }
        return Rect.fromLTRB(
          left.toDouble(),
          top.toDouble(),
          right.toDouble(),
          bottom.toDouble(),
        );
      }

      await show(false);
      final moving = await capture(tester, key);
      await tester.pump(const Duration(seconds: 1));
      expect(await capture(tester, key), orderedEquals(moving));
      clock.value = const Duration(milliseconds: 3800);
      await tester.pump();
      expect(await capture(tester, key), orderedEquals(moving));
      Uint8List firstWord(Uint8List png) => Uint8List.fromList(
        images.encodePng(
          images.copyCrop(
            images.decodePng(png)!,
            x: 20,
            y: 10,
            width: 250,
            height: 140,
          ),
        ),
      );
      clock.value = const Duration(seconds: 5);
      await tester.pump();
      expect(
        firstWord(await capture(tester, key)),
        orderedEquals(firstWord(moving)),
      );
      clock.value = const Duration(milliseconds: 1500);
      await tester.pump();
      expect(
        firstWord(await capture(tester, key)),
        isNot(orderedEquals(firstWord(moving))),
      );
      clock.value = const Duration(milliseconds: 2500);
      await tester.pump();
      expect(await capture(tester, key), orderedEquals(moving));
      await show(true);
      final resting = await capture(tester, key);
      expect(ink(moving).top, lessThan(ink(resting).top - 2));
      expect(ink(moving).width, greaterThan(ink(resting).width + 1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'mixed glyphs wrap without changing geometry and RTL timing paints safely',
    (tester) async {
      final clock = ValueNotifier(const Duration(milliseconds: 1500));
      addTearDown(clock.dispose);
      for (final direction in TextDirection.values) {
        final cue = SubtitleItem(
          index: 1,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 4),
          text: '你好 e\u0301🙂 مرحبا world wraps onto another line',
          timedSpans: [
            SubtitleTimedSpan(
              textStart: 0,
              textEnd: 2,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 3),
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Directionality(
              textDirection: direction,
              child: Center(
                child: SizedBox(
                  width: 160,
                  child: MusicTimedLyricText(
                    text: cue.text,
                    spans: cue.timedSpans,
                    position: clock,
                    style: const TextStyle(
                      fontFamily: 'Noto Sans SC',
                      fontSize: 28,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final size = tester.getSize(find.text(cue.text));
        clock.value = const Duration(milliseconds: 2500);
        await tester.pump();
        expect(tester.getSize(find.text(cue.text)), size);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'lyrics preview preserves timed bilingual text, background voices and paused taps',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(960, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final clock = ValueNotifier(const Duration(milliseconds: 2200));
      addTearDown(clock.dispose);
      final key = GlobalKey();
      final cues = SubtitleParser.parse(
        '''<tt xmlns="http://www.w3.org/ns/ttml"
      xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions"
      xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
      <body><p begin="00:01.000" end="00:05.500" ttm:agent="v1"><span begin="00:01.000" end="00:02.000">Hold </span><span begin="00:02.000" end="00:04.000">on </span><span begin="00:04.000" end="00:05.500">to the light</span><span ttm:role="x-translation">让光芒停留在此刻</span></p>
      <p begin="00:06.000" end="00:09.000" ttm:agent="v2"><span begin="00:06.000" end="00:07.000">We </span><span begin="00:07.000" end="00:09.000">come alive</span><span ttm:role="x-bg"><span begin="00:07.000" end="00:09.000"> (alive)</span></span><span ttm:role="x-translation">我们在音乐中醒来</span></p>
      <p begin="00:10.000" end="00:13.000" ttm:agent="v1"><span begin="00:10.000" end="00:11.000">穿过</span><span begin="00:11.000" end="00:13.000">漫长的夜晚</span></p>
      <p begin="00:20.000" end="00:24.000"><span begin="00:20.000" end="00:22.000">And </span><span begin="00:22.000" end="00:24.000">shine again</span></p></body></tt>''',
      );
      final seeks = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xff60474c), Color(0xff221b2f)],
                  ),
                ),
                child: MusicLyricView(
                  subtitles: cues,
                  positionListenable: clock,
                  isPlaying: false,
                  onSeek: seeks.add,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final directory = Directory(
        r'D:\2Document\Codex\2026-10-14\ai-music-player-screen-apple-music\outputs',
      );
      await tester.runAsync(() => directory.create(recursive: true));
      if (const bool.fromEnvironment('CAPTURE_WORD_LYRICS_VIDEO')) {
        final frames = Directory(
          r'D:\2Document\Codex\2026-10-14\ai-music-player-screen-apple-music\work\lyric-motion-v2-frames',
        );
        await tester.runAsync(() => frames.create(recursive: true));
        for (var frame = 0; frame < 420; frame++) {
          final elapsed = frame < 300
              ? 1000 + (frame * 1000 / 30).round()
              : frame < 360
              ? 20000 + ((frame - 300) * 1000 / 30).round()
              : 10000 + ((frame - 360) * 1000 / 30).round();
          clock.value = Duration(milliseconds: elapsed);
          await tester.pump(const Duration(milliseconds: 33));
          final png = await capture(tester, key);
          await tester.runAsync(
            () => File(
              '${frames.path}/frame-${frame.toString().padLeft(4, '0')}.png',
            ).writeAsBytes(png),
          );
        }
      }
      for (final entry in {
        'word-start': 1100,
        'word-sweep': 2800,
        'word-complete': 5100,
        'background-voice': 7900,
        'interlude': 15500,
      }.entries) {
        clock.value = Duration(milliseconds: entry.value);
        await tester.pumpAndSettle();
        final png = await capture(tester, key);
        await tester.runAsync(
          () => File('${directory.path}/${entry.key}.png').writeAsBytes(png),
        );
      }
      await tester.tap(find.text('穿过漫长的夜晚'));
      await tester.pump(const Duration(milliseconds: 900));
      expect(seeks.last, const Duration(seconds: 10));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
