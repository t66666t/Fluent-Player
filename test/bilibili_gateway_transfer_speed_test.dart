import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';

void main() {
  test('formatTransferSpeedLabel renders common units', () {
    expect(MediaPlaybackService.formatTransferSpeedLabel(0), isNull);
    expect(MediaPlaybackService.formatTransferSpeedLabel(512), '512 B/s');
    expect(MediaPlaybackService.formatTransferSpeedLabel(2048), '2.0 KB/s');
    expect(
      MediaPlaybackService.formatTransferSpeedLabel(2.5 * 1024 * 1024),
      '2.5 MB/s',
    );
  });

  test('gateway speed uses a full one-second window, not the burst interval', () {
    final now = DateTime(2026, 9, 19, 13, 51, 0);
    final samples = <({DateTime at, int bytes})>[
      (at: now.subtract(const Duration(milliseconds: 50)), bytes: 2 * 1024 * 1024),
    ];
    // 2 MB in 50 ms is 40 MB/s if divided by elapsed-since-first-sample.
    expect(
      measureGatewayBytesPerSecond(samples, now: now),
      closeTo(2 * 1024 * 1024, 1),
    );
  });

  test('online Bilibili playback never paints a buffering spinner', () {
    expect(
      MediaPlaybackService.shouldShowBilibiliBufferingOverlay(
        isStreamingCard: true,
        state: PlaybackState.playing,
        coveringUntilFrame: false,
        controllerBuffering: true,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldShowBilibiliBufferingOverlay(
        isStreamingCard: true,
        state: PlaybackState.playing,
        coveringUntilFrame: false,
        controllerBuffering: true,
        controllerPlaying: false,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldShowBilibiliBufferingOverlay(
        isStreamingCard: true,
        state: PlaybackState.playing,
        coveringUntilFrame: false,
        controllerBuffering: false,
        seekHold: true,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldShowBilibiliBufferingOverlay(
        isStreamingCard: true,
        state: PlaybackState.loading,
        coveringUntilFrame: false,
        controllerBuffering: false,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldShowBilibiliBufferingOverlay(
        isStreamingCard: true,
        state: PlaybackState.paused,
        coveringUntilFrame: false,
        controllerBuffering: true,
        seekHold: true,
      ),
      isFalse,
    );
  });

  test('seek-hold still freezes the timeline without painting a spinner', () {
    expect(
      MediaPlaybackService.bilibiliSeekHoldOverlayDelay,
      const Duration(milliseconds: 350),
    );
    final source = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'static bool shouldShowBilibiliBufferingOverlay',
    );
    final end = source.indexOf('String get bilibiliBufferingStatusText', start);
    final method = source.substring(start, end);
    expect(method, contains('return false'));
    expect(method, isNot(contains('if (seekHold) return true')));
    expect(source, contains('Timer(bilibiliSeekHoldOverlayDelay'));
  });

  test('cached Range responses release the cache IO lock before streaming', () {
    final source = File(
      'lib/services/bilibili/bilibili_streaming_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<bool> _tryServeCachedTrack');
    final end = source.indexOf(
      '({int start, int? endInclusive})? _parseByteRange',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    expect(method, contains('final plan = await _runCacheOp'));
    expect(method, contains('return _CachedTrackServePlan'));
    expect(method.indexOf('_runCacheOp'), lessThan(method.indexOf('raf.read')));
    final streamed = method.substring(method.indexOf('if (plan == null)'));
    expect(streamed, contains('raf.read'));
    expect(streamed, isNot(contains('_runCacheOp')));
  });
}
