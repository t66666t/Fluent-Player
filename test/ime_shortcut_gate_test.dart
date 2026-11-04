import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/ime_shortcut_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final reported = <bool>[];

  setUp(() {
    reported.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ImeShortcutGate.channel, (call) async {
          reported.add(call.arguments as bool);
          return null;
        });
  });

  tearDown(() {
    ImeShortcutGate.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ImeShortcutGate.channel, null);
  });

  testWidgets('shortcut focus keeps the input method detached', (tester) async {
    ImeShortcutGate.install();
    await tester.pumpWidget(
      const MaterialApp(
        home: Focus(autofocus: true, child: SizedBox(width: 20, height: 20)),
      ),
    );
    await tester.pump();

    expect(reported, isNotEmpty);
    expect(reported.last, isFalse);
  });

  testWidgets('a text field attaches the input method and blur detaches it', (
    tester,
  ) async {
    ImeShortcutGate.install();
    await tester.pumpWidget(
      const MaterialApp(home: Material(child: TextField())),
    );
    await tester.pump();
    expect(reported.last, isFalse);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(reported.last, isTrue);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(reported.last, isFalse);
  });
}
