import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/desktop_player_sidebar.dart';
import 'package:video_player_app/widgets/player_sidebar_resize_indicator.dart';
import 'package:video_player_app/widgets/subtitle_chat_sidebar.dart';

void main() {
  testWidgets(
    'changing handedness retains reading surfaces and an active draft',
    (tester) async {
      var left = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) {
                update = set;
                return Center(
                  child: SizedBox(
                    height: 500,
                    child: DesktopPlayerSidebar(
                      panelId: 'reading',
                      panel: null,
                      width: 320,
                      retainedId: 'reading',
                      retainedWidth: 320,
                      viewportSize: const Size(800, 600),
                      onLeft: left,
                      divider: const ColoredBox(color: Colors.grey),
                      dividerWidth: 12,
                      retainedPanel: SubtitleChatSidebar(
                        key: const ValueKey('reading-surfaces'),
                        showChat: true,
                        onLeft: left,
                        subtitleWidth: 320,
                        chatWidth: 320,
                        subtitles: const TextField(
                          key: ValueKey('transcript-draft'),
                        ),
                        chat: const TextField(key: ValueKey('chat-draft')),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('chat-draft')),
        '保留中的草稿',
      );
      final surfaces = tester.element(
        find.byKey(const ValueKey('reading-surfaces')),
      );
      final input = tester.element(find.byKey(const ValueKey('chat-draft')));
      for (var change = 0; change < 20; change++) {
        update(() => left = !left);
        await tester.pump(const Duration(microseconds: 8333));
        expect(
          tester.element(find.byKey(const ValueKey('reading-surfaces'))),
          same(surfaces),
        );
        expect(
          tester.element(find.byKey(const ValueKey('chat-draft'))),
          same(input),
        );
        expect(find.text('保留中的草稿'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final left in [false, true]) {
    testWidgets('no dark seam at fractional sidebar widths, left=$left', (
      tester,
    ) async {
      final hovered = ValueNotifier(false);
      final capture = GlobalKey();
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(hovered.dispose);

      for (final ratio in [1.0, 1.25, 1.5, 1.75, 2.0]) {
        tester.view.devicePixelRatio = ratio;
        tester.view.physicalSize = Size(800 * ratio, 600 * ratio);
        for (final showChat in [false, true]) {
          final surface = Color(showChat ? 0xFF191919 : 0xFF1E1E1E);
          for (final width in [100.0, 100.2, 100.5, 127.3, 175.7, 300.3]) {
            final sidebar = DesktopPlayerSidebar(
              panelId: 'subtitles',
              panel: null,
              width: width,
              retainedId: 'subtitles',
              retainedWidth: width,
              retainedPanel: SubtitleChatSidebar(
                showChat: showChat,
                subtitleWidth: width,
                chatWidth: width,
                onLeft: left,
                subtitles: const ColoredBox(color: Color(0xFF1E1E1E)),
                chat: const ColoredBox(color: Color(0xFF191919)),
              ),
              viewportSize: const Size(800, 600),
              resizing: true,
              divider: PlayerSidebarResizeIndicator(
                hovered: hovered,
                resizing: true,
                backgroundColor: surface,
              ),
              dividerWidth: 12,
              onLeft: left,
              backgroundColor: surface,
            );
            await tester.pumpWidget(
              MaterialApp(
                home: RepaintBoundary(
                  key: capture,
                  child: Row(
                    children: [
                      if (left) sidebar,
                      const Expanded(child: ColoredBox(color: Colors.black)),
                      if (!left) sidebar,
                    ],
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: ratio);
              try {
                final pixels = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                final edge = (left ? width : 800 - width) * ratio;
                final expected = surface.toARGB32() & 0xFF;
                // Sample across both independently composited surfaces, away
                // from the handle. A black underlay produced a darker pixel
                // here (e.g. 15 instead of 30 at a width of 100.5).
                for (final y in [80, 500]) {
                  for (var x = edge.floor() - 3; x <= edge.ceil() + 3; x++) {
                    final offset = ((y * ratio).floor() * image.width + x) * 4;
                    expect(
                      [for (var c = 0; c < 4; c++) pixels.getUint8(offset + c)],
                      [expected, expected, expected, 255],
                      reason: 'ratio=$ratio width=$width chat=$showChat x=$x',
                    );
                  }
                }
              } finally {
                image.dispose();
              }
            });
          }
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('continuous transitions and retained state, left=$left', (
      tester,
    ) async {
      final subtitleKey = GlobalKey();
      final settingsKey = GlobalKey();
      final playerKey = GlobalKey();
      var layouts = 0;
      Widget host(
        String? id, {
        double width = 200,
        bool resizing = false,
        Size viewport = const Size(800, 600),
      }) {
        final sidebar = DesktopPlayerSidebar(
          key: const ValueKey('sidebar'),
          panelId: id,
          panel: id == 'settings' ? SizedBox(key: settingsKey) : null,
          width: width,
          retainedId: 'subtitles',
          retainedPanel: LayoutBuilder(
            key: subtitleKey,
            builder: (context, constraints) {
              layouts++;
              return const Text('subtitles');
            },
          ),
          retainedWidth: width,
          viewportSize: viewport,
          divider: id == 'subtitles'
              ? const ColoredBox(color: Colors.grey)
              : null,
          dividerWidth: id == 'subtitles' ? 8 : 0,
          onLeft: left,
          resizing: resizing,
        );
        return MaterialApp(
          home: Row(
            children: [
              if (left) sidebar,
              Expanded(
                key: const ValueKey('player'),
                child: SizedBox(key: playerKey),
              ),
              if (!left) sidebar,
            ],
          ),
        );
      }

      double extent() =>
          tester.getSize(find.byType(DesktopPlayerSidebar)).width;
      await tester.pumpWidget(host('subtitles'));
      expect(extent(), 208);
      final subtitleElement = subtitleKey.currentContext;
      final playerElement = playerKey.currentContext;
      await tester.pumpWidget(host(null));
      expect(extent(), 208); // Removing the divider must not jump the width.
      final beforeAnimation = layouts;
      var previous = extent();
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(microseconds: 8333));
        expect(extent(), lessThanOrEqualTo(previous));
        previous = extent();
      }
      expect(extent(), 0);
      expect(layouts, beforeAnimation); // Content is not laid out each frame.
      expect(subtitleKey.currentContext, same(subtitleElement));
      expect(TickerMode.valuesOf(subtitleKey.currentContext!).enabled, isFalse);
      await tester.pumpWidget(host('settings', width: 280));
      await tester.pump(const Duration(milliseconds: 70));
      final interruptedWidth = extent();
      await tester.pumpWidget(host('subtitles'));
      expect(extent(), closeTo(interruptedWidth, 0.001));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpWidget(host('settings', width: 280));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(host('subtitles'));
      await tester.pumpAndSettle();
      expect(extent(), 208);
      expect(settingsKey.currentContext, isNull);
      expect(subtitleKey.currentContext, same(subtitleElement));
      expect(playerKey.currentContext, same(playerElement));
      expect(TickerMode.valuesOf(subtitleKey.currentContext!).enabled, isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(host('subtitles', width: 250, resizing: true));
      await tester.pump();
      expect(extent(), 258);
      await tester.pumpWidget(
        host('subtitles', width: 300, viewport: const Size(1920, 1080)),
      );
      await tester.pump();
      expect(extent(), 308); // Fullscreen metrics do not start a second tween.
      expect(playerKey.currentContext, same(playerElement));
      expect(subtitleKey.currentContext, same(subtitleElement));
    });
  }
}
