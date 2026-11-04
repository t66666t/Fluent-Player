import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/home_search_request.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';

Future<void> _openPrompt(
  WidgetTester tester, {
  ValueChanged<HomeSearchRequest?>? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await showHomeSearchPrompt(context);
            onResult?.call(result);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'arrows keep the local input focused without opening a scope menu',
    (tester) async {
      await _openPrompt(tester);
      await tester.enterText(find.byType(TextField), 'saved draft');
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      for (final key in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await _key(tester, key);
        expect(
          find.byKey(const ValueKey('home-search-scope-menu')),
          findsNothing,
        );
        expect(field.focusNode!.hasFocus, isTrue);
        expect(field.controller!.text, 'saved draft');
      }
      expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    },
  );

  testWidgets(
    'IME composition prevents premature submission and escape dismissal',
    (tester) async {
      HomeSearchRequest? result;
      await _openPrompt(tester, onResult: (value) => result = value);
      const composing = TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      field.onSubmitted!('zhong');
      await _key(tester, LogicalKeyboardKey.escape);
      expect(result, isNull);
      expect(find.byType(TextField), findsOneWidget);
      expect(field.controller!.text, 'zhong');
      expect(field.focusNode!.hasFocus, isTrue);
      expect(
        find.byKey(const ValueKey('home-search-scope-menu')),
        findsNothing,
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(result!.query, '中文');
      expect(result!.scope, HomeSearchScope.library);
    },
  );

  testWidgets(
    'modified arrows keep the draft and system back closes the prompt',
    (tester) async {
      await _openPrompt(tester);
      await tester.enterText(find.byType(TextField), 'local draft');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'local draft');
      expect(field.focusNode!.hasFocus, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    },
  );
}
