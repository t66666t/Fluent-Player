import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_root_surface_host.dart';

void main() {
  const frame = Duration(microseconds: 16667);

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    for (final entry in MediaLibraryRootEntry.values) {
      testWidgets(
        '${kind.name} release fully paints cold ${entry.name} on the next frame',
        (tester) async {
          final initial = entry == MediaLibraryRootEntry.folders
              ? MediaLibraryRootEntry.recent
              : MediaLibraryRootEntry.folders;
          final state = await _pumpLibrary(tester, initial: initial);
          expect(state.initializations[entry], isNull);

          final mouse = await tester.startGesture(
            tester.getCenter(find.text(entry.label)),
            kind: kind,
          );
          await tester.pump(frame);
          // Keep release-to-select so dragging a title still only reorders it.
          expect(state.selected, initial);
          await mouse.up();
          // The callback itself has no gesture-arena or press-animation delay.
          expect(state.selected, entry);
          final paints = <int>[];
          debugMediaLibrarySurfacePaintAlpha = paints.add;
          addTearDown(() => debugMediaLibrarySurfacePaintAlpha = null);
          await tester.pump(frame);

          expect(state.selected, entry);
          expect(state.initializations[entry], 1);
          expect(state.active[entry], isTrue);
          expect(state.active[initial], isFalse);

          expect(_alphaOf(tester, entry), 255);
          expect(_alphaOf(tester, initial), 0);
          // Checking alpha alone could accept a retained but empty texture.
          expect(paints, contains(255));
          expect(paints, isNot(contains(inExclusiveRange(0, 255))));
          expect(
            find.byKey(ValueKey('surface-${entry.name}')).hitTestable(),
            findsOneWidget,
          );
          await tester.pump(kMediaLibraryRootFadeDuration);
          expect(_alphaOf(tester, entry), 255);
          expect(_alphaOf(tester, initial), 0);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('${kind.name} title drag reorders without selecting', (
      tester,
    ) async {
      final state = await _pumpLibrary(tester);
      final first = tester.getRect(find.text('继续学习'));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('最近添加')),
        kind: kind,
      );
      if (kind == PointerDeviceKind.touch) {
        await tester.pump(kLongPressTimeout + frame);
      }
      await gesture.moveTo(Offset(first.right - 1, first.center.dy));
      await tester.pump();
      await gesture.moveTo(first.center);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.selected, MediaLibraryRootEntry.folders);
      expect(state.order.first, MediaLibraryRootEntry.recent);
    });

    testWidgets('${kind.name} cancelled press does not select', (tester) async {
      final state = await _pumpLibrary(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('最近添加')),
        kind: kind,
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(state.selected, MediaLibraryRootEntry.folders);
      await _click(tester, MediaLibraryRootEntry.recent);
      await tester.pump();
      expect(state.selected, MediaLibraryRootEntry.recent);
      expect(_alphaOf(tester, MediaLibraryRootEntry.recent), 255);
    });
  }

  testWidgets('Windows spurious mouse delta cannot turn a click into reorder', (
    tester,
  ) async {
    final state = await _pumpLibrary(tester);
    final position = tester.getCenter(find.text('最近添加'));
    final gesture = await tester.startGesture(
      position,
      pointer: 741,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.updateWithCustomEvent(
      PointerMoveEvent(
        pointer: 741,
        device: 1,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
        position: position,
        delta: const Offset(500, 0),
      ),
    );
    await gesture.up();
    expect(state.selected, MediaLibraryRootEntry.recent);
    await tester.pump();
    expect(_alphaOf(tester, MediaLibraryRootEntry.recent), 255);
    expect(state.order, MediaLibraryRootEntryOrder.defaults);
  });

  testWidgets('secondary mouse button does not switch Windows tabs', (
    tester,
  ) async {
    final state = await _pumpLibrary(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('最近添加')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.selected, MediaLibraryRootEntry.folders);
    expect(state.order, MediaLibraryRootEntryOrder.defaults);
  });

  testWidgets('Windows narrow title row still scrolls without selecting', (
    tester,
  ) async {
    final state = await _pumpLibrary(tester, width: 360);
    await tester.pump();
    final recent = find.text('最近添加');
    expect(recent.hitTestable(), findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(recent));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.selected, MediaLibraryRootEntry.folders);
    expect(state.order, MediaLibraryRootEntryOrder.defaults);
  });

  testWidgets('Windows touchscreen page swipe keeps its snap animation', (
    tester,
  ) async {
    final state = await _pumpLibrary(
      tester,
      initial: MediaLibraryRootEntry.continueLearning,
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('surface-continueLearning'))),
    );
    await gesture.moveBy(const Offset(-800, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final folders = find.byKey(const ValueKey('surface-folders'));
    expect(tester.getCenter(folders).dx, greaterThan(600));
    expect(state.selected, MediaLibraryRootEntry.continueLearning);
    await tester.pumpAndSettle();
    expect(state.selected, MediaLibraryRootEntry.folders);
    expect(_alphaOf(tester, MediaLibraryRootEntry.folders), 255);
  });

  testWidgets('rapid cold clicks keep the latest page and its local state', (
    tester,
  ) async {
    final state = await _pumpLibrary(tester);
    for (final entry in [
      MediaLibraryRootEntry.bilibili,
      MediaLibraryRootEntry.podcasts,
      MediaLibraryRootEntry.cloudDrive,
    ]) {
      await _click(tester, entry);
      await tester.pump(frame);
      expect(state.active[entry], isTrue);
    }
    await tester.pumpAndSettle();
    final cloud = find.byKey(const ValueKey('surface-cloudDrive'));
    await tester.tap(cloud);
    await tester.pump();
    expect(find.text('cloudDrive:1'), findsOneWidget);

    await _click(tester, MediaLibraryRootEntry.folders);
    await tester.pumpAndSettle();
    await _click(tester, MediaLibraryRootEntry.cloudDrive);
    await tester.pump(frame);
    expect(state.active[MediaLibraryRootEntry.cloudDrive], isTrue);
    await tester.pumpAndSettle();
    expect(find.text('cloudDrive:1'), findsOneWidget);
    expect(state.initializations.values, everyElement(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a click interrupts hidden warmup without changing the target', (
    tester,
  ) async {
    final state = await _pumpLibrary(tester);
    // Run the first optional prewarm callback, but do not settle its layers.
    await tester.pump(kMediaLibraryRootPrewarmDelay);
    await tester.pump();
    await _click(tester, MediaLibraryRootEntry.cloudDrive);
    await tester.pump(frame);
    expect(state.active[MediaLibraryRootEntry.cloudDrive], isTrue);
    await tester.pumpAndSettle();
    await tester.pump(kMediaLibraryRootPrewarmDelay);
    await tester.pumpAndSettle();
    expect(state.selected, MediaLibraryRootEntry.cloudDrive);
    expect(_alphaOf(tester, MediaLibraryRootEntry.cloudDrive), 255);
    expect(state.initializations.values, everyElement(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion paints every selected entry on its first frame', (
    tester,
  ) async {
    final state = await _pumpLibrary(tester, reduceMotion: true);
    for (final entry in MediaLibraryRootEntry.values) {
      if (entry == state.selected) continue;
      await _click(tester, entry);
      await tester.pump(frame);
      expect(state.active[entry], isTrue);
      expect(_alphaOf(tester, entry), 255);
      expect(tester.takeException(), isNull);
    }
    expect(state.initializations.length, MediaLibraryRootEntry.values.length);
    expect(state.initializations.values, everyElement(1));
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('${platform.name} keeps its intended tab transition', (
      tester,
    ) async {
      await _pumpLibrary(tester, platform: platform);
      final paints = <int>[];
      if (platform == TargetPlatform.windows) {
        debugMediaLibrarySurfacePaintAlpha = paints.add;
        addTearDown(() => debugMediaLibrarySurfacePaintAlpha = null);
      }
      await _click(tester, MediaLibraryRootEntry.bilibili);
      await tester.pump();
      if (platform == TargetPlatform.windows) {
        expect(_alphaOf(tester, MediaLibraryRootEntry.bilibili), 255);
        expect(_alphaOf(tester, MediaLibraryRootEntry.folders), 0);
        expect(paints, contains(255));
      }
      await tester.pump(const Duration(milliseconds: 50));
      final incoming = _alphaOf(tester, MediaLibraryRootEntry.bilibili);
      final outgoing = _alphaOf(tester, MediaLibraryRootEntry.folders);
      if (platform == TargetPlatform.windows) {
        expect(incoming, 255);
        expect(outgoing, 0);
      } else {
        expect(incoming, closeTo(85, 1));
        expect(outgoing, closeTo(170, 1));
        expect(incoming, lessThan(255));
      }
      paints.clear();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_alphaOf(tester, MediaLibraryRootEntry.bilibili), 255);
      expect(_alphaOf(tester, MediaLibraryRootEntry.folders), 0);
      if (platform == TargetPlatform.windows) {
        // No fade keeps requesting surface paints after the first full frame.
        expect(paints, isEmpty);
      }
    });
  }
}

Future<void> _click(WidgetTester tester, MediaLibraryRootEntry entry) async {
  final mouse = await tester.startGesture(
    tester.getCenter(find.text(entry.label)),
    kind: PointerDeviceKind.mouse,
  );
  await mouse.up();
}

int _alphaOf(WidgetTester tester, MediaLibraryRootEntry entry) {
  RenderObject? render = tester.renderObject(
    find.byKey(ValueKey('surface-${entry.name}')),
  );
  while (render != null) {
    // Read the real composited alpha so a built but invisible page cannot pass.
    // ignore: invalid_use_of_protected_member
    final layer = render.layer;
    if (layer is OpacityLayer) return layer.alpha!;
    render = render.parent;
  }
  throw StateError('Missing surface opacity for $entry');
}

Future<_LibraryState> _pumpLibrary(
  WidgetTester tester, {
  MediaLibraryRootEntry initial = MediaLibraryRootEntry.folders,
  bool reduceMotion = false,
  TargetPlatform platform = TargetPlatform.windows,
  double width = 1200,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey<_LibraryState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      builder: (context, child) => reduceMotion
          ? MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : child!,
      home: _Library(key: key, initial: initial),
    ),
  );
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  return key.currentState!;
}

class _Library extends StatefulWidget {
  const _Library({super.key, required this.initial});
  final MediaLibraryRootEntry initial;

  @override
  State<_Library> createState() => _LibraryState();
}

class _LibraryState extends State<_Library> {
  late MediaLibraryRootEntry selected = widget.initial;
  List<MediaLibraryRootEntry> order = MediaLibraryRootEntryOrder.defaults;
  final initializations = <MediaLibraryRootEntry, int>{};
  final active = <MediaLibraryRootEntry, bool>{};

  Widget surface(MediaLibraryRootEntry entry, bool isActive) {
    active[entry] = isActive;
    return _Page(
      key: ValueKey(entry),
      entry: entry,
      onInit: () => initializations.update(
        entry,
        (count) => count + 1,
        ifAbsent: () => 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: MediaLibraryEntrySwitcher(
          selected: selected,
          availableEntries: MediaLibraryRootEntry.values.toSet(),
          entries: order,
          reorderEnabled: true,
          onReorder: (oldIndex, newIndex) => setState(() {
            order = MediaLibraryRootEntryOrder.moved(
              order,
              oldIndex: oldIndex,
              newIndex: newIndex,
            );
          }),
          onSelected: (entry) => setState(() => selected = entry),
        ),
      ),
      body: MediaLibraryRootSurfaceHost(
        displayedEntry: selected,
        entryOrder: order,
        onUserSwipe: (entry) => setState(() => selected = entry),
        continueBuilder: (_, active) =>
            surface(MediaLibraryRootEntry.continueLearning, active),
        recentBuilder: (_, active) =>
            surface(MediaLibraryRootEntry.recent, active),
        foldersBuilder: (_, active) =>
            surface(MediaLibraryRootEntry.folders, active),
        bilibiliBuilder: (_, active) =>
            surface(MediaLibraryRootEntry.bilibili, active),
        podcastsBuilder: (_, active) =>
            surface(MediaLibraryRootEntry.podcasts, active),
        cloudDriveBuilder: (_, active) =>
            surface(MediaLibraryRootEntry.cloudDrive, active),
      ),
    );
  }
}

class _Page extends StatefulWidget {
  const _Page({super.key, required this.entry, required this.onInit});
  final MediaLibraryRootEntry entry;
  final VoidCallback onInit;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  int count = 0;

  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      key: ValueKey('surface-${widget.entry.name}'),
      onPressed: () => setState(() => count++),
      child: Text('${widget.entry.name}:$count'),
    ),
  );
}
