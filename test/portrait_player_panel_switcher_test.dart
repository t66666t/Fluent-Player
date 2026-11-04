import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/portrait_player_panel_switcher.dart';

void main() {
  testWidgets(
    'an active tool is opaque as soon as it takes input, including reopen',
    (tester) async {
      final host = _PanelHost();
      await host.mount(tester);
      for (final panel in ['manager', 'settings', 'manager']) {
        host.change(() {
          host.panel = panel;
          host.returnPanels.add(panel);
        });
        await tester.pump();
        final surface = find.byKey(ValueKey<Object>(panel));
        final fade = find
            .descendant(of: surface, matching: find.byType(FadeTransition))
            .first;
        expect(
          tester.widget<FadeTransition>(fade).opacity.value,
          1,
          reason: 'An input-owning tool must never be an invisible hit target.',
        );
        expect(await host.surfaceColor(tester), _panelColor(panel));
        expect(find.byKey(_readingMarker), findsNothing);
        await tester.tap(find.text(panel));
        expect(host.panelTaps, greaterThan(0));
        expect(host.readingTaps, 0);
        await tester.pump(const Duration(milliseconds: 32));
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.all(),
  );

  testWidgets('muted tickers cannot leave a tool over the returning document', (
    tester,
  ) async {
    final host = _PanelHost()..tickersEnabled = false;
    await host.mount(tester);
    host.change(() => host.panel = 'manager');
    await tester.pump();
    expect(await host.surfaceColor(tester), _panelColor('manager'));
    await tester.pump(const Duration(seconds: 1));
    expect(await host.surfaceColor(tester), _panelColor('manager'));
    await tester.tap(find.text('manager'));
    expect(host.panelTaps, 1);
    host.change(() => host.panel = null);
    await tester.pump();
    expect(find.text('manager'), findsNothing);
    await tester.tap(find.byKey(_readingMarker));
    expect(host.readingTaps, 1);
    expect(host.panelTaps, 1);
    expect(tester.takeException(), isNull);
  });

  for (final openingMs in [0, 40, 200]) {
    testWidgets(
      'tool fades keep the document hidden after ${openingMs}ms of opening',
      (tester) async {
        final host = _PanelHost();
        await host.mount(tester);
        final document = host.documentKey.currentState!;
        document.scroll.jumpTo(420);
        host.change(() {
          host.panel = 'manager';
          host.returnPanels.add('manager');
        });
        await tester.pump();
        await tester.pump(Duration(milliseconds: openingMs));
        for (final panel in ['ai', 'manager', 'ocr', 'manager']) {
          host.change(() => host.panel = panel);
          for (var frame = 0; frame < 24; frame++) {
            await tester.pump(const Duration(microseconds: 8333));
            expect(
              find.byKey(_readingMarker),
              findsNothing,
              reason: 'The document must not paint during the fade to $panel.',
            );
            expect(host.documentKey.currentState, same(document));
            expect(document.scroll.offset, 420);
          }
        }
        host.change(() {
          host.panel = null;
          host.returnPanels.clear();
        });
        await tester.pumpAndSettle();
        expect(find.byKey(_readingMarker), findsOneWidget);
        expect(host.documentKey.currentState, same(document));
        expect(document.scroll.offset, 420);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'return holds the tool until the restored reading view is painted',
    (tester) async {
      final ready = ValueNotifier(true);
      final host = _PanelHost()..readiness = ready;
      await host.mount(tester);
      host.change(() => host.panel = 'settings');
      await tester.pumpAndSettle();
      ready.value = false;
      host.change(() => host.panel = null);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      await tester.tapAt(tester.getCenter(find.byKey(_readingMarker)));
      expect(
        host.readingTaps,
        0,
        reason: 'A held tool must not expose input on the unreadied document.',
      );
      ready.value = true;
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      ready.dispose();
    },
  );

  testWidgets('hidden reading keeps its geometry and text environment', (
    tester,
  ) async {
    final host = _PanelHost();
    await host.mount(tester);
    final document = find.byType(_Document, skipOffstage: false);
    host.change(() => host.panel = 'settings');
    await tester.pumpAndSettle();
    host.change(() {
      host.textScale = 2;
      host.height = 220;
    });
    await tester.pumpAndSettle();
    expect(tester.getSize(document).height, 440);
    expect(MediaQuery.textScalerOf(tester.element(document)).scale(14), 14);
    host.change(() => host.panel = null);
    await tester.pumpAndSettle();
    expect(tester.getSize(document).height, 220);
    expect(MediaQuery.textScalerOf(tester.element(document)).scale(14), 28);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an aborted opening removes the never-visible tool surface', (
    tester,
  ) async {
    final host = _PanelHost();
    await host.mount(tester);
    host.change(() => host.panel = 'settings');
    await tester.pump();
    host.change(() => host.panel = null);
    await tester.pumpAndSettle();
    expect(find.text('settings'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion changes panels without a fade', (tester) async {
    final host = _PanelHost()..reducedMotion = true;
    await host.mount(tester);
    host.change(() => host.panel = 'settings');
    await tester.pump();
    final opacity = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(opacity.duration, Duration.zero);
    expect(opacity.opacity, 1);
    host.change(() => host.panel = null);
    await tester.pumpAndSettle();
    expect(find.text('settings'), findsNothing);
    expect(tester.getTopLeft(find.byKey(_readingMarker)).dy, 0);
  });

  testWidgets('returning reading panel has no geometric entrance animation', (
    tester,
  ) async {
    final host = _PanelHost();
    await host.mount(tester);
    final initial = tester.getRect(find.byKey(_readingMarker));
    host.change(() => host.panel = 'settings');
    await tester.pumpAndSettle();
    host.change(() => host.panel = null);
    for (var frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getRect(find.byKey(_readingMarker)),
        initial,
        reason:
            'Returning text must be laid out at its final position from '
            'its first visible frame, without rising through the reading area.',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rapid panel returns retain one document and its reading offset',
    (tester) async {
      final host = _PanelHost();
      await host.mount(tester);
      final document = host.documentKey.currentState;
      final scroll = document!.scroll;
      scroll.jumpTo(420);
      await tester.pump();
      for (var visit = 0; visit < 4; visit++) {
        host.change(() => host.panel = 'settings');
        await tester.pump(const Duration(milliseconds: 32));
        host.change(() => host.panel = null);
        await tester.pump(const Duration(milliseconds: 32));
        expect(host.documentKey.currentState, same(document));
        expect(scroll.offset, closeTo(420, .01));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsNothing);
    },
  );

  testWidgets('inactive panels cannot intercept reading gestures', (
    tester,
  ) async {
    final host = _PanelHost();
    await host.mount(tester);
    host.change(() => host.panel = 'settings');
    await tester.pumpAndSettle();
    host.change(() => host.panel = 'other');
    await tester.pump(const Duration(milliseconds: 32));
    host.change(() => host.panel = null);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.byKey(_readingMarker));
    expect(host.readingTaps, 1);
    expect(host.panelTaps, 0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

const _readingMarker = ValueKey('reading-marker');

class _PanelHost {
  final surfaceKey = GlobalKey();
  final documentKey = GlobalKey<_DocumentState>();
  final returnPanels = <Object>{};
  Object? panel;
  late StateSetter change;
  int readingTaps = 0;
  int panelTaps = 0;
  bool reducedMotion = false;
  bool tickersEnabled = true;
  double textScale = 1;
  double height = 440;
  ValueListenable<bool>? readiness;

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                return MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 360,
                      height: height,
                      child: RepaintBoundary(
                        key: surfaceKey,
                        child: TickerMode(
                          enabled: tickersEnabled,
                          child: PortraitPlayerPanelSwitcher(
                            readingReady: readiness,
                            returnPanelIds: returnPanels.toSet(),
                            readingPanel: _Document(
                              key: documentKey,
                              onTap: () => readingTaps++,
                            ),
                            panelId: panel,
                            panel: panel == null
                                ? null
                                : GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => panelTaps++,
                                    child: ColoredBox(
                                      color: _panelColor(panel),
                                      child: Center(child: Text('$panel')),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<Color?> surfaceColor(WidgetTester tester) => tester.runAsync(() async {
    final boundary =
        surfaceKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = (image.width * 10 + 10) * 4;
      return Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  });
}

Color _panelColor(Object? panel) =>
    panel == 'manager' ? const Color(0xFFAA0000) : const Color(0xFF0000AA);

class _Document extends StatefulWidget {
  const _Document({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<_Document> createState() => _DocumentState();
}

class _DocumentState extends State<_Document> {
  final scroll = ScrollController();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      GestureDetector(
        onTap: widget.onTap,
        child: const SizedBox(
          key: _readingMarker,
          width: double.infinity,
          height: 40,
          child: Text('reading toolbar'),
        ),
      ),
      Expanded(
        child: ListView.builder(
          controller: scroll,
          itemCount: 100,
          itemExtent: 40,
          itemBuilder: (_, index) => Text('line $index'),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }
}
