import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_episode_press.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester, {
    required VoidCallback onOpen,
    required VoidCallback onSelect,
    required VoidCallback onRangeSelect,
    required VoidCallback onLongPress,
    bool selecting = false,
    Widget? child,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 72,
              child: PodcastEpisodePress(
                selecting: selecting,
                onOpen: onOpen,
                onSelect: onSelect,
                onRangeSelect: onRangeSelect,
                onLongPress: onLongPress,
                child: child ?? const Text('第一集'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> click(
    WidgetTester tester, {
    Offset delta = Offset.zero,
    Duration held = const Duration(milliseconds: 40),
    int buttons = kPrimaryButton,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第一集')),
      kind: PointerDeviceKind.mouse,
      buttons: buttons,
    );
    if (delta != Offset.zero) await gesture.moveBy(delta);
    await tester.pump(held);
    await gesture.up();
    await tester.pump();
  }

  testWidgets('a still mouse click opens the episode and does not select it', (
    tester,
  ) async {
    var opens = 0, selects = 0, ranges = 0, holds = 0;
    await pump(
      tester,
      onOpen: () => opens++,
      onSelect: () => selects++,
      onRangeSelect: () => ranges++,
      onLongPress: () => holds++,
    );
    await click(tester);
    expect(opens, 1);
    expect(selects, 0);
    expect(ranges, 0);
    expect(holds, 0);
  });

  testWidgets('a one-pixel mouse twitch is still a click, not a selection', (
    tester,
  ) async {
    var opens = 0, selects = 0, holds = 0;
    await pump(
      tester,
      onOpen: () => opens++,
      onSelect: () => selects++,
      onRangeSelect: () {},
      onLongPress: () => holds++,
    );
    await click(tester, delta: const Offset(1, 0));
    await click(tester, delta: const Offset(4, 3));
    expect(opens, 2);
    expect(selects, 0);
    expect(holds, 0);
  });

  testWidgets('a short upward swipe cannot open an episode on release', (
    tester,
  ) async {
    var opens = 0, selects = 0, holds = 0;
    await pump(
      tester,
      onOpen: () => opens++,
      onSelect: () => selects++,
      onRangeSelect: () {},
      onLongPress: () => holds++,
    );
    // A quick swipe can end between the row's 10px click tolerance and
    // InkWell's 18px tap tolerance, especially when the list hits an edge.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第一集')),
    );
    await gesture.moveBy(const Offset(0, -14));
    await tester.pump(const Duration(milliseconds: 10));
    await gesture.up();
    await tester.pump();
    expect(opens, 0);
    expect(selects, 0);
    expect(holds, 0);

    await tester.tap(find.text('第一集'));
    await tester.pump();
    expect(opens, 1, reason: 'The next deliberate tap still opens the row');
  });

  testWidgets('holding still selects and the release does not also open', (
    tester,
  ) async {
    var opens = 0, selects = 0, holds = 0;
    await pump(
      tester,
      onOpen: () => opens++,
      onSelect: () => selects++,
      onRangeSelect: () {},
      onLongPress: () => holds++,
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第一集')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(1, 1));
    await tester.pump(podcastEpisodeLongPressDelay);
    expect(holds, 1);
    expect(opens, 0);
    await gesture.up();
    await tester.pump();
    expect(opens, 0);
    expect(selects, 0);
    expect(holds, 1);
  });

  testWidgets('a short hold, even with a small move, does not select', (
    tester,
  ) async {
    var opens = 0, holds = 0;
    await pump(
      tester,
      onOpen: () => opens++,
      onSelect: () {},
      onRangeSelect: () {},
      onLongPress: () => holds++,
    );
    await click(
      tester,
      delta: const Offset(2, 1),
      held: podcastEpisodeLongPressDelay - const Duration(milliseconds: 50),
    );
    expect(holds, 0);
    expect(opens, 1);
  });

  testWidgets('a stuck Windows key does not turn a click into a selection', (
    tester,
  ) async {
    var opens = 0, selects = 0;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    addTearDown(() => tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft));
    await pump(
      tester,
      onOpen: () => opens++,
      onSelect: () => selects++,
      onRangeSelect: () {},
      onLongPress: () {},
    );
    await click(tester);
    expect(selects, 0);
    expect(opens, 1);
  });

  testWidgets('pressing the Windows key on this page still opens the episode', (
    tester,
  ) async {
    var opens = 0, selects = 0;
    await pump(
      tester,
      onOpen: () => opens++,
      onSelect: () => selects++,
      onRangeSelect: () {},
      onLongPress: () {},
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    addTearDown(() => tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft));
    await click(tester);
    expect(selects, 0);
    expect(opens, 1);
  });

  testWidgets(
    'Ctrl and Shift pressed for this click select instead of opening',
    (tester) async {
      var opens = 0, selects = 0, ranges = 0;
      await pump(
        tester,
        onOpen: () => opens++,
        onSelect: () => selects++,
        onRangeSelect: () => ranges++,
        onLongPress: () {},
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await click(tester, delta: const Offset(1, 0));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await click(tester);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(selects, 1);
      expect(ranges, 1);
      expect(opens, 0);
    },
  );

  testWidgets('a click while already selecting toggles that episode', (
    tester,
  ) async {
    var opens = 0, selects = 0;
    await pump(
      tester,
      selecting: true,
      onOpen: () => opens++,
      onSelect: () => selects++,
      onRangeSelect: () {},
      onLongPress: () {},
    );
    await click(tester);
    expect(selects, 1);
    expect(opens, 0);
  });

  testWidgets('the play control keeps its own click', (tester) async {
    var opens = 0, plays = 0, holds = 0;
    await pump(
      tester,
      onOpen: () => opens++,
      onSelect: () {},
      onRangeSelect: () {},
      onLongPress: () => holds++,
      child: TextButton(onPressed: () => plays++, child: const Text('播放')),
    );
    await tester.tap(find.text('播放'));
    await tester.pump();
    expect(plays, 1);
    expect(opens, 0);
    expect(holds, 0);
  });
}
