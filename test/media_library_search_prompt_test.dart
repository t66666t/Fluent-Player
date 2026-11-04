import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';

void main() {
  testWidgets('搜索框提交去除首尾空白后的文字', (tester) async {
    Future<String?>? searchFuture;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              searchFuture = showMediaLibrarySearchPrompt(context);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('搜索媒体库'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  NBA finals  ');
    await tester.pump();
    final submitButton = find.widgetWithIcon(
      IconButton,
      Icons.arrow_forward_rounded,
    );
    expect(tester.widget<IconButton>(submitButton).onPressed, isNotNull);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(await searchFuture, 'NBA finals');
  });

  testWidgets('放大镜到左边框和文字起点保持等距', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaLibrarySearchPrompt(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final textFieldFinder = find.byType(TextField);
    final prefixIconFinder = find.byIcon(Icons.search_rounded);
    final editableFinder = find.byType(EditableText);
    final fieldRect = tester.getRect(textFieldFinder);
    final iconRect = tester.getRect(prefixIconFinder);
    final editableRect = tester.getRect(editableFinder);
    final decoration = tester.widget<TextField>(textFieldFinder).decoration!;

    expect(iconRect.left - fieldRect.left, closeTo(10, 0.01));
    expect(editableRect.left - iconRect.right, closeTo(10, 0.01));
    expect(decoration.prefixIconConstraints?.maxWidth, 38);
    expect(decoration.contentPadding, const EdgeInsets.fromLTRB(0, 12, 14, 14));
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入文字和提示文字应用相同的向上光学校正', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaLibrarySearchPrompt(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final fieldRect = tester.getRect(find.byType(TextField));
    final hintRect = tester.getRect(find.text('输入文件夹或媒体名称'));
    expect(hintRect.center.dy, lessThan(fieldRect.center.dy));
    expect(fieldRect.center.dy - hintRect.center.dy, lessThan(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Esc 可以平滑关闭尚未提交的搜索框', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaLibrarySearchPrompt(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端搜索输入支持键盘确认', (tester) async {
    Future<String?>? searchFuture;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              searchFuture = showMediaLibrarySearchPrompt(context);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'NBA');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(await searchFuture, 'NBA');
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('手机键盘弹出后搜索面板保持在可见区域内', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaLibrarySearchPrompt(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final panelBottom = tester.getBottomRight(find.byType(TextField)).dy;
    expect(panelBottom, lessThanOrEqualTo(524));
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机端长文本最大高度保持在顶栏和屏幕范围内', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('原顶栏')),
            body: TextButton(
              onPressed: () => showMediaLibrarySearchPrompt(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      List<String>.filled(40, '这是一行很长的搜索文字').join('\n'),
    );
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('media-search-panel'));
    expect(tester.getTopLeft(panel).dy, lessThan(kToolbarHeight));
    expect(tester.getBottomRight(panel).dy, lessThanOrEqualTo(834));
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机端普通高度的搜索框不会随键盘出现而移动', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaLibrarySearchPrompt(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('media-search-panel'));
    final beforeKeyboard = tester.getRect(panel);

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();
    final afterKeyboard = tester.getRect(panel);

    expect(afterKeyboard.top, closeTo(beforeKeyboard.top, 0.01));
    expect(afterKeyboard.height, closeTo(beforeKeyboard.height, 0.01));
    expect(tester.takeException(), isNull);
  });
}
