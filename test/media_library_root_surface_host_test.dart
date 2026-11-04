import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_root_surface_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'stale online entries and orders only mount the three local surfaces',
    (tester) async {
      final inits = <String, int>{};
      final highlight = ValueNotifier<double>(0);
      addTearDown(highlight.dispose);
      var displayed = MediaLibraryRootEntry.bilibili;
      Widget host() => MaterialApp(
        home: Scaffold(
          body: MediaLibraryRootSurfaceHost(
            displayedEntry: displayed,
            entryOrder: const [
              MediaLibraryRootEntry.cloudDrive,
              MediaLibraryRootEntry.recent,
              MediaLibraryRootEntry.podcasts,
              MediaLibraryRootEntry.recent,
            ],
            swipeHighlightIndex: highlight,
            continueBuilder: (_, _) => _InitProbe(id: 'continue', inits: inits),
            recentBuilder: (_, _) => _InitProbe(id: 'recent', inits: inits),
            foldersBuilder: (_, _) => _InitProbe(id: 'folders', inits: inits),
          ),
        ),
      );
      for (final retired in [
        MediaLibraryRootEntry.bilibili,
        MediaLibraryRootEntry.podcasts,
        MediaLibraryRootEntry.cloudDrive,
      ]) {
        displayed = retired;
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();
        expect(
          find
              .byKey(
                const ValueKey<MediaLibraryRootEntry>(
                  MediaLibraryRootEntry.folders,
                ),
              )
              .hitTestable(),
          findsOneWidget,
        );
        expect(highlight.value, 2);
        for (final remote in MediaLibraryRootEntry.values.where(
          (entry) => !entry.isLocal,
        )) {
          expect(
            find.byKey(ValueKey<MediaLibraryRootEntry>(remote)),
            findsNothing,
          );
        }
      }
      // Idle prewarming remains bounded to local pages as well.
      for (var i = 0; i < 4; i++) {
        await tester.pump(kMediaLibraryRootPrewarmDelay);
        await tester.pumpAndSettle();
      }
      expect(inits, {'folders': 1, 'recent': 1, 'continue': 1});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('initial folder highlight updates an already built title', (
    tester,
  ) async {
    final highlight = ValueNotifier<double>(0);
    addTearDown(highlight.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ValueListenableBuilder<double>(
                valueListenable: highlight,
                builder: (_, value, _) => Text('selected:$value'),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, _) => MediaLibraryRootSurfaceHost(
                    displayedEntry: MediaLibraryRootEntry.folders,
                    swipeHighlightIndex: highlight,
                    continueBuilder: (_, _) => const Text('continue'),
                    recentBuilder: (_, _) => const Text('recent'),
                    foldersBuilder: (_, _) => const Text('folders'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final folderIndex = MediaLibraryRootEntryOrder.defaults
        .indexOf(MediaLibraryRootEntry.folders)
        .toDouble();
    expect(find.text('selected:$folderIndex'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('root host keeps visited surfaces and does not build the rest', (
    tester,
  ) async {
    final inits = <String, int>{};
    var displayed = MediaLibraryRootEntry.continueLearning;

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        continueBuilder: (_, _) => _InitProbe(id: 'continue', inits: inits),
        recentBuilder: (_, _) => _InitProbe(id: 'recent', inits: inits),
        foldersBuilder: (_, _) => _InitProbe(id: 'folders', inits: inits),
      );
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();

    expect(inits['continue'], 1);
    expect(inits['recent'], isNull);
    expect(inits['folders'], isNull);

    displayed = MediaLibraryRootEntry.recent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(inits['continue'], 1);
    expect(inits['recent'], 1);
    expect(inits['folders'], isNull);

    displayed = MediaLibraryRootEntry.continueLearning;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(inits['continue'], 1);
    expect(inits['recent'], 1);
    expect(inits['folders'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden surfaces are not rebuilt on later parent ticks', (
    tester,
  ) async {
    var continueBuilds = 0;
    var recentBuilds = 0;
    var displayed = MediaLibraryRootEntry.continueLearning;
    var tick = 0;

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        continueBuilder: (_, _) {
          continueBuilds++;
          return Text('c$tick');
        },
        recentBuilder: (_, _) {
          recentBuilds++;
          return Text('r$tick');
        },
        foldersBuilder: (_, _) => const SizedBox.shrink(),
      );
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    expect(continueBuilds, 1);
    expect(recentBuilds, 0);

    displayed = MediaLibraryRootEntry.recent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(recentBuilds, greaterThanOrEqualTo(1));
    final continueAfterSwitch = continueBuilds;

    tick = 1;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    expect(continueBuilds, continueAfterSwitch);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inactive freeze ignores replacement children', (tester) async {
    var builds = 0;
    var active = true;
    var generation = 0;

    Widget tree() {
      return MediaLibraryFrozenWhenInactive(
        active: active,
        child: _BuildProbe(generation: generation, onBuild: () => builds++),
      );
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: tree())));
    await tester.pump();
    expect(builds, 1);

    generation = 1;
    active = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: tree())));
    await tester.pump();
    expect(builds, 1);

    generation = 2;
    active = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: tree())));
    await tester.pump();
    expect(builds, 2);
  });

  test(
    'saveMediaLibraryRootChoice notifies once and skips anchor notify',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();

      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.saveMediaLibraryRootChoice('recent');
      expect(notifications, 1);
      expect(settings.mediaLibraryRootEntry, 'recent');
      expect(settings.mediaLibraryRootEntryUserChosen, isTrue);

      await settings.saveMediaLibraryEntryAnchors('{"recent":{"offset":12}}');
      expect(notifications, 1);
      expect(settings.mediaLibraryEntryAnchors, '{"recent":{"offset":12}}');

      await settings.saveMediaLibraryRootChoice('folders', notify: false);
      expect(notifications, 1);
      expect(settings.mediaLibraryRootEntry, 'folders');
    },
  );

  testWidgets('touch fling opens the next tab, mouse drag does not', (
    tester,
  ) async {
    var displayed = MediaLibraryRootEntry.continueLearning;
    MediaLibraryRootEntry? swiped;

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        onUserSwipe: (entry) {
          swiped = entry;
          displayed = entry;
        },
        continueBuilder: (_, _) => const Center(child: Text('continue')),
        recentBuilder: (_, _) => const Center(child: Text('recent')),
        foldersBuilder: (_, _) => const Center(child: Text('folders')),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 400, height: 640, child: host())),
      ),
    );
    await tester.pump();
    expect(find.text('continue'), findsOneWidget);

    final origin = tester.getCenter(find.text('continue'));
    final mouse = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(-220, 0));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(swiped, isNull);
    expect(find.text('recent'), findsNothing);

    await tester.fling(find.text('continue'), const Offset(-240, 0), 1800);
    await tester.pumpAndSettle();
    expect(swiped, MediaLibraryRootEntry.folders);
  });

  testWidgets('a reverse fling during snap is not dropped', (tester) async {
    var displayed = MediaLibraryRootEntry.continueLearning;
    final swiped = <MediaLibraryRootEntry>[];

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        onUserSwipe: (entry) {
          swiped.add(entry);
          displayed = entry;
        },
        continueBuilder: (_, _) => const Center(child: Text('continue')),
        recentBuilder: (_, _) => const Center(child: Text('recent')),
        foldersBuilder: (_, _) => const Center(child: Text('folders')),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 400, height: 640, child: host())),
      ),
    );
    await tester.pump();

    await tester.fling(
      find.byType(MediaLibraryRootSurfaceHost),
      const Offset(-240, 0),
      1800,
    );
    await tester.pump(const Duration(milliseconds: 40));
    await tester.fling(
      find.byType(MediaLibraryRootSurfaceHost),
      const Offset(240, 0),
      1800,
    );
    await tester.pumpAndSettle();
    expect(displayed, MediaLibraryRootEntry.continueLearning);
    expect(swiped, isNot(contains(MediaLibraryRootEntry.folders)));
  });

  testWidgets('a follow-up swipe near the end of a snap opens the next page', (
    tester,
  ) async {
    var displayed = MediaLibraryRootEntry.continueLearning;
    final swiped = <MediaLibraryRootEntry>[];

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        onUserSwipe: (entry) {
          swiped.add(entry);
          displayed = entry;
        },
        continueBuilder: (_, _) => const Center(child: Text('continue')),
        recentBuilder: (_, _) => const Center(child: Text('recent')),
        foldersBuilder: (_, _) => const Center(child: Text('folders')),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 400, height: 640, child: host())),
      ),
    );
    await tester.pump();

    await tester.fling(
      find.byType(MediaLibraryRootSurfaceHost),
      const Offset(-240, 0),
      1800,
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(swiped, isEmpty);
    await tester.fling(
      find.byType(MediaLibraryRootSurfaceHost),
      const Offset(-280, 0),
      1800,
    );
    await tester.pumpAndSettle();
    expect(displayed, MediaLibraryRootEntry.recent);
    expect(swiped, contains(MediaLibraryRootEntry.recent));
  });

  for (final width in [400.0, 800.0]) {
    for (final delay in [80, 150, 240, 300]) {
      for (final forward in [true, false]) {
        testWidgets('short follow-up flick is kept at ${width}px, ${delay}ms, '
            '${forward ? 'forward' : 'backward'}', (tester) async {
          final order = MediaLibraryRootEntryOrder.defaults;
          final state = await _pumpSwipeHost(
            tester,
            width: width,
            initial: forward ? order.first : order.last,
          );
          final direction = forward ? -1.0 : 1.0;
          final host = find.byType(MediaLibraryRootSurfaceHost);
          await tester.fling(host, Offset(direction * 160, 0), 1800);
          await tester.pump();
          await tester.pump(Duration(milliseconds: delay));
          await _shortFlick(tester, direction * 40);
          await tester.pumpAndSettle();

          final expected = order[forward ? 2 : order.length - 3];
          expect(state.displayed, expected);
          expect(state.highlight.value, order.indexOf(expected).toDouble());
          expect(state.settled.value, isTrue);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final vertical in [false, true]) {
    testWidgets(
      '${vertical ? 'vertical scroll' : 'tap'} during snap keeps committed page',
      (tester) async {
        final state = await _pumpSwipeHost(tester);
        final host = find.byType(MediaLibraryRootSurfaceHost);
        await tester.fling(host, const Offset(-160, 0), 1800);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final before = state.highlight.value;
        if (vertical) {
          await tester.drag(host, const Offset(0, -100));
        } else {
          await tester.tap(host);
        }
        // No time has elapsed: a rejected pointer must not finish the snap
        // immediately or snap it back toward its old origin.
        expect(state.highlight.value, closeTo(before, 0.001));
        await tester.pumpAndSettle();
        expect(state.displayed, MediaLibraryRootEntry.folders);
        expect(state.highlight.value, 1);
        expect(state.settled.value, isTrue);
      },
    );
  }

  testWidgets('a slow follow-up drag uses its own commit distance', (
    tester,
  ) async {
    final state = await _pumpSwipeHost(tester);
    final host = find.byType(MediaLibraryRootSurfaceHost);
    await tester.fling(host, const Offset(-160, 0), 1800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.timedDrag(
      host,
      const Offset(-150, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(state.displayed, MediaLibraryRootEntry.recent);
    expect(state.highlight.value, 2);
  });

  testWidgets('a late reverse flick returns to the previous page', (
    tester,
  ) async {
    final state = await _pumpSwipeHost(tester);
    final host = find.byType(MediaLibraryRootSurfaceHost);
    await tester.fling(host, const Offset(-160, 0), 1800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await _shortFlick(tester, 40);
    await tester.pumpAndSettle();
    expect(state.displayed, MediaLibraryRootEntry.continueLearning);
    expect(state.highlight.value, 0);
    expect(state.settled.value, isTrue);
  });

  testWidgets('a pointer can cross snap completion before its first move', (
    tester,
  ) async {
    final state = await _pumpSwipeHost(tester);
    final host = find.byType(MediaLibraryRootSurfaceHost);
    await tester.fling(host, const Offset(-160, 0), 1800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    final gesture = await tester.startGesture(tester.getCenter(host));
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.displayed, MediaLibraryRootEntry.folders);
    for (var i = 1; i <= 4; i++) {
      await gesture.moveBy(
        const Offset(-10, 0),
        timeStamp: Duration(milliseconds: 100 + i * 5),
      );
      await tester.pump(const Duration(milliseconds: 5));
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 125));
    await tester.pumpAndSettle();
    expect(state.displayed, MediaLibraryRootEntry.recent);
    expect(state.highlight.value, 2);
    expect(state.settled.value, isTrue);
  });

  testWidgets('vertical list scrolling keeps the gesture arena', (
    tester,
  ) async {
    final controller = ScrollController();
    final state = await _pumpSwipeHost(tester, scrollController: controller);
    addTearDown(controller.dispose);
    await tester.drag(
      find.byType(MediaLibraryRootSurfaceHost),
      const Offset(4, -120),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(80));
    expect(state.displayed, MediaLibraryRootEntry.continueLearning);
    expect(state.highlight.value, 0);
    expect(state.settled.value, isTrue);
  });

  testWidgets('chained flicks reach the last page and stop at the edge', (
    tester,
  ) async {
    final state = await _pumpSwipeHost(tester);
    final host = find.byType(MediaLibraryRootSurfaceHost);
    await tester.fling(host, const Offset(-160, 0), 1800);
    for (var i = 0; i < MediaLibraryRootEntryOrder.defaults.length - 2; i++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await _shortFlick(tester, -40);
    }
    await tester.pumpAndSettle();
    expect(state.displayed, MediaLibraryRootEntry.recent);
    await _shortFlick(tester, -40);
    await tester.pumpAndSettle();
    expect(state.displayed, MediaLibraryRootEntry.recent);
    expect(
      state.highlight.value,
      MediaLibraryRootEntryOrder.defaults.length - 1,
    );
    expect(state.settled.value, isTrue);
  });

  testWidgets('snap handoff preserves position and the first drag delta', (
    tester,
  ) async {
    final state = await _pumpSwipeHost(tester);
    final host = find.byType(MediaLibraryRootSurfaceHost);
    await tester.fling(host, const Offset(-160, 0), 1800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final before = state.highlight.value;
    final gesture = await tester.startGesture(tester.getCenter(host));
    await gesture.moveBy(const Offset(-10, 0));
    await tester.pump();
    expect(state.highlight.value, closeTo(before + 10 / 400, 0.001));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.displayed, MediaLibraryRootEntry.folders);
    expect(state.settled.value, isTrue);
  });

  testWidgets('a halfway drag that flicks back returns to the current tab', (
    tester,
  ) async {
    var displayed = MediaLibraryRootEntry.folders;
    MediaLibraryRootEntry? swiped;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 640,
            child: MediaLibraryRootSurfaceHost(
              displayedEntry: displayed,
              onUserSwipe: (entry) {
                swiped = entry;
                displayed = entry;
              },
              continueBuilder: (_, _) => const Center(child: Text('continue')),
              recentBuilder: (_, _) => const Center(child: Text('recent')),
              foldersBuilder: (_, _) => const Center(child: Text('folders')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final origin = tester.getCenter(find.text('folders'));
    final gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(
      const Offset(-240, 0),
      timeStamp: const Duration(milliseconds: 280),
    );
    await gesture.moveBy(
      const Offset(28, 0),
      timeStamp: const Duration(milliseconds: 296),
    );
    await gesture.moveBy(
      const Offset(28, 0),
      timeStamp: const Duration(milliseconds: 312),
    );
    await gesture.moveBy(
      const Offset(28, 0),
      timeStamp: const Duration(milliseconds: 328),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 340));
    await tester.pumpAndSettle();

    expect(swiped, isNull);
    expect(displayed, MediaLibraryRootEntry.folders);
  });

  testWidgets('touch drag publishes a fractional chip highlight', (
    tester,
  ) async {
    final highlight = ValueNotifier<double>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 640,
            child: MediaLibraryRootSurfaceHost(
              displayedEntry: MediaLibraryRootEntry.continueLearning,
              swipeHighlightIndex: highlight,
              continueBuilder: (_, _) => const Center(child: Text('continue')),
              recentBuilder: (_, _) => const Center(child: Text('recent')),
              foldersBuilder: (_, _) => const Center(child: Text('folders')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final origin = tester.getCenter(find.text('continue'));
    final gesture = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    expect(highlight.value, closeTo(0.4, 0.08));
    expect(find.text('folders'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('rapid swipes keep the chip highlight on the open page', (
    tester,
  ) async {
    var displayed = MediaLibraryRootEntry.continueLearning;
    final highlight = ValueNotifier<double>(0);
    final order = MediaLibraryRootEntryOrder.defaults;
    tester.view.physicalSize = const Size(400, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Widget page(String label) => Center(child: Text(label));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: highlight,
                    builder: (context, value, _) {
                      return MediaLibraryEntrySwitcher(
                        selected: displayed,
                        highlightIndex: value,
                        entries: order,
                        availableEntries: order.toSet(),
                        onSelected: (entry) =>
                            setState(() => displayed = entry),
                      );
                    },
                  ),
                  Expanded(
                    child: MediaLibraryRootSurfaceHost(
                      displayedEntry: displayed,
                      entryOrder: order,
                      swipeHighlightIndex: highlight,
                      onUserSwipe: (entry) => setState(() => displayed = entry),
                      continueBuilder: (_, _) => page('continue'),
                      foldersBuilder: (_, _) => page('folders'),
                      recentBuilder: (_, _) => page('recent'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      const Offset(200, 320),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-900, 0));
    await tester.pump();
    expect(highlight.value, greaterThan(1.5));
    Color? chip(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;
    expect(chip('继续学习'), Color.lerp(AppTokens.text3, AppTokens.text1, 0));
    expect(
      chip('最近添加')!.computeLuminance(),
      greaterThan(chip('继续学习')!.computeLuminance()),
    );

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 40));
    final follow = await tester.startGesture(
      const Offset(200, 320),
      kind: PointerDeviceKind.touch,
    );
    await follow.moveBy(const Offset(-280, 0));
    await follow.up();
    await tester.pumpAndSettle();

    final index = order.indexOf(displayed).toDouble();
    expect(index, greaterThan(1));
    expect(highlight.value, closeTo(index, 0.05));
    expect(
      chip(displayed.label),
      Color.lerp(AppTokens.text3, AppTokens.text1, 1),
    );
  });

  testWidgets('a folder page warmed while hidden is hittable after the fling', (
    tester,
  ) async {
    var displayed = MediaLibraryRootEntry.continueLearning;

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        onUserSwipe: (entry) {
          displayed = entry;
        },
        continueBuilder: (_, _) => const Center(child: Text('continue')),
        recentBuilder: (_, _) => const Center(child: Text('recent')),
        foldersBuilder: (_, _) => const Center(child: Text('folders')),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 400, height: 640, child: host())),
      ),
    );
    await tester.pump();
    await tester.pump(kMediaLibraryRootPrewarmDelay);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.fling(
      find.byType(MediaLibraryRootSurfaceHost),
      const Offset(-240, 0),
      1800,
    );
    await tester.pumpAndSettle();

    expect(displayed, MediaLibraryRootEntry.folders);
    final folders = find.text('folders');
    expect(folders, findsOneWidget);
    expect(tester.getCenter(folders).dx, inInclusiveRange(120, 280));
    final foldersBox = tester.renderObject(folders);
    final hit = tester.hitTestOnBinding(tester.getCenter(folders));
    expect(
      hit.path.any((HitTestEntry entry) => entry.target == foldersBox),
      isTrue,
    );
  });

  testWidgets('a root switch fades the previous page fully out', (
    tester,
  ) async {
    var displayed = MediaLibraryRootEntry.continueLearning;

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        continueBuilder: (_, _) =>
            const ColoredBox(color: Color(0xFF111111), child: Text('continue')),
        recentBuilder: (_, _) =>
            const ColoredBox(color: Color(0xFF222222), child: Text('recent')),
        foldersBuilder: (_, _) => const SizedBox.shrink(),
      );
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    expect(find.text('continue'), findsOneWidget);

    displayed = MediaLibraryRootEntry.recent;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(kMediaLibraryRootFadeDuration);
    await tester.pump();

    expect(find.text('recent'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final alphas = _pageAlphas(tester);
    expect(alphas.where((alpha) => alpha == 255), isNotEmpty);
    expect(alphas.where((alpha) => alpha == 0), isNotEmpty);
    expect(alphas.every((alpha) => alpha == 0 || alpha == 255), isTrue);
  });

  testWidgets('fade-in repaints the warmed folder on the opaque frame', (
    tester,
  ) async {
    var displayed = MediaLibraryRootEntry.continueLearning;
    final paintedAlphas = <int>[];
    debugMediaLibrarySurfacePaintAlpha = paintedAlphas.add;
    addTearDown(() => debugMediaLibrarySurfacePaintAlpha = null);

    Widget host() {
      return MediaLibraryRootSurfaceHost(
        displayedEntry: displayed,
        continueBuilder: (_, _) => const Center(child: Text('continue')),
        recentBuilder: (_, _) => const SizedBox.shrink(),
        foldersBuilder: (_, _) => const ColoredBox(color: Color(0xFF224466)),
      );
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    // The prewarm timer only queues a post-frame callback. A later frame has
    // to run it, then the hidden folder page needs its layout and raster
    // frames before a tap can fade a page that is already warm.
    await tester.pump(kMediaLibraryRootPrewarmDelay);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    paintedAlphas.clear();

    displayed = MediaLibraryRootEntry.folders;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: host())));
    for (var i = 0; i < 8 && !paintedAlphas.any((a) => a > 0 && a < 255); i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(paintedAlphas.any((alpha) => alpha > 0 && alpha < 255), isTrue);
    final afterPartialFade = paintedAlphas.length;

    await tester.pump(const Duration(milliseconds: 200));
    // A low-alpha first frame used to set the retained picture. The opaque
    // frame then only retinted that empty texture.
    expect(paintedAlphas.length, greaterThan(afterPartialFade));
    expect(paintedAlphas.last, 255);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a library update during the active prewarm frame is kept when hidden',
    (tester) async {
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      var active = true;
      var label = 'empty';

      Widget tree() {
        return MediaLibraryFrozenWhenInactive(
          active: active,
          changes: changes,
          child: Text(label, textDirection: TextDirection.ltr),
        );
      }

      await tester.pumpWidget(tree());
      expect(find.text('empty'), findsOneWidget);

      // Same order as startup: notify while the prewarm frame is still
      // active, then the next frame drops the page back to inactive.
      changes.notifyListeners();
      label = 'loaded';
      active = false;
      await tester.pumpWidget(tree());
      expect(find.text('loaded'), findsOneWidget);
      expect(find.text('empty'), findsNothing);

      active = true;
      await tester.pumpWidget(tree());
      expect(find.text('loaded'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _shortFlick(WidgetTester tester, double dx) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(MediaLibraryRootSurfaceHost)),
  );
  for (var i = 1; i <= 4; i++) {
    await gesture.moveBy(
      Offset(dx / 4, 0),
      timeStamp: Duration(milliseconds: i * 5),
    );
    await tester.pump(const Duration(milliseconds: 5));
  }
  await gesture.up(timeStamp: const Duration(milliseconds: 25));
}

class _SwipeHostState {
  _SwipeHostState(this.displayed);

  MediaLibraryRootEntry displayed;
  final highlight = ValueNotifier<double>(0);
  final settled = ValueNotifier<bool>(true);
}

Future<_SwipeHostState> _pumpSwipeHost(
  WidgetTester tester, {
  double width = 400,
  MediaLibraryRootEntry initial = MediaLibraryRootEntry.continueLearning,
  ScrollController? scrollController,
}) async {
  tester.view.physicalSize = Size(width, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = _SwipeHostState(initial);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => MediaLibraryRootSurfaceHost(
            displayedEntry: state.displayed,
            swipeHighlightIndex: state.highlight,
            swipeSettled: state.settled,
            onUserSwipe: (entry) => setState(() => state.displayed = entry),
            continueBuilder: (_, _) => scrollController == null
                ? const Center(child: Text('continue'))
                : ListView(
                    controller: scrollController,
                    children: [
                      for (var i = 0; i < 40; i++)
                        SizedBox(height: 64, child: Text('item $i')),
                    ],
                  ),
            foldersBuilder: (_, _) => const Center(child: Text('folders')),
            recentBuilder: (_, _) => const Center(child: Text('recent')),
          ),
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.highlight.dispose();
    state.settled.dispose();
  });
  await tester.pump();
  return state;
}

List<int> _pageAlphas(WidgetTester tester) {
  final alphas = <int>[];
  void visit(RenderObject object) {
    final layer = object.debugLayer;
    if (layer is OpacityLayer && layer.alpha != null) {
      alphas.add(layer.alpha!);
    }
    object.visitChildren(visit);
  }

  visit(tester.renderObject(find.byType(MediaLibraryRootSurfaceHost)));
  return alphas;
}

class _InitProbe extends StatefulWidget {
  const _InitProbe({required this.id, required this.inits});

  final String id;
  final Map<String, int> inits;

  @override
  State<_InitProbe> createState() => _InitProbeState();
}

class _InitProbeState extends State<_InitProbe> {
  @override
  void initState() {
    super.initState();
    widget.inits[widget.id] = (widget.inits[widget.id] ?? 0) + 1;
  }

  @override
  Widget build(BuildContext context) {
    return Text(widget.id);
  }
}

class _BuildProbe extends StatelessWidget {
  const _BuildProbe({required this.generation, required this.onBuild});

  final int generation;
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return Text('g$generation');
  }
}
