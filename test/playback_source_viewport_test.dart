import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/playback_source_viewport.dart';
import 'package:video_player_app/widgets/bilibili_adaptive_list.dart';

void main() {
  testWidgets('portrait landscape round trip retains the original viewport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    final controller = PlaybackScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [PlaybackRouteObserver()],
        theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
        home: Builder(
          builder: (context) {
            final wide = MediaQuery.sizeOf(context).width > 500;
            return Scaffold(
              body: PlaybackGridView.builder(
                itemKey: (i) => 'item $i',
                controller: controller,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: wide ? 8 : 2,
                  mainAxisExtent: wide ? 40 : 180,
                ),
                itemCount: 40,
                itemBuilder: (_, i) => Text('item $i'),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.jumpTo(2400);
    await tester.pump();
    final before = controller.offset;
    navigator.currentState!.push(
      AppMaterialPageRoute<void>(
        settings: const RouteSettings(name: '/playback/portrait'),
        builder: (_) => const Scaffold(body: Text('portrait')),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      AppMaterialPageRoute<void>(
        settings: const RouteSettings(name: '/playback/landscape'),
        builder: (_) => const Scaffold(body: Text('landscape')),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    expect(controller.offset, closeTo(before, 1));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(before, 1));
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '$platform direct landscape returns to the same item on its first frame',
      (tester) async {
        final fixture = await _fixture(tester, platform: platform);
        fixture.controller.jumpTo(1440);
        await tester.pump();
        final before = tester
            .getTopLeft(find.byKey(const ValueKey('item-16')))
            .dy;
        fixture.open();
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(800, 400);
        await tester.pumpAndSettle();
        fixture.navigator.currentState!.pop();
        await tester.pump();
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('item-16'))).dy,
          closeTo(before, 1),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 60));
          expect(
            tester.getTopLeft(find.byKey(const ValueKey('item-16'))).dy,
            closeTo(before, 1),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final deleteAnchor in [false, true]) {
    testWidgets(
      'latest data retains ${deleteAnchor ? 'a visible neighbor' : 'the original item'}',
      (tester) async {
        final fixture = await _fixture(tester);
        fixture.controller.jumpTo(1440);
        await tester.pump();
        fixture.open();
        await tester.pumpAndSettle();
        fixture.items.value = [
          for (var i = 200; i < 208; i++) i,
          ...fixture.items.value.where((i) => !deleteAnchor || i != 16),
        ];
        await tester.pumpAndSettle();
        fixture.navigator.currentState!.pop();
        await tester.pump();
        final id = deleteAnchor ? 17 : 16;
        expect(
          tester.getTopLeft(find.byKey(ValueKey('item-$id'))).dy,
          closeTo(0, 1),
        );
        expect(fixture.items.value.first, 200);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'loading replacement and player replacement preserve the first origin',
    (tester) async {
      final fixture = await _fixture(tester);
      fixture.controller.jumpTo(1440);
      await tester.pump();
      final loading = fixture.open('/bilibili/watch-loading');
      await tester.pumpAndSettle();
      fixture.navigator.currentState!.replace(
        oldRoute: loading,
        newRoute: fixture.route('/playback/landscape'),
      );
      tester.view.physicalSize = const Size(800, 400);
      await tester.pumpAndSettle();
      final player = fixture.navigator.currentState!.widget.observers
          .whereType<PlaybackRouteObserver>()
          .single
          .topRoute!;
      fixture.navigator.currentState!.replace(
        oldRoute: player,
        newRoute: fixture.route('/playback/landscape'),
      );
      await tester.pumpAndSettle();
      fixture.navigator.currentState!.pop();
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('item-16'))).dy,
        closeTo(0, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an explicit locate overrides the return snapshot', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    fixture.controller.jumpTo(1440);
    await tester.pump();
    fixture.open();
    await tester.pumpAndSettle();
    fixture.controller.jumpTo(360);
    await tester.pump();
    fixture.navigator.currentState!.pop();
    await tester.pump();
    expect(fixture.controller.offset, closeTo(360, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('late native rotation after pop keeps the visible item', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    fixture.controller.jumpTo(1440);
    await tester.pump();
    fixture.open();
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    fixture.navigator.currentState!.pop();
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('item-16'))).dy,
      closeTo(0, 1),
    );
    tester.view.physicalSize = const Size(400, 800);
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('item-16'))).dy,
      closeTo(0, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a projection update arriving after pop keeps the visible item', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    fixture.controller.jumpTo(1440);
    await tester.pump();
    fixture.open();
    await tester.pumpAndSettle();
    fixture.navigator.currentState!.pop();
    await tester.pump();
    fixture.items.value = [
      for (var i = 200; i < 208; i++) i,
      ...fixture.items.value,
    ];
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('item-16'))).dy,
      closeTo(0, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bilibili width regrouping corrects rows before painting', (
    tester,
  ) async {
    final fixture = await _fixture(tester, bilibili: true);
    fixture.controller.jumpTo(1000);
    await tester.pump();
    final visible = find.byKey(const ValueKey('item-12'));
    final before = tester.getTopLeft(visible).dy;
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pump();
    expect(tester.getTopLeft(visible).dy, closeTo(before, 1));
    await tester.pump();
    expect(tester.getTopLeft(visible).dy, closeTo(before, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed slivers keep the same occurrence after a header grows', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    final headerHeight = ValueNotifier(80.0);
    addTearDown(fixture.controller.dispose);
    addTearDown(fixture.items.dispose);
    addTearDown(headerHeight.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: fixture.navigator,
        navigatorObservers: [PlaybackRouteObserver()],
        theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
        home: ValueListenableBuilder<double>(
          valueListenable: headerHeight,
          builder: (_, height, _) => Scaffold(
            body: CustomScrollView(
              controller: fixture.controller,
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: height)),
                for (final group in ['a', 'b'])
                  PlaybackSliverGrid(
                    regionId: group,
                    itemCount: 40,
                    itemKey: (i) => i,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: 100,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => SizedBox(key: ValueKey('$group-$i')),
                      childCount: 40,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    fixture.controller.jumpTo(2580);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(const ValueKey('b-10'))).dy;
    fixture.open();
    await tester.pumpAndSettle();
    headerHeight.value = 160;
    await tester.pumpAndSettle();
    fixture.navigator.currentState!.pop();
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('b-10'))).dy,
      closeTo(before, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested library navigator preserves its top folder', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    final inner = GlobalKey<NavigatorState>();
    addTearDown(fixture.controller.dispose);
    addTearDown(fixture.items.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: fixture.navigator,
        navigatorObservers: [PlaybackRouteObserver()],
        theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
        home: Navigator(
          key: inner,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('home')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    inner.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          body: PlaybackGridView.builder(
            controller: fixture.controller,
            padding: EdgeInsets.zero,
            itemKey: (i) => i,
            itemCount: 100,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: MediaQuery.sizeOf(context).width > 500 ? 4 : 2,
              mainAxisExtent: 180,
            ),
            itemBuilder: (_, i) => SizedBox(key: ValueKey('nested-$i')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    fixture.controller.jumpTo(1440);
    await tester.pump();
    fixture.open();
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    fixture.navigator.currentState!.pop();
    await tester.pump();
    expect(inner.currentState!.canPop(), isTrue);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('nested-16'))).dy,
      closeTo(0, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'repeated visits release their snapshots and source registrations',
    (tester) async {
      final fixture = await _fixture(tester);
      fixture.controller.jumpTo(1440);
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        fixture.open();
        await tester.pumpAndSettle();
        expect(PlaybackViewportRegistry.retainedSnapshotCount, 1);
        fixture.navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(PlaybackViewportRegistry.retainedSnapshotCount, 0);
        expect(fixture.controller.offset, closeTo(1440, 1));
      }
      await tester.pumpWidget(const SizedBox());
      expect(PlaybackViewportRegistry.registeredSourceCount, 0);
      expect(PlaybackViewportRegistry.retainedSnapshotCount, 0);
    },
  );

  testWidgets(
    'covered rotations do no thumbnail work or full-list key lookup',
    (tester) async {
      var builds = 0;
      var keyReads = 0;
      final fixture = await _fixture(
        tester,
        onItemBuilt: () => builds++,
        onKeyRead: () => keyReads++,
      );
      fixture.items.value = List.generate(10000, (i) => i);
      await tester.pump();
      fixture.controller.jumpTo(1440);
      await tester.pump();
      fixture.open();
      await tester.pumpAndSettle();
      final beforeBuilds = builds;
      final beforeReads = keyReads;
      for (var i = 0; i < 20; i++) {
        tester.view.physicalSize = i.isEven
            ? const Size(800, 400)
            : const Size(400, 800);
        await tester.pump();
      }
      expect(builds, beforeBuilds);
      expect(keyReads, beforeReads);
      fixture.navigator.currentState!.pop();
      await tester.pump();
      expect(fixture.controller.offset, closeTo(1440, 1));
      expect(keyReads - beforeReads, lessThan(16));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('variable podcast rows use the existing lazy index layout', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    final layout = ListController();
    addTearDown(fixture.controller.dispose);
    addTearDown(fixture.items.dispose);
    addTearDown(layout.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: fixture.navigator,
        navigatorObservers: [PlaybackRouteObserver()],
        theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
        home: ValueListenableBuilder<List<int>>(
          valueListenable: fixture.items,
          builder: (_, items, _) => Scaffold(
            body: CustomScrollView(
              controller: fixture.controller,
              slivers: [
                PlaybackSliverRegion(
                  regionId: 'episodes',
                  itemCount: items.length,
                  itemKey: (i) => items[i],
                  findIndex: (key) {
                    final index = items.indexOf(key as int);
                    return index < 0 ? null : index;
                  },
                  sliver: SuperSliverList.builder(
                    listController: layout,
                    itemCount: items.length,
                    findChildIndexCallback: (key) {
                      final index = items.indexOf((key as ValueKey<int>).value);
                      return index < 0 ? null : index;
                    },
                    itemBuilder: (_, i) => SizedBox(
                      key: ValueKey(items[i]),
                      height: 40.0 + items[i] % 7 * 37,
                      child: Text('episode ${items[i]}'),
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
    layout.jumpToItem(
      index: 30,
      scrollController: fixture.controller,
      alignment: 0,
    );
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.byKey(const ValueKey(30))).dy;
    fixture.open();
    await tester.pumpAndSettle();
    fixture.items.value = [
      for (var i = 200; i < 230; i++) i,
      ...fixture.items.value,
    ];
    await tester.pumpAndSettle();
    fixture.navigator.currentState!.pop();
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey(30))).dy,
      closeTo(before, 1),
    );
    expect(tester.takeException(), isNull);
  });
}

class _Fixture {
  final navigator = GlobalKey<NavigatorState>();
  final controller = PlaybackScrollController();
  final items = ValueNotifier(List.generate(100, (i) => i));

  Route<void> route(String name) => AppMaterialPageRoute<void>(
    settings: RouteSettings(name: name),
    builder: (_) => const Scaffold(body: Text('player')),
  );

  Route<void> open([String name = '/playback/landscape']) {
    final next = route(name);
    navigator.currentState!.push(next);
    return next;
  }
}

Future<_Fixture> _fixture(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  bool bilibili = false,
  VoidCallback? onItemBuilt,
  VoidCallback? onKeyRead,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.reset);
  final fixture = _Fixture();
  addTearDown(fixture.controller.dispose);
  addTearDown(fixture.items.dispose);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: fixture.navigator,
      navigatorObservers: [PlaybackRouteObserver()],
      theme: ThemeData(
        platform: platform,
        pageTransitionsTheme: appPageTransitionsTheme,
      ),
      home: ValueListenableBuilder<List<int>>(
        valueListenable: fixture.items,
        builder: (context, items, _) => Scaffold(
          body: bilibili
              ? BilibiliAdaptiveList(
                  controller: fixture.controller,
                  itemCount: items.length,
                  itemKey: (index) {
                    onKeyRead?.call();
                    return items[index];
                  },
                  itemBuilder: (_, i) {
                    onItemBuilt?.call();
                    return SizedBox(
                      height: 60 + (i % 3) * 20.0,
                      key: ValueKey('item-${items[i]}'),
                      child: Text('${items[i]}'),
                    );
                  },
                )
              : PlaybackGridView.builder(
                  controller: fixture.controller,
                  itemCount: items.length,
                  itemKey: (index) {
                    onKeyRead?.call();
                    return items[index];
                  },
                  padding: EdgeInsets.zero,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: MediaQuery.sizeOf(context).width > 500
                        ? 4
                        : 2,
                    mainAxisExtent: 180,
                  ),
                  itemBuilder: (_, i) {
                    onItemBuilt?.call();
                    return SizedBox(
                      key: ValueKey('item-${items[i]}'),
                      child: Text('${items[i]}'),
                    );
                  },
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}
