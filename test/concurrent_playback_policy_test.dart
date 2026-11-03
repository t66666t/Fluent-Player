import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/platform/local_playback_backend_policy.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

void main() {
  group('concurrent playback audio session', () {
    test('enables iOS mixWithOthers without pausing when ducked', () {
      final config = buildConcurrentPlaybackAudioSessionConfiguration(
        allowConcurrentPlayback: true,
      );

      expect(config.avAudioSessionCategory, AVAudioSessionCategory.playback);
      expect(
        config.avAudioSessionCategoryOptions,
        AVAudioSessionCategoryOptions.mixWithOthers,
      );
      expect(config.androidWillPauseWhenDucked, isFalse);
    });

    test('keeps exclusive playback when mixing is off', () {
      final config = buildConcurrentPlaybackAudioSessionConfiguration(
        allowConcurrentPlayback: false,
      );

      expect(
        config.avAudioSessionCategoryOptions,
        AVAudioSessionCategoryOptions.none,
      );
      expect(config.androidAudioFocusGainType, AndroidAudioFocusGainType.gain);
      expect(config.androidWillPauseWhenDucked, isFalse);
    });
  });

  group('audio interruption policy', () {
    test('ignores other apps while mixing', () {
      expect(
        shouldPauseForAudioInterruption(
          allowConcurrentPlayback: true,
          interruptionBegan: true,
          type: AudioInterruptionType.pause,
        ),
        isFalse,
      );
      expect(
        shouldResumeAfterAudioInterruption(
          allowConcurrentPlayback: true,
          interruptionBegan: false,
          type: AudioInterruptionType.pause,
          isPaused: true,
          pausedByInterruption: true,
        ),
        isFalse,
      );
    });

    test('pauses and resumes exclusive playback on a pause interruption', () {
      expect(
        shouldPauseForAudioInterruption(
          allowConcurrentPlayback: false,
          interruptionBegan: true,
          type: AudioInterruptionType.pause,
        ),
        isTrue,
      );
      expect(
        shouldResumeAfterAudioInterruption(
          allowConcurrentPlayback: false,
          interruptionBegan: false,
          type: AudioInterruptionType.pause,
          isPaused: true,
          pausedByInterruption: true,
        ),
        isTrue,
      );
    });

    test('does not pause exclusive playback for a duck', () {
      expect(
        shouldPauseForAudioInterruption(
          allowConcurrentPlayback: false,
          interruptionBegan: true,
          type: AudioInterruptionType.duck,
        ),
        isFalse,
      );
    });

    test('ignores self AUDIOFOCUS_LOSS while taking exclusive focus', () {
      expect(
        shouldPauseForAudioInterruption(
          allowConcurrentPlayback: false,
          interruptionBegan: true,
          type: AudioInterruptionType.unknown,
          withinSelfFocusGrace: true,
        ),
        isFalse,
      );
      expect(
        shouldReclaimExclusiveFocusAfterInterruption(
          allowConcurrentPlayback: false,
          interruptionBegan: true,
          type: AudioInterruptionType.unknown,
          desiredPlaying: true,
          withinSelfFocusGrace: true,
        ),
        isTrue,
      );
    });

    test('still pauses a real permanent loss after the grace window', () {
      expect(
        shouldPauseForAudioInterruption(
          allowConcurrentPlayback: false,
          interruptionBegan: true,
          type: AudioInterruptionType.unknown,
        ),
        isTrue,
      );
      expect(
        isWithinSelfAudioFocusGrace(
          exclusiveFocusGrantedAt: DateTime(2026, 1, 1),
          now: DateTime(2026, 1, 1, 0, 0, 2),
        ),
        isFalse,
      );
    });

    test('ignores becoming-noisy from speaker reroute while taking focus', () {
      expect(
        shouldPauseForBecomingNoisy(
          isTransportPlaying: true,
          withinSelfFocusGrace: true,
        ),
        isFalse,
      );
      expect(
        shouldPauseForBecomingNoisy(
          isTransportPlaying: false,
          withinSelfFocusGrace: false,
        ),
        isFalse,
      );
      expect(
        shouldPauseForBecomingNoisy(
          isTransportPlaying: true,
          withinSelfFocusGrace: false,
        ),
        isTrue,
      );
    });

    test('does not resume exclusive playback from an unknown interruption', () {
      expect(
        shouldResumeAfterAudioInterruption(
          allowConcurrentPlayback: false,
          interruptionBegan: false,
          type: AudioInterruptionType.unknown,
          isPaused: true,
          pausedByInterruption: true,
        ),
        isFalse,
      );
    });
  });

  group('ExoPlayer mix and reload policy', () {
    setUp(LocalPlaybackBackendPolicy.clearForTesting);

    test(
      'Android ExoPlayer always mixes so AudioSession owns exclusive focus',
      () {
        expect(
          MediaPlaybackService.platformPlayerShouldMixWithOthers(
            isAndroid: true,
            allowConcurrentPlayback: false,
          ),
          isTrue,
        );
        expect(
          MediaPlaybackService.platformPlayerShouldMixWithOthers(
            isAndroid: true,
            allowConcurrentPlayback: true,
          ),
          isTrue,
        );
      },
    );

    test('iOS still maps mixWithOthers onto the native player', () {
      expect(
        MediaPlaybackService.platformPlayerShouldMixWithOthers(
          isAndroid: false,
          allowConcurrentPlayback: false,
        ),
        isFalse,
      );
      expect(
        MediaPlaybackService.platformPlayerShouldMixWithOthers(
          isAndroid: false,
          allowConcurrentPlayback: true,
        ),
        isTrue,
      );
    });

    test(
      'does not reload Android ExoPlayer when concurrent playback toggles',
      () {
        expect(
          MediaPlaybackService.shouldReloadPlayerForConcurrentPlayback(
            isAndroid: true,
            sourceType: DataSourceType.file,
            resource: '/storage/emulated/0/Movies/a.mp4',
          ),
          isFalse,
        );
      },
    );

    test('does not reload media_kit or non-Android sessions', () {
      expect(
        MediaPlaybackService.shouldReloadPlayerForConcurrentPlayback(
          isAndroid: false,
          sourceType: DataSourceType.file,
          resource: '/storage/emulated/0/Movies/a.mp4',
        ),
        isFalse,
      );
      expect(
        MediaPlaybackService.shouldReloadPlayerForConcurrentPlayback(
          isAndroid: true,
          sourceType: DataSourceType.network,
          resource: 'https://example.com/a.mp4',
        ),
        isFalse,
      );
    });
  });
}
