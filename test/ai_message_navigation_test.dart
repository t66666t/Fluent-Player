import 'test_artifacts.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_message_navigation.dart';

List<AiChatMessage> _messages(int turns) => [
  for (var i = 0; i < turns; i++) ...[
    AiChatMessage(
      id: 'q$i',
      role: 'user',
      content: '第 $i 个问题：如何理解视频中的这个观点？',
      createdAt: DateTime(2026, 10, 14, 11, i % 60),
    ),
    AiChatMessage(id: 'a$i', role: 'assistant', content: '这是第 $i 轮回答。'),
  ],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AiMessageViewportController controller;
  late List<AiChatMessage> messages;
  late StateSetter update;
  var navigations = 0;
  var reachedEnd = 0;
  var builds = 0;
  var answerHeight = 240.0;
  var questionHeight = 80.0;
  final capture = GlobalKey();

  setUp(() {
    controller = AiMessageViewportController();
    messages = _messages(5);
    navigations = 0;
    reachedEnd = 0;
    builds = 0;
    answerHeight = 240;
    questionHeight = 80;
  });
  tearDown(() => controller.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 640),
    double scale = 1,
    FocusNode? composerFocus,
    bool initialAtEnd = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'NavigationPreview',
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: capture,
            child: ColoredBox(
              color: const Color(0xff191919),
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  final viewport = AiMessageViewport(
                    messages: messages,
                    controller: controller,
                    initialAtEnd: initialAtEnd,
                    onNavigate: () => navigations++,
                    onReachedEnd: () => reachedEnd++,
                    onUserScroll: (_) => false,
                    itemBuilder: (context, message) {
                      builds++;
                      return SizedBox(
                        height: message.role == 'user'
                            ? questionHeight
                            : answerHeight,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            message.content,
                            key: ValueKey('body-${message.id}'),
                          ),
                        ),
                      );
                    },
                  );
                  return composerFocus == null
                      ? viewport
                      : Column(
                          children: [
                            Expanded(child: viewport),
                            TextField(
                              focusNode: composerFocus,
                              showCursor: false,
                            ),
                          ],
                        );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final rail = find.byKey(const ValueKey('ai-message-navigation'));
  final list = find.byKey(const ValueKey('ai-chat-messages'));
  Finder node(String id) => find.byKey(ValueKey('ai-node-$id'));
  Finder body(String id) => find.byKey(ValueKey('body-$id'));
  Offset nodePoint(WidgetTester tester, String id) =>
      Offset(tester.getRect(rail).left + 12, tester.getCenter(node(id)).dy);

  for (final bookmark in [
    null,
    const AiMessageBookmark('q2', 0, 0),
    const AiMessageBookmark('a2', 0, .45),
    const AiMessageBookmark('a2', .3, 0),
  ]) {
    testWidgets(
      'restoring a captured bookmark is pixel stable across repetitions for ${bookmark?.messageId ?? 'tail'}, alignment=${bookmark?.alignment}',
      (tester) async {
        answerHeight = 1600;
        await mount(tester, initialAtEnd: bookmark == null);
        if (bookmark != null) {
          controller.restore(bookmark);
          await tester.pumpAndSettle();
        }
        final target = body(bookmark?.messageId ?? messages.last.id);
        final top = tester.getTopLeft(target).dy;
        for (var cycle = 0; cycle < 5; cycle++) {
          controller.restore(controller.bookmark!);
          await tester.pumpAndSettle();
          expect(
            tester.getTopLeft(target).dy,
            closeTo(top, .5),
            reason: 'cycle $cycle must restore the same physical position',
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'restoring inside an unmounted first message excludes list padding',
    (tester) async {
      messages = _messages(10);
      questionHeight = 1600;
      await mount(tester, initialAtEnd: true);
      expect(body('q0'), findsNothing);
      controller.restore(const AiMessageBookmark('q0', 0, .45));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(body('q0')).dy + questionHeight * .45,
        closeTo(tester.getTopLeft(list).dy, .5),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('click an unmounted question and align its real message', (
    tester,
  ) async {
    messages = _messages(10);
    await mount(tester);
    controller.scrollToEnd();
    await tester.pumpAndSettle();
    expect(body('q0'), findsNothing);
    await tester.tapAt(nodePoint(tester, 'q0'));
    await tester.pumpAndSettle();
    expect(navigations, 1);
    expect(controller.bookmark!.messageId, 'q0');
    expect(
      tester.getTopLeft(body('q0')).dy,
      closeTo(tester.getTopLeft(list).dy + 10, 1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'hover shows a compact question and complete local date without navigating',
    (tester) async {
      await mount(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(node('q1')));
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('ai-node-preview'));
      expect(preview, findsOneWidget);
      expect(
        find.descendant(of: preview, matching: find.text('2026-10-14 11:01')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: preview, matching: find.text(messages[2].content)),
        findsOneWidget,
      );
      expect(navigations, 0);
      expect(tester.getSize(preview).width, lessThanOrEqualTo(312));
      await mouse.moveTo(tester.getCenter(preview));
      await tester.pump(const Duration(milliseconds: 250));
      expect(preview, findsOneWidget);
      await mouse.moveTo(const Offset(5, 620));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 250));
      expect(preview, findsNothing);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('touch long press previews and a separate tap jumps', (
    tester,
  ) async {
    await mount(tester, size: const Size(240, 360), scale: 1.4);
    await tester.longPressAt(nodePoint(tester, 'q0'));
    await tester.pumpAndSettle();
    expect(navigations, 0);
    final preview = find.byKey(const ValueKey('ai-node-preview'));
    expect(preview, findsOneWidget);
    final bounds = tester.getRect(preview);
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(240));
    expect(bounds.bottom, lessThanOrEqualTo(360));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('ai-node-preview-q0')));
    await tester.pumpAndSettle();
    expect(navigations, 1);
    expect(preview, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('node preview opens within 300ms despite small touch jitter', (
    tester,
  ) async {
    await mount(tester);
    final press = await tester.startGesture(nodePoint(tester, 'q0'));
    await tester.pump(const Duration(milliseconds: 200));
    final preview = find.byKey(const ValueKey('ai-node-preview'));
    expect(preview, findsNothing);
    await press.moveBy(const Offset(2, 2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(preview, findsOneWidget);
    expect(navigations, 0);
    expect(controller.isUserScrolling, isFalse);
    await press.up();
    await tester.pumpAndSettle();
    expect(preview, findsOneWidget);
    expect(navigations, 0, reason: 'releasing a preview must not also jump');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a quick node tap jumps without a delayed preview', (
    tester,
  ) async {
    await mount(tester);
    final press = await tester.startGesture(nodePoint(tester, 'q1'));
    await tester.pump(const Duration(milliseconds: 100));
    await press.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    expect(navigations, 1);
    expect(controller.bookmark!.messageId, 'q1');
    expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dragging just before the preview deadline wins the gesture', (
    tester,
  ) async {
    await mount(tester);
    final press = await tester.startGesture(nodePoint(tester, 'q0'));
    await tester.pump(const Duration(milliseconds: 250));
    await press.moveBy(const Offset(0, 32));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.isUserScrolling, isTrue);
    expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
    await press.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(navigations, greaterThan(0));
    await press.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('horizontal movement cancels a node preview without jumping', (
    tester,
  ) async {
    await mount(tester);
    final press = await tester.startGesture(nodePoint(tester, 'q0'));
    await tester.pump(const Duration(milliseconds: 200));
    await press.moveBy(const Offset(-32, 0));
    await tester.pump(const Duration(milliseconds: 600));
    await press.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
    expect(navigations, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a cancelled touch never leaves a pending node preview', (
    tester,
  ) async {
    await mount(tester);
    final press = await tester.startGesture(nodePoint(tester, 'q0'));
    await tester.pump(const Duration(milliseconds: 200));
    await press.cancel();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
    expect(navigations, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('returning after horizontal movement does not revive a tap', (
    tester,
  ) async {
    await mount(tester);
    final point = nodePoint(tester, 'q0');
    final press = await tester.startGesture(point);
    await tester.pump(const Duration(milliseconds: 150));
    await press.moveBy(const Offset(-32, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await press.moveTo(point);
    await tester.pump(const Duration(milliseconds: 600));
    await press.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
    expect(navigations, 0);
    expect(controller.isUserScrolling, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('holding empty track leaves a later drag available', (
    tester,
  ) async {
    await mount(tester);
    final first = nodePoint(tester, 'q0');
    final second = nodePoint(tester, 'q1');
    final press = await tester.startGesture((first + second) / 2);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
    expect(navigations, 0);
    await press.moveBy(const Offset(0, 32));
    await tester.pump();
    expect(controller.isUserScrolling, isTrue);
    await press.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(navigations, greaterThan(0));
    await press.up();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a second touch cancels preview recognition and permits retry', (
    tester,
  ) async {
    await mount(tester);
    final point = nodePoint(tester, 'q0');
    final first = await tester.startGesture(point, pointer: 1);
    await tester.pump(const Duration(milliseconds: 150));
    final second = await tester.startGesture(
      point + const Offset(-4, 0),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
    await second.cancel();
    await first.cancel();
    await tester.pumpAndSettle();
    expect(navigations, 0);
    await tester.longPressAt(nodePoint(tester, 'q1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-node-preview')), findsOneWidget);
    expect(navigations, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sliding after a preview changes details without scrolling', (
    tester,
  ) async {
    await mount(tester);
    final press = await tester.startGesture(nodePoint(tester, 'q0'));
    await tester.pump(const Duration(milliseconds: 300));
    await press.moveTo(nodePoint(tester, 'q1'));
    await tester.pump();
    final preview = find.byKey(const ValueKey('ai-node-preview'));
    expect(
      find.descendant(of: preview, matching: find.text(messages[2].content)),
      findsOneWidget,
    );
    expect(navigations, 0);
    expect(controller.isUserScrolling, isFalse);
    await press.up();
    await tester.pumpAndSettle();
    expect(navigations, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('long press preview leaves the composer keyboard focus intact', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await mount(tester, composerFocus: focus);
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    await tester.longPressAt(nodePoint(tester, 'q0'));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(find.byKey(const ValueKey('ai-node-preview')), findsOneWidget);
    expect(navigations, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'thousands of turns stay lazy and every clustered question is selectable',
    (tester) async {
      messages = _messages(2000);
      await mount(tester, size: const Size(320, 280));
      expect(builds, lessThan(40));
      controller.scrollToEnd();
      await tester.pumpAndSettle();
      expect(builds, lessThan(80));
      await tester.tap(node('q0'));
      await tester.pumpAndSettle();
      final previewList = find.byKey(const ValueKey('ai-node-preview-list'));
      final previewRows = tester.widget<ListView>(previewList);
      final count = (previewRows.childrenDelegate as SliverChildBuilderDelegate)
          .childCount!;
      expect(count, greaterThan(2));
      final target = 'q${count - 1}';
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('ai-node-preview-$target')),
        180,
        scrollable: find.descendant(
          of: previewList,
          matching: find.byType(Scrollable),
        ),
        maxScrolls: 200,
      );
      await tester.tap(find.byKey(ValueKey('ai-node-preview-$target')));
      await tester.pumpAndSettle();
      expect(controller.bookmark!.messageId, target);
      expect(
        tester.getTopLeft(body(target)).dy,
        closeTo(tester.getTopLeft(list).dy, 1),
      );
      expect(builds, lessThan(120));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'dragging the thumb can traverse the interior of a very long answer',
    (tester) async {
      messages = _messages(1);
      answerHeight = 12000;
      await mount(tester);
      final thumb = find.byKey(const ValueKey('ai-navigation-thumb'));
      final start = tester.getCenter(thumb);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump();
      await gesture.moveTo(Offset(start.dx, tester.getRect(rail).height * .58));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(navigations, greaterThan(0));
      expect(controller.bookmark!.messageId, 'a0');
      expect(controller.bookmark!.fraction, greaterThan(.2));
      expect(controller.bookmark!.fraction, lessThan(.9));
      final ending = await tester.startGesture(tester.getCenter(thumb));
      await ending.moveBy(const Offset(0, 24));
      await tester.pump();
      await ending.moveTo(Offset(start.dx, tester.getRect(rail).bottom - 1));
      await tester.pumpAndSettle();
      await ending.up();
      await tester.pumpAndSettle();
      expect(reachedEnd, greaterThan(0));
      expect(controller.awayFromBottom, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'adding or withdrawing turns during a drag cancels obsolete layout estimates',
    (tester) async {
      await mount(tester);
      final thumb = find.byKey(const ValueKey('ai-navigation-thumb'));
      final gesture = await tester.startGesture(tester.getCenter(thumb));
      await gesture.moveBy(const Offset(0, 28));
      await tester.pump();
      update(() => messages = _messages(500));
      await tester.pumpAndSettle();
      await gesture.moveTo(Offset(tester.getRect(rail).right - 12, 500));
      await tester.pumpAndSettle();
      update(() => messages = [...messages.take(4)]);
      await tester.pumpAndSettle();
      await gesture.moveTo(Offset(tester.getRect(rail).right - 12, 100));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(node('q2'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'edits update previews; rewinds and branches remove obsolete nodes and preserve common anchors',
    (tester) async {
      await mount(tester);
      await tester.tap(node('q2'));
      await tester.pumpAndSettle();
      expect(tester.getRect(body('q2')).overlaps(tester.getRect(list)), isTrue);
      update(() => messages = [...messages.take(6)]);
      await tester.pumpAndSettle();
      expect(node('q3'), findsNothing);
      expect(tester.getRect(body('q2')).overlaps(tester.getRect(list)), isTrue);
      update(
        () => messages = [
          for (final message in messages)
            if (message.id == 'q2')
              message.copyWith(content: '修改后的提问')
            else
              message,
        ],
      );
      await tester.pumpAndSettle();
      await tester.longPressAt(nodePoint(tester, 'q2'));
      await tester.pumpAndSettle();
      expect(find.text('修改后的提问'), findsWidgets);
      expect(find.text('2026-10-14 11:02'), findsOneWidget);
      update(
        () => messages = [
          ...messages.take(2),
          ..._messages(1).map(
            (m) => AiChatMessage(
              id: 'branch-${m.id}',
              role: m.role,
              content: '新分支',
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(node('q2'), findsNothing);
      expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
      expect(controller.bookmark, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('resizing and streaming keep an interior reading anchor', (
    tester,
  ) async {
    answerHeight = 1600;
    await mount(tester);
    await tester.tap(node('q2'));
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, -500));
    await tester.pumpAndSettle();
    final before = controller.bookmark!;
    expect(before.messageId, 'a2');
    update(
      () => messages = [
        ...messages.take(messages.length - 1),
        messages.last.copyWith(content: '${messages.last.content}\n新增流式内容'),
      ],
    );
    await tester.pumpAndSettle();
    expect(controller.bookmark!.messageId, before.messageId);
    expect(controller.bookmark!.fraction, closeTo(before.fraction, .01));
    for (final size in [
      const Size(840, 360),
      const Size(320, 800),
      const Size(1400, 900),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(controller.bookmark!.messageId, before.messageId);
      expect(controller.bookmark!.fraction, closeTo(before.fraction, .02));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'rail supports keyboard question navigation and Escape dismisses the preview',
    (tester) async {
      await mount(tester);
      await tester.tapAt(nodePoint(tester, 'q1'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.bookmark!.messageId, 'q2');
      await tester.longPressAt(nodePoint(tester, 'q2'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-node-preview')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(controller.awayFromBottom, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [
    const Size(240, 96),
    const Size(320, 568),
    const Size(844, 180),
    const Size(440, 720),
    const Size(768, 1024),
    const Size(1366, 768),
  ]) {
    testWidgets('navigation and preview fit ${size.width} x ${size.height}', (
      tester,
    ) async {
      messages = _messages(32);
      await mount(tester, size: size, scale: 1.6);
      await tester.longPressAt(nodePoint(tester, 'q0'));
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('ai-node-preview'));
      expect(preview, findsOneWidget);
      final rect = tester.getRect(preview);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      expect(rect.right, lessThan(tester.getRect(node('q0')).left));
      final date = find.descendant(
        of: preview,
        matching: find.text('2026-10-14 11:00'),
      );
      expect(tester.getRect(date).bottom, lessThanOrEqualTo(rect.bottom));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('capture representative phone and desktop node previews', (
    tester,
  ) async {
    if (Platform.isWindows && File('C:/Windows/Fonts/msyh.ttc').existsSync()) {
      await tester.runAsync(() async {
        final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
        final loader = FontLoader('NavigationPreview')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      });
    }
    for (final (name, size) in [
      ('phone', const Size(320, 568)),
      ('desktop', const Size(960, 600)),
    ]) {
      messages = _messages(18);
      await mount(tester, size: size);
      await tester.longPressAt(nodePoint(tester, 'q0'));
      await tester.pumpAndSettle();
      final render =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = testArtifact('navigation-$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    }
  });
}
