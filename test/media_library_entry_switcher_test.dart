import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'selects on pointer down so a short click is not waiting on splash',
    (tester) async {
      MediaLibraryRootEntry selected = MediaLibraryRootEntry.folders;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: MediaLibraryEntrySwitcher(
                selected: selected,
                availableEntries: MediaLibraryRootEntry.values.toSet(),
                onSelected: (entry) => selected = entry,
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('最近添加')),
      );
      await tester.pump();
      expect(selected, MediaLibraryRootEntry.recent);

      await gesture.up();
      await tester.pump();
      expect(selected, MediaLibraryRootEntry.recent);
      expect(find.byType(InkWell), findsNothing);
    },
  );

  testWidgets('padding around the label is still tappable', (tester) async {
    MediaLibraryRootEntry selected = MediaLibraryRootEntry.folders;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibraryEntrySwitcher(
              selected: selected,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              onSelected: (entry) => selected = entry,
            ),
          ),
        ),
      ),
    );

    final label = tester.getRect(find.text('最近添加'));
    await tester.tapAt(Offset(label.center.dx, label.top - 5));
    await tester.pump();
    expect(selected, MediaLibraryRootEntry.recent);
  });

  testWidgets('fractional highlight paints the neighbor chip', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibraryEntrySwitcher(
              selected: MediaLibraryRootEntry.continueLearning,
              highlightIndex: 1,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    final foldersChip = tester.widget<Text>(find.text('文件夹'));
    final continueChip = tester.widget<Text>(find.text('继续学习'));
    expect(
      foldersChip.style?.color,
      Color.lerp(AppTokens.text3, AppTokens.text1, 1),
    );
    expect(
      continueChip.style?.color,
      Color.lerp(AppTokens.text3, AppTokens.text1, 0),
    );
  });

  testWidgets('a highlight more than one page away is not snapped back', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibraryEntrySwitcher(
              selected: MediaLibraryRootEntry.continueLearning,
              highlightIndex: 2.5,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    Color? colorOf(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;
    final recent = colorOf('最近添加');
    final bilibili = colorOf('哔哩哔哩');
    final start = colorOf('继续学习');
    expect(recent, Color.lerp(AppTokens.text3, AppTokens.text1, 0.5));
    expect(bilibili, recent);
    expect(start, Color.lerp(AppTokens.text3, AppTokens.text1, 0));
  });

  testWidgets('default chip order puts folders between the activity pages', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibraryEntrySwitcher(
              selected: MediaLibraryRootEntry.folders,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    final continueX = tester.getTopLeft(find.text('继续学习')).dx;
    final foldersX = tester.getTopLeft(find.text('文件夹')).dx;
    final recentX = tester.getTopLeft(find.text('最近添加')).dx;
    expect(continueX < foldersX, isTrue);
    expect(foldersX < recentX, isTrue);
  });

  testWidgets('swipe highlight does not shift chip positions', (tester) async {
    Future<List<double>> pumpHighlight(double highlight) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: MediaLibraryEntrySwitcher(
                selected: MediaLibraryRootEntry.continueLearning,
                highlightIndex: highlight,
                availableEntries: MediaLibraryRootEntry.values.toSet(),
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return [
        tester.getTopLeft(find.text('继续学习')).dx,
        tester.getTopLeft(find.text('文件夹')).dx,
        tester.getTopLeft(find.text('最近添加')).dx,
      ];
    }

    final rest = await pumpHighlight(0);
    final mid = await pumpHighlight(0.5);
    expect(mid[0], closeTo(rest[0], 0.5));
    expect(mid[1], closeTo(rest[1], 0.5));
    expect(mid[2], closeTo(rest[2], 0.5));
  });

  testWidgets(
    'overflow uses the full width and swipes without changing destination',
    (tester) async {
      var selections = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 180,
                height: 48,
                child: MediaLibraryEntrySwitcher(
                  selected: MediaLibraryRootEntry.continueLearning,
                  availableEntries: MediaLibraryRootEntry.values.toSet(),
                  onSelected: (_) => selections++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final switcher = find.byType(MediaLibraryEntrySwitcher);
      final scrollable = find.descendant(
        of: switcher,
        matching: find.byType(Scrollable),
      );
      expect(tester.getSize(scrollable).width, 180);
      expect(
        tester.getTopLeft(find.text('继续学习')).dx,
        tester.getTopLeft(switcher).dx,
      );
      expect(find.byType(IconButton), findsNothing);
      final state = tester.state<ScrollableState>(scrollable);
      await tester.drag(switcher, const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(state.position.pixels, greaterThan(0));
      final before = state.position.pixels;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(switcher),
          scrollDelta: const Offset(0, -80),
        ),
      );
      await tester.pumpAndSettle();
      expect(state.position.pixels, lessThan(before));
      expect(selections, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long pressing then dragging reorders a chip', (tester) async {
    var order = List<MediaLibraryRootEntry>.of(
      MediaLibraryRootEntryOrder.defaults,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              height: 48,
              child: MediaLibraryEntrySwitcher(
                selected: MediaLibraryRootEntry.folders,
                availableEntries: MediaLibraryRootEntry.values.toSet(),
                entries: order,
                reorderEnabled: true,
                onReorder: (oldIndex, newIndex) {
                  order = MediaLibraryRootEntryOrder.moved(
                    order,
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                  );
                },
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final start = tester.getCenter(find.text('文件夹'));
    final firstLabel = tester.getRect(find.text('继续学习'));
    final target = firstLabel.center;
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // Cross the first chip's insertion zone before releasing over its label.
    // Its flush leading label can be narrower than the dragged chip's proxy.
    await gesture.moveTo(Offset(firstLabel.right - 1, target.dy));
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(order.first, MediaLibraryRootEntry.folders);
  });

  testWidgets('dragging an unselected chip reorders without switching', (
    tester,
  ) async {
    MediaLibraryRootEntry selected = MediaLibraryRootEntry.folders;
    var order = List<MediaLibraryRootEntry>.of(
      MediaLibraryRootEntryOrder.defaults,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              height: 48,
              child: MediaLibraryEntrySwitcher(
                selected: selected,
                availableEntries: MediaLibraryRootEntry.values.toSet(),
                entries: order,
                reorderEnabled: true,
                onReorder: (oldIndex, newIndex) {
                  order = MediaLibraryRootEntryOrder.moved(
                    order,
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                  );
                },
                onSelected: (entry) => selected = entry,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('最近添加')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(selected, MediaLibraryRootEntry.folders);

    await tester.pump(const Duration(milliseconds: 600));
    final firstLabel = tester.getRect(find.text('继续学习'));
    final target = firstLabel.center;
    await gesture.moveTo(Offset(firstLabel.right - 1, target.dy));
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, MediaLibraryRootEntry.folders);
    expect(order.first, MediaLibraryRootEntry.recent);
  });

  testWidgets('a short horizontal slip does not reorder the chips', (
    tester,
  ) async {
    var order = List<MediaLibraryRootEntry>.of(
      MediaLibraryRootEntryOrder.defaults,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              height: 48,
              child: MediaLibraryEntrySwitcher(
                selected: MediaLibraryRootEntry.folders,
                availableEntries: MediaLibraryRootEntry.values.toSet(),
                entries: order,
                reorderEnabled: true,
                onReorder: (oldIndex, newIndex) {
                  order = MediaLibraryRootEntryOrder.moved(
                    order,
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                  );
                },
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('文件夹')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(order, MediaLibraryRootEntryOrder.defaults);
  });

  testWidgets('short mouse click still switches instead of reordering', (
    tester,
  ) async {
    MediaLibraryRootEntry selected = MediaLibraryRootEntry.folders;
    var order = List<MediaLibraryRootEntry>.of(
      MediaLibraryRootEntryOrder.defaults,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibraryEntrySwitcher(
              selected: selected,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              entries: order,
              reorderEnabled: true,
              onReorder: (oldIndex, newIndex) {
                order = MediaLibraryRootEntryOrder.moved(
                  order,
                  oldIndex: oldIndex,
                  newIndex: newIndex,
                );
              },
              onSelected: (entry) => selected = entry,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('最近添加'));
    await tester.pump();
    expect(selected, MediaLibraryRootEntry.recent);
    expect(order, MediaLibraryRootEntryOrder.defaults);
  });
}
