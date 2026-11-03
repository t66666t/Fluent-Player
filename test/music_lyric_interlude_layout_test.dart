import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_timed_lyric_text.dart';

SubtitleItem _cue(int index, int start, int end, {bool bilingual = false}) =>
    SubtitleItem(
      index: index,
      startTime: Duration(seconds: start),
      endTime: Duration(seconds: end),
      text: 'Lyric $index',
      lyricTranslation: bilingual ? 'Translation $index' : '',
    );

Finder _dots(int next) => find.byKey(ValueKey('music-lyric-interlude-$next'));

Future<void> _show(
  WidgetTester tester,
  TargetPlatform platform,
  ValueNotifier<Duration> clock,
  List<SubtitleItem> cues, {
  double font = 1,
  double spacing = 1,
  double textScale = 1,
  bool blur = true,
  List<Duration>? seeks,
  MusicLyricPositionController? positionController,
  GlobalKey? previewKey,
  double anchorFraction = .3,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        backgroundColor: const Color(0xff241d2e),
        body: RepaintBoundary(
          key: previewKey,
          child: ColoredBox(
            color: const Color(0xff241d2e),
            child: MusicLyricView(
              subtitles: cues,
              positionListenable: clock,
              positionController: positionController,
              isPlaying: false,
              lyricFontSizeScale: font,
              lyricSpacingScale: spacing,
              lyricBlurEnabled: blur,
              anchorFraction: anchorFraction,
              applyEdgeFade: false,
              onSeek: (time) {
                seeks?.add(time);
                clock.value = time;
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _preview(WidgetTester tester, GlobalKey key, String name) async {
  const directory = String.fromEnvironment('INTERLUDE_PREVIEW_DIRECTORY');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    for (final font in {
      'Inter': 'assets/fonts/Inter-ExtraBold.otf',
      'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      '$platform focuses an independent interlude and then the lyric',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final clock = ValueNotifier(Duration.zero);
        addTearDown(clock.dispose);
        final seeks = <Duration>[];
        final locate = MusicLyricPositionController();
        addTearDown(locate.dispose);
        await _show(
          tester,
          platform,
          clock,
          [
            _cue(0, 0, 2, bilingual: true),
            _cue(1, 12, 14, bilingual: true),
            _cue(2, 14, 16),
          ],
          seeks: seeks,
          positionController: locate,
        );
        expect(tester.getTopLeft(find.text('Lyric 0')).dy, closeTo(180, .2));

        clock.value = const Duration(seconds: 6);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(_dots(1)).dy, closeTo(180, .6));
        expect(
          find.ancestor(
            of: _dots(1),
            matching: find.byType(MusicLyricRowOpacity),
          ),
          findsNothing,
        );
        MusicLyricDepth depth(Finder child) => tester.widget<MusicLyricDepth>(
          find.ancestor(of: child, matching: find.byType(MusicLyricDepth)),
        );
        expect(depth(_dots(1)).active, isTrue);
        expect(depth(find.text('Lyric 0')).active, isFalse);
        expect(depth(find.text('Lyric 1')).active, isFalse);
        expect(depth(find.text('Lyric 0')).distance, -1);
        expect(depth(find.text('Lyric 1')).distance, 1);
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(const ValueKey('music-lyric-row-opacity-0')),
              )
              .opacity,
          lessThan(.5),
        );
        await tester.tapAt(tester.getCenter(_dots(1)));
        // A pointer on the scroll surface temporarily suspends auto-follow.
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(seeks, isEmpty);

        clock.value = const Duration(seconds: 12);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text('Lyric 1')).dy, closeTo(180, .2));
        expect(depth(find.text('Lyric 1')).active, isTrue);
        expect(depth(_dots(1)).active, isFalse);

        clock.value = const Duration(seconds: 1);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text('Lyric 0')).dy, closeTo(180, .2));
        clock.value = const Duration(seconds: 7);
        locate.locate(clock.value);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(_dots(1)).dy, closeTo(180, .6));
        await tester.tap(find.text('Lyric 1'));
        await tester.pumpAndSettle();
        expect(seeks, [const Duration(seconds: 12)]);
        expect(tester.getTopLeft(find.text('Lyric 1')).dy, closeTo(180, .2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('$platform scales dots and balanced gaps with lyric settings', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final clock = ValueNotifier(const Duration(seconds: 6));
      addTearDown(clock.dispose);
      final cues = [
        _cue(0, 0, 2, bilingual: true),
        _cue(1, 12, 14, bilingual: true),
      ];
      final previewKey = GlobalKey();
      for (final (font, spacing, textScale) in [
        (1.0, 1.0, 1.0),
        (0.4, 1.0, 1.0),
        (3.0, 1.0, 1.0),
        (1.0, 0.0, 1.0),
        (1.0, 4.0, 1.0),
        (1.0, 1.0, 1.8),
      ]) {
        await _show(
          tester,
          platform,
          clock,
          cues,
          font: font,
          spacing: spacing,
          textScale: textScale,
          blur: false,
          previewKey: previewKey,
        );
        final dots = tester.getRect(_dots(1));
        final em = 900 * .045 * font * textScale;
        final gap = em * spacing * .8;
        expect(dots.height, closeTo(em, .01));
        expect(dots.width, closeTo(em * 1.6, .01));
        expect(dots.top, closeTo(270, .6));
        expect(
          dots.top - tester.getBottomLeft(find.text('Translation 0')).dy,
          closeTo(gap, em * .15),
          reason: 'The existing inactive-row scale adds a small optical gap.',
        );
        expect(
          tester.getTopLeft(find.text('Lyric 1')).dy - dots.bottom,
          closeTo(gap, .2),
        );
        if (platform == TargetPlatform.windows && spacing == 1 && font >= 1) {
          await _preview(tester, previewKey, 'interlude-$font-$textScale');
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$platform keeps large prelude dots above the first lyric', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final clock = ValueNotifier(const Duration(seconds: 5));
      addTearDown(clock.dispose);
      final cues = [_cue(0, 12, 16)];
      for (final (font, textScale) in [(1.0, 1.0), (3.0, 1.0), (3.0, 1.8)]) {
        await _show(
          tester,
          platform,
          clock,
          cues,
          font: font,
          textScale: textScale,
          anchorFraction: .15,
        );
        final prelude = tester.getRect(
          find.byKey(const ValueKey('music-lyric-prelude')),
        );
        expect(prelude.top, greaterThanOrEqualTo(0));
        expect(
          prelude.bottom,
          lessThanOrEqualTo(tester.getTopLeft(find.text('Lyric 0')).dy),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$platform locates distant interludes and appended subtitles', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final clock = ValueNotifier(const Duration(seconds: 6));
      addTearDown(clock.dispose);
      final buffer = SubtitleCueBuffer()..addAll([_cue(0, 0, 2)]);
      await _show(tester, platform, clock, buffer.snapshot);
      expect(find.byType(MusicLyricInterlude), findsNothing);
      buffer.addAll(
        List.generate(49, (i) => _cue(i + 1, (i + 1) * 14, (i + 1) * 14 + 2)),
      );
      final previewKey = GlobalKey();
      await _show(
        tester,
        platform,
        clock,
        buffer.snapshot,
        previewKey: previewKey,
      );
      expect(tester.getTopLeft(_dots(1)).dy, closeTo(844 * .3, .6));
      if (platform == TargetPlatform.windows) {
        await _preview(tester, previewKey, 'interlude-phone');
      }
      clock.value = const Duration(seconds: 49 * 14 - 5);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_dots(49)).dy, closeTo(844 * .3, .6));
      clock.value = const Duration(seconds: 49 * 14);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Lyric 49')).dy,
        closeTo(844 * .3, .2),
      );
      clock.value = const Duration(seconds: 6);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_dots(1)).dy, closeTo(844 * .3, .6));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$platform enters a long gap without visiting the next lyric', (
      tester,
    ) async {
      final clock = ValueNotifier(Duration.zero);
      addTearDown(clock.dispose);
      await _show(tester, platform, clock, [
        _cue(0, 0, 4).copyWith(
          timedSpans: [
            SubtitleTimedSpan(
              textStart: 0,
              textEnd: 7,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
            ),
          ],
        ),
        _cue(1, 12, 14),
      ]);
      final anchor = tester.getTopLeft(find.text('Lyric 0')).dy;
      clock.value = const Duration(seconds: 3);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Lyric 0')).dy, closeTo(anchor, .2));
      clock.value = const Duration(seconds: 5);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_dots(1)).dy, closeTo(anchor, .6));
      clock.value = const Duration(seconds: 12);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Lyric 1')).dy, closeTo(anchor, .2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$platform excludes overlapping vocals from interlude gaps', (
      tester,
    ) async {
      final clock = ValueNotifier(const Duration(seconds: 3));
      addTearDown(clock.dispose);
      await _show(tester, platform, clock, [
        _cue(0, 0, 12),
        _cue(1, 1, 2),
        _cue(2, 14, 16),
      ]);
      expect(find.byType(MusicLyricInterlude), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
