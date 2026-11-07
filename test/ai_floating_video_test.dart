import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_floating_video.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/media_playback_service.dart';

/// The caption paints through a TextSpan tree, so the size lives on a span.
double _spanFontSize(RichText rich) {
  double? walk(InlineSpan span) {
    if (span is! TextSpan) return null;
    final size = span.style?.fontSize;
    if (size != null) return size;
    for (final child in span.children ?? const <InlineSpan>[]) {
      final found = walk(child);
      if (found != null) return found;
    }
    return null;
  }

  return walk(rich.text) ?? 0;
}

void main() {
  group('floating geometry', () {
    test('first-run width stays reasonable on every screen class', () {
      // Phone portrait, phone landscape, tablet, desktop.
      const sizes = <Size>[
        Size(390, 700),
        Size(844, 330),
        Size(1024, 1200),
        Size(1400, 760),
        Size(320, 420),
      ];
      for (final size in sizes) {
        final width = defaultFloatingVideoWidth(size);
        expect(width, greaterThanOrEqualTo(120), reason: '$size');
        expect(width, lessThanOrEqualTo(kFloatingVideoMaxWidth), reason: '$size');
        expect(width, lessThanOrEqualTo(size.width), reason: '$size');
      }
      // A desktop card is bigger than a phone card, but not by an order.
      expect(
        defaultFloatingVideoWidth(const Size(1400, 760)),
        greaterThan(defaultFloatingVideoWidth(const Size(390, 700))),
      );
    });

    test('rect sits bottom-right by default and clamps on every edge', () {
      const available = Size(800, 600);
      final rect = floatingVideoRect(
        available: available,
        width: 320,
        aspect: 16 / 9,
        stripHeight: 40,
        anchor: const Offset(1, 1),
      );
      expect(rect.right, closeTo(available.width, .01));
      expect(rect.bottom, closeTo(available.height, .01));
      expect(rect.width, 320);

      for (final anchor in const <Offset>[
        Offset(-3, -3),
        Offset(2, 2),
        Offset(0, 1),
        Offset(1, 0),
      ]) {
        final clamped = floatingVideoRect(
          available: available,
          width: 320,
          aspect: 16 / 9,
          stripHeight: 40,
          anchor: anchor,
        );
        expect(clamped.left, greaterThanOrEqualTo(-.01), reason: '$anchor');
        expect(clamped.top, greaterThanOrEqualTo(-.01), reason: '$anchor');
        expect(
          clamped.right,
          lessThanOrEqualTo(available.width + .01),
          reason: '$anchor',
        );
        expect(
          clamped.bottom,
          lessThanOrEqualTo(available.height + .01),
          reason: '$anchor',
        );
      }
    });

    test('width is clamped between the usable bounds', () {
      const available = Size(800, 600);
      final tiny = floatingVideoRect(
        available: available,
        width: 10,
        aspect: 16 / 9,
        stripHeight: 40,
        anchor: const Offset(0, 0),
      );
      expect(tiny.width, kFloatingVideoMinWidth);
      final huge = floatingVideoRect(
        available: available,
        width: 5000,
        aspect: 16 / 9,
        stripHeight: 40,
        anchor: const Offset(0, 0),
      );
      expect(huge.width, lessThanOrEqualTo(maxFloatingVideoWidth(available)));
      expect(huge.width, lessThanOrEqualTo(available.width));
    });

    test('a degenerate aspect falls back to 16:9', () {
      final rect = floatingVideoRect(
        available: const Size(800, 600),
        width: 320,
        aspect: 0,
        stripHeight: 40,
        anchor: const Offset(0, 0),
      );
      expect(rect.height, closeTo(320 * 9 / 16 + 40, .01));
    });
  });

  group('mini metrics', () {
    test('every dimension grows with the card', () {
      final small = MiniVideoMetrics.fromWidth(176);
      final medium = MiniVideoMetrics.fromWidth(260);
      final large = MiniVideoMetrics.fromWidth(400);
      expect(small.scale, lessThan(medium.scale));
      expect(medium.scale, lessThan(large.scale));
      for (final pick in <double Function(MiniVideoMetrics)>[
        (m) => m.iconSize,
        (m) => m.buttonExtent,
        (m) => m.stripHeight,
        (m) => m.cornerRadius,
      ]) {
        expect(pick(small), lessThanOrEqualTo(pick(medium)));
        expect(pick(medium), lessThanOrEqualTo(pick(large)));
      }
      // Six buttons plus the resize gutter must still fit the smallest card.
      expect(small.buttonExtent * 7, lessThanOrEqualTo(176));
    });
  });

  group('mini clock', () {
    test('time labels stay compact', () {
      expect(formatMiniDuration(Duration.zero), '0:00');
      expect(formatMiniDuration(const Duration(minutes: 3, seconds: 7)), '3:07');
      expect(
        formatMiniDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });
  });

  group('floating player state', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('is on by default and remembers a toggle', () async {
      final state = AiFloatingVideoState();
      await state.load();
      expect(state.enabled, isTrue);

      await state.setEnabled(false);
      expect(state.enabled, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          AiFloatingVideoState.enabledKey,
        ),
        isFalse,
      );

      final restored = AiFloatingVideoState();
      await restored.load();
      expect(restored.enabled, isFalse);
    });

    test('remembers a layout and normalizes the anchor', () async {
      final state = AiFloatingVideoState();
      await state.load();
      await state.rememberLayout(anchor: const Offset(.25, .5), width: 264);

      final restored = AiFloatingVideoState();
      await restored.load();
      expect(restored.anchorX, closeTo(.25, .0001));
      expect(restored.anchorY, closeTo(.5, .0001));
      expect(restored.width, closeTo(264, .0001));

      await restored.rememberLayout(anchor: const Offset(-4, 9), width: 200);
      expect(restored.anchorX, 0);
      expect(restored.anchorY, 1);
    });
  });

  group('floating player layer', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    Future<({Rect bounds, AiFloatingVideoState state})> pumpLayer(
      WidgetTester tester, {
      required Size size,
      AiFloatingVideoState? state,
    }) async {
      final resolved = state ?? AiFloatingVideoState();
      await resolved.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: const ValueKey<String>('viewport'),
                width: size.width,
                height: size.height,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: AiFloatingVideoLayer(
                        key: const ValueKey<String>('layer'),
                        state: resolved,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return (
        bounds: tester.getRect(find.byKey(const ValueKey<String>('viewport'))),
        state: resolved,
      );
    }

    testWidgets('appears bottom-right and sizes itself to the viewport', (
      tester,
    ) async {
      const size = Size(700, 520);
      final bounds = (await pumpLayer(tester, size: size)).bounds;
      final card = find.byKey(const ValueKey<String>('ai-floating-video'));
      expect(card, findsOneWidget);
      final rect = tester.getRect(card);
      expect(rect.width, greaterThanOrEqualTo(kFloatingVideoMinWidth));
      expect(
        rect.width,
        lessThanOrEqualTo(maxFloatingVideoWidth(size)),
      );
      expect(rect.right, closeTo(bounds.right, .5));
      expect(rect.bottom, closeTo(bounds.bottom, .5));
      expect(rect.left, greaterThanOrEqualTo(bounds.left - .5));
      expect(rect.top, greaterThanOrEqualTo(bounds.top - .5));
    });

    testWidgets('stays hidden when the viewport is too small', (tester) async {
      await pumpLayer(tester, size: const Size(180, 120));
      expect(
        find.byKey(const ValueKey<String>('ai-floating-video')),
        findsNothing,
      );
    });

    testWidgets('dragging the picture moves the card and keeps it inside', (
      tester,
    ) async {
      const size = Size(700, 520);
      final bounds = (await pumpLayer(tester, size: size)).bounds;
      final card = find.byKey(const ValueKey<String>('ai-floating-video'));
      final before = tester.getRect(card);
      await tester.drag(card, const Offset(-200, -160));
      await tester.pumpAndSettle();
      final after = tester.getRect(card);
      expect(after.left, lessThan(before.left));
      expect(after.top, lessThan(before.top));
      expect(after.width, closeTo(before.width, .5));
      expect(after.left, greaterThanOrEqualTo(bounds.left - .5));
      expect(after.top, greaterThanOrEqualTo(bounds.top - .5));

      // A far overshoot must not push it off screen.
      await tester.drag(card, const Offset(2000, 2000));
      await tester.pumpAndSettle();
      final clamped = tester.getRect(card);
      expect(clamped.right, lessThanOrEqualTo(bounds.right + .5));
      expect(clamped.bottom, lessThanOrEqualTo(bounds.bottom + .5));
    });

    testWidgets('there is no drag handle over the picture', (tester) async {
      await pumpLayer(tester, size: const Size(700, 520));
      expect(
        find.byKey(const ValueKey<String>('ai-floating-grip')),
        findsNothing,
      );
    });

    testWidgets('a long press boosts without dragging the card', (
      tester,
    ) async {
      await pumpLayer(tester, size: const Size(700, 520));
      final card = find.byKey(const ValueKey<String>('ai-floating-video'));
      final before = tester.getRect(card);

      final gesture = await tester.startGesture(before.center);
      // Past the long-press timeout, then move: the hold owns the sequence, so
      // this must not turn into a drag.
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(-90, -60));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final after = tester.getRect(card);
      expect(after.left, closeTo(before.left, .5));
      expect(after.top, closeTo(before.top, .5));
    });

    testWidgets('the corner handle resizes within bounds', (tester) async {
      await pumpLayer(tester, size: const Size(900, 600));
      final card = find.byKey(const ValueKey<String>('ai-floating-video'));
      final before = tester.getRect(card);
      await tester.drag(
        find.byKey(const ValueKey<String>('ai-floating-resize')),
        const Offset(90, 0),
      );
      await tester.pumpAndSettle();
      final wider = tester.getRect(card);
      expect(wider.width, greaterThan(before.width));

      await tester.drag(
        find.byKey(const ValueKey<String>('ai-floating-resize')),
        const Offset(-4000, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(card).width,
        greaterThanOrEqualTo(kFloatingVideoMinWidth),
      );
    });

    testWidgets('the card follows the pointer and stops dead', (tester) async {
      final bounds = (await pumpLayer(tester, size: const Size(700, 520)))
          .bounds;
      final card = find.byKey(const ValueKey<String>('ai-floating-video'));
      final before = tester.getRect(card);

      final gesture = await tester.startGesture(tester.getCenter(card));
      await tester.pump(const Duration(milliseconds: 16));
      // The first move only trips the drag slop; the second one is tracked.
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-110, 0));
      await tester.pump();
      await gesture.up();
      final atRelease = tester.getRect(card);
      await tester.pumpAndSettle();
      final after = tester.getRect(card);

      // It moved with the pointer...
      expect(atRelease.left, lessThan(before.left - 60));
      // ...and it did not travel a single pixel further after release.
      expect(after.left, closeTo(atRelease.left, .5));
      expect(after.left, greaterThanOrEqualTo(bounds.left - .5));
      expect(after.right, lessThanOrEqualTo(bounds.right + .5));
    });

    testWidgets('the card does not snap to an edge', (tester) async {
      final bounds = (await pumpLayer(tester, size: const Size(700, 520)))
          .bounds;
      final card = find.byKey(const ValueKey<String>('ai-floating-video'));
      expect(tester.getRect(card).right, closeTo(bounds.right, .5));

      final gesture = await tester.startGesture(tester.getCenter(card));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-110, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Nothing pulls it back to the edge.
      expect(tester.getRect(card).right, lessThan(bounds.right - 40));
    });

    testWidgets('a move alone never pins the automatic width', (tester) async {
      final state = AiFloatingVideoState();
      await pumpLayer(tester, size: const Size(700, 520), state: state);
      await tester.drag(
        find.byKey(const ValueKey<String>('ai-floating-video')),
        const Offset(-120, -90),
      );
      await tester.pumpAndSettle();
      expect(state.width, isNull);
      expect(state.anchorX, lessThan(1));
      expect(state.anchorY, lessThan(1));
    });

    testWidgets('a resize does pin the width', (tester) async {
      final state = AiFloatingVideoState();
      await pumpLayer(tester, size: const Size(900, 600), state: state);
      await tester.drag(
        find.byKey(const ValueKey<String>('ai-floating-resize')),
        const Offset(70, 0),
      );
      await tester.pumpAndSettle();
      expect(state.width, isNotNull);
      expect(state.width, greaterThan(kFloatingVideoMinWidth));
    });

    testWidgets('two fingers pinch the card bigger on touch', (tester) async {
      final state = AiFloatingVideoState();
      await pumpLayer(tester, size: const Size(900, 620), state: state);
      final card = find.byKey(const ValueKey<String>('ai-floating-video'));
      final before = tester.getRect(card);
      final center = before.center;

      final left = await tester.startGesture(
        center - const Offset(24, 0),
        pointer: 1,
      );
      final right = await tester.startGesture(
        center + const Offset(24, 0),
        pointer: 2,
      );
      await tester.pump();
      await left.moveBy(const Offset(-40, 0));
      await right.moveBy(const Offset(40, 0));
      await tester.pump();
      await left.up();
      await right.up();
      await tester.pumpAndSettle();

      expect(tester.getRect(card).width, greaterThan(before.width));
      expect(state.width, isNotNull);
    });

    testWidgets('controls stay clustered on a wide card', (tester) async {
      await pumpLayer(tester, size: const Size(900, 640));
      final card = tester.getRect(
        find.byKey(const ValueKey<String>('ai-floating-video')),
      );
      final rewind = tester.getRect(find.byTooltip('快退 10 秒'));
      final play = tester.getRect(find.byTooltip('播放'));
      final forward = tester.getRect(find.byTooltip('快进 10 秒'));

      // The old equal-slot row let the gap grow with the card. Buttons should
      // stay a fixed distance apart and the group should not span the strip.
      expect(play.left - rewind.right, lessThanOrEqualTo(16));
      expect(forward.left - play.right, lessThanOrEqualTo(16));
      expect(forward.right - rewind.left, lessThan(card.width * .8));
    });

    testWidgets('toggles sit flush right in the player order', (tester) async {
      await pumpLayer(tester, size: const Size(900, 640));
      final card = tester.getRect(
        find.byKey(const ValueKey<String>('ai-floating-video')),
      );
      final speed = tester.getRect(find.byTooltip('播放速度'));
      final subtitles = tester.getRect(find.byTooltip('关闭字幕'));
      final mute = tester.getRect(find.byTooltip('静音'));

      // The full player's bottom row runs speed - subtitles - mute.
      expect(speed.left, lessThan(subtitles.left));
      expect(subtitles.left, lessThan(mute.left));
      // Only the resize corner sits beyond them.
      expect(card.right - mute.right, lessThan(48));

      final play = tester.getRect(find.byTooltip('播放'));
      expect(play.left, lessThan(mute.left));
    });

    testWidgets('transport centres when it can and slides left otherwise', (
      tester,
    ) async {
      await pumpLayer(tester, size: const Size(900, 640));
      final card = tester.getRect(
        find.byKey(const ValueKey<String>('ai-floating-video')),
      );
      final play = tester.getRect(find.byTooltip('播放'));
      final mute = tester.getRect(find.byTooltip('静音'));

      // Never right of centre, never on top of the toggles, but still pulled
      // towards the middle rather than parked at the left edge.
      expect(play.center.dx, lessThanOrEqualTo(card.center.dx + .5));
      expect(play.right, lessThan(mute.left));
      expect(play.center.dx - card.left, greaterThan(card.width * .3));
    });

    testWidgets('captions scale with the card instead of a fixed size', (
      tester,
    ) async {
      Future<({double font, double width})> caption(Size size) async {
        final service = MediaPlaybackService.forTesting();
        service.setSubtitles(<SubtitleItem>[
          SubtitleItem(
            index: 0,
            startTime: Duration.zero,
            endTime: const Duration(minutes: 5),
            text: '测试字幕',
          ),
        ]);
        await tester.pumpWidget(
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: service,
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: Stack(
                      children: <Widget>[
                        Positioned.fill(
                          child: AiFloatingVideoLayer(
                            state: AiFloatingVideoState(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        // The caption group waits for its font future before painting.
        await tester.pump();
        final rich = tester
            .widgetList<RichText>(find.byType(RichText))
            .firstWhere((r) => r.text.toPlainText().contains('测试字幕'));
        final card = tester.getRect(
          find.byKey(const ValueKey<String>('ai-floating-video')),
        );
        return (font: _spanFontSize(rich), width: card.width);
      }

      final small = await caption(const Size(320, 260));
      final large = await caption(const Size(900, 700));

      // The card video box is sized from the card width, so the caption has to
      // grow with it — the same ratio the full player keeps against its own
      // video box — instead of keeping a fixed pixel size.
      expect(small.font, greaterThan(0));
      final widthRatio = large.width / small.width;
      final fontRatio = large.font / small.font;
      expect(fontRatio, closeTo(widthRatio, widthRatio * .12));
    });

    testWidgets('control strip keeps the six requested controls', (
      tester,
    ) async {
      await pumpLayer(tester, size: const Size(700, 520));
      for (final tooltip in <String>[
        '播放',
        '快进 10 秒',
        '快退 10 秒',
        '播放速度',
      ]) {
        expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
      }
      expect(find.byType(IconButton), findsNWidgets(5));
      // Mute and subtitles flip their labels with state.
      int count(String first, String second) =>
          find.byTooltip(first).evaluate().length +
          find.byTooltip(second).evaluate().length;
      expect(count('静音', '取消静音'), 1);
      expect(count('打开字幕', '关闭字幕'), 1);
    });
  });

  group('toolbar command', () {
    testWidgets('is a 32px icon button with a distinct plate', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AiFloatingVideoButton(enabled: true, onPressed: () {}),
            ),
          ),
        ),
      );
      final button = find.byType(IconButton);
      expect(button, findsOneWidget);
      expect(tester.getRect(button).size, const Size.square(32));
      expect(find.byTooltip('悬浮播放'), findsOneWidget);
    });
  });
}
