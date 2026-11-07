import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_keyboard_navigation.dart';

void main() {
  testWidgets('arrows cross header and cards; Enter focuses loaded page', (
    tester,
  ) async {
    final key = GlobalKey<_BrowsingHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaLibrarySpatialNavigation(child: _BrowsingHarness(key: key)),
      ),
    );
    await tester.pumpAndSettle();
    expect(key.currentState!.region.currentState!.focusInitial(), isTrue);
    await tester.pump();
    expect(
      _focus(tester, 'card 0-0'),
      isTrue,
      reason:
          'focus after Down: ${FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<MediaLibraryKeyboardItem>()?.itemId}',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_focus(tester, 'page 0'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      _focus(tester, 'card 0-0'),
      isTrue,
      reason:
          'focus after Down: ${FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<MediaLibraryKeyboardItem>()?.itemId}',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_focus(tester, 'page 1'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_focus(tester, 'page 1'), isTrue);
    key.currentState!.finishLoading();
    await tester.pumpAndSettle();
    expect(_focus(tester, 'card 1-0'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_focus(tester, 'action 1-0'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(key.currentState!.actions, 1);
  });

  testWidgets('loading does not steal focus after another key', (tester) async {
    final key = GlobalKey<_BrowsingHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaLibrarySpatialNavigation(child: _BrowsingHarness(key: key)),
      ),
    );
    await tester.pumpAndSettle();
    key.currentState!.region.currentState!.focusInitial();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(_focus(tester, 'page 0'), isTrue);
    key.currentState!.finishLoading();
    await tester.pumpAndSettle();
    expect(_focus(tester, 'page 0'), isTrue);
  });

  testWidgets('mini player buttons participate in directional navigation', (
    tester,
  ) async {
    final key = GlobalKey<_BrowsingHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaLibrarySpatialNavigation(
          child: _BrowsingHarness(key: key, mini: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    key.currentState!.region.currentState!.focusInitial();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_focus(tester, 'mini 0'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_focus(tester, 'mini 1'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(key.currentState!.actions, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_focus(tester, 'card 0-1'), isTrue);
  });

  testWidgets('an input retains its caret keys', (tester) async {
    final controller = TextEditingController(text: 'abcd');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaLibrarySpatialNavigation(
          child: Scaffold(
            body: Column(
              children: [
                TextField(controller: controller),
                TextButton(onPressed: () {}, child: const Text('next control')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(controller.selection.baseOffset, 2);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNotNull,
    );
  });

  testWidgets('excluded native surface is not a directional target', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaLibrarySpatialNavigation(
          child: Scaffold(
            body: Row(
              children: [
                TextButton(
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('toolbar'),
                ),
                MediaLibrarySpatialNavigationExcluded(
                  child: TextButton(
                    focusNode: focus,
                    onPressed: () {},
                    child: const Text('native'),
                  ),
                ),
                TextButton(onPressed: () {}, child: const Text('next toolbar')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    expect(_focus(tester, 'next toolbar'), isTrue);
  });
  testWidgets('offscreen floating controls cannot receive arrow focus', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaLibrarySpatialNavigation(
          child: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 20,
                  top: 40,
                  child: TextButton(
                    autofocus: true,
                    onPressed: () {},
                    child: const Text('underlying content'),
                  ),
                ),
                Positioned(
                  left: 200,
                  top: 200,
                  width: 140,
                  height: 100,
                  child: MediaLibrarySpatialNavigationOverlay(
                    child: SingleChildScrollView(
                      controller: scroll,
                      child: Column(
                        children: [
                          for (var index = 0; index < 12; index++)
                            TextButton(
                              onPressed: () {},
                              child: Text('floating $index'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_focus(tester, 'underlying content'), isTrue);
  });
}

bool _focus(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label))).hasPrimaryFocus;

class _BrowsingHarness extends StatefulWidget {
  const _BrowsingHarness({super.key, this.mini = false});
  final bool mini;
  @override
  State<_BrowsingHarness> createState() => _BrowsingHarnessState();
}

class _BrowsingHarnessState extends State<_BrowsingHarness> {
  final region = GlobalKey<MediaLibraryKeyboardRegionState>();
  int page = 0;
  bool loaded = false;
  int actions = 0;

  void finishLoading() => setState(() => loaded = true);

  void selectPage(int next) {
    setState(() => page = next);
    MediaLibrarySpatialNavigation.focusInitial(context);
  }

  @override
  Widget build(BuildContext context) {
    final count = page == 0 || loaded ? 2 : 0;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 240,
            child: Row(
              children: [
                for (var i = 0; i < 2; i++)
                  Expanded(
                    child: TextButton(
                      onPressed: () => selectPage(i),
                      child: Text('page $i'),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 240,
                child: MediaLibraryKeyboardRegion(
                  key: region,
                  surface: () => page,
                  orderedIds: () => List.generate(count, (i) => '$page-$i'),
                  selectionMode: () => false,
                  selectedIds: () => <String>{},
                  onSelectionChanged: (_) {},
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: 100,
                        ),
                    itemCount: count,
                    itemBuilder: (_, i) => MediaLibraryKeyboardItem(
                      itemId: '$page-$i',
                      selected: false,
                      selectionMode: false,
                      onActivate: () {},
                      child: Column(
                        children: [
                          Text('card $page-$i'),
                          TextButton(
                            onPressed: () => setState(() => actions++),
                            child: Text('action $page-$i'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.mini)
            MediaLibraryKeyboardMiniPlayer(
              child: SizedBox(
                width: 240,
                child: Row(
                  children: [
                    for (var i = 0; i < 2; i++)
                      Expanded(
                        child: TextButton(
                          onPressed: () => setState(() => actions++),
                          child: Text('mini $i'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
