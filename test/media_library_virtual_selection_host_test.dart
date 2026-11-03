import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/media_library_range_selection.dart';
import 'package:video_player_app/widgets/media_library_virtual_selection_host.dart';

void main() {
  test('mergeRange follows reading order across sections', () {
    final host = MediaLibraryVirtualSelectionHost()
      ..updateOrderedIds(const ['pin', 'clip', 'old']);
    final merged = host.mergeRange(
      snapshot: <String>{},
      startIndex: 0,
      currentIndex: 2,
    );
    expect(merged, {'pin', 'clip', 'old'});
    expect(
      MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
        snapshot: const <String>{'keep'},
        startIndex: 1,
        currentIndex: 1,
        itemCount: host.itemCount,
        idAt: host.idAt,
      ),
      {'keep', 'clip'},
    );
  });

  test('没有已布局卡片时拖选不会落到第 0 项', () {
    final host = MediaLibraryVirtualSelectionHost()
      ..updateOrderedIds(const ['a', 'b', 'c']);
    expect(host.indexForDragSelection(const Offset(12, -40)), isNull);
  });

  test('updateOrderedIds drops stale card keys', () {
    final host = MediaLibraryVirtualSelectionHost()
      ..updateOrderedIds(const ['a', 'b']);
    final keyA = host.keyFor('a');
    expect(identical(host.keyFor('a'), keyA), isTrue);
    host.updateOrderedIds(const ['b']);
    expect(host.keyFor('a'), isNot(keyA));
    expect(host.orderedIds, ['b']);
  });

  testWidgets('hitsCard uses registered global rects', (tester) async {
    final host = MediaLibraryVirtualSelectionHost()
      ..updateOrderedIds(const ['card']);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (context) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: KeyedSubtree(
                    key: host.keyFor('card'),
                    child: const SizedBox(width: 80, height: 60),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(host.hitsCard(const Offset(10, 10)), isTrue);
    expect(host.hitsCard(const Offset(200, 200)), isFalse);
    expect(host.idsOverlapping(const Rect.fromLTWH(0, 0, 40, 40)), {'card'});
  });
}
