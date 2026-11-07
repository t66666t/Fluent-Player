import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/keyboard_shortcut_hints.dart';
import 'package:video_player_app/utils/page_shortcut_keys.dart';
import 'package:video_player_app/widgets/confirmation_dialog_shortcuts.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';

void main() {
  for (final cupertino in [false, true]) {
    for (final (key, expected) in [
      (LogicalKeyboardKey.escape, false),
      (LogicalKeyboardKey.enter, true),
      (LogicalKeyboardKey.numpadEnter, true),
      (LogicalKeyboardKey.keyD, true),
    ]) {
      testWidgets(
        '${cupertino ? 'music' : 'standard'} subtitle confirmation $key',
        (tester) async {
          bool? result;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await showSubtitleDeletionConfirmationDialog(
                        context,
                        fileName: 'example.srt',
                        isSidecar: true,
                        isExternal: false,
                        useCupertinoStyle: cupertino,
                      );
                    },
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          expect(
            find.byType(cupertino ? CupertinoAlertDialog : AlertDialog),
            findsOneWidget,
          );
          expect(find.text(' (Esc)'), findsOneWidget);
          expect(find.text(' (Enter / D)'), findsOneWidget);
          await tester.sendKeyEvent(
            key,
            platform: key == LogicalKeyboardKey.numpadEnter ? 'android' : null,
          );
          await tester.pumpAndSettle();
          expect(result, expected);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final (tabs, expected) in [(1, false), (2, true)]) {
    testWidgets('Tab selects action $tabs and Enter activates it', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showSubtitleDeletionConfirmationDialog(
                  context,
                  fileName: 'example.srt',
                  isSidecar: false,
                  isExternal: false,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      for (var i = 0; i < tabs; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, expected);
    });
  }

  testWidgets(
    'modifiers, repeats, disabled actions and nested dialogs are safe',
    (tester) async {
      var calls = 0;
      final enabled = ValueNotifier(false);
      addTearDown(enabled.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, active, _) => ConfirmationDialogShortcuts(
              onCancel: null,
              confirmKey: LogicalKeyboardKey.keyD,
              onConfirm: active ? () => calls++ : null,
              child: const Scaffold(body: Text('底层')),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 0);
      enabled.value = true;
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(calls, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
      expect(calls, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      expect(calls, 2);

      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('上层弹窗')),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      expect(calls, 2);
      expect(find.text('上层弹窗'), findsOneWidget);
    },
  );

  testWidgets('editing and IME composition retain their keys', (tester) async {
    var calls = 0;
    final input = TextEditingController();
    addTearDown(input.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ConfirmationDialogShortcuts(
          onCancel: () => calls++,
          confirmKey: LogicalKeyboardKey.keyD,
          onConfirm: () => calls++,
          child: Scaffold(body: TextField(controller: input)),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    input.value = const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(calls, 0);
    expect(input.text, 'ni');
    expect(isEditableTextFocused(), isTrue);
    input.clearComposing();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(calls, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    expect(calls, 1);
  });

  testWidgets('shortcut labels follow hardware keyboard hint policy', (
    tester,
  ) async {
    final mobile = HardwareKeyboardPresence(platform: TargetPlatform.android);
    final desktop = HardwareKeyboardPresence(platform: TargetPlatform.windows);
    addTearDown(mobile.dispose);
    addTearDown(desktop.dispose);
    await tester.pumpWidget(
      KeyboardShortcutHints(
        presence: mobile,
        child: const MaterialApp(
          home: Scaffold(body: ConfirmationShortcutLabel('删除', 'D')),
        ),
      ),
    );
    expect(find.text('删除'), findsOneWidget);
    expect(find.text(' (D)'), findsNothing);
    await tester.pumpWidget(
      KeyboardShortcutHints(
        presence: desktop,
        child: const MaterialApp(
          home: Scaffold(body: ConfirmationShortcutLabel('删除', 'D')),
        ),
      ),
    );
    expect(find.text(' (D)'), findsOneWidget);
  });
}
