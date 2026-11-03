import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/ocr_duration_estimator.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';

const mobile = OcrSubtitleTrack(
  number: 1,
  region: NormalizedOcrRegion.subtitleDefault(),
  language: OcrSubtitleLanguage.chinese,
  modelId: 'ppocr-v5-mobile',
);
final small = mobile.copyWith(modelId: 'ppocr-v6-small');

void record(
  OcrPerformanceHistory history,
  OcrSubtitleTrack track, {
  int frameMs = 100,
}) {
  history.recordChunk(
    videoId: 'video',
    track: track,
    mediaMs: 15000,
    extractionMs: 1500,
    frames: 30,
    steadyFrames: 30,
    recognitionMs: 30.0 * frameMs,
  );
  history.recordStartup(track.language, 300, track: track);
  history.recordPreparation(1, 600);
  history.recordFinalization(1, 1200);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'parallel region ETA follows worker throughput and can return to serial',
    () {
      final history = OcrPerformanceHistory(mobile: false);
      final second = mobile.copyWith(
        number: 2,
        language: OcrSubtitleLanguage.english,
      );
      record(history, mobile);
      record(history, second);
      OcrRuntimeEstimate runtime(int workers) {
        final estimate = OcrRuntimeEstimate(
          history: history,
          videoId: 'video',
          tracks: [mobile, second],
          spanMs: 60000,
          elapsedMs: () => 0,
          pipeline: true,
        );
        estimate.pipelineStarted(workers: workers);
        estimate.pipelineChunkStarted(
          mediaMs: 15000,
          extractionMs: 3000,
          frames: {1: 30, 2: 30},
        );
        return estimate;
      }

      final serial = runtime(1), parallel = runtime(2);
      expect(parallel.remaining, lessThan(serial.remaining));
      parallel.pipelineChunkStarted(
        mediaMs: 15000,
        extractionMs: 3000,
        frames: {1: 30, 2: 30},
        workers: 1,
      );
      expect(parallel.remaining, serial.remaining);
    },
  );

  test(
    'each parallel session has its own warmup, including the same model',
    () {
      final history = OcrPerformanceHistory(mobile: false);
      final second = mobile.copyWith(
        number: 2,
        language: OcrSubtitleLanguage.english,
      );
      record(history, mobile);
      record(history, second);
      final runtime = OcrRuntimeEstimate(
        history: history,
        videoId: 'video',
        tracks: [mobile, second],
        spanMs: 60000,
        elapsedMs: () => 0,
        pipeline: true,
      );
      runtime.pipelineStarted(workers: 2);
      runtime.pipelineChunkStarted(
        mediaMs: 15000,
        extractionMs: 3000,
        frames: {1: 30, 2: 30},
      );
      runtime.pipelineFrameStarted(1);
      runtime.pipelineFrameStarted(2);
      for (final track in [mobile, second]) {
        runtime.pipelineFrameCompleted(
          trackNumber: track.number,
          wallMs: 5000,
          executionProfile: history.executionProfileFor(track),
          warmup: true,
        );
      }
      expect(runtime.pipelineStartupOverheadMs, 9800);
      expect(history.profileFor('video', mobile).frameMs, 100);
      expect(history.profileFor('video', second).frameMs, 100);
    },
  );

  test('measured saving time is not inflated by the runtime display floor', () {
    final history = OcrPerformanceHistory(mobile: false);
    record(history, mobile);
    history.recordFinalization(1, 10);
    history.recordPipeline(
      videoId: 'video',
      tracks: [mobile],
      spanMs: 60000,
      wallMs: 6000,
    );
    expect(history.finalizationMs(1), 724);
    final estimate = history.estimate(
      spanMs: 60000,
      videoId: 'video',
      tracks: [mobile],
      pipeline: true,
    );
    expect(estimate.inMilliseconds, 7624);
  });

  test('model IDs and startup timings stay separate for the same language', () {
    final history = OcrPerformanceHistory(mobile: false);
    record(history, mobile);
    record(history, small, frameMs: 1000);
    history.recordStartup(small.language, 3000, track: small);
    expect(history.profileFor('video', mobile).frameMs, 100);
    expect(history.profileFor('video', small).frameMs, 1000);
    expect(history.startupMs(mobile.language, track: mobile), 300);
    expect(history.startupMs(small.language, track: small), greaterThan(1000));
  });

  test(
    'preflight resolves current revisions without checking installed weights',
    () async {
      const models = OcrModelManager();
      final frozenMobile = await models.resolveTrackIdentity(mobile);
      final frozenSmall = await models.resolveTrackIdentity(small);
      final history = OcrPerformanceHistory(mobile: false);
      record(history, frozenMobile);
      record(history, frozenSmall, frameMs: 1000);
      SharedPreferences.setMockInitialValues({
        'ocrSubtitlePerformanceV4.${Platform.operatingSystem}.${Platform.numberOfProcessors}':
            jsonEncode(history.toJson()),
      });
      final manager = OcrSubtitleManager(library: LibraryService());
      addTearDown(manager.dispose);
      Future<Duration> estimate(OcrSubtitleTrack track) =>
          manager.estimateDuration(
            mediaDuration: const Duration(minutes: 1),
            start: Duration.zero,
            end: const Duration(minutes: 1),
            videoId: 'video',
            tracks: [track],
          );
      final fast = await estimate(mobile);
      final slow = await estimate(
        small.copyWith(modelIdentity: 'stale-revision'),
      );
      expect(fast.inMilliseconds, 15600);
      expect(slow.inMilliseconds, 123600);
      expect(manager.hasDurationMeasurements('video', [mobile]), isTrue);
      expect(manager.hasDurationMeasurements('video', [small]), isTrue);
    },
  );

  test(
    'complete pipeline timings prefer the exact video range and persist',
    () {
      final history = OcrPerformanceHistory(mobile: false);
      record(history, mobile);
      history.recordPipeline(
        videoId: 'video',
        tracks: [mobile],
        startMs: 0,
        spanMs: 60000,
        wallMs: 6000,
      );
      history.recordPipeline(
        videoId: 'video',
        tracks: [mobile],
        startMs: 60000,
        spanMs: 60000,
        wallMs: 12000,
      );
      final restored = OcrPerformanceHistory(mobile: false)
        ..restore(jsonDecode(jsonEncode(history.toJson())));
      Duration estimate(int startMs) => restored.estimate(
        spanMs: 60000,
        startMs: startMs,
        tracks: [mobile],
        videoId: 'video',
        pipeline: true,
      );
      expect(estimate(0).inMilliseconds, 8100);
      expect(estimate(60000).inMilliseconds, 14100);
      restored.useExecutionProfile(mobile, 'DirectML:raw-v1');
      expect(restored.hasMeasurements('video', [mobile]), isFalse);
      expect(estimate(0).inMilliseconds, isNot(8100));
    },
  );

  test('pipeline initialized at zero counts actual remaining frames', () {
    var now = 0;
    final history = OcrPerformanceHistory(mobile: false);
    record(history, mobile);
    final runtime = OcrRuntimeEstimate(
      history: history,
      videoId: 'video',
      tracks: [mobile],
      spanMs: 15000,
      elapsedMs: () => now,
      pipeline: true,
    );
    runtime.pipelineStarted();
    now += 1500;
    runtime.pipelineChunkStarted(
      mediaMs: 15000,
      extractionMs: 1500,
      frames: {1: 90},
    );
    expect(runtime.remaining.inMilliseconds, 10200);
    runtime.pipelineFrameStarted(1);
    now += 100;
    runtime.pipelineFrameCompleted(
      trackNumber: 1,
      wallMs: 100,
      executionProfile: 'CPU:raw-v1',
    );
    expect(runtime.remaining.inMilliseconds, 10100);
    runtime.pipelineFrameStarted(1);
    now += 50;
    expect(runtime.remaining.inMilliseconds, 10050);
    now += 950;
    expect(runtime.remaining.inMilliseconds, inInclusiveRange(10000, 10200));
  });

  test('slower frames revise future chunks before the first chunk ends', () {
    var now = 0;
    final history = OcrPerformanceHistory(mobile: false);
    record(history, mobile);
    final runtime = OcrRuntimeEstimate(
      history: history,
      videoId: 'video',
      tracks: [mobile],
      spanMs: 60000,
      elapsedMs: () => now,
      pipeline: true,
    );
    runtime.pipelineStarted();
    runtime.pipelineChunkStarted(
      mediaMs: 15000,
      extractionMs: 1500,
      frames: {1: 30},
    );
    final before = runtime.remaining;
    for (var i = 0; i < 20; i++) {
      runtime.pipelineFrameStarted(1);
      now += 400;
      runtime.pipelineFrameCompleted(
        trackNumber: 1,
        wallMs: 400,
        executionProfile: 'CPU:raw-v1',
      );
    }
    expect(runtime.remaining, greaterThan(before));
    runtime.pipelineChunkCompleted(15000, now);
    expect(history.profileFor('video', mobile).frameMs, greaterThan(200));
  });

  test('first model warmup is excluded from frame throughput', () {
    var now = 0;
    final history = OcrPerformanceHistory(mobile: false);
    final runtime = OcrRuntimeEstimate(
      history: history,
      videoId: 'video',
      tracks: [mobile],
      spanMs: 60000,
      elapsedMs: () => now,
      pipeline: true,
    );
    runtime.workerReady(500);
    runtime.pipelineStarted();
    runtime.pipelineChunkStarted(
      mediaMs: 5000,
      extractionMs: 500,
      frames: {1: 10},
    );
    runtime.pipelineFrameStarted(1);
    now += 6000;
    runtime.pipelineFrameCompleted(
      trackNumber: 1,
      wallMs: 6000,
      executionProfile: 'CPU:raw-v1',
      warmup: true,
    );
    expect(runtime.hasMeasurements, isFalse);
    runtime.pipelineFrameStarted(1);
    now += 100;
    runtime.pipelineFrameCompleted(
      trackNumber: 1,
      wallMs: 100,
      executionProfile: 'CPU:raw-v1',
    );
    expect(runtime.hasMeasurements, isTrue);
    runtime.pipelineChunkCompleted(5000, now);
    expect(history.profileFor('video', mobile).frameMs, 100);
    expect(runtime.pipelineStartupOverheadMs, 5880);
    expect(history.startupMs(mobile.language, track: mobile), 6380);
  });

  test('different regions keep independent pending work within a chunk', () {
    var now = 0;
    final second = small.copyWith(number: 2);
    final history = OcrPerformanceHistory(mobile: false);
    record(history, mobile);
    record(history, second, frameMs: 1000);
    final runtime = OcrRuntimeEstimate(
      history: history,
      videoId: 'video',
      tracks: [mobile, second],
      spanMs: 5000,
      elapsedMs: () => now,
      pipeline: true,
    );
    runtime.pipelineStarted();
    runtime.pipelineChunkStarted(
      mediaMs: 5000,
      extractionMs: 500,
      frames: {1: 2, 2: 2},
    );
    expect(runtime.remaining.inMilliseconds, 4600);
    runtime.pipelineFrameStarted(1);
    now += 100;
    runtime.pipelineFrameCompleted(
      trackNumber: 1,
      wallMs: 100,
      executionProfile: 'CPU:raw-v1',
    );
    expect(runtime.remaining.inMilliseconds, 4500);
    runtime.pipelineFrameStarted(2);
    now += 1000;
    runtime.pipelineFrameCompleted(
      trackNumber: 2,
      wallMs: 1000,
      executionProfile: 'CPU:raw-v1',
    );
    expect(runtime.remaining.inMilliseconds, 3500);
  });
}
