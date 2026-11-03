import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/media_library_virtual_selection_actions.dart';

void main() {
  test('continue pins only offer unpin export recycle', () {
    final actions = MediaLibraryVirtualSelectionActions.forContinueLearning(
      selectedIds: {'a', 'b'},
      pinnedIds: {'a', 'b', 'c'},
    );
    expect(actions.map((action) => action.kind).toList(), [
      MediaLibraryVirtualSelectionActionKind.unpin,
      MediaLibraryVirtualSelectionActionKind.export,
      MediaLibraryVirtualSelectionActionKind.recycle,
    ]);
  });

  test('continue records offer hide and pin', () {
    final actions = MediaLibraryVirtualSelectionActions.forContinueLearning(
      selectedIds: {'clip'},
      pinnedIds: const <String>{},
    );
    expect(actions.map((action) => action.kind).toList(), [
      MediaLibraryVirtualSelectionActionKind.hideContinue,
      MediaLibraryVirtualSelectionActionKind.pin,
      MediaLibraryVirtualSelectionActionKind.export,
      MediaLibraryVirtualSelectionActionKind.recycle,
      MediaLibraryVirtualSelectionActionKind.rename,
    ]);
  });

  test('continue cross-selection drops hide and pin', () {
    final actions = MediaLibraryVirtualSelectionActions.forContinueLearning(
      selectedIds: {'pin', 'clip'},
      pinnedIds: {'pin'},
    );
    expect(actions.map((action) => action.kind).toList(), [
      MediaLibraryVirtualSelectionActionKind.export,
      MediaLibraryVirtualSelectionActionKind.recycle,
    ]);
  });

  test('recent always dismisses and pins only when uniform', () {
    final mixed = MediaLibraryVirtualSelectionActions.forRecentAdded(
      selectedIds: {'a', 'b'},
      pinnedIds: {'a'},
    );
    expect(mixed.map((action) => action.kind).toList(), [
      MediaLibraryVirtualSelectionActionKind.dismissRecent,
      MediaLibraryVirtualSelectionActionKind.export,
      MediaLibraryVirtualSelectionActionKind.recycle,
    ]);

    final unpinned = MediaLibraryVirtualSelectionActions.forRecentAdded(
      selectedIds: {'a', 'b'},
      pinnedIds: const <String>{},
    );
    expect(
      unpinned.map((action) => action.kind),
      contains(MediaLibraryVirtualSelectionActionKind.pin),
    );
  });
}
