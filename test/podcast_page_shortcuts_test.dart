import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_page_shortcuts.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  const channel = MethodChannel('window_manager');
  final calls = <MethodCall>[];
  late SettingsService settings;

  setUp(() {
    settings = SettingsService()..resetForTest();
    settings.isFullScreen = false;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getBounds') {
            return {'x': 0.0, 'y': 0.0, 'width': 1280.0, 'height': 800.0};
          }
          return null;
        });
  });
  tearDown(() {
    settings.isFullScreen = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('F and F11 toggle once, survive focus loss and ignore repeats', (
    tester,
  ) async {
    var inherited = 0;
    await tester.pumpWidget(
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f11): () {
            inherited++;
            unawaited(settings.toggleFullScreen());
          },
        },
        child: const MaterialApp(
          home: PodcastPageShortcuts(child: Scaffold(body: Text('page'))),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(settings.isFullScreen, isTrue);
    expect(calls.where((call) => call.method == 'setFullScreen'), hasLength(1));

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(settings.isFullScreen, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(settings.isFullScreen, isTrue);
    expect(inherited, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(settings.isFullScreen, isFalse);
    expect(calls.where((call) => call.method == 'setFullScreen'), hasLength(4));
  });

  testWidgets('editing and modified keys keep their normal input behavior', (
    tester,
  ) async {
    final input = TextEditingController(text: 'find a podcast');
    addTearDown(input.dispose);
    var commands = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PodcastPageShortcuts(
          bindings: {
            LogicalKeyboardKey.keyS: () => commands++,
            LogicalKeyboardKey.keyP: () => commands++,
            LogicalKeyboardKey.space: () => commands++,
          },
          onSelectAll: () => commands++,
          child: Scaffold(body: TextField(controller: input)),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.space,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(
      input.selection,
      TextSelection(baseOffset: 0, extentOffset: input.text.length),
    );
    expect(commands, 0);
    expect(settings.isFullScreen, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    expect(commands, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(commands, 1);
    expect(settings.isFullScreen, isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(commands, 2);
  });

  testWidgets('only the current page receives commands; dialogs shield pages', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var first = 0, second = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: PodcastPageShortcuts(
          bindings: {LogicalKeyboardKey.space: () => first++},
          child: const Scaffold(body: Text('first')),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => PodcastPageShortcuts(
            bindings: {LogicalKeyboardKey.space: () => second++},
            child: const Scaffold(body: Text('second')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect((first, second), (0, 1));
    unawaited(
      showDialog<void>(
        context: tester.element(find.text('second')),
        builder: (_) => const AlertDialog(content: Text('dialog')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(settings.isFullScreen, isFalse);
    expect((first, second), (0, 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('dialog'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect((first, second), (1, 1));
  });

  testWidgets('inactive overview cannot handle keys after focus is lost', (
    tester,
  ) async {
    var commands = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PodcastPageShortcuts(
          enabled: false,
          bindings: {LogicalKeyboardKey.keyS: () => commands++},
          child: const Scaffold(),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    expect(settings.isFullScreen, isFalse);
    expect(commands, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: false,
          child: PodcastPageShortcuts(
            bindings: {LogicalKeyboardKey.keyS: () => commands++},
            child: const Scaffold(),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    expect(settings.isFullScreen, isFalse);
    expect(commands, 0);
  });
}
