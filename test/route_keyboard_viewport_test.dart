import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/dialog_autofocus.dart';
import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';

void main() {
  for (final initialInset in [0.0, 120.0]) {
    testWidgets('covered pages keep their geometry from inset $initialInset', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 900);
      tester.view.viewInsets = FakeViewPadding(bottom: initialInset);
      addTearDown(tester.view.reset);
      var layouts = 0;
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
          home: Builder(
            builder: (context) {
              MediaQuery.of(context);
              builds++;
              return Scaffold(
                body: LayoutBuilder(
                  builder: (context, constraints) {
                    layouts++;
                    return SizedBox.expand(
                      key: const ValueKey('covered-body'),
                      child: Center(
                        child: TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => DialogKeyboardViewport(
                              child: AlertDialog(
                                content: const TextField(),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Save'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          child: const Text('Open'),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final body = find.byKey(const ValueKey('covered-body'));
      final before = tester.getRect(body);
      final beforeLayouts = layouts;
      final beforeBuilds = builds;
      for (final inset in [24.0, 60.0, 140.0, 240.0, 320.0, 160.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        tester.view.padding = FakeViewPadding(bottom: math.max(0, 24 - inset));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(body), before);
        expect(tester.getRect(find.text('Save')).bottom, lessThan(900 - inset));
        expect(tester.takeException(), isNull);
      }
      expect(layouts, beforeLayouts);
      expect(builds, beforeBuilds);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(tester.getRect(body).height, 900);
    });
  }

  testWidgets(
    'dialog focus starts after entrance and never steals focus back',
    (tester) async {
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => DialogAutofocus(
                  focusNode: first,
                  child: AlertDialog(
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(focusNode: first),
                        TextField(focusNode: second),
                      ],
                    ),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      expect(first.hasFocus, false);
      await tester.pumpAndSettle();
      expect(first.hasFocus, true);
      second.requestFocus();
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      expect(second.hasFocus, true);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
