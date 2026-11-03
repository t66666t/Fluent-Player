import 'package:flutter_test/flutter_test.dart';

import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/subtitle_hop_seek_policy.dart';

void main() {
  test('sentence and keyboard hops share the hop source family', () {
    expect(SubtitleHopSeekPolicy.isHopSeekSource('subtitle_hop'), isTrue);
    expect(
      SubtitleHopSeekPolicy.isHopSeekSource('subtitle_navigation'),
      isTrue,
    );
    expect(
      SubtitleHopSeekPolicy.isHopSeekSource('external_double_tap'),
      isTrue,
    );
    expect(SubtitleHopSeekPolicy.isHopSeekSource('ui'), isFalse);
    expect(
      SubtitleHopSeekPolicy.isHopSeekSource('bilibili_zero_resync'),
      isFalse,
    );
  });

  test('only online hops wait to coalesce native Range seeks', () {
    expect(
      SubtitleHopSeekPolicy.nativeDispatchDelay(
        isOnlineBilibiliStream: true,
        source: 'subtitle_hop',
      ),
      SubtitleHopSeekPolicy.onlineNativeDispatchDelay,
    );
    expect(
      SubtitleHopSeekPolicy.nativeDispatchDelay(
        isOnlineBilibiliStream: false,
        source: 'subtitle_hop',
      ),
      SubtitleHopSeekPolicy.offlineNativeDispatchDelay,
    );
    expect(
      SubtitleHopSeekPolicy.nativeDispatchDelay(
        isOnlineBilibiliStream: true,
        source: 'ui',
      ),
      Duration.zero,
    );
  });

  test('online hops do not await the native seek Future', () {
    expect(
      SubtitleHopSeekPolicy.shouldAwaitNativeSeekAck(
        isOnlineBilibiliStream: true,
        source: 'external_double_tap',
      ),
      isFalse,
    );
    expect(
      SubtitleHopSeekPolicy.shouldAwaitNativeSeekAck(
        isOnlineBilibiliStream: false,
        source: 'external_double_tap',
      ),
      isTrue,
    );
    expect(
      SubtitleHopSeekPolicy.shouldAwaitNativeSeekAck(
        isOnlineBilibiliStream: true,
        source: 'ui',
      ),
      isTrue,
    );
  });

  test('online hops and scrubs keep audio/video on the same clock', () {
    expect(SubtitleHopSeekPolicy.hopHrSeek, 'yes');
    expect(SubtitleHopSeekPolicy.scrubHrSeek, 'yes');
    expect(
      SubtitleHopSeekPolicy.hrSeekFor(StreamingSeekStyle.hop),
      'yes',
    );
    expect(
      SubtitleHopSeekPolicy.hrSeekFor(StreamingSeekStyle.scrub),
      'yes',
    );
  });

  test('slider seeks use the scrub profile on online Bilibili streams', () {
    expect(
      SubtitleHopSeekPolicy.streamingSeekStyleFor(
        isOnlineBilibiliStream: true,
        source: 'ui',
      ),
      StreamingSeekStyle.scrub,
    );
    expect(
      SubtitleHopSeekPolicy.streamingSeekStyleFor(
        isOnlineBilibiliStream: true,
        source: 'system_media',
      ),
      StreamingSeekStyle.scrub,
    );
    expect(
      SubtitleHopSeekPolicy.streamingSeekStyleFor(
        isOnlineBilibiliStream: true,
        source: 'play_same_item_reuse',
      ),
      StreamingSeekStyle.precise,
    );
    expect(
      SubtitleHopSeekPolicy.cachePauseWaitSecondsFor(StreamingSeekStyle.scrub),
      SubtitleHopSeekPolicy.streamingScrubCachePauseWaitSeconds,
    );
  });

  test('split-stream hop tuning is isolated from slider seeks', () {
    expect(
      SubtitleHopSeekPolicy.shouldUseStreamingHopTuning(
        isOnlineBilibiliStream: true,
        source: 'subtitle_hop',
      ),
      isTrue,
    );
    expect(
      SubtitleHopSeekPolicy.shouldUseStreamingHopTuning(
        isOnlineBilibiliStream: true,
        source: 'ui',
      ),
      isFalse,
    );
    expect(
      SubtitleHopSeekPolicy.shouldUseStreamingHopTuning(
        isOnlineBilibiliStream: false,
        source: 'subtitle_hop',
      ),
      isFalse,
    );
  });

  test('hop verification keeps the optimistic subtitle timestamp', () {
    expect(
      SubtitleHopSeekPolicy.shouldRewritePositionOnSeekDrift('subtitle_hop'),
      isFalse,
    );
    expect(
      SubtitleHopSeekPolicy.shouldRewritePositionOnSeekDrift('ui'),
      isTrue,
    );
  });

  test('recent hops suppress the online zero-clock resync', () {
    final now = DateTime(2026, 9, 19, 10);
    expect(
      SubtitleHopSeekPolicy.shouldSuppressZeroClockResync(
        hopSeekInFlight: true,
        lastSeekSource: 'ui',
        now: now,
        lastHopSeekAt: null,
      ),
      isTrue,
    );
    expect(
      SubtitleHopSeekPolicy.shouldSuppressZeroClockResync(
        hopSeekInFlight: false,
        lastSeekSource: 'subtitle_hop',
        now: now,
        lastHopSeekAt: now.subtract(const Duration(milliseconds: 400)),
      ),
      isTrue,
    );
    expect(
      SubtitleHopSeekPolicy.shouldSuppressZeroClockResync(
        hopSeekInFlight: false,
        lastSeekSource: 'subtitle_hop',
        now: now,
        lastHopSeekAt: now.subtract(const Duration(seconds: 3)),
      ),
      isFalse,
    );
  });

  test('zero-clock resync stays off during an in-flight hop', () {
    expect(
      shouldResyncBilibiliClockFromZero(
        isOnlineBilibiliStream: true,
        expectedPosition: const Duration(minutes: 4),
        nativeSample: Duration.zero,
        now: DateTime(2026, 1, 1, 12),
        lastResyncAt: null,
        hopSeekInFlight: true,
      ),
      isFalse,
    );
  });

  test('hop overlay/sidebar keeps the optimistic clock until native lands', () {
    final now = DateTime(2026, 9, 19, 16);
    expect(
      SubtitleHopSeekPolicy.shouldHoldSubtitleClockOnHop(
        lastSeekSource: 'external_double_tap',
        now: now,
        lastHopSeekAt: now,
        nativePosition: const Duration(seconds: 20),
        hopTarget: const Duration(seconds: 18),
        hopSeekInFlight: true,
      ),
      isTrue,
    );
    // Backward hop of 2s: native is still on the old cue (+2000ms).
    expect(
      SubtitleHopSeekPolicy.shouldHoldSubtitleClockOnHop(
        lastSeekSource: 'external_double_tap',
        now: now,
        lastHopSeekAt: now.subtract(const Duration(milliseconds: 200)),
        nativePosition: const Duration(seconds: 20),
        hopTarget: const Duration(seconds: 18),
        hopSeekInFlight: false,
      ),
      isTrue,
    );
    expect(
      SubtitleHopSeekPolicy.shouldHoldSubtitleClockOnHop(
        lastSeekSource: 'external_double_tap',
        now: now,
        lastHopSeekAt: now.subtract(const Duration(milliseconds: 200)),
        nativePosition: const Duration(milliseconds: 18100),
        hopTarget: const Duration(seconds: 18),
        hopSeekInFlight: false,
      ),
      isFalse,
    );
    expect(
      SubtitleHopSeekPolicy.shouldHoldSubtitleClockOnHop(
        lastSeekSource: 'ui',
        now: now,
        lastHopSeekAt: now,
        nativePosition: const Duration(seconds: 20),
        hopTarget: const Duration(seconds: 18),
        hopSeekInFlight: false,
      ),
      isFalse,
    );
    expect(
      SubtitleHopSeekPolicy.shouldHoldSubtitleClockOnHop(
        lastSeekSource: 'subtitle_hop',
        now: now,
        lastHopSeekAt: now.subtract(const Duration(seconds: 3)),
        nativePosition: const Duration(seconds: 20),
        hopTarget: const Duration(seconds: 18),
        hopSeekInFlight: false,
      ),
      isFalse,
    );
  });
}
