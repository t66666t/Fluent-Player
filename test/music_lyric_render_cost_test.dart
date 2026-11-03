import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

void main() {
  setUpAll(() async {
    for (final font in {
      'Inter': 'assets/fonts/Inter-ExtraBold.otf',
      'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Medium.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '$platform keeps long bilingual lyrics bounded and locates distant rows',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(600, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final clock = ValueNotifier(Duration.zero);
        addTearDown(clock.dispose);
        final cues = List.generate(
          2000,
          (i) => SubtitleItem(
            index: i,
            startTime: Duration(seconds: i * 5),
            endTime: Duration(seconds: i * 5 + 4),
            text:
                'Line $i: ${i.isEven ? 'a short phrase' : 'a much longer phrase that wraps across several lines in this narrow viewport'}.',
            lyricTranslation: i.isEven
                ? '这一句的翻译。'
                : '这是一段较长的翻译，会随着可用宽度换行，但不能影响准确定位。',
            lyricRomanization: i % 3 == 0 ? 'zhe shi yi ju yin yi' : '',
          ),
        );
        double scale = 1;
        Future<void> show() => tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(600, 800),
                textScaler: TextScaler.linear(1.15),
              ),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 320,
                    child: MusicLyricView(
                      subtitles: cues,
                      positionListenable: clock,
                      lyricFontSizeScale: scale,
                      applyEdgeFade: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await show();
        await tester.pumpAndSettle();
        expect(find.byType(MusicLyricDepth).evaluate().length, lessThan(35));
        expect(find.text(cues.last.text), findsNothing);
        clock.value = cues.last.startTime;
        await tester.pumpAndSettle();
        expect(find.text(cues.last.text), findsOneWidget);
        expect(find.byType(MusicLyricDepth).evaluate().length, lessThan(35));
        expect(
          tester.getTopLeft(find.text(cues.last.text)).dy,
          closeTo(800 * 0.3, 0.2),
        );
        scale = 0.8;
        await show();
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.text(cues.last.text)).dy,
          closeTo(800 * 0.3, 0.2),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'timed text repaints only when its visible word progress changes, including seeks',
    (tester) async {
      final clock = ValueNotifier(Duration.zero);
      addTearDown(clock.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: MusicTimedLyricText(
                text: 'Hello world',
                spans: [
                  SubtitleTimedSpan(
                    textStart: 0,
                    textEnd: 5,
                    startTime: const Duration(seconds: 1),
                    endTime: const Duration(seconds: 2),
                  ),
                  SubtitleTimedSpan(
                    textStart: 6,
                    textEnd: 11,
                    startTime: const Duration(seconds: 4),
                    endTime: const Duration(seconds: 5),
                  ),
                ],
                position: clock,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 36,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
      final paint = tester.renderObject<RenderCustomPaint>(
        find.descendant(
          of: find.byType(MusicTimedLyricText),
          matching: find.byType(CustomPaint),
        ),
      );
      clock.value = const Duration(milliseconds: 500);
      expect(paint.debugNeedsPaint, isFalse);
      clock.value = const Duration(milliseconds: 1500);
      expect(paint.debugNeedsPaint, isTrue);
      await tester.pump();
      clock.value = const Duration(milliseconds: 2500);
      await tester.pump();
      clock.value = const Duration(milliseconds: 3500);
      expect(paint.debugNeedsPaint, isFalse);
      clock.value = const Duration(seconds: 6);
      expect(paint.debugNeedsPaint, isTrue);
      await tester.pump();
      clock.value = const Duration(seconds: 7);
      expect(paint.debugNeedsPaint, isFalse);
      clock.value = const Duration(milliseconds: 1500);
      expect(paint.debugNeedsPaint, isTrue);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final blur in [false, true]) {
    testWidgets(
      'word animation does not allocate frame-by-frame images (blur=$blur)',
      (tester) async {
        final clock = ValueNotifier(Duration.zero);
        addTearDown(clock.dispose);
        var images = 0;
        final previousOnCreate = ui.Image.onCreate;
        ui.Image.onCreate = (image) {
          images++;
          previousOnCreate?.call(image);
        };
        addTearDown(() => ui.Image.onCreate = previousOnCreate);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  child: MusicLyricDepth(
                    active: true,
                    distance: 0,
                    browsing: false,
                    rasterFocus: true,
                    blurEnabled: blur,
                    child: MusicTimedLyricText(
                      text: 'Hello world',
                      spans: const [
                        SubtitleTimedSpan(
                          textStart: 0,
                          textEnd: 11,
                          startTime: Duration(seconds: 1),
                          endTime: Duration(seconds: 4),
                        ),
                      ],
                      position: clock,
                      style: const TextStyle(fontSize: 36, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        clock.value = const Duration(milliseconds: 1100);
        await tester.pump();
        final before = images;
        for (var frame = 0; frame < 30; frame++) {
          clock.value = Duration(milliseconds: 1100 + frame * 16);
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          images,
          before,
          reason: 'moving words must not create GPU textures every frame',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('clear settled lyrics do not repaint on viewport motion', (
    tester,
  ) async {
    final motion = MusicLyricFollowMotion();
    final inkKey = GlobalKey();
    addTearDown(motion.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MusicLyricDepth(
          active: true,
          distance: 0,
          browsing: false,
          rasterFocus: true,
          blurEnabled: false,
          motion: motion,
          child: RepaintBoundary(
            key: inkKey,
            child: const MusicTimedLyricText(
              text: 'A stationary clear paragraph',
              spans: [],
              style: TextStyle(fontSize: 36, color: Colors.white),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final paint = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(inkKey),
    );
    for (var frame = 0; frame < 20; frame++) {
      motion.advance(2);
      expect(paint.debugNeedsPaint, isFalse);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('text textures are released after density and layout changes', (
    tester,
  ) async {
    final clock = ValueNotifier(const Duration(milliseconds: 1500));
    addTearDown(clock.dispose);
    final liveImages = <ui.Image>{};
    final previousOnCreate = ui.Image.onCreate;
    final previousOnDispose = ui.Image.onDispose;
    ui.Image.onCreate = (image) {
      liveImages.add(image);
      previousOnCreate?.call(image);
    };
    ui.Image.onDispose = (image) {
      liveImages.remove(image);
      previousOnDispose?.call(image);
    };
    addTearDown(() {
      ui.Image.onCreate = previousOnCreate;
      ui.Image.onDispose = previousOnDispose;
    });
    for (final ratio in [1.0, 2.0, 1.25]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(devicePixelRatio: ratio),
            child: Center(
              child: SizedBox(
                width: 400 - ratio * 30,
                child: MusicLyricDepth(
                  active: true,
                  distance: 1,
                  browsing: false,
                  rasterFocus: true,
                  child: MusicTimedLyricText(
                    text: 'Hello world',
                    spans: const [
                      SubtitleTimedSpan(
                        textStart: 0,
                        textEnd: 11,
                        startTime: Duration(seconds: 1),
                        endTime: Duration(seconds: 3),
                      ),
                    ],
                    position: clock,
                    style: const TextStyle(fontSize: 36, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      clock.value = const Duration(seconds: 4);
      await tester.pump();
      clock.value = const Duration(milliseconds: 1500);
      await tester.pump();
      expect(liveImages.length, lessThan(8));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(liveImages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('oversized timed text keeps painting without a giant texture', (
    tester,
  ) async {
    var images = 0;
    final previousOnCreate = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      images++;
      previousOnCreate?.call(image);
    };
    addTearDown(() => ui.Image.onCreate = previousOnCreate);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(devicePixelRatio: 20),
          child: Center(
            child: SizedBox(
              width: 400,
              child: MusicTimedLyricText(
                text: 'Hello world',
                spans: [
                  SubtitleTimedSpan(
                    textStart: 0,
                    textEnd: 11,
                    startTime: Duration(seconds: 1),
                    endTime: Duration(seconds: 3),
                  ),
                ],
                fallbackPosition: Duration(milliseconds: 1500),
                style: TextStyle(fontSize: 36, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
    expect(images, 0);
    expect(find.text('Hello world'), findsOneWidget);
    expect(tester.getSize(find.text('Hello world')).height, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
