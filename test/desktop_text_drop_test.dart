import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/desktop_text_drop.dart';

import 'support/desktop_text_drop.dart';

const _desktops = TargetPlatformVariant({
  TargetPlatform.windows,
  TargetPlatform.macOS,
  TargetPlatform.linux,
});

Widget _app(Widget child) => MaterialApp(
  builder: (_, child) => DesktopTextDropHost(child: child!),
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(16), child: child),
  ),
);

void main() {
  testWidgets(
    'batch drops retain a blurred caret and notify normal user edits',
    (tester) async {
      final controller = TextEditingController(text: '第一条\n后面的链接');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      final changed = <String>[];
      var submitted = 0;
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              DesktopTextDropTarget(
                insertion: DesktopTextDropInsertion.appendLine,
                preferUrl: true,
                child: TextField(
                  controller: controller,
                  focusNode: focus,
                  maxLines: 4,
                  onChanged: changed.add,
                  onSubmitted: (_) => submitted++,
                ),
              ),
              TextButton(onPressed: focus.unfocus, child: const Text('网页')),
            ],
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      controller.selection = const TextSelection.collapsed(offset: 1);
      await tester.tap(find.text('网页'));
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      final point =
          tester.getTopLeft(find.byType(TextField)) + const Offset(6, 6);
      expect(
        await dropDesktopText(
          tester,
          point,
          text: '链接标题',
          urls: ['https://example.com/one'],
        ),
        isTrue,
      );
      await tester.pump();
      await tester.tap(find.text('网页'));
      expect(
        await dropDesktopText(tester, point, text: 'https://example.com/two'),
        isTrue,
      );
      await tester.pump();
      expect(
        controller.text,
        '第一条\nhttps://example.com/one\nhttps://example.com/two\n后面的链接',
      );
      expect(changed.length, 2);
      expect(submitted, 0);
      expect(focus.hasFocus, isTrue);
    },
    variant: _desktops,
  );

  testWidgets(
    'rename uses selected text and does not reselect after browser focus',
    (tester) async {
      final controller = TextEditingController(text: '原名称');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              DesktopTextDropTarget(
                insertion: DesktopTextDropInsertion.appendLine,
                child: TextField(
                  controller: controller,
                  focusNode: focus,
                  maxLines: 8,
                  selectAllOnFocus: true,
                ),
              ),
              TextButton(onPressed: focus.unfocus, child: const Text('网页')),
            ],
          ),
        ),
      );
      controller.selection = const TextSelection(
        baseOffset: 3,
        extentOffset: 0,
      );
      final point = tester.getCenter(find.byType(TextField));
      expect(
        await dropDesktopText(
          tester,
          point,
          text: '中文标题😀',
          urls: ['https://example.com'],
        ),
        isTrue,
      );
      await tester.pump();
      expect(controller.text, '中文标题😀');
      await tester.tap(find.text('网页'));
      await tester.pump();
      expect(await dropDesktopText(tester, point, text: '副标题'), isTrue);
      await tester.pump();
      expect(controller.text, '中文标题😀\n副标题');
    },
    variant: _desktops,
  );

  testWidgets(
    'ordinary editors keep caret insertion, formatters and undo',
    (tester) async {
      final controller = TextEditingController(text: '左右');
      final undo = UndoHistoryController();
      addTearDown(controller.dispose);
      addTearDown(undo.dispose);
      await tester.pumpWidget(
        _app(
          TextField(
            controller: controller,
            undoController: undo,
            inputFormatters: [LengthLimitingTextInputFormatter(5)],
            autofocus: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      controller.selection = const TextSelection.collapsed(offset: 1);
      final point = tester.getCenter(find.byType(EditableText));
      expect(await dropDesktopText(tester, point, text: '中文名字'), isTrue);
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.text, '左中文名字');
      expect(undo.value.canUndo, isTrue);
      undo.undo();
      await tester.pump();
      expect(controller.text, '左右');
    },
    variant: _desktops,
  );

  testWidgets(
    'URL-only payload falls back to text and URL fields replace their value',
    (tester) async {
      final controller = TextEditingController(text: 'https://old.example');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          TextField(controller: controller, keyboardType: TextInputType.url),
        ),
      );
      expect(
        await dropDesktopText(
          tester,
          tester.getCenter(find.byType(EditableText)),
          urls: ['https://new.example'],
        ),
        isTrue,
      );
      await tester.pump();
      expect(controller.text, 'https://new.example');
    },
    variant: _desktops,
  );

  testWidgets(
    'covered, disabled, private and numeric fields never accept a drop',
    (tester) async {
      for (final field in <Widget Function(TextEditingController)>[
        (c) => TextField(controller: c, readOnly: true),
        (c) => TextField(controller: c, enabled: false),
        (c) => TextField(controller: c, obscureText: true),
        (c) => TextField(controller: c, keyboardType: TextInputType.number),
      ]) {
        final controller = TextEditingController(text: '原值');
        await tester.pumpWidget(
          _app(
            SizedBox(
              height: 80,
              child: DesktopTextDropTarget(child: field(controller)),
            ),
          ),
        );
        expect(
          await dropDesktopText(tester, const Offset(30, 30), text: '新值'),
          isFalse,
        );
        expect(controller.text, '原值');
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
      final controller = TextEditingController(text: '被遮挡');
      await tester.pumpWidget(
        _app(
          SizedBox(
            height: 80,
            child: Stack(
              children: [
                DesktopTextDropTarget(child: TextField(controller: controller)),
                const Positioned.fill(child: ColoredBox(color: Colors.black)),
              ],
            ),
          ),
        ),
      );
      expect(
        await dropDesktopText(tester, const Offset(30, 30), text: '新值'),
        isFalse,
      );
      expect(controller.text, '被遮挡');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
    variant: _desktops,
  );

  testWidgets(
    'Windows coordinates scale once and text never reaches file imports',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var files = 0;
      await tester.pumpWidget(
        _app(
          DropTarget(
            onDragDone: (_) => files++,
            child: DesktopTextDropTarget(
              child: TextField(controller: controller),
            ),
          ),
        ),
      );
      final point = tester.getCenter(find.byType(EditableText));
      await dropDesktopText(tester, point, method: 'textEntered');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('desktop-text-drop-highlight')),
        findsOneWidget,
      );
      expect(
        await dropDesktopText(tester, point, text: 'https://example.com'),
        isTrue,
      );
      await tester.pump();
      expect(controller.text, 'https://example.com');
      expect(files, 0);
      expect(
        find.byKey(const ValueKey('desktop-text-drop-highlight')),
        findsNothing,
      );
      await sendDesktopDropMessage(tester, 'entered', [
        point.dx * 2,
        point.dy * 2,
      ]);
      await sendDesktopDropMessage(tester, 'performOperation', [
        'D:/video.mp4',
      ]);
      expect(files, 1);
      expect(controller.text, 'https://example.com');
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );
}
