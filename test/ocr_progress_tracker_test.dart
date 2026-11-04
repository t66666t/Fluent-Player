import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/ocr_progress_tracker.dart';

void main() {
  test(
    'whole percent boundaries do not lose one percent to float rounding',
    () {
      expect(OcrTaskProgressTracker.percentFor(.29), 29);
      expect(OcrTaskProgressTracker.percentFor(.58), 58);
      expect(OcrTaskProgressTracker.percentFor(.999), 99);
      expect(OcrTaskProgressTracker.percentFor(1), 100);
      expect(OcrTaskProgressTracker.percentFor(double.nan), 0);
    },
  );
  test('single region starts at zero and covers the selected time range', () {
    final tracker = OcrRegionProgressTracker(
      startMs: 90000,
      spanMs: 60000,
      tracks: [1],
    );
    expect(tracker.progress, 0);
    expect(tracker.snapshot.completedByTrack[1], Duration.zero);
    tracker.completedThrough(1, 120000);
    expect(tracker.progress, .5);
    expect(tracker.snapshot.total, const Duration(minutes: 1));
    expect(tracker.snapshot.completedByTrack[1], const Duration(seconds: 30));
    tracker.completedThrough(1, 180000);
    expect(tracker.snapshot.completedByTrack[1], const Duration(minutes: 1));
    expect(tracker.progress, .99);
  });

  test(
    'parallel completion is counted only after a region finishes its work',
    () {
      final tracker = OcrRegionProgressTracker(
        startMs: 30000,
        spanMs: 10000,
        tracks: [1, 2],
      );
      tracker.completedThrough(2, 40000);
      expect(tracker.progress, .5);
      expect(tracker.snapshot.completedByTrack[1], Duration.zero);
      tracker.completedThrough(1, 31000);
      expect(tracker.progress, .55);
      // A delayed notification/replay cannot move any region backwards.
      tracker.completedThrough(2, 35000);
      tracker.completedThrough(1, 30000);
      expect(tracker.progress, .55);
      tracker.completedThrough(1, 40000);
      expect(tracker.progress, .99);
    },
  );

  test(
    'long jobs publish elapsed seconds even without a whole-percent change',
    () {
      final tracker = OcrRegionProgressTracker(
        startMs: 0,
        spanMs: 4 * 3600000,
        tracks: [1, 2],
      );
      expect(tracker.shouldPublish(), isTrue);
      tracker.completedThrough(1, 100);
      expect(tracker.shouldPublish(), isFalse);
      tracker.completedThrough(1, 1200);
      expect(tracker.shouldPublish(), isTrue);
      tracker.completedThrough(2, 1200);
      expect(tracker.shouldPublish(), isTrue);
      expect(tracker.shouldPublish(), isFalse);
    },
  );

  test('a published snapshot stays immutable while recognition advances', () {
    final tracker = OcrRegionProgressTracker(
      startMs: 0,
      spanMs: 60000,
      tracks: [1],
    );
    final first = tracker.snapshot;
    tracker.completedThrough(1, 5000);
    expect(first.completedByTrack[1], Duration.zero);
    expect(
      () => first.completedByTrack[1] = Duration.zero,
      throwsUnsupportedError,
    );
    expect(() => tracker.completedThrough(99, 100), throwsArgumentError);
  });
}
