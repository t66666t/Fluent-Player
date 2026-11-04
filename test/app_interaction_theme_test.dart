import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';

Future<Uint8List> pixels(WidgetTester tester, GlobalKey key) async {
  late Uint8List bytes;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    bytes = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    image.dispose();
  });
  return bytes;
}

void main() {
  for (final type in [
    'ink',
    'text',
    'filled',
    'elevated',
    'outlined',
    'icon',
  ]) {
    for (final popup in [false, true]) {
      testWidgets(
        '$type press clears before ${popup ? 'dialog' : 'page'} navigation',
        (tester) async {
          final boundary = GlobalKey();
          final nav = GlobalKey<NavigatorState>();
          var calls = 0;
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: nav,
              theme: appInteractionTheme(ThemeData.dark(useMaterial3: true)),
              home: Scaffold(
                body: Center(
                  child: Builder(
                    builder: (context) {
                      void open() {
                        calls++;
                        if (popup) {
                          showDialog<void>(
                            context: context,
                            builder: (_) =>
                                const AlertDialog(content: Text('Next')),
                          );
                        } else {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  const Scaffold(body: Text('Next')),
                            ),
                          );
                        }
                      }

                      final button = switch (type) {
                        'text' => TextButton(
                          onPressed: open,
                          child: const Text('Open'),
                        ),
                        'filled' => FilledButton(
                          onPressed: open,
                          child: const Text('Open'),
                        ),
                        'elevated' => ElevatedButton(
                          onPressed: open,
                          child: const Text('Open'),
                        ),
                        'outlined' => OutlinedButton(
                          onPressed: open,
                          child: const Text('Open'),
                        ),
                        'icon' => IconButton(
                          onPressed: open,
                          icon: const Icon(Icons.settings),
                        ),
                        _ => Material(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: open,
                            child: const SizedBox(
                              width: 140,
                              height: 52,
                              child: Center(child: Text('Open')),
                            ),
                          ),
                        ),
                      };
                      return RepaintBoundary(
                        key: boundary,
                        child: SizedBox(
                          width: 160,
                          height: 64,
                          child: Center(child: button),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final baseline = await pixels(tester, boundary);
          for (var round = 0; round < 2; round++) {
            final gesture = await tester.startGesture(
              tester.getCenter(find.byKey(boundary)),
            );
            await tester.pump(const Duration(milliseconds: 120));
            expect(
              await pixels(tester, boundary),
              isNot(orderedEquals(baseline)),
              reason: 'A held press must be visible',
            );
            await gesture.up();
            await tester.pumpAndSettle();
            expect(find.text('Next'), findsOneWidget);
            // Leave the old route muted for longer than a normal ink animation.
            await tester.pump(const Duration(seconds: 1));
            nav.currentState!.pop();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              await pixels(tester, boundary),
              orderedEquals(baseline),
              reason: 'The first returning frames must already be clear',
            );
            await tester.pumpAndSettle();
            expect(
              await pixels(tester, boundary),
              orderedEquals(baseline),
              reason: 'Returning must restore the resting appearance',
            );
            await tester.pump(const Duration(milliseconds: 80));
            expect(
              await pixels(tester, boundary),
              orderedEquals(baseline),
              reason: 'No delayed press may appear',
            );
          }
          expect(calls, 2);
        },
      );
    }
  }

  testWidgets('cancelled and keyboard presses release their feedback', (
    tester,
  ) async {
    final boundary = GlobalKey();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: appInteractionTheme(ThemeData.dark()),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundary,
              child: TextButton(
                onPressed: () => calls++,
                child: const Text('Action'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final baseline = await pixels(tester, boundary);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Action')),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(await pixels(tester, boundary), orderedEquals(baseline));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final focused = await pixels(tester, boundary);
    expect(
      focused,
      isNot(orderedEquals(baseline)),
      reason: 'Keyboard focus must remain visible before activation',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(await pixels(tester, boundary), orderedEquals(focused));
    expect(tester.takeException(), isNull);
  });
}
