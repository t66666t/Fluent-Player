import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';

class _ReorderViewportHarness extends StatefulWidget {
  const _ReorderViewportHarness({
    required this.initialSelection,
    this.explicitHighlight = false,
  });

  final MediaLibraryRootEntry initialSelection;
  final bool explicitHighlight;

  @override
  State<_ReorderViewportHarness> createState() =>
      _ReorderViewportHarnessState();
}

class _ReorderViewportHarnessState extends State<_ReorderViewportHarness> {
  late MediaLibraryRootEntry selected = widget.initialSelection;
  var order = List<MediaLibraryRootEntry>.of(
    MediaLibraryRootEntryOrder.defaults,
  );
  double? swipeHighlight;

  void highlight(double value) => setState(() => swipeHighlight = value);

  void reorder(int oldIndex, int newIndex) {
    setState(() {
      order = MediaLibraryRootEntryOrder.moved(
        order,
        oldIndex: oldIndex,
        newIndex: newIndex,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 48,
            child: MediaLibraryEntrySwitcher(
              selected: selected,
              highlightIndex:
                  swipeHighlight ??
                  (widget.explicitHighlight
                      ? order.indexOf(selected).toDouble()
                      : null),
              entries: order,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              compact: true,
              reorderEnabled: true,
              onReorder: reorder,
              onSelected: (entry) => setState(() => selected = entry),
            ),
          ),
        ),
      ),
    );
  }
}

Finder get _tabScroller => find.descendant(
  of: find.byType(MediaLibraryEntrySwitcher),
  matching: find.byType(Scrollable),
);

void main() {
  for (final selected in [
    MediaLibraryRootEntry.folders,
    MediaLibraryRootEntryOrder.defaults.last,
  ]) {
    testWidgets(
      'long-press reorder preserves the viewport, selected=$selected',
      (tester) async {
        await tester.pumpWidget(
          _ReorderViewportHarness(
            initialSelection: selected,
            explicitHighlight: true,
          ),
        );
        await tester.pumpAndSettle();
        final state = tester.state<_ReorderViewportHarnessState>(
          find.byType(_ReorderViewportHarness),
        );
        final position = tester.state<ScrollableState>(_tabScroller).position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        final moved = state.order.last;
        final start = tester.getCenter(find.text(moved.label));
        final viewport = tester.getRect(find.byType(MediaLibraryEntrySwitcher));
        final target = Offset(viewport.left + 40, start.dy);
        final gesture = await tester.createGesture(
          kind: selected == MediaLibraryRootEntry.folders
              ? PointerDeviceKind.mouse
              : PointerDeviceKind.touch,
        );
        await gesture.addPointer(location: start);
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.down(start);
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 100),
        );
        await gesture.moveTo(target);
        await tester.pumpAndSettle();
        final dropOffset = position.pixels;
        expect(dropOffset, greaterThan(0));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(state.order.indexOf(moved), lessThan(state.order.length - 1));
        expect(state.selected, selected);
        expect(
          tester.state<ScrollableState>(_tabScroller).position,
          same(position),
        );
        expect(position.pixels, closeTo(dropOffset, 0.01));
        await tester.pump(const Duration(milliseconds: 500));
        expect(position.pixels, closeTo(dropOffset, 0.01));
        await gesture.removePointer();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final explicitHighlight in [false, true]) {
    testWidgets(
      'reindexing keeps the viewport and later navigation still follows, '
      'explicitHighlight=$explicitHighlight',
      (tester) async {
        await tester.pumpWidget(
          _ReorderViewportHarness(
            initialSelection: MediaLibraryRootEntry.folders,
            explicitHighlight: explicitHighlight,
          ),
        );
        await tester.pumpAndSettle();
        final state = tester.state<_ReorderViewportHarnessState>(
          find.byType(_ReorderViewportHarness),
        );
        final position = tester.state<ScrollableState>(_tabScroller).position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        final parked = position.pixels;

        // Moving a title across the current page changes its index without
        // navigating to another page, just as the home page's callback does.
        tester
            .widget<ReorderableListView>(find.byType(ReorderableListView))
            .onReorderItem!(state.order.length - 1, 0);
        await tester.pumpAndSettle();
        expect(state.order.indexOf(state.selected), 2);
        expect(position.pixels, closeTo(parked, 0.01));

        // Navigating to a different destination resumes viewport following.
        final destination = state.order[1];
        tester.widget<MediaLibraryEntrySwitcher>(
          find.byType(MediaLibraryEntrySwitcher),
        ).onSelected(destination);
        await tester.pumpAndSettle();
        expect(state.selected, destination);
        expect(position.pixels, lessThan(parked));
        state.highlight(1);
        await tester.pump();
        await tester.pump();
        final start = position.pixels;
        expect(start, lessThan(parked));
        state.highlight(1.5);
        await tester.pump();
        await tester.pump();
        expect(position.pixels, greaterThan(start));
        state.highlight(1);
        await tester.pumpAndSettle();
        expect(position.pixels, closeTo(start, 0.01));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
