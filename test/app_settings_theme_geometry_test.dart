import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_settings_theme.dart';

void main() {
  for (final width in [320.0, 768.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('appearance preserves control bounds at $width / $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const keys = [
          'bar',
          'text',
          'outline',
          'filled',
          'raised',
          'input',
          'tile',
          'chip',
        ];
        final base = ThemeData.dark().copyWith(
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 9),
              minimumSize: const Size(75, 37),
            ),
          ),
        );
        Future<Map<String, Rect>> measure(bool restyle) async {
          final content = Scaffold(
            appBar: AppBar(
              key: const ValueKey('bar'),
              title: const Text('Queue'),
            ),
            body: SingleChildScrollView(
              child: Column(
                children: [
                  Wrap(
                    children: [
                      TextButton(
                        key: const ValueKey('text'),
                        onPressed: () {},
                        child: const Text('Select'),
                      ),
                      OutlinedButton(
                        key: const ValueKey('outline'),
                        onPressed: () {},
                        child: const Text('Settings'),
                      ),
                      FilledButton(
                        key: const ValueKey('filled'),
                        onPressed: () {},
                        child: const Text('Start'),
                      ),
                      ElevatedButton(
                        key: const ValueKey('raised'),
                        onPressed: () {},
                        child: const Text('Pause'),
                      ),
                    ],
                  ),
                  const TextField(
                    key: ValueKey('input'),
                    decoration: InputDecoration(labelText: 'Address'),
                  ),
                  const ListTile(
                    key: ValueKey('tile'),
                    title: Text('Title'),
                    subtitle: Text('Description'),
                  ),
                  const Chip(key: ValueKey('chip'), label: Text('Selected')),
                ],
              ),
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: base,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: restyle ? AppSettingsTheme(child: content) : content,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          return {
            for (final key in keys)
              key: tester.getRect(find.byKey(ValueKey(key))),
          };
        }

        final original = await measure(false);
        final styled = await measure(true);
        expect(
          styled,
          original,
          reason: 'Appearance must not resize or reposition existing controls.',
        );
      });
    }
  }
}
