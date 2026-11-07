import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/hardware_keyboard_shortcuts.dart';
import 'package:video_player_app/utils/keyboard_focus_visibility.dart';
import 'package:video_player_app/widgets/card_context_menu.dart';
import 'package:video_player_app/widgets/media_library_anchor_menu.dart';
import 'package:video_player_app/widgets/media_library_keyboard_navigation.dart';
import 'package:video_player_app/widgets/media_library_scroll_viewport.dart';

void main() {
  testWidgets('row actions scroll into view from an oversized focused item', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 300);
    addTearDown(tester.view.reset);
    final region = GlobalKey<MediaLibraryKeyboardRegionState>();
    final scroll = ScrollController();
    var playCount = 0;
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaLibrarySpatialNavigation(
            child: MediaLibraryKeyboardRegion(
              key: region,
              surface: () => 'channel',
              orderedIds: () => ['episode'],
              selectionMode: () => false,
              selectedIds: () => <String>{},
              onSelectionChanged: (_) {},
              child: SingleChildScrollView(
                controller: scroll,
                child: MediaLibraryKeyboardItem(
                  itemId: 'episode',
                  selected: false,
                  selectionMode: false,
                  onActivate: () {},
                  child: SizedBox(
                    height: 600,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Row(
                          children: [
                            const Expanded(child: Text('episode')),
                            MediaLibraryKeyboardDirectionalAction(
                              child: IconButton(
                                tooltip: 'offscreen play',
                                onPressed: () => playCount++,
                                icon: const Icon(Icons.play_arrow),
                              ),
                            ),
                            MediaLibraryKeyboardDirectionalAction(
                              child: IconButton(
                                tooltip: 'offscreen menu',
                                onPressed: () {},
                                icon: const Icon(Icons.more_horiz),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(region.currentState!.focusInitial(), isTrue);
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(find.byIcon(Icons.play_arrow))).hasPrimaryFocus,
      isTrue,
    );
    expect(scroll.offset, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(playCount, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(find.byIcon(Icons.more_horiz))).hasPrimaryFocus,
      isTrue,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(MediaLibraryKeyboardItem.hasPrimaryFocus, isTrue);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(find.byIcon(Icons.play_arrow))).hasPrimaryFocus,
      isTrue,
    );
    expect(scroll.offset, greaterThan(0));
  });

  testWidgets(
    'pointer hides the card outline while preserving focus and selection',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(MaterialApp(home: _Harness(key: key, count: 3)));
      await tester.pumpAndSettle();
      key.currentState!.setSelectionMode(true);
      key.currentState!.region.currentState!.focusInitial();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus;
      double opacity(String id) => tester
          .widget<FadeTransition>(
            find.descendant(
              of: find.byWidgetPredicate(
                (widget) =>
                    widget is MediaLibraryKeyboardItem && widget.itemId == id,
              ),
              matching: find.byType(FadeTransition),
            ),
          )
          .opacity
          .value;
      expect(opacity('1'), 1);
      expect(key.currentState!.selected, {'1'});
      await tester.tapAt(const Offset(20, 500), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacity('1'), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(opacity('1'), 0);
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(key.currentState!.selected, {'1'});
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focused(tester, 'card 2'), isTrue);
      expect(opacity('2'), 1);
      expect(key.currentState!.selected, {'1'});
    },
  );

  testWidgets(
    'arrows move through a lazy grid, Enter activates, and focus scrolls',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(MaterialApp(home: _Harness(key: key, count: 30)));
      await tester.pump();
      expect(key.currentState!.region.currentState!.focusInitial(), isTrue);
      await tester.pump();
      expect(_focused(tester, 'card 0'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'card 1'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(key.currentState!.activated, ['1']);
      for (var i = 0; i < 9; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(_focused(tester, 'card 28'), isTrue);
      expect(key.currentState!.scroll.offset, greaterThan(0));
    },
  );

  testWidgets(
    'selection toggles with Space and Enter and shift range shrinks',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(MaterialApp(home: _Harness(key: key, count: 9)));
      await tester.pump();
      key.currentState!.setSelectionMode(true);
      key.currentState!.region.currentState!.focusInitial();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(key.currentState!.selected, {'0'});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(key.currentState!.selected, {'0', '1', '2'});
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(key.currentState!.selected, {'0', '1'});
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(key.currentState!.selected, {'0'});
    },
  );

  testWidgets('navigation can build the next row beyond the lazy cache', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 300);
    addTearDown(tester.view.reset);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(home: _Harness(key: key, count: 6, mainAxisExtent: 650)),
    );
    await tester.pump();
    key.currentState!.region.currentState!.focusInitial();
    await tester.pump();
    expect(find.text('card 3'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focused(tester, 'card 3'), isTrue);
    expect(key.currentState!.scroll.offset, greaterThan(0));
  });

  testWidgets(
    'menu key opens the actual menu, arrows choose and Escape returns',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(MaterialApp(home: _Harness(key: key, count: 3)));
      await tester.pump();
      key.currentState!.region.currentState!.focusInitial();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('first menu item'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text('second menu item'),
        matching: find.byType(MediaLibraryMenuItemFocus),
      );
      expect(row, findsOneWidget);
      final highlight = find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (widget) => widget is KeyboardFocusHighlight && widget.focused,
        ),
      );
      expect(highlight, findsOneWidget);
      final decoration = tester
          .widget<KeyboardFocusHighlight>(highlight)
          .decoration;
      expect(decoration.borderRadius, isNot(BorderRadius.zero));
      expect(decoration.border, isA<Border>());
      expect((decoration.border! as Border).top.width, greaterThan(0));
      final painted =
          tester
                  .widget<AnimatedContainer>(
                    find.descendant(
                      of: highlight,
                      matching: find.byType(AnimatedContainer),
                    ),
                  )
                  .foregroundDecoration!
              as BoxDecoration;
      expect(painted.border!.top.color.a, greaterThan(0));
      expect(painted.borderRadius, decoration.borderRadius);
      final rowRect = tester.getRect(row);
      final highlightRect = tester.getRect(highlight);
      expect(highlightRect.left, greaterThan(rowRect.left));
      expect(highlightRect.right, lessThan(rowRect.right));
      expect(highlightRect.top, greaterThan(rowRect.top));
      expect(highlightRect.bottom, lessThan(rowRect.bottom));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(key.currentState!.menuChoice, 'second');
      expect(_focused(tester, 'card 0'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('first menu item'), findsNothing);
      expect(_focused(tester, 'card 0'), isTrue);
    },
  );

  testWidgets('down reaches the mini player and up returns to the card', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(home: _Harness(key: key, count: 1, mini: true)),
    );
    await tester.pump();
    key.currentState!.region.currentState!.focusInitial();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(MediaLibraryKeyboardMiniPlayer.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(key.currentState!.miniActivations, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_focused(tester, 'card 0'), isTrue);
  });

  testWidgets('switching surfaces restores each surface’s last card', (
    tester,
  ) async {
    final key = GlobalKey<_SwitchingHarnessState>();
    await tester.pumpWidget(MaterialApp(home: _SwitchingHarness(key: key)));
    await tester.pump();
    key.currentState!.region.currentState!.focusInitial();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_focused(tester, 'page 0 card 1'), isTrue);
    key.currentState!.showPage(1);
    await tester.pump();
    expect(key.currentState!.region.currentState!.focusInitial(), isTrue);
    await tester.pump();
    expect(_focused(tester, 'page 1 card 0'), isTrue);
    key.currentState!.showPage(0);
    await tester.pump();
    expect(key.currentState!.region.currentState!.focusInitial(), isTrue);
    await tester.pump();
    expect(_focused(tester, 'page 0 card 1'), isTrue);
  });

  testWidgets('Android native fallback moves and selects only once', (
    tester,
  ) async {
    debugNativeTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugNativeTargetPlatformOverride = null);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(MaterialApp(home: _Harness(key: key, count: 6)));
    await tester.pump();
    key.currentState!.setSelectionMode(true);
    key.currentState!.region.currentState!.focusInitial();
    await tester.pump();
    Future<void> native(int code, {bool shift = false}) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'com.example.video_player_app/hardware_input',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('keyEvent', {
            'keyCode': code,
            'action': 0,
            'eventTime': 10,
            'shift': shift,
          }),
        ),
        (_) {},
      );
      await tester.pump();
    }

    await native(62);
    expect(key.currentState!.selected, {'0'});
    await native(22, shift: true);
    expect(key.currentState!.selected, {'0', '1'});
    expect(_focused(tester, 'card 1'), isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(_focused(tester, 'card 1'), isTrue);
    expect(key.currentState!.selected, {'0', '1'});
  });

  testWidgets(
    'Android does not move twice when native and Flutter arrows overlap',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.reset);
      debugNativeTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugNativeTargetPlatformOverride = null);
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _Harness(key: key, count: 1, directionalActions: true),
        ),
      );
      await tester.pump();
      key.currentState!.region.currentState!.focusInitial();
      await tester.pump();
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'com.example.video_player_app/hardware_input',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('keyEvent', {'keyCode': 22, 'action': 0, 'eventTime': 10}),
        ),
        (_) {},
      );
      await tester.pump();
      expect(_focused(tester, 'row play'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focused(tester, 'row play'), isTrue);
    },
  );
}

bool _focused(WidgetTester tester, String text) =>
    Focus.of(tester.element(find.text(text))).hasPrimaryFocus;

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.count,
    this.mini = false,
    this.directionalActions = false,
    this.mainAxisExtent = 95,
  });
  final int count;
  final bool mini;
  final bool directionalActions;
  final double mainAxisExtent;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final region = GlobalKey<MediaLibraryKeyboardRegionState>();
  final scroll = ScrollController();
  final selected = <String>{};
  final activated = <String>[];
  bool selecting = false;
  String? menuChoice;
  int miniActivations = 0;

  void setSelectionMode(bool value) => setState(() => selecting = value);

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Expanded(
          child: MediaLibraryKeyboardRegion(
            key: region,
            surface: () => 'home',
            orderedIds: () => List.generate(widget.count, (index) => '$index'),
            selectionMode: () => selecting,
            selectedIds: () => selected,
            onSelectionChanged: (ids) => setState(() {
              selected
                ..clear()
                ..addAll(ids);
            }),
            child: MediaLibraryScrollViewport(
              controller: scroll,
              child: GridView.builder(
                controller: scroll,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisExtent: widget.mainAxisExtent,
                ),
                itemCount: widget.count,
                itemBuilder: (context, index) {
                  final id = '$index';
                  return CardContextMenu(
                    onFallback: () => fail('keyboard menu used fallback'),
                    builder: (context, _) => MediaLibraryKeyboardItem(
                      itemId: id,
                      selected: selected.contains(id),
                      selectionMode: selecting,
                      onActivate: () => setState(() {
                        if (selecting) {
                          if (!selected.add(id)) selected.remove(id);
                        } else {
                          activated.add(id);
                        }
                      }),
                      child: CardContextMenuTarget(
                        onOpen: () async {
                          final choice = await MediaLibraryAnchorMenu.show(
                            context: context,
                            anchor: const Rect.fromLTWH(20, 20, 10, 10),
                            items: const [
                              MediaLibraryAnchorMenuEntry(
                                value: 'first',
                                label: 'first menu item',
                                icon: Icons.edit,
                              ),
                              MediaLibraryAnchorMenuEntry(
                                value: 'second',
                                label: 'second menu item',
                                icon: Icons.edit,
                              ),
                            ],
                          );
                          if (mounted) setState(() => menuChoice = choice);
                        },
                        child: widget.directionalActions
                            ? Row(
                                children: [
                                  Expanded(child: Text('card $id')),
                                  MediaLibraryKeyboardDirectionalAction(
                                    child: TextButton(
                                      onPressed: () {},
                                      child: const Text('row play'),
                                    ),
                                  ),
                                  MediaLibraryKeyboardDirectionalAction(
                                    child: TextButton(
                                      onPressed: () {},
                                      child: const Text('row menu'),
                                    ),
                                  ),
                                ],
                              )
                            : Center(child: Text('card $id')),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        if (widget.mini)
          MediaLibraryKeyboardMiniPlayer(
            child: SizedBox(
              height: 70,
              child: TextButton(
                onPressed: () => setState(() => miniActivations++),
                child: const Text('mini play'),
              ),
            ),
          ),
      ],
    ),
  );
}

class _SwitchingHarness extends StatefulWidget {
  const _SwitchingHarness({super.key});

  @override
  State<_SwitchingHarness> createState() => _SwitchingHarnessState();
}

class _SwitchingHarnessState extends State<_SwitchingHarness> {
  final region = GlobalKey<MediaLibraryKeyboardRegionState>();
  int page = 0;

  void showPage(int value) => setState(() => page = value);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: MediaLibraryKeyboardRegion(
      key: region,
      surface: () => page,
      orderedIds: () => ['${page}a', '${page}b'],
      selectionMode: () => false,
      selectedIds: () => {},
      onSelectionChanged: (_) {},
      child: IndexedStack(
        index: page,
        children: [
          for (var p = 0; p < 2; p++)
            ExcludeFocus(
              excluding: p != page,
              child: Row(
                children: [
                  for (var i = 0; i < 2; i++)
                    Expanded(
                      child: MediaLibraryKeyboardItem(
                        itemId: '$p${i == 0 ? 'a' : 'b'}',
                        selected: false,
                        selectionMode: false,
                        onActivate: () {},
                        child: SizedBox(
                          height: 100,
                          child: Text('page $p card $i'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
