import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/bilibili/bilibili_account_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/mouse_back_button_listener.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';

/// A stand-in library page or cover page: a label, nothing else.
class _Page extends StatelessWidget {
  const _Page(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Center(child: Text(label)),
    );
  }
}

class _AttachmentProbe extends StatefulWidget {
  const _AttachmentProbe(this.onDeactivate);
  final VoidCallback onDeactivate;
  @override
  State<_AttachmentProbe> createState() => _AttachmentProbeState();
}

class _AttachmentProbeState extends State<_AttachmentProbe> {
  @override
  void deactivate() {
    widget.onDeactivate();
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => const _Page('attached home');
}

class _VisibilityProbe extends StatefulWidget {
  const _VisibilityProbe(this.onVisibility);
  final ValueChanged<bool> onVisibility;
  @override
  State<_VisibilityProbe> createState() => _VisibilityProbeState();
}

class _VisibilityProbeState extends State<_VisibilityProbe> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onVisibility(mediaLibraryRouteIsCurrent(context) == true);
  }

  @override
  Widget build(BuildContext context) => const _Page('visibility probe');
}

/// A library page whose back is held, like a page in selection mode.
class _HeldPage extends StatelessWidget {
  const _HeldPage({required this.onHeldBack});

  final VoidCallback onHeldBack;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onHeldBack();
      },
      child: const _Page('held'),
    );
  }
}

/// A library page that answers keys only while it is the page on screen,
/// with the same guard the media library pages use.
class _KeyedPage extends StatefulWidget {
  const _KeyedPage({required this.onKey});

  final ValueChanged<LogicalKeyboardKey> onKey;

  @override
  State<_KeyedPage> createState() => _KeyedPageState();
}

class _KeyedPageState extends State<_KeyedPage> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!isMediaLibraryRouteCurrent(context)) return false;
    widget.onKey(event.logicalKey);
    return true;
  }

  @override
  Widget build(BuildContext context) => const _Page('keyed');
}

/// Records the inset supplied to real library content.
class _InsetPage extends StatefulWidget {
  const _InsetPage(this.label);

  final String label;

  @override
  State<_InsetPage> createState() => _InsetPageState();
}

class _InsetPageState extends State<_InsetPage> {
  double? fromFrame;

  @override
  Widget build(BuildContext context) {
    fromFrame = MediaLibraryShell.stableBottomInsetOf(context);
    return _Page(widget.label);
  }
}

/// A library page that can show the same selection bar the media library uses.
class _SelectingPage extends StatefulWidget {
  const _SelectingPage({required this.onRecycle});

  final VoidCallback onRecycle;

  @override
  State<_SelectingPage> createState() => _SelectingPageState();
}

class _SelectingPageState extends State<_SelectingPage> {
  bool selecting = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: TextButton(
          onPressed: () => setState(() => selecting = !selecting),
          child: const Text('toggle-select'),
        ),
      ),
      bottomNavigationBar: MediaLibrarySelectionBarTransition(
        child: selecting
            ? MediaLibrarySelectionBottomBar.folders(
                onMoveToRecycleBin: widget.onRecycle,
                onExportFluentPack: () {},
                onRename: () {},
              )
            : null,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MediaPlaybackService playback;
  late GlobalKey<NavigatorState> rootKey;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    rootKey = GlobalKey<NavigatorState>();
    playback = MediaPlaybackService();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'clip',
        path: 'clip.mp4',
        title: 'clip',
        durationMs: 330000,
        lastUpdated: 0,
      ),
      const Duration(seconds: 196),
    );
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pumpShell(
    WidgetTester tester,
    Widget home, {
    bool mouseBack = true,
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child: MaterialApp(
          navigatorKey: rootKey,
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          builder: (context, child) => MouseBackButtonListener(
            navigatorKey: rootKey,
            enabled: mouseBack,
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: disableAnimations),
              child: child!,
            ),
          ),
          home: MediaLibraryShell(home: home),
        ),
      ),
    );
    await settle(tester);
  }

  BuildContext contextOf(WidgetTester tester, String label) {
    return tester.element(find.text(label));
  }

  Route<void> folder(String id) {
    return buildMediaLibraryFolderRoute<void>(
      folderId: id,
      builder: (_) => _Page('folder $id'),
    );
  }

  testWidgets('folder navigation avoids duplicate inset consumer rebuilds', (
    tester,
  ) async {
    var builds = 0;
    late BuildContext pageContext;
    await pumpShell(
      tester,
      Builder(
        builder: (context) {
          pageContext = context;
          builds++;
          MediaLibraryShell.stableBottomInsetOf(context);
          MediaLibraryShell.selectionBarObstructionOf(context);
          return const _Page('stable home');
        },
      ),
    );
    final initial = builds;
    final navigator = Navigator.of(pageContext);
    navigator.push(folder('nested'));
    await settle(tester);
    // Navigator may rebuild its route once; the shell must not add a second
    // broadcast when the inset and selection obstruction have not changed.
    expect(builds, initial + 1);
    navigator.pop();
    await settle(tester);
    expect(builds, initial + 2);
  });

  testWidgets('folder transition keeps the existing home subtree attached', (
    tester,
  ) async {
    var deactivations = 0;
    await pumpShell(tester, _AttachmentProbe(() => deactivations++));
    final navigator = Navigator.of(contextOf(tester, 'attached home'));
    navigator.push(folder('nested'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(deactivations, 0);
    await settle(tester);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(deactivations, 0);
    await settle(tester);
    expect(deactivations, 0);
  });

  final card = find.byType(MiniPlaybackCard);
  final offstageCard = find.byType(MiniPlaybackCard, skipOffstage: false);

  State<StatefulWidget> cardState(WidgetTester tester) {
    return tester.state(offstageCard);
  }

  Offset cardSlide(WidgetTester tester) {
    return tester
        .widget<SlideTransition>(
          find
              .descendant(
                of: offstageCard,
                matching: find.byType(SlideTransition),
              )
              .first,
        )
        .position
        .value;
  }

  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await settle(tester);
  }

  Future<void> mouseButton(WidgetTester tester, int buttons) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: buttons,
    );
    await gesture.addPointer(location: const Offset(450, 300));
    await gesture.down(const Offset(450, 300));
    await gesture.up();
    await gesture.removePointer();
    await settle(tester);
  }

  bool hits(WidgetTester tester, Offset point, Finder target) {
    final result = HitTestResult();
    tester.binding.hitTestInView(result, point, tester.view.viewId);
    final box = tester.renderObject(target);
    return result.path.any((entry) => identical(entry.target, box));
  }

  testWidgets(
    'nested library observes settings-sheet closure without app resume',
    (tester) async {
      final visibility = <bool>[];
      await pumpShell(tester, _VisibilityProbe(visibility.add));
      expect(visibility.last, isTrue);
      showModalBottomSheet<void>(
        context: contextOf(tester, 'visibility probe'),
        useRootNavigator: true,
        builder: (_) =>
            const SizedBox(height: 200, child: Text('clipboard settings')),
      );
      await settle(tester);
      expect(visibility.last, isFalse);
      rootKey.currentState!.pop();
      await settle(tester);
      expect(visibility.last, isTrue);
    },
  );

  group('folders switch inside the frame', () {
    testWidgets('the mini player is one card that never rebuilds or moves', (
      tester,
    ) async {
      await pumpShell(tester, const _Page('home'));
      expect(card, findsOneWidget);
      final state = cardState(tester);
      final rect = tester.getRect(card);
      expect(cardSlide(tester), Offset.zero);

      unawaited(Navigator.of(contextOf(tester, 'home')).push(folder('a')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        expect(card, findsOneWidget);
        expect(cardState(tester), same(state));
        expect(tester.getRect(card), rect);
        expect(cardSlide(tester), Offset.zero);
      }
      await settle(tester);
      expect(find.text('folder a'), findsOneWidget);

      unawaited(Navigator.of(contextOf(tester, 'folder a')).push(folder('b')));
      await settle(tester);
      expect(cardState(tester), same(state));

      // Breadcrumb straight back to the library root.
      popMediaLibraryToFolder(Navigator.of(contextOf(tester, 'folder b')));
      await settle(tester);
      expect(find.text('home'), findsOneWidget);
      expect(cardState(tester), same(state));
      expect(tester.getRect(card), rect);

      unawaited(Navigator.of(contextOf(tester, 'home')).push(folder('c')));
      await settle(tester);
      Navigator.of(contextOf(tester, 'folder c')).pop();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        expect(cardState(tester), same(state));
        expect(tester.getRect(card), rect);
        expect(cardSlide(tester), Offset.zero);
      }
    });

    testWidgets('the card sits at the stable bottom inset, full width', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.resetPadding);
      await pumpShell(tester, const _Page('home'));
      final rect = tester.getRect(card);
      expect(rect.left, 0);
      expect(rect.width, 900);
      expect(rect.bottom, 1600 - PlaybackCardOverlayLayout.cardBottom(24));
      expect(
        MediaLibraryShell.stableBottomInsetOf(contextOf(tester, 'home')),
        24,
      );
    });

    testWidgets(
      'selection actions stay above the mini player and receive taps',
      (tester) async {
        var recycled = 0;
        await pumpShell(tester, _SelectingPage(onRecycle: () => recycled++));
        final restingBottom = tester.getRect(card).bottom;

        await tester.tap(find.text('toggle-select'));
        await settle(tester);

        final cardRect = tester.getRect(card);
        final barRect = tester.getRect(
          find.byType(MediaLibrarySelectionBottomBar),
        );
        expect(cardRect.bottom, lessThanOrEqualTo(barRect.top));
        expect(cardRect.bottom, lessThan(restingBottom));
        final fill = tester.getRect(
          find.byKey(MediaLibraryOverlayKeys.playbackBottomFill),
        );
        expect(fill.bottom, lessThanOrEqualTo(barRect.top + 0.5));

        await tester.tap(find.textContaining('移入回收站'));
        await tester.pump();
        expect(recycled, 1);

        // A folder without a selection bar gets the resting player back.
        final libraryNavigator = Navigator.of(
          contextOf(tester, 'toggle-select'),
        );
        unawaited(libraryNavigator.push(folder('a')));
        await settle(tester);
        expect(tester.getRect(card).bottom, restingBottom);

        libraryNavigator.pop();
        await settle(tester);
        expect(
          tester.getRect(card).bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byType(MediaLibrarySelectionBottomBar)).top,
          ),
        );
      },
    );

    for (final inset in [0.0, 24.0]) {
      testWidgets(
        'selection bar and mini player animate together with inset $inset',
        (tester) async {
          tester.view.padding = FakeViewPadding(bottom: inset);
          tester.view.viewPadding = FakeViewPadding(bottom: inset);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          var recycled = 0;
          await pumpShell(tester, _SelectingPage(onRecycle: () => recycled++));
          final state = cardState(tester);
          final restingBottom = tester.getRect(card).bottom;
          final transition = find.byType(MediaLibrarySelectionBarTransition);
          final fade = find.descendant(
            of: transition,
            matching: find.byType(FadeTransition),
          );

          void expectAligned() {
            final height = tester.getSize(transition).height;
            expect(
              tester.getRect(card).bottom,
              closeTo(
                1600 -
                    PlaybackCardOverlayLayout.cardBottomAbove(
                      stableBottomInset: inset,
                      selectionBarHeight: height,
                    ),
                1,
              ),
            );
            final fill = tester.getRect(
              find.byKey(MediaLibraryOverlayKeys.playbackBottomFill),
            );
            expect(fill.bottom, closeTo(1600 - height, 1));
            expect(fill.top, closeTo(tester.getRect(card).bottom, 1));
            expect(cardState(tester), same(state));
            expect(cardSlide(tester), Offset.zero);
          }

          await tester.tap(find.text('toggle-select'));
          await tester.pump();
          expect(tester.getRect(card).bottom, restingBottom);
          var previousBottom = restingBottom;
          for (var frame = 0; frame < 7; frame++) {
            await tester.pump(const Duration(milliseconds: 32));
            expect(
              tester.getRect(card).bottom,
              lessThanOrEqualTo(previousBottom),
            );
            previousBottom = tester.getRect(card).bottom;
            expectAligned();
          }
          final liftedBottom = tester.getRect(card).bottom;
          final fullHeight = tester.getSize(transition).height;
          expect(liftedBottom, lessThan(restingBottom));

          await tester.tap(find.text('toggle-select'));
          await tester.pump();
          expect(tester.getRect(card).bottom, liftedBottom);
          expect(tester.getSize(transition).height, fullHeight);
          expect(find.byType(MediaLibrarySelectionBottomBar), findsOneWidget);
          // Retained actions become inert as soon as selection ends.
          await tester.tap(find.textContaining('移入回收站'), warnIfMissed: false);
          expect(recycled, 0);
          for (var frame = 0; frame < 7; frame++) {
            await tester.pump(const Duration(milliseconds: 32));
            expect(
              tester.getRect(card).bottom,
              greaterThanOrEqualTo(previousBottom),
            );
            previousBottom = tester.getRect(card).bottom;
            if (frame == 1) {
              expect(
                tester.getSize(transition).height,
                inExclusiveRange(0, fullHeight),
              );
              expect(
                tester.widget<FadeTransition>(fade).opacity.value,
                inExclusiveRange(0, 1),
              );
              expect(
                tester.getRect(card).bottom,
                inExclusiveRange(liftedBottom, restingBottom),
              );
            }
            expectAligned();
          }
          expect(tester.getRect(card).bottom, restingBottom);
          expect(tester.getSize(transition).height, 0);
          expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'reselecting during exit reverses without moving the card abruptly',
      (tester) async {
        await pumpShell(tester, _SelectingPage(onRecycle: () {}));
        await tester.tap(find.text('toggle-select'));
        await settle(tester);
        final selectedBottom = tester.getRect(card).bottom;
        final state = cardState(tester);

        await tester.tap(find.text('toggle-select'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final interruptedBottom = tester.getRect(card).bottom;
        expect(interruptedBottom, greaterThan(selectedBottom));

        await tester.tap(find.text('toggle-select'));
        await tester.pump();
        expect(tester.getRect(card).bottom, interruptedBottom);
        await tester.pump(const Duration(milliseconds: 32));
        expect(tester.getRect(card).bottom, lessThan(interruptedBottom));
        await settle(tester);
        expect(tester.getRect(card).bottom, selectedBottom);
        expect(cardState(tester), same(state));
        expect(find.byType(MediaLibrarySelectionBottomBar), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('selection transitions respect reduced motion', (tester) async {
      await pumpShell(
        tester,
        _SelectingPage(onRecycle: () {}),
        disableAnimations: true,
      );
      final restingBottom = tester.getRect(card).bottom;
      await tester.tap(find.text('toggle-select'));
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(card).bottom, lessThan(restingBottom));
      await tester.tap(find.text('toggle-select'));
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(card).bottom, restingBottom);
      expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search results show the card in Noto Sans SC', (tester) async {
      await pumpShell(tester, const _Page('home'));
      String? cardFont() =>
          Theme.of(tester.element(card)).textTheme.bodyMedium?.fontFamily;
      expect(cardFont(), isNot('Noto Sans SC'));

      unawaited(
        Navigator.of(
          contextOf(tester, 'home'),
        ).push(buildMediaLibrarySearchResultsRoute(const _Page('results'))),
      );
      await settle(tester);
      expect(cardFont(), 'Noto Sans SC');

      Navigator.of(contextOf(tester, 'results')).pop();
      await settle(tester);
      expect(cardFont(), isNot('Noto Sans SC'));
    });
  });

  group('the card follows the visible window safe area', () {
    const portrait = Size(900, 1600);
    const landscape = Size(1600, 900);

    Future<void> setMetrics(
      WidgetTester tester, {
      required Size size,
      double padding = 0,
      double viewPadding = 0,
      double gesture = 0,
    }) async {
      tester.view.physicalSize = size;
      tester.view.padding = FakeViewPadding(bottom: padding);
      tester.view.viewPadding = FakeViewPadding(bottom: viewPadding);
      tester.view.systemGestureInsets = FakeViewPadding(bottom: gesture);
      await settle(tester);
    }

    Future<void> openFolder(WidgetTester tester, String from, String id) async {
      unawaited(
        Navigator.of(contextOf(tester, from)).push(
          buildMediaLibraryFolderRoute<void>(
            folderId: id,
            builder: (_) => _InsetPage('folder $id'),
          ),
        ),
      );
      await settle(tester);
    }

    Future<void> back(WidgetTester tester, String from) async {
      Navigator.of(contextOf(tester, from)).pop();
      await settle(tester);
    }

    _InsetPageState page(WidgetTester tester, String label) =>
        tester.state<_InsetPageState>(
          find.ancestor(
            of: find.text(label, skipOffstage: false),
            matching: find.byType(_InsetPage, skipOffstage: false),
          ),
        );

    void expectInset(WidgetTester tester, String top, double expected) {
      expect(page(tester, top).fromFrame, expected, reason: top);
      expect(
        tester.getRect(card).bottom,
        tester.view.physicalSize.height - expected - 6,
      );
      expect(
        tester
            .getSize(find.byKey(MediaLibraryOverlayKeys.playbackBottomFill))
            .height,
        expected + 6,
      );
    }

    testWidgets('rotation and returning folders use the current window', (
      tester,
    ) async {
      await pumpShell(tester, const _InsetPage('home'));
      await setMetrics(tester, size: portrait, viewPadding: 48);
      expectInset(tester, 'home', 48);
      await setMetrics(tester, size: landscape);
      expectInset(tester, 'home', 0);
      await openFolder(tester, 'home', 'a');
      expectInset(tester, 'folder a', 0);
      await setMetrics(tester, size: portrait, viewPadding: 34);
      expectInset(tester, 'folder a', 34);
      await back(tester, 'folder a');
      expectInset(tester, 'home', 34);
      await setMetrics(tester, size: landscape, gesture: 20);
      expectInset(tester, 'home', 20);
    });

    testWidgets(
      'a settled smaller inset shrinks without another metrics event',
      (tester) async {
        await pumpShell(tester, const _InsetPage('home'));
        await setMetrics(tester, size: portrait, viewPadding: 72);
        tester.view.viewPadding = const FakeViewPadding(bottom: 24);
        await tester.pump();
        expectInset(tester, 'home', 72);
        await tester.pump(const Duration(milliseconds: 699));
        expectInset(tester, 'home', 72);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expectInset(tester, 'home', 24);
      },
    );

    testWidgets('a hidden folder is not updated by the page above it', (
      tester,
    ) async {
      await pumpShell(tester, const _InsetPage('home'));
      await setMetrics(tester, size: portrait, padding: 16);
      await openFolder(tester, 'home', 'a');
      await setMetrics(tester, size: portrait, gesture: 40);
      expectInset(tester, 'folder a', 40);
      expect(page(tester, 'home').fromFrame, 16);
      await back(tester, 'folder a');
      expectInset(tester, 'home', 40);
    });

    testWidgets('opening and closing folders has no stale-inset frame', (
      tester,
    ) async {
      await pumpShell(tester, const _InsetPage('home'));
      await setMetrics(tester, size: portrait, viewPadding: 48);
      await setMetrics(tester, size: landscape);
      unawaited(
        Navigator.of(contextOf(tester, 'home')).push(
          buildMediaLibraryFolderRoute<void>(
            folderId: 'a',
            builder: (_) => const _InsetPage('folder a'),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.getRect(card).bottom, landscape.height - 6);
      }
      await settle(tester);
      Navigator.of(contextOf(tester, 'folder a')).pop();
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(card).bottom, landscape.height - 6);
      await settle(tester);
    });

    testWidgets('an immersive covering route cannot overwrite library insets', (
      tester,
    ) async {
      await pumpShell(tester, const _InsetPage('home'));
      await setMetrics(tester, size: portrait, viewPadding: 24);
      await openFolder(tester, 'home', 'a');
      unawaited(
        pushAboveMediaLibrary<void>(
          contextOf(tester, 'folder a'),
          MaterialPageRoute<void>(builder: (_) => const _Page('player')),
        ),
      );
      await settle(tester);
      await setMetrics(tester, size: landscape, viewPadding: 80);
      expect(page(tester, 'folder a').fromFrame, 24);
      expect(page(tester, 'home').fromFrame, 24);
      await setMetrics(tester, size: portrait, viewPadding: 24);
      Navigator.of(contextOf(tester, 'player')).pop();
      await settle(tester);
      expectInset(tester, 'folder a', 24);
      await back(tester, 'folder a');
      expectInset(tester, 'home', 24);
    });
  });

  group('pages above the frame cover the card', () {
    testWidgets('a player covers the card and leaves it in place on return', (
      tester,
    ) async {
      await pumpShell(tester, const _Page('home'));
      final state = cardState(tester);
      final rect = tester.getRect(card);

      unawaited(
        pushAboveMediaLibrary(
          contextOf(tester, 'home'),
          MaterialPageRoute<void>(builder: (_) => const _Page('player')),
        ),
      );
      await settle(tester);
      expect(find.text('player'), findsOneWidget);
      expect(card, findsNothing);
      // The card belongs to the app route under the player, not to a layer
      // above every route.
      final cardContext = tester.element(offstageCard);
      expect(Navigator.of(cardContext), same(rootKey.currentState));
      expect(ModalRoute.of(cardContext)!.isFirst, isTrue);

      rootKey.currentState!.pop();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        expect(cardState(tester), same(state));
        expect(cardSlide(tester), Offset.zero);
      }
      await settle(tester);
      expect(card, findsOneWidget);
      expect(tester.getRect(card), rect);
    });

    testWidgets('a root bottom sheet covers the card', (tester) async {
      await pumpShell(tester, const _Page('home'));
      unawaited(Navigator.of(contextOf(tester, 'home')).push(folder('a')));
      await settle(tester);
      const sheetKey = ValueKey<String>('sheet');
      unawaited(
        showModalBottomSheet<void>(
          context: contextOf(tester, 'folder a'),
          useRootNavigator: true,
          builder: (_) =>
              const SizedBox(key: sheetKey, height: 600, child: Text('sheet')),
        ),
      );
      await settle(tester);
      final center = tester.getCenter(offstageCard);
      expect(hits(tester, center, find.byKey(sheetKey)), isTrue);
      expect(hits(tester, center, offstageCard), isFalse);
    });

    testWidgets('the Bilibili account page opens above the card', (
      tester,
    ) async {
      final settings = SettingsService();
      await settings.init();
      await pumpShell(
        tester,
        const Scaffold(body: BilibiliHomePage(isActive: true)),
      );
      expect(card, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bilibili-account-button')));
      await settle(tester);
      expect(find.byType(BilibiliAccountScreen), findsOneWidget);
      expect(card, findsNothing);
      expect(
        Navigator.of(tester.element(find.byType(BilibiliAccountScreen))),
        same(rootKey.currentState),
      );
    });

    testWidgets('a page opened above the library shows no card', (
      tester,
    ) async {
      await pumpShell(tester, const _Page('home'));
      unawaited(Navigator.of(contextOf(tester, 'home')).push(folder('a')));
      await settle(tester);
      unawaited(
        pushAboveMediaLibrary(
          contextOf(tester, 'folder a'),
          MaterialPageRoute<void>(builder: (_) => const _Page('recycle bin')),
        ),
      );
      await settle(tester);
      expect(find.text('recycle bin'), findsOneWidget);
      expect(card, findsNothing);
    });
  });

  group('back', () {
    testWidgets('system back steps out of folders one at a time', (
      tester,
    ) async {
      await pumpShell(tester, const _Page('home'));
      final state = cardState(tester);
      unawaited(Navigator.of(contextOf(tester, 'home')).push(folder('a')));
      await settle(tester);
      unawaited(Navigator.of(contextOf(tester, 'folder a')).push(folder('b')));
      await settle(tester);

      await systemBack(tester);
      expect(find.text('folder a'), findsOneWidget);
      expect(find.text('folder b'), findsNothing);
      await systemBack(tester);
      expect(find.text('home'), findsOneWidget);
      expect(cardState(tester), same(state));
    });

    testWidgets('system back reaches a held library page and a dialog', (
      tester,
    ) async {
      await pumpShell(tester, const _Page('home'));
      var held = 0;
      unawaited(
        Navigator.of(contextOf(tester, 'home')).push(
          MaterialPageRoute<void>(
            builder: (_) => _HeldPage(onHeldBack: () => held++),
          ),
        ),
      );
      await settle(tester);
      await systemBack(tester);
      expect(held, 1);
      expect(find.text('held'), findsOneWidget);

      unawaited(
        showDialog<void>(
          context: contextOf(tester, 'held'),
          builder: (_) => const AlertDialog(content: Text('dialog')),
        ),
      );
      await settle(tester);
      await systemBack(tester);
      expect(find.text('dialog'), findsNothing);
      expect(find.text('held'), findsOneWidget);
      expect(held, 1);
    });

    testWidgets('mouse back does what system back does; forward does nothing', (
      tester,
    ) async {
      await pumpShell(tester, const _Page('home'));
      unawaited(Navigator.of(contextOf(tester, 'home')).push(folder('a')));
      await settle(tester);
      unawaited(Navigator.of(contextOf(tester, 'folder a')).push(folder('b')));
      await settle(tester);

      await mouseButton(tester, kForwardMouseButton);
      expect(find.text('folder b'), findsOneWidget);

      await mouseButton(tester, kBackMouseButton);
      expect(find.text('folder a'), findsOneWidget);
      expect(find.text('folder b'), findsNothing);

      unawaited(
        showDialog<void>(
          context: contextOf(tester, 'folder a'),
          builder: (_) => const AlertDialog(content: Text('dialog')),
        ),
      );
      await settle(tester);
      await mouseButton(tester, kBackMouseButton);
      expect(find.text('dialog'), findsNothing);
      expect(find.text('folder a'), findsOneWidget);

      unawaited(
        pushAboveMediaLibrary(
          contextOf(tester, 'folder a'),
          MaterialPageRoute<void>(builder: (_) => const _Page('player')),
        ),
      );
      await settle(tester);
      await mouseButton(tester, kForwardMouseButton);
      expect(find.text('player'), findsOneWidget);
      await mouseButton(tester, kBackMouseButton);
      expect(find.text('player'), findsNothing);
      expect(find.text('folder a'), findsOneWidget);

      await mouseButton(tester, kBackMouseButton);
      expect(find.text('home'), findsOneWidget);
      // At the first page there is nothing to go back to.
      await mouseButton(tester, kBackMouseButton);
      expect(find.text('home'), findsOneWidget);
      expect(card, findsOneWidget);
    });

    testWidgets('mouse back reaches a held page like system back', (
      tester,
    ) async {
      await pumpShell(tester, const _Page('home'));
      var held = 0;
      unawaited(
        Navigator.of(contextOf(tester, 'home')).push(
          MaterialPageRoute<void>(
            builder: (_) => _HeldPage(onHeldBack: () => held++),
          ),
        ),
      );
      await settle(tester);
      await mouseButton(tester, kBackMouseButton);
      expect(held, 1);
      expect(find.text('held'), findsOneWidget);
    });

    testWidgets('mouse back is off where the platform handles it', (
      tester,
    ) async {
      await pumpShell(tester, const _Page('home'), mouseBack: false);
      unawaited(Navigator.of(contextOf(tester, 'home')).push(folder('a')));
      await settle(tester);
      await mouseButton(tester, kBackMouseButton);
      expect(find.text('folder a'), findsOneWidget);
    });
  });

  group('the library page on screen', () {
    testWidgets('is current only while nothing covers it', (tester) async {
      await pumpShell(tester, const _Page('home'));
      final home = contextOf(tester, 'home');
      expect(isMediaLibraryRouteCurrent(home), isTrue);

      unawaited(Navigator.of(home).push(folder('a')));
      await settle(tester);
      final folderA = contextOf(tester, 'folder a');
      expect(isMediaLibraryRouteCurrent(home), isFalse);
      expect(isMediaLibraryRouteCurrent(folderA), isTrue);

      unawaited(
        pushAboveMediaLibrary(
          folderA,
          MaterialPageRoute<void>(builder: (_) => const _Page('player')),
        ),
      );
      await settle(tester);
      // The folder is still the top of the library navigator, but the
      // player covers the whole frame.
      expect(ModalRoute.of(folderA)!.isCurrent, isTrue);
      expect(isMediaLibraryRouteCurrent(folderA), isFalse);
      expect(mediaLibraryRouteIsCurrent(folderA), isFalse);

      rootKey.currentState!.pop();
      await settle(tester);
      expect(isMediaLibraryRouteCurrent(folderA), isTrue);

      unawaited(
        showModalBottomSheet<void>(
          context: folderA,
          useRootNavigator: true,
          builder: (_) => const SizedBox(height: 200),
        ),
      );
      await settle(tester);
      expect(isMediaLibraryRouteCurrent(folderA), isFalse);
    });

    testWidgets('keys pressed in a player never reach the library', (
      tester,
    ) async {
      final keys = <LogicalKeyboardKey>[];
      await pumpShell(tester, const _Page('home'));
      unawaited(
        Navigator.of(contextOf(tester, 'home')).push(
          MaterialPageRoute<void>(builder: (_) => _KeyedPage(onKey: keys.add)),
        ),
      );
      await settle(tester);
      unawaited(
        pushAboveMediaLibrary(
          contextOf(tester, 'keyed'),
          MaterialPageRoute<void>(builder: (_) => const _Page('player')),
        ),
      );
      await settle(tester);

      for (final key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await settle(tester);
      expect(keys, isEmpty);
      expect(find.text('player'), findsOneWidget);

      rootKey.currentState!.pop();
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(keys, <LogicalKeyboardKey>[LogicalKeyboardKey.space]);
    });

    testWidgets('outside a frame a page falls back to its own route', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: _Page('alone')));
      final alone = contextOf(tester, 'alone');
      expect(isMediaLibraryRouteCurrent(alone), isTrue);
      expect(MediaLibraryShell.maybeOf(alone), isNull);
      expect(mediaLibraryCoverNavigator(alone), same(Navigator.of(alone)));
    });
  });

  group('file drop cover', () {
    testWidgets('dims the card above the page while files are dragged', (
      tester,
    ) async {
      await pumpShell(tester, const _Page('home'));
      final shell = MediaLibraryShell.maybeOf(contextOf(tester, 'home'))!;
      final cover = find.byKey(MediaLibraryShell.miniPlayerDropCoverKey);
      expect(cover, findsNothing);

      final owner = Object();
      shell.setFileDropActive(owner, true);
      await tester.pump();
      expect(cover, findsOneWidget);
      expect(tester.getRect(cover), tester.getRect(card));
      final center = tester.getCenter(card);
      expect(hits(tester, center, card), isTrue);

      shell.setFileDropActive(owner, false);
      await tester.pump();
      expect(cover, findsNothing);
    });
  });
}
