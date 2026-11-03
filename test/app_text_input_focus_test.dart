import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/app_text_input_focus.dart';

enum _Field { material, form, cupertino }

const _mobile = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
});

Widget _app(Widget child) => MaterialApp(
  builder: (context, child) => AppTextInputFocus(child: child!),
  home: Scaffold(body: child),
);

Widget _field(
  _Field type,
  TextEditingController controller,
  FocusNode focus, {
  bool readOnly = false,
}) => switch (type) {
  _Field.material => TextField(
    controller: controller,
    focusNode: focus,
    readOnly: readOnly,
  ),
  _Field.form => TextFormField(
    controller: controller,
    focusNode: focus,
    readOnly: readOnly,
  ),
  _Field.cupertino => CupertinoTextField(
    controller: controller,
    focusNode: focus,
    readOnly: readOnly,
  ),
};

Future<void> _touch(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.touch,
  );
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final type in _Field.values) {
    for (final hideKeyboard in [false, true]) {
      testWidgets(
        '$type outside touch dismisses with keyboard '
        '${hideKeyboard ? 'hidden' : 'visible'} and still activates the target',
        (tester) async {
          final controller = TextEditingController(text: '未提交的文字');
          final focus = FocusNode();
          addTearDown(controller.dispose);
          addTearDown(focus.dispose);
          var presses = 0;
          await tester.pumpWidget(
            _app(
              Column(
                children: [
                  _field(type, controller, focus),
                  TextButton(
                    onPressed: () => presses++,
                    child: const Text('outside'),
                  ),
                ],
              ),
            ),
          );
          focus.requestFocus();
          await tester.pump();
          expect(focus.hasFocus, isTrue);
          if (hideKeyboard) tester.testTextInput.hide();
          await _touch(tester, find.text('outside'));
          expect(focus.hasFocus, isFalse);
          expect(tester.testTextInput.isVisible, isFalse);
          expect(controller.text, '未提交的文字');
          expect(presses, 1);
          expect(tester.takeException(), isNull);
        },
        variant: _mobile,
      );
    }

    testWidgets(
      '$type read-only selection remains usable by outside actions',
      (tester) async {
        final controller = TextEditingController(text: '视频名与歌词');
        final focus = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focus.dispose);
        var selected = '';
        await tester.pumpWidget(
          _app(
            Column(
              children: [
                _field(type, controller, focus, readOnly: true),
                TextButton(
                  onPressed: () => selected = controller.selection.textInside(
                    controller.text,
                  ),
                  child: const Text('search selection'),
                ),
              ],
            ),
          ),
        );
        focus.requestFocus();
        await tester.pump();
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 3,
        );
        await tester.pump();
        await _touch(tester, find.text('search selection'));
        expect(selected, '视频名');
        expect(focus.hasFocus, isTrue);
        expect(
          controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: 3),
        );
      },
      variant: _mobile,
    );
  }

  testWidgets(
    'related controls retain focus without swallowing other taps',
    (tester) async {
      final controller = TextEditingController(text: 'abc');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      var outside = 0;
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              TextField(controller: controller, focusNode: focus),
              TextFieldTapRegion(
                child: TextButton(
                  onPressed: () => controller.text += 'd',
                  child: const Text('edit action'),
                ),
              ),
              TextButton(
                onPressed: () => outside++,
                child: const Text('outside'),
              ),
            ],
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('edit action')),
      );
      await tester.pump();
      expect(
        focus.hasFocus,
        isTrue,
        reason: 'Keep the field alive across pointer-down',
      );
      await gesture.up();
      await tester.pump();
      expect(controller.text, 'abcd');
      expect(focus.hasFocus, isTrue);
      await _touch(tester, find.text('outside'));
      expect(focus.hasFocus, isFalse);
      expect(outside, 1);
    },
    variant: _mobile,
  );

  testWidgets('explicit field callbacks retain precedence', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var callbacks = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            TextField(focusNode: focus, onTapOutside: (_) => callbacks++),
            const Text('outside'),
          ],
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await _touch(tester, find.text('outside'));
    expect(callbacks, 1);
    expect(focus.hasFocus, isTrue);
  }, variant: _mobile);

  testWidgets('switching fields and Next keep the destination focused', (
    tester,
  ) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            TextFormField(
              key: const ValueKey('first'),
              focusNode: first,
              textInputAction: TextInputAction.next,
            ),
            TextFormField(key: const ValueKey('second'), focusNode: second),
          ],
        ),
      ),
    );
    await _touch(tester, find.byKey(const ValueKey('first')));
    await _touch(tester, find.byKey(const ValueKey('second')));
    expect(second.hasFocus, isTrue);
    await _touch(tester, find.byKey(const ValueKey('first')));
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(first.hasFocus, isFalse);
    expect(second.hasFocus, isTrue);
  }, variant: _mobile);

  testWidgets('dismissal neither submits nor discards composing text', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var submissions = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            TextField(
              controller: controller,
              focusNode: focus,
              onSubmitted: (_) => submissions++,
            ),
            const Text('outside'),
          ],
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '正在输入',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      ),
    );
    await tester.pump();
    await _touch(tester, find.text('outside'));
    expect(controller.text, '正在输入');
    expect(submissions, 0);
    expect(focus.hasFocus, isFalse);
  }, variant: _mobile);

  testWidgets('policy reaches dialog routes and preserves explicit save', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'rename draft');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    String? saved;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              saved = await showDialog<String>(
                context: context,
                barrierDismissible: false,
                builder: (context) => AlertDialog(
                  title: const Text('dialog title'),
                  content: TextField(
                    controller: controller,
                    focusNode: focus,
                    autofocus: true,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: const Text('save'),
                    ),
                  ],
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await _touch(tester, find.text('open'));
    expect(focus.hasFocus, isTrue);
    await _touch(tester, find.text('dialog title'));
    expect(focus.hasFocus, isFalse);
    expect(find.text('save'), findsOneWidget);
    expect(saved, isNull);
    await _touch(tester, find.text('save'));
    expect(saved, 'rename draft');
  }, variant: _mobile);

  testWidgets('native copy menu keeps the editable field focused', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'copy this draft');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.hasStrings') return {'value': false};
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      _app(
        Center(
          child: TextField(controller: controller, focusNode: focus),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.pump();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.showToolbar(), isTrue);
    await tester.pumpAndSettle();
    final copy = MaterialLocalizations.of(
      tester.element(find.byType(TextField)),
    ).copyButtonLabel;
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(copy)),
    );
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    expect(find.text(copy), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(copied, 'copy');
    expect(focus.hasFocus, isTrue);
  }, variant: _mobile);

  testWidgets('framework time input keeps both values when dismissing', (
    tester,
  ) async {
    TimeOfDay? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showTimePicker(
                context: context,
                initialTime: const TimeOfDay(hour: 10, minute: 30),
                initialEntryMode: TimePickerEntryMode.input,
                helpText: 'Choose time',
              );
            },
            child: const Text('open time picker'),
          ),
        ),
      ),
    );
    await _touch(tester, find.text('open time picker'));
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '10');
    await tester.enterText(fields.at(1), '45');
    await tester.pump();
    tester.testTextInput.hide();
    await _touch(tester, find.text('Choose time'));
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .every((field) => !field.focusNode.hasFocus),
      isTrue,
    );
    expect(result, isNull);
    await _touch(tester, find.text('OK'));
    expect(result, const TimeOfDay(hour: 10, minute: 45));
  }, variant: _mobile);

  testWidgets(
    'desktop pointer behavior still delegates to Flutter',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              TextField(focusNode: focus, readOnly: true),
              const Text('outside'),
            ],
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.tap(find.text('outside'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
