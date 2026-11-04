import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_message_navigation.dart';
import 'package:video_player_app/features/ai_chat/ai_scroll_to_latest_button.dart';

void main() {
  final list = find.byKey(const ValueKey('ai-chat-messages'));
  final answerCard = find.byKey(const ValueKey('streaming-answer'));
  late AiMessageViewportController controller;
  late List<AiChatMessage> messages;
  late StateSetter update;
  var answerBuilds = 0;
  var following = true;

  Widget buildMessage(BuildContext context, AiChatMessage message) {
    final answer = message.role == 'assistant';
    if (answer) answerBuilds++;
    return SizedBox(
      key: answer ? const ValueKey('streaming-answer') : ValueKey(message.id),
      height: answer ? double.parse(message.content) : 80,
      child: Text(message.id),
    );
  }

  Future<void> mountViewport(WidgetTester tester) async {
    controller = AiMessageViewportController();
    messages = [
      AiChatMessage(id: 'question', role: 'user', content: 'question'),
      AiChatMessage(
        id: 'answer',
        role: 'assistant',
        content: '5000',
        status: 'streaming',
      ),
    ];
    answerBuilds = 0;
    following = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 500,
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return AiMessageViewport(
                    messages: messages,
                    controller: controller,
                    initialAtEnd: true,
                    followOutput: following,
                    isFollowingOutput: () => following,
                    itemBuilder: buildMessage,
                    onNavigate: () => following = false,
                    onReachedEnd: () => following = true,
                    onUserScroll: (event) {
                      if (event.direction != ScrollDirection.idle) {
                        following = false;
                      }
                      return false;
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(controller.dispose);
  }

  void streamHeight(double height, {String status = 'streaming'}) {
    update(
      () => messages = [
        messages.first,
        messages.last.copyWith(content: '$height', status: status),
      ],
    );
  }

  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first,
      )
      .position;

  testWidgets(
    'streaming keeps the reading thumb stable between layout frames',
    (tester) async {
      await mountViewport(tester);
      following = false;
      controller.restore(const AiMessageBookmark('answer', 0, .35));
      await tester.pumpAndSettle();
      final thumb = find.byKey(const ValueKey('ai-navigation-thumb'));
      final answerTop = tester.getTopLeft(answerCard).dy;
      var previousTop = tester.getTopLeft(thumb).dy;
      for (var chunk = 1; chunk <= 12; chunk++) {
        streamHeight(5000 + chunk * 20);
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final top = tester.getTopLeft(thumb).dy;
          expect(
            top,
            closeTo(previousTop, 2),
            reason:
                'chunk $chunk, frame $frame must not use a temporary estimate',
          );
          expect(tester.getTopLeft(answerCard).dy, closeTo(answerTop, 1));
          previousTop = top;
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('rail dragging defers streaming until the pointer is released', (
    tester,
  ) async {
    await mountViewport(tester);
    final thumb = find.byKey(const ValueKey('ai-navigation-thumb'));
    final gesture = await tester.startGesture(tester.getCenter(thumb));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));
    final before = answerBuilds;
    final thumbTop = tester.getTopLeft(thumb).dy;
    final answerTop = tester.getTopLeft(answerCard).dy;
    for (var chunk = 1; chunk <= 12; chunk++) {
      streamHeight(5000 + chunk * 20);
      await tester.pump(const Duration(milliseconds: 70));
      expect(controller.isUserScrolling, isTrue, reason: 'chunk $chunk');
      expect(answerBuilds, before);
      expect(tester.getSize(answerCard).height, 5000);
      expect(tester.getTopLeft(thumb).dy, closeTo(thumbTop, 1));
      expect(tester.getTopLeft(answerCard).dy, closeTo(answerTop, 1));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.isUserScrolling, isFalse);
    expect(answerBuilds, before + 1);
    expect(tester.getSize(answerCard).height, 5240);
    expect(tester.getTopLeft(answerCard).dy, closeTo(answerTop, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dragging to latest resumes streaming after release', (
    tester,
  ) async {
    await mountViewport(tester);
    final rail = find.byKey(const ValueKey('ai-message-navigation'));
    final thumb = find.byKey(const ValueKey('ai-navigation-thumb'));
    final gesture = await tester.startGesture(tester.getCenter(thumb));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.moveTo(
      Offset(tester.getCenter(thumb).dx, tester.getRect(rail).bottom - 1),
    );
    await tester.pump();
    final before = answerBuilds;
    final thumbTop = tester.getTopLeft(thumb).dy;
    for (var chunk = 1; chunk <= 4; chunk++) {
      streamHeight(5000 + chunk * 20);
      await tester.pump(const Duration(milliseconds: 70));
      expect(controller.isUserScrolling, isTrue);
      expect(answerBuilds, before);
      expect(tester.getTopLeft(thumb).dy, closeTo(thumbTop, 1));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(following, isTrue);
    expect(controller.isUserScrolling, isFalse);
    expect(tester.getSize(answerCard).height, 5080);
    expect(position(tester).extentAfter, closeTo(0, 1));
    streamHeight(5120);
    await tester.pumpAndSettle();
    expect(tester.getSize(answerCard).height, 5120);
    expect(position(tester).extentAfter, closeTo(0, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('touch scrolling batches deltas and flushes once after idle', (
    tester,
  ) async {
    await mountViewport(tester);
    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump(const Duration(milliseconds: 16));
    final before = answerBuilds;
    final displayedList = tester.widget(list);
    final top = tester.getTopLeft(answerCard).dy;
    for (var chunk = 1; chunk <= 16; chunk++) {
      streamHeight(5000 + chunk * 20);
      await tester.pump(const Duration(milliseconds: 70));
      expect(answerBuilds, before, reason: 'chunk $chunk interrupts dragging');
      expect(tester.widget(list), same(displayedList));
      expect(tester.getSize(answerCard).height, 5000);
      expect(tester.getTopLeft(answerCard).dy, closeTo(top, 1));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(answerBuilds, before + 1);
    expect(tester.getSize(answerCard).height, 5320);
    expect(tester.getTopLeft(answerCard).dy, closeTo(top, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('streaming does not rebuild the answer during fling inertia', (
    tester,
  ) async {
    await mountViewport(tester);
    await tester.fling(list, const Offset(0, 300), 1800);
    await tester.pump(const Duration(milliseconds: 16));
    expect(position(tester).isScrollingNotifier.value, isTrue);
    final before = answerBuilds;
    final start = position(tester).pixels;
    for (var chunk = 1; chunk <= 10; chunk++) {
      streamHeight(5000 + chunk * 20);
      await tester.pump(const Duration(milliseconds: 16));
      expect(answerBuilds, before);
      expect(position(tester).isScrollingNotifier.value, isTrue);
    }
    expect(position(tester).pixels, lessThan(start));
    await tester.pumpAndSettle();
    expect(answerBuilds, before + 1);
    expect(tester.getSize(answerCard).height, 5200);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('consecutive mouse wheel events share one deferred update', (
    tester,
  ) async {
    await mountViewport(tester);
    final before = answerBuilds;
    for (var chunk = 1; chunk <= 10; chunk++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(list),
          scrollDelta: const Offset(0, -40),
        ),
      );
      streamHeight(5000 + chunk * 20);
      await tester.pump(const Duration(milliseconds: 40));
      expect(answerBuilds, before);
    }
    await tester.pumpAndSettle();
    expect(answerBuilds, before + 1);
    expect(tester.getSize(answerCard).height, 5200);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('completion and structural edits bypass scroll deferral', (
    tester,
  ) async {
    await mountViewport(tester);
    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    streamHeight(5100);
    await tester.pump();
    expect(tester.getSize(answerCard).height, 5000);
    streamHeight(5200, status: 'complete');
    await tester.pump();
    expect(tester.getSize(answerCard).height, 5200);
    update(() => messages = [messages.last]);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AiMessageViewport>(find.byType(AiMessageViewport))
          .messages
          .length,
      1,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('return to latest flushes pending text during a wheel burst', (
    tester,
  ) async {
    await mountViewport(tester);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, -120),
      ),
    );
    streamHeight(5400);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getSize(answerCard).height, 5000);
    following = true;
    controller.scrollToEnd();
    await tester.pumpAndSettle();
    expect(tester.getSize(answerCard).height, 5400);
    expect(position(tester).extentAfter, closeTo(0, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('floating arrow adapts without blocking surrounding content', (
    tester,
  ) async {
    final button = find.byKey(const ValueKey('ai-scroll-to-latest'));
    final surface = find.byKey(const ValueKey('ai-scroll-to-latest-surface'));
    var taps = 0;
    var contentTaps = 0;
    for (final size in const [
      Size(100, 36),
      Size(160, 64),
      Size(240, 160),
      Size(320, 300),
      Size(390, 540),
      Size(800, 200),
      Size(1024, 600),
      Size(1920, 900),
    ]) {
      await tester.binding.setSurfaceSize(size);
      for (final scale in [1.0, 2.0, 3.0]) {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => contentTaps++,
                  ),
                  Positioned.fill(
                    child: AiScrollToLatestButton(onPressed: () => taps++),
                  ),
                ],
              ),
            ),
          ),
        );
        final rect = tester.getRect(button);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.bottom, lessThanOrEqualTo(size.height));
        expect(rect.width, lessThanOrEqualTo(44));
        expect(tester.getSize(surface).width, lessThanOrEqualTo(30));
        expect(find.text('回到最新'), findsNothing);
        expect(find.byTooltip('回到最新'), findsOneWidget);
        final previousTaps = taps;
        await tester.tap(button);
        expect(taps, previousTaps + 1);
        final previousContentTaps = contentTaps;
        await tester.tapAt(const Offset(2, 2));
        expect(contentTaps, previousContentTaps + 1);
        expect(tester.takeException(), isNull, reason: '$size, scale=$scale');
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
}
