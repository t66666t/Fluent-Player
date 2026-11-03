import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

void main() {
  group('system media control layout', () {
    test('Android compact slots remain previous, play/pause, next', () {
      final first = buildSystemMediaControlLayout(
        enabled: true,
        hasMedia: true,
        playing: true,
        canStepWithinMedia: true,
        isIOS: false,
      );
      final last = buildSystemMediaControlLayout(
        enabled: true,
        hasMedia: true,
        playing: false,
        canStepWithinMedia: true,
        isIOS: false,
      );

      expect(first.controls.map((control) => control.action), <MediaAction>[
        MediaAction.skipToPrevious,
        MediaAction.rewind,
        MediaAction.pause,
        MediaAction.fastForward,
        MediaAction.skipToNext,
      ]);
      expect(first.androidCompactActionIndices, <int>[0, 2, 4]);
      expect(last.androidCompactActionIndices, <int>[0, 2, 4]);
      expect(last.controls.first.action, MediaAction.skipToPrevious);
      expect(last.controls.last.action, MediaAction.skipToNext);
    });

    test('iOS publishes track commands instead of interval skip buttons', () {
      final layout = buildSystemMediaControlLayout(
        enabled: true,
        hasMedia: true,
        playing: true,
        canStepWithinMedia: true,
        isIOS: true,
      );

      expect(layout.controls.map((control) => control.action), <MediaAction>[
        MediaAction.skipToPrevious,
        MediaAction.pause,
        MediaAction.skipToNext,
      ]);
      expect(
        layout.controls.map((control) => control.action),
        isNot(contains(MediaAction.rewind)),
      );
      expect(
        layout.controls.map((control) => control.action),
        isNot(contains(MediaAction.fastForward)),
      );
    });

    test('headset play/pause follows the live transport and drops a duplicate', () {
      final first = DateTime(2026, 10, 12, 21);
      expect(
        resolveHeadsetPlayPause(
          transportPlaying: false,
          lastAcceptedAt: null,
          now: first,
        ),
        HeadsetPlayPauseResolution.play,
      );
      expect(
        resolveHeadsetPlayPause(
          transportPlaying: true,
          lastAcceptedAt: first,
          now: first.add(const Duration(milliseconds: 40)),
        ),
        HeadsetPlayPauseResolution.ignore,
      );
      expect(
        resolveHeadsetPlayPause(
          transportPlaying: true,
          lastAcceptedAt: first,
          now: first.add(headsetPlayPauseDebounce),
        ),
        HeadsetPlayPauseResolution.pause,
      );
    });

    test('no commands are registered without an active media item', () {
      final layout = buildSystemMediaControlLayout(
        enabled: true,
        hasMedia: false,
        playing: false,
        canStepWithinMedia: false,
        isIOS: false,
      );

      expect(layout.controls, isEmpty);
      expect(layout.androidCompactActionIndices, isEmpty);
    });
  });

  group('subtitle boundary scheduling', () {
    test('converts media time to wall time at 2x speed', () {
      final delay = calculateSubtitleBoundaryDelay(
        position: const Duration(seconds: 10),
        boundary: const Duration(seconds: 12),
        playbackSpeed: 2,
        padding: const Duration(milliseconds: 12),
        minimumDelay: const Duration(milliseconds: 20),
      );

      expect(delay, const Duration(milliseconds: 1012));
    });

    test('converts media time to wall time at half speed', () {
      final delay = calculateSubtitleBoundaryDelay(
        position: const Duration(seconds: 10),
        boundary: const Duration(seconds: 12),
        playbackSpeed: 0.5,
        padding: const Duration(milliseconds: 12),
        minimumDelay: const Duration(milliseconds: 20),
      );

      expect(delay, const Duration(milliseconds: 4012));
    });

    test('uses a short floor for an already-reached boundary', () {
      final delay = calculateSubtitleBoundaryDelay(
        position: const Duration(seconds: 12),
        boundary: const Duration(seconds: 12),
        playbackSpeed: 1,
        padding: const Duration(milliseconds: 12),
        minimumDelay: const Duration(milliseconds: 20),
      );

      expect(delay, const Duration(milliseconds: 20));
    });
  });
}
