import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_swipe_policy.dart';

void main() {
  test('only touch and stylus may swipe between library tabs', () {
    expect(
      MediaLibraryRootSwipePolicy.isEligiblePointer(PointerDeviceKind.touch),
      isTrue,
    );
    expect(
      MediaLibraryRootSwipePolicy.isEligiblePointer(PointerDeviceKind.stylus),
      isTrue,
    );
    expect(
      MediaLibraryRootSwipePolicy.isEligiblePointer(PointerDeviceKind.mouse),
      isFalse,
    );
    expect(
      MediaLibraryRootSwipePolicy.isEligiblePointer(PointerDeviceKind.trackpad),
      isFalse,
    );
  });

  test('system back edges are not swipe starts', () {
    expect(
      MediaLibraryRootSwipePolicy.isAwayFromSystemEdges(localX: 8, width: 400),
      isFalse,
    );
    expect(
      MediaLibraryRootSwipePolicy.isAwayFromSystemEdges(
        localX: 392,
        width: 400,
      ),
      isFalse,
    );
    expect(
      MediaLibraryRootSwipePolicy.isAwayFromSystemEdges(localX: 80, width: 400),
      isTrue,
    );
  });

  test('swipe direction maps to the adjacent chip only', () {
    expect(
      MediaLibraryRootSwipePolicy.neighbor(
        current: MediaLibraryRootEntry.continueLearning,
        dx: -40,
      ),
      MediaLibraryRootEntry.folders,
    );
    expect(
      MediaLibraryRootSwipePolicy.neighbor(
        current: MediaLibraryRootEntry.folders,
        dx: -40,
      ),
      MediaLibraryRootEntry.podcasts,
    );
    expect(
      MediaLibraryRootSwipePolicy.neighbor(
        current: MediaLibraryRootEntry.folders,
        dx: 40,
      ),
      MediaLibraryRootEntry.continueLearning,
    );
    expect(
      MediaLibraryRootSwipePolicy.neighbor(
        current: MediaLibraryRootEntry.continueLearning,
        dx: 40,
      ),
      isNull,
    );
    expect(
      MediaLibraryRootSwipePolicy.neighbor(
        current: MediaLibraryRootEntry.recent,
        dx: -40,
      ),
      isNull,
    );
    expect(
      MediaLibraryRootSwipePolicy.neighbor(
        current: MediaLibraryRootEntry.podcasts,
        dx: -40,
      ),
      MediaLibraryRootEntry.recent,
    );
    expect(
      MediaLibraryRootSwipePolicy.neighbor(
        current: MediaLibraryRootEntry.recent,
        dx: 40,
      ),
      MediaLibraryRootEntry.podcasts,
    );
    for (final retired in [
      MediaLibraryRootEntry.bilibili,
      MediaLibraryRootEntry.cloudDrive,
    ]) {
      expect(
        MediaLibraryRootSwipePolicy.neighbor(current: retired, dx: -40),
        isNull,
      );
      expect(
        MediaLibraryRootSwipePolicy.neighbor(current: retired, dx: 40),
        isNull,
      );
    }
  });

  test('a reverse flick returns to the current page', () {
    expect(
      MediaLibraryRootSwipePolicy.settleTarget(
        current: MediaLibraryRootEntry.folders,
        dragDx: -200,
        width: 400,
        velocityDx: 1400,
      ),
      isNull,
    );
    expect(
      MediaLibraryRootSwipePolicy.settleTarget(
        current: MediaLibraryRootEntry.folders,
        dragDx: 200,
        width: 400,
        velocityDx: -1400,
      ),
      isNull,
    );
    expect(
      MediaLibraryRootSwipePolicy.settleTarget(
        current: MediaLibraryRootEntry.folders,
        dragDx: 200,
        width: 400,
        velocityDx: 1400,
      ),
      MediaLibraryRootEntry.continueLearning,
    );
    expect(
      MediaLibraryRootSwipePolicy.settleTarget(
        current: MediaLibraryRootEntry.continueLearning,
        dragDx: -200,
        width: 400,
        velocityDx: 1400,
      ),
      isNull,
    );
    expect(
      MediaLibraryRootSwipePolicy.settleTarget(
        current: MediaLibraryRootEntry.folders,
        dragDx: -200,
        width: 400,
        velocityDx: -1400,
      ),
      MediaLibraryRootEntry.podcasts,
    );
    expect(
      MediaLibraryRootSwipePolicy.settleTarget(
        current: MediaLibraryRootEntry.folders,
        dragDx: -160,
        width: 400,
        velocityDx: 0,
      ),
      MediaLibraryRootEntry.podcasts,
    );
    expect(
      MediaLibraryRootSwipePolicy.settleTarget(
        current: MediaLibraryRootEntry.folders,
        dragDx: -40,
        width: 400,
        velocityDx: 200,
      ),
      isNull,
    );
  });

  test('travel past a full page continues from that page', () {
    final shift = MediaLibraryRootSwipePolicy.shiftOrigin(
      dragDx: -480,
      width: 400,
    );
    expect(shift, isNotNull);
    expect(shift!.indexDelta, 1);
    expect(shift.residualDx, -80);

    final before = MediaLibraryRootSwipePolicy.highlightIndex(
      current: MediaLibraryRootEntry.continueLearning,
      dragDx: -480,
      width: 400,
    );
    final after = MediaLibraryRootSwipePolicy.highlightIndex(
      current: MediaLibraryRootEntry.folders,
      dragDx: shift.residualDx,
      width: 400,
    );
    expect(before, closeTo(after, 0.001));

    expect(
      MediaLibraryRootSwipePolicy.shiftOrigin(dragDx: -200, width: 400),
      isNull,
    );
    final back = MediaLibraryRootSwipePolicy.shiftOrigin(
      dragDx: 450,
      width: 400,
    );
    expect(back!.indexDelta, -1);
    expect(back.residualDx, 50);
  });

  test('commit needs a real fraction or a flick, not a twitch', () {
    expect(
      MediaLibraryRootSwipePolicy.shouldCommit(
        dragDx: -20,
        width: 400,
        velocityDx: 0,
      ),
      isFalse,
    );
    expect(
      MediaLibraryRootSwipePolicy.shouldCommit(
        dragDx: -160,
        width: 400,
        velocityDx: 0,
      ),
      isTrue,
    );
    expect(
      MediaLibraryRootSwipePolicy.shouldCommit(
        dragDx: -40,
        width: 400,
        velocityDx: -1200,
      ),
      isTrue,
    );
  });

  test('chip highlight tracks page offset in index space', () {
    expect(
      MediaLibraryRootSwipePolicy.highlightIndex(
        current: MediaLibraryRootEntry.continueLearning,
        dragDx: -200,
        width: 400,
      ),
      0.5,
    );
    expect(
      MediaLibraryRootSwipePolicy.highlightIndex(
        current: MediaLibraryRootEntry.folders,
        dragDx: 200,
        width: 400,
      ),
      0.5,
    );
    expect(
      MediaLibraryRootSwipePolicy.chipWeight(
        entryIndex: 0,
        highlightIndex: 0.5,
      ),
      0.5,
    );
    expect(
      MediaLibraryRootSwipePolicy.chipWeight(
        entryIndex: 1,
        highlightIndex: 0.5,
      ),
      0.5,
    );
    expect(
      MediaLibraryRootSwipePolicy.chipWeight(
        entryIndex: 2,
        highlightIndex: 0.5,
      ),
      0.0,
    );
  });
}
