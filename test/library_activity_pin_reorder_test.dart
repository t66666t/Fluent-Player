import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dropping a later pin inserts after the target', () {
    expect(
      LibraryActivityStore.reorderVisiblePinnedIds(
        pinnedIds: const ['a', 'b', 'c'],
        visibleIds: const {'a', 'b', 'c'},
        fromVisibleIndex: 0,
        toVisibleIndex: 2,
      ),
      ['b', 'c', 'a'],
    );
  });

  test('dropping an earlier pin inserts before the target', () {
    expect(
      LibraryActivityStore.reorderVisiblePinnedIds(
        pinnedIds: const ['a', 'b', 'c'],
        visibleIds: const {'a', 'b', 'c'},
        fromVisibleIndex: 2,
        toVisibleIndex: 0,
      ),
      ['c', 'a', 'b'],
    );
  });

  test('recycled pins keep their slots while visible cards move', () {
    expect(
      LibraryActivityStore.reorderVisiblePinnedIds(
        pinnedIds: const ['a', 'hidden', 'b', 'c'],
        visibleIds: const {'a', 'b', 'c'},
        fromVisibleIndex: 0,
        toVisibleIndex: 1,
      ),
      ['b', 'hidden', 'a', 'c'],
    );
  });

  test('out-of-range or same-slot drops leave the list unchanged', () {
    const original = ['a', 'b'];
    expect(
      LibraryActivityStore.reorderVisiblePinnedIds(
        pinnedIds: original,
        visibleIds: const {'a', 'b'},
        fromVisibleIndex: 0,
        toVisibleIndex: 0,
      ),
      original,
    );
    expect(
      LibraryActivityStore.reorderVisiblePinnedIds(
        pinnedIds: original,
        visibleIds: const {'a', 'b'},
        fromVisibleIndex: 0,
        toVisibleIndex: 9,
      ),
      original,
    );
  });

  test('LibraryService pin reorder does not change folder children', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    final library = LibraryService();
    library.resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    library.seedCollectionForTesting(
      VideoCollection(
        id: 'course',
        name: 'Course',
        createTime: 1,
        childrenIds: ['ep1', 'ep2'],
      ),
    );
    library.seedVideoForTesting(
      VideoItem(
        id: 'ep1',
        path: '/tmp/ep1.mp4',
        title: 'ep1',
        durationMs: 1,
        lastUpdated: 1,
        parentId: 'course',
      ),
    );
    library.seedVideoForTesting(
      VideoItem(
        id: 'ep2',
        path: '/tmp/ep2.mp4',
        title: 'ep2',
        durationMs: 1,
        lastUpdated: 1,
        parentId: 'course',
      ),
    );
    await library.pinLibraryItem('ep1');
    await library.pinLibraryItem('ep2');
    expect(library.pinnedItemIds, ['ep2', 'ep1']);

    await library.reorderVisiblePinnedLibraryItems(0, 1);
    expect(library.pinnedItemIds, ['ep1', 'ep2']);
    expect(library.getCollection('course')!.childrenIds, ['ep1', 'ep2']);
  });
}
