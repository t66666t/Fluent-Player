import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

const _style = TextStyle(fontSize: 36, color: Colors.white);
const _spans = [
  SubtitleTimedSpan(
    textStart: 0,
    textEnd: 11,
    startTime: Duration(seconds: 1),
    endTime: Duration(seconds: 5),
  ),
];

void main() {
  testWidgets(
    'completed glow reuses images at 144 Hz and releases track pixels',
    (tester) async {
      final clock = ValueNotifier(const Duration(milliseconds: 3100));
      addTearDown(clock.dispose);
      final created = <ui.Image>[];
      final previous = ui.Image.onCreate;
      ui.Image.onCreate = (image) {
        created.add(image);
        previous?.call(image);
      };
      addTearDown(() => ui.Image.onCreate = previous);
      Widget player(Color color) => MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Center(
          child: SizedBox(
            width: 320,
            child: MusicTimedLyricText(
              text: 'Hello world',
              spans: const [
                SubtitleTimedSpan(
                  textStart: 0,
                  textEnd: 5,
                  startTime: Duration(seconds: 1),
                  endTime: Duration(seconds: 3),
                ),
                SubtitleTimedSpan(
                  textStart: 6,
                  textEnd: 11,
                  startTime: Duration(seconds: 3),
                  endTime: Duration(seconds: 5),
                ),
              ],
              position: clock,
              style: _style.copyWith(color: color),
            ),
          ),
        ),
      );
      await tester.pumpWidget(player(Colors.white));
      expect(created, isNotEmpty);
      final count = created.length;
      for (var frame = 1; frame <= 144; frame++) {
        clock.value = Duration(microseconds: 3100000 + frame * 6944);
        await tester.pump(const Duration(microseconds: 6944));
      }
      expect(
        created.length,
        count,
        reason:
            'the following word must not allocate completed glow every frame',
      );
      final oldInk = created.toList();
      await tester.pumpWidget(player(const Color(0xFFE0D0C0)));
      expect(
        oldInk.every((image) => image.debugDisposed),
        isTrue,
        reason: 'a tint change must release the previous atlas and glow',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(created.every((image) => image.debugDisposed), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('inactive timed ink ignores row-only opacity animation', (
    tester,
  ) async {
    final opacity = ValueNotifier(0.34);
    addTearDown(opacity.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            child: ValueListenableBuilder<double>(
              valueListenable: opacity,
              builder: (context, value, _) => MusicLyricRowOpacity(
                opacity: value,
                duration: const Duration(milliseconds: 400),
                child: const MusicTimedLyricText(
                  text: 'Hello world',
                  spans: _spans,
                  dimUnplayed: false,
                  style: _style,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    opacity.value = 0.23;
    await tester.pump();
    final painter = tester
        .renderObject<RenderCustomPaint>(
          find.descendant(
            of: find.byType(MusicTimedLyricText),
            matching: find.byType(CustomPaint),
          ),
        )
        .foregroundPainter!;
    var repaints = 0;
    void repaint() => repaints++;
    painter.addListener(repaint);
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    painter.removeListener(repaint);
    expect(
      repaints,
      0,
      reason: 'the compositor can fade unchanged ink without repainting it',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('word-row fading does not rebuild focus images every frame', (
    tester,
  ) async {
    final opacity = ValueNotifier(0.34);
    addTearDown(opacity.dispose);
    var images = 0;
    final previous = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      images++;
      previous?.call(image);
    };
    addTearDown(() => ui.Image.onCreate = previous);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Center(
          child: SizedBox(
            width: 320,
            child: MusicLyricDepth(
              active: true,
              distance: 0,
              browsing: false,
              rasterFocus: true,
              child: ValueListenableBuilder<double>(
                valueListenable: opacity,
                builder: (context, value, _) => MusicLyricRowOpacity(
                  opacity: value,
                  duration: const Duration(milliseconds: 400),
                  child: const MusicTimedLyricText(
                    text: 'Hello world',
                    spans: _spans,
                    fallbackPosition: Duration(milliseconds: 1500),
                    style: _style,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    opacity.value = 1;
    await tester.pump();
    final before = images;
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      images - before,
      lessThanOrEqualTo(3),
      reason: 'opacity compensation must not invalidate textures every frame',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform disabled depth has no image filter layer', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: const MusicLyricDepth(
            active: true,
            distance: 0,
            browsing: false,
            rasterFocus: true,
            blurEnabled: false,
            child: MusicTimedLyricText(
              text: 'A clear lyric',
              spans: [],
              style: _style,
            ),
          ),
        ),
      );
      final filter = find.byWidgetPredicate(
        (widget) => widget is ImageFiltered,
      );
      expect(tester.widget<ImageFiltered>(filter).enabled, isFalse);
      expect(
        tester.renderObject(filter).debugLayer,
        isNot(isA<ImageFilterLayer>()),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$platform plain lyric depth creates no Dart image surfaces', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewport = GlobalKey();
      final top = ValueNotifier(300.0);
      final motion = MusicLyricFollowMotion();
      addTearDown(top.dispose);
      addTearDown(motion.dispose);
      var images = 0;
      final previous = ui.Image.onCreate;
      ui.Image.onCreate = (image) {
        images++;
        previous?.call(image);
      };
      addTearDown(() => ui.Image.onCreate = previous);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              devicePixelRatio: 3.5,
            ),
            child: Scaffold(
              body: SizedBox.expand(
                key: viewport,
                child: Stack(
                  children: [
                    ValueListenableBuilder<double>(
                      valueListenable: top,
                      builder: (context, value, _) => Positioned(
                        top: value,
                        left: 24,
                        width: 320,
                        child: MusicLyricDepth(
                          active: false,
                          distance: 1,
                          browsing: false,
                          rasterFocus: true,
                          viewportKey: viewport,
                          motion: motion,
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              MusicTimedLyricText(
                                text: 'A plain lyric paragraph',
                                spans: [],
                                style: _style,
                              ),
                              MusicTimedLyricText(
                                text: '这一行的歌词翻译',
                                spans: [],
                                style: TextStyle(
                                  fontSize: 18,
                                  color: Colors.white,
                                ),
                              ),
                            ],
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
      await tester.pumpAndSettle();
      for (var frame = 0; frame < 40; frame++) {
        top.value = 300 - frame * 4.0;
        motion.advance(4);
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(
        images,
        0,
        reason: 'mobile depth should reuse the paragraph compositing layer',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
