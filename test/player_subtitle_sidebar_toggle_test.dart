import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/player_subtitle_sidebar_toggle.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final left in [false, true]) {
      testWidgets('attached tab keeps press feedback inside its shape, '
          '$platform, left=$left', (tester) async {
        final capture = GlobalKey();
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1280, 800)),
              child: Center(
                child: RepaintBoundary(
                  key: capture,
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    child: ColoredBox(
                      color: const Color(0xff304050),
                      child: Center(
                        child: PlayerSubtitleSidebarToggle(
                          expanded: true,
                          onLeft: left,
                          onPressed: () => taps++,
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
        final hit = tester.getRect(
          find.byKey(const ValueKey('player-subtitle-sidebar-toggle')),
        );
        final shape = tester.getRect(
          find.byKey(const ValueKey('player-subtitle-sidebar-fold')),
        );
        expect(
          hit.size,
          platform == TargetPlatform.android
              ? const Size(48, 48)
              : const Size(32, 40),
          reason: 'Large touch screens also need a full touch target.',
        );
        expect(shape.width, lessThanOrEqualTo(16));
        expect(left ? shape.left : shape.right, left ? hit.left : hit.right);
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final origin = tester.getTopLeft(find.byKey(capture));
        final paintedBounds = shape.shift(-origin).inflate(1);
        Future<ByteData> pixels() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            return (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
          } finally {
            image.dispose();
          }
        }

        final before = await tester.runAsync(pixels);
        // Tap the invisible extension, well outside the small visible tab.
        final press = await tester.startGesture(
          Offset(left ? hit.right - 4 : hit.left + 4, hit.center.dy),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 150));
        final during = await tester.runAsync(pixels);
        var changed = 0;
        for (var y = 0; y < 100; y++) {
          for (var x = 0; x < 100; x++) {
            final index = (y * 100 + x) * 4;
            if (before!.getUint32(index) != during!.getUint32(index)) {
              changed++;
              expect(
                paintedBounds.contains(Offset(x + 0.5, y + 0.5)),
                isTrue,
                reason: 'No rectangular splash outside the visible tab.',
              );
            }
          }
        }
        expect(changed, greaterThan(0), reason: 'Press feedback is visible.');
        await press.up();
        await tester.pumpAndSettle();
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final reduceMotion in [false, true]) {
    testWidgets('keyboard and accessibility, reduceMotion=$reduceMotion', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        var taps = 0;
        Widget host({bool expanded = true, bool visible = true}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(800, 600),
              disableAnimations: reduceMotion,
            ),
            child: Scaffold(
              body: Row(
                children: [
                  const Spacer(),
                  PlayerSubtitleSidebarToggle(
                    expanded: expanded,
                    visible: visible,
                    onPressed: () => taps++,
                  ),
                ],
              ),
            ),
          ),
        );

        final button = find.byKey(
          const ValueKey('player-subtitle-sidebar-toggle'),
        );
        await tester.pumpWidget(host());
        final node = tester.getSemantics(button);
        expect(node.label, '收起字幕边栏');
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.flagsCollection.isExpanded, ui.Tristate.isTrue);
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(taps, 1);

        await tester.pumpWidget(host(expanded: false));
        if (reduceMotion) {
          await tester.pump();
          expect(tester.binding.transientCallbackCount, 0);
        }
        await tester.pumpAndSettle();
        expect(tester.getSemantics(button).label, '展开字幕边栏');
        expect(
          tester.getSemantics(button).flagsCollection.isExpanded,
          ui.Tristate.isFalse,
        );
        final originalLane = tester.getRect(
          find.byType(PlayerSubtitleSidebarToggle),
        );
        await tester.pumpWidget(host(expanded: false, visible: false));
        await tester.pumpAndSettle();
        expect(button.hitTestable(), findsNothing);
        expect(find.semantics.byLabel('展开字幕边栏'), findsNothing);
        expect(
          tester.getRect(find.byType(PlayerSubtitleSidebarToggle)),
          originalLane,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
