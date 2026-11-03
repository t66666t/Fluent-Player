import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_layout.dart';
import 'package:video_player_app/features/ai_chat/ai_message_navigation.dart';

class _Cards {
  final builds = <String, int>{};
  Widget build(BuildContext context, AiChatMessage message) {
    builds.update(message.id, (value) => value + 1, ifAbsent: () => 1);
    return SizedBox(
      key: ValueKey('card-${message.id}'),
      height: message.content.startsWith('height:')
          ? double.parse(message.content.substring(7))
          : 80,
      child: Text(message.id),
    );
  }
}

void main() {
  for (final initialHeight in [40.0, 400.0, 900.0]) {
    final long = initialHeight > 40;
    testWidgets(
      'keyboard frames and streaming keep height=$initialHeight stable in the same frame',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = AiMessageViewportController();
        final cards = _Cards();
        final question = AiChatMessage(id: 'q', role: 'user', content: 'q');
        var height = initialHeight;
        var answer = AiChatMessage(
          id: 'a',
          role: 'assistant',
          content: 'height:$height',
        );
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              resizeToAvoidBottomInset: false,
              body: AiKeyboardViewport(
                child: Column(
                  children: [
                    const SizedBox(height: 100),
                    Expanded(
                      child: StatefulBuilder(
                        builder: (_, setState) {
                          update = setState;
                          return AiMessageViewport(
                            messages: [question, answer],
                            controller: controller,
                            initialAtEnd: true,
                            followOutput: true,
                            itemBuilder: cards.build,
                            onNavigate: () {},
                            onUserScroll: (_) => false,
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final list = find.byKey(const ValueKey('ai-chat-messages'));
        for (final inset in [
          24.0,
          64.0,
          120.0,
          180.0,
          240.0,
          300.0,
          320.0,
          280.0,
          220.0,
          160.0,
          96.0,
          48.0,
          0.0,
        ]) {
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          update(() {
            height += long ? 8 : 1;
            answer = answer.copyWith(content: 'height:$height');
          });
          await tester.pump(const Duration(milliseconds: 16));
          final rect = tester.getRect(list);
          if (height + 102 > rect.height) {
            expect(
              tester.getBottomLeft(find.byKey(const ValueKey('card-a'))).dy +
                  12,
              closeTo(rect.bottom, 1),
              reason: 'inset=$inset must settle before paint',
            );
          } else {
            expect(
              tester.getTopLeft(find.byKey(const ValueKey('card-q'))).dy,
              closeTo(rect.top + 10, 1),
              reason: 'inset=$inset must not move the first question',
            );
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }

  testWidgets(
    'height-only keyboard changes preserve the physical reading anchor without a correction frame',
    (tester) async {
      final controller = AiMessageViewportController();
      final cards = _Cards();
      var height = 500.0;
      late StateSetter update;
      var messages = List.generate(
        100,
        (i) => AiChatMessage(id: 'm$i', role: 'user', content: 'history'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 400,
                    height: height,
                    child: AiMessageViewport(
                      messages: messages,
                      controller: controller,
                      itemBuilder: cards.build,
                      onNavigate: () {},
                      onUserScroll: (_) => false,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.restore(const AiMessageBookmark('m20', .35, .25));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('card-m20'));
      final top = tester.getTopLeft(card).dy;
      for (final value in [
        480.0,
        440.0,
        380.0,
        300.0,
        240.0,
        300.0,
        380.0,
        440.0,
        500.0,
      ]) {
        update(() {
          height = value;
          messages = [
            ...messages.take(messages.length - 1),
            messages.last.copyWith(content: 'height:${1000 - value}'),
          ];
        });
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getTopLeft(card).dy,
          closeTo(top, 1),
          reason: 'height=$value',
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getTopLeft(card).dy,
          closeTo(top, 1),
          reason: 'no delayed reverse correction',
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'short conversation stays at the top and streams into overflow without a bottom gap',
    (tester) async {
      final controller = AiMessageViewportController();
      final cards = _Cards();
      final question = AiChatMessage(
        id: 'q',
        role: 'user',
        content: 'question',
      );
      var answer = AiChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'height:40',
        status: 'streaming',
      );
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 500,
              child: StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return AiMessageViewport(
                    messages: [question, answer],
                    controller: controller,
                    initialAtEnd: true,
                    followOutput: true,
                    itemBuilder: cards.build,
                    onNavigate: () {},
                    onUserScroll: (_) => false,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('ai-chat-messages'));
      final top = tester.getTopLeft(list).dy;
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('card-q'))).dy,
        closeTo(top + 10, 1),
      );
      for (final height in [60.0, 100.0, 250.0, 390.0, 430.0, 600.0, 900.0]) {
        update(() => answer = answer.copyWith(content: 'height:$height'));
        await tester.pump(const Duration(milliseconds: 16));
        controller.scrollToEnd();
        await tester.pump(const Duration(milliseconds: 16));
        if (height + 102 <= 500) {
          expect(
            tester.getTopLeft(find.byKey(const ValueKey('card-q'))).dy,
            closeTo(top + 10, 1),
          );
        } else {
          final positions = tester
              .widget<ScrollablePositionedList>(
                find.byType(ScrollablePositionedList),
              )
              .itemPositionsNotifier!
              .itemPositions
              .value;
          expect(
            positions.singleWhere((p) => p.index == 2).itemTrailingEdge,
            closeTo(1, .01),
          );
        }
        for (final scroll in tester.stateList<ScrollableState>(
          find.byType(Scrollable),
        )) {
          expect(scroll.position.isScrollingNotifier.value, isFalse);
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'stream updates reuse unchanged cards in a long lazy conversation and preserve manual reading',
    (tester) async {
      final controller = AiMessageViewportController();
      final cards = _Cards();
      var messages = List.generate(
        2000,
        (i) => AiChatMessage(
          id: 'm$i',
          role: i.isEven ? 'user' : 'assistant',
          content: 'history $i',
        ),
      );
      var following = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 500,
              child: StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return AiMessageViewport(
                    messages: messages,
                    controller: controller,
                    initialAtEnd: true,
                    followOutput: following,
                    itemBuilder: cards.build,
                    onNavigate: () => following = false,
                    onUserScroll: (event) {
                      if (event.direction == ScrollDirection.forward) {
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
      );
      await tester.pumpAndSettle();
      expect(cards.builds.length, lessThan(30));
      final unchanged = Map.of(cards.builds)..remove('m1999');
      for (var chunk = 0; chunk < 20; chunk++) {
        update(
          () => messages = [
            ...messages.take(messages.length - 1),
            messages.last.copyWith(
              content: 'height:${80 + chunk * 4}',
              status: 'streaming',
            ),
          ],
        );
        await tester.pump(const Duration(milliseconds: 16));
        controller.scrollToEnd();
        await tester.pump(const Duration(milliseconds: 16));
        for (final entry in unchanged.entries) {
          expect(
            cards.builds[entry.key],
            entry.value,
            reason: 'unchanged ${entry.key} was rebuilt for a streaming delta',
          );
        }
      }
      expect(cards.builds['m1999'], greaterThan(10));
      following = false;
      controller.restore(const AiMessageBookmark('m20', 0, .25));
      await tester.pumpAndSettle();
      final before = controller.bookmark!;
      for (var chunk = 20; chunk < 30; chunk++) {
        update(
          () => messages = [
            ...messages.take(messages.length - 1),
            messages.last.copyWith(content: 'height:${80 + chunk * 4}'),
          ],
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.bookmark!.messageId, before.messageId);
        expect(controller.bookmark!.fraction, closeTo(before.fraction, .01));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
