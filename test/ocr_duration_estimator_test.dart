import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/ocr_duration_estimator.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';

const chinese = OcrSubtitleTrack(
  number: 1,
  region: NormalizedOcrRegion.subtitleDefault(),
  language: OcrSubtitleLanguage.chinese,
);
const english = OcrSubtitleTrack(
  number: 2,
  region: NormalizedOcrRegion.subtitleDefault(),
  language: OcrSubtitleLanguage.english,
);

void record(
  OcrPerformanceHistory history, {
  String videoId = 'video',
  OcrSubtitleTrack track = chinese,
  int frames = 30,
  int frameMs = 100,
}) => history.recordChunk(
  videoId: videoId,
  track: track,
  mediaMs: 15000,
  extractionMs: 1500,
  frames: frames,
  steadyFrames: frames,
  recognitionMs: (frames * frameMs).toDouble(),
);

OcrPerformanceHistory calibratedHistory() {
  final history = OcrPerformanceHistory(mobile: false);
  record(history);
  history.recordStartup(OcrSubtitleLanguage.chinese, 300);
  history.recordPreparation(1, 600);
  history.recordFinalization(1, 1200);
  return history;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'preflight includes measured extraction, frames, startup and saving',
    () {
      final history = calibratedHistory();
      expect(history.hasMeasurements('video', [chinese]), isTrue);
      expect(
        history.estimate(spanMs: 60000, tracks: [chinese], videoId: 'video'),
        const Duration(milliseconds: 20100),
      );
      expect(history.estimate(spanMs: 0, tracks: [chinese]), Duration.zero);
      expect(history.estimate(spanMs: 60000, tracks: []), Duration.zero);
    },
  );

  test(
    'legacy device speed supplies a prior until real phase data arrives',
    () {
      final history = OcrPerformanceHistory(mobile: false)
        ..useLegacyProcessingRate(0.5);
      expect(
        history.estimate(spanMs: 60000, tracks: [chinese]).inMilliseconds,
        124500,
      );
      expect(history.hasMeasurements('video', [chinese]), isFalse);
      record(history);
      expect(
        history.profileFor('video', chinese).processingMs(60000),
        closeTo(18000, 0.001),
      );
      expect(history.hasMeasurements('video', [chinese]), isTrue);
      history.useLegacyProcessingRate(double.nan);
      expect(history.profileFor('video', chinese).frameMs, 100);
    },
  );

  test(
    'manager reads existing V2 timings for the first estimate after upgrade',
    () async {
      SharedPreferences.setMockInitialValues({
        'ocrSubtitlePerformanceV2.${Platform.operatingSystem}.${Platform.numberOfProcessors}':
            0.5,
      });
      final manager = OcrSubtitleManager(library: LibraryService());
      addTearDown(manager.dispose);
      expect(
        (await manager.estimateDuration(
          mediaDuration: const Duration(minutes: 1),
          start: Duration.zero,
          end: const Duration(minutes: 1),
          tracks: [chinese],
        )).inMilliseconds,
        120000,
      );
      expect(manager.hasDurationMeasurements('video', [chinese]), isFalse);
    },
  );

  test('source density, language and crop profiles are kept separate', () {
    final history = calibratedHistory();
    record(history, videoId: 'busy', frames: 90);
    record(history, track: english, frameMs: 200);
    final wide = chinese.copyWith(
      region: const NormalizedOcrRegion(left: 0, top: 0, right: 1, bottom: 1),
    );
    record(history, track: wide, frameMs: 400);
    expect(history.profileFor('video', chinese).framesPerMediaMs, 0.002);
    expect(history.profileFor('busy', chinese).framesPerMediaMs, 0.006);
    expect(history.profileFor('video', chinese).frameMs, 100);
    expect(history.profileFor('video', english).frameMs, 200);
    expect(history.profileFor('video', wide).frameMs, 400);
    expect(history.profileFor('new-source', chinese).mediaSamplesMs, 30000);
    expect(history.hasMeasurements('new-source', [chinese]), isTrue);
    expect(
      history.hasMeasurements('new-source', [
        chinese.copyWith(language: OcrSubtitleLanguage.japanese),
      ]),
      isFalse,
    );
  });

  test('initialization is counted per language switch, including reuse', () {
    final history = calibratedHistory();
    record(history, track: english);
    history.recordStartup(OcrSubtitleLanguage.english, 700);
    final same = history.estimate(spanMs: 60000, tracks: [chinese, chinese]);
    final mixed = history.estimate(spanMs: 60000, tracks: [chinese, english]);
    // One more model validation (600 ms) and one more engine start (700 ms).
    expect(mixed - same, const Duration(milliseconds: 1300));
    final a = history.estimate(
      spanMs: 60000,
      tracks: [chinese, english, chinese],
    );
    final b = history.estimate(
      spanMs: 60000,
      tracks: [chinese, chinese, english],
    );
    expect(a - b, const Duration(milliseconds: 300));
  });

  test('persisted profiles round-trip and malformed values are ignored', () {
    final history = calibratedHistory();
    final restored = OcrPerformanceHistory(mobile: false)
      ..restore(jsonDecode(jsonEncode(history.toJson())));
    expect(
      restored.estimate(spanMs: 60000, tracks: [chinese], videoId: 'video'),
      history.estimate(spanMs: 60000, tracks: [chinese], videoId: 'video'),
    );
    restored.restore({
      'profiles': {
        'invalid': {'extraction': double.nan},
      },
      'startup': {'chinese': double.infinity},
      'preparation': -10,
    });
    expect(restored.startupMs(OcrSubtitleLanguage.chinese), 300);
    expect(
      restored.estimate(spanMs: 60000, tracks: [chinese]).inMilliseconds,
      greaterThan(0),
    );
  });

  test('history stays bounded across many sources', () {
    final history = calibratedHistory();
    for (var i = 0; i < 200; i++) {
      record(history, videoId: 'video-$i');
    }
    expect(
      (history.toJson()['profiles'] as Map).length,
      OcrPerformanceHistory.maxProfiles,
    );
    expect(history.profileFor('video-199', chinese).frameMs, 100);
  });

  test('short tail chunks do not dominate the decoding forecast', () {
    final profile = OcrTimingProfile.fallback(false);
    profile.observeExtraction(15000, 1500, 30);
    profile.observeExtraction(500, 1500, 1);
    expect(profile.extractionMsPerMediaMs, lessThan(0.2));
  });

  test('recent observations recover from both slowdown and speedup', () {
    final profile = OcrTimingProfile.fallback(false);
    profile.observeFrames(100, 10000);
    for (var i = 0; i < 48; i++) {
      profile.observeFrames(1, 400);
    }
    expect(profile.frameMs, greaterThan(380));
    for (var i = 0; i < 48; i++) {
      profile.observeFrames(1, 100);
    }
    expect(profile.frameMs, lessThan(120));
  });

  test('extraction ETA counts down before any recognition frame arrives', () {
    var now = 0;
    final runtime = OcrRuntimeEstimate(
      history: calibratedHistory(),
      videoId: 'video',
      tracks: [chinese],
      spanMs: 60000,
      elapsedMs: () => now,
    );
    runtime.trackStarted(0, needsStartup: true);
    now = 100;
    runtime.workerReady(100);
    runtime.extractionStarted(15000);
    final before = runtime.remaining;
    now += 500;
    expect(before - runtime.remaining, const Duration(milliseconds: 500));
    now += 10000;
    expect(runtime.remaining, greaterThan(Duration.zero));
  });

  test('first-frame warmup is isolated from steady recognition throughput', () {
    var now = 0;
    final history = calibratedHistory();
    final runtime = OcrRuntimeEstimate(
      history: history,
      videoId: 'video',
      tracks: [chinese],
      spanMs: 60000,
      elapsedMs: () => now,
    );
    runtime.trackStarted(0, needsStartup: true);
    now = 500;
    runtime.workerReady(500);
    runtime.extractionStarted(15000);
    now += 1500;
    runtime.recognitionStarted(frames: 30, extractionMs: 1500);
    now += 6000;
    expect(runtime.frameCompleted(6000), isFalse);
    expect(history.startupMs(OcrSubtitleLanguage.chinese), greaterThan(2500));
    now += 100;
    expect(runtime.frameCompleted(100), isTrue);
    // Future work remains at .1 ms decoding/media ms + 100 ms/frame,
    // instead of extrapolating the six-second warm-up across every chunk.
    expect(runtime.remaining.inMilliseconds, 17500);
  });

  test(
    'current chunk uses actual retained-frame count and advances per frame',
    () {
      var now = 0;
      final runtime = OcrRuntimeEstimate(
        history: calibratedHistory(),
        videoId: 'video',
        tracks: [chinese],
        spanMs: 15000,
        elapsedMs: () => now,
      );
      runtime.trackStarted(0, needsStartup: false);
      runtime.extractionStarted(15000);
      now += 1500;
      runtime.recognitionStarted(frames: 90, extractionMs: 1500);
      expect(runtime.remaining.inMilliseconds, 10200);
      now += 100;
      runtime.frameCompleted(100);
      expect(runtime.remaining.inMilliseconds, 10100);
      now += 50;
      expect(runtime.remaining.inMilliseconds, 10050);
      now +=
          950; // A frame has stalled: revise the forecast while it is in flight.
      expect(runtime.remaining.inMilliseconds, greaterThan(10050));
    },
  );

  test('later frames revise the next chunk before this chunk has finished', () {
    var now = 0;
    final runtime = OcrRuntimeEstimate(
      history: calibratedHistory(),
      videoId: 'video',
      tracks: [chinese],
      spanMs: 60000,
      elapsedMs: () => now,
    );
    runtime.trackStarted(0, needsStartup: false);
    runtime.extractionStarted(15000);
    now += 1500;
    runtime.recognitionStarted(frames: 30, extractionMs: 1500);
    final before = runtime.remaining;
    for (var i = 0; i < 20; i++) {
      now += 400;
      runtime.frameCompleted(400);
    }
    expect(runtime.remaining, greaterThan(before));
    runtime.chunkCompleted();
    expect(runtime.remaining.inMilliseconds, greaterThan(30000));
  });

  test(
    'empty chunks and finalization keep a positive ETA until completion',
    () {
      var now = 0;
      final runtime = OcrRuntimeEstimate(
        history: calibratedHistory(),
        videoId: 'video',
        tracks: [chinese],
        spanMs: 100,
        elapsedMs: () => now,
      );
      runtime.trackStarted(0, needsStartup: false);
      runtime.extractionStarted(100);
      runtime.recognitionStarted(frames: 0, extractionMs: 100);
      runtime.chunkCompleted();
      expect(runtime.remaining.inMilliseconds, 1200);
      runtime.finalizationStarted();
      now += 10000;
      expect(runtime.remaining, const Duration(seconds: 1));
    },
  );

  test(
    'manager clips the chosen range and restores history only once',
    () async {
      final resolved = await const OcrModelManager().resolveTrackIdentity(
        chinese,
      );
      final history = OcrPerformanceHistory(mobile: false);
      record(history, track: resolved);
      history.recordStartup(resolved.language, 300, track: resolved);
      history.recordPreparation(1, 600);
      history.recordFinalization(1, 1200);
      final key =
          'ocrSubtitlePerformanceV4.${Platform.operatingSystem}.'
          '${Platform.numberOfProcessors}';
      SharedPreferences.setMockInitialValues({
        key: jsonEncode(history.toJson()),
      });
      final manager = OcrSubtitleManager(library: LibraryService());
      addTearDown(manager.dispose);
      final estimate = await manager.estimateDuration(
        mediaDuration: const Duration(minutes: 1),
        start: const Duration(seconds: -10),
        end: const Duration(minutes: 2),
        tracks: [chinese],
      );
      // Decoding overlaps recognition after the first chunk.
      expect(estimate.inMilliseconds, 15600);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
      expect(
        await manager.estimateDuration(
          mediaDuration: const Duration(minutes: 1),
          start: Duration.zero,
          end: const Duration(minutes: 1),
          tracks: [chinese],
        ),
        estimate,
      );
      expect(
        await manager.estimateDuration(
          mediaDuration: Duration.zero,
          start: Duration.zero,
          end: Duration.zero,
          tracks: [chinese],
        ),
        Duration.zero,
      );
    },
  );

  test('an unknown materialization ETA can clear the old OCR-only ETA', () {
    const job = OcrSubtitleJob(
      videoId: 'video',
      videoPath: 'online',
      tracks: [chinese],
      start: Duration.zero,
      end: Duration(minutes: 1),
      remaining: Duration(minutes: 5),
    );
    expect(job.copyWith(clearRemaining: true).remaining, isNull);
    expect(job.copyWith(progress: 0.1).remaining, const Duration(minutes: 5));
  });
}
