import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/playback_behavior_policy.dart';

void main() {
  group('PlaybackBehaviorPolicy lifecycle transitions', () {
    test(
      'returning from paused does not pause notification-resumed playback',
      () {
        var previous = AppLifecycleState.resumed;
        var transportPlaying = true;
        var pauseCount = 0;
        void transition(AppLifecycleState next) {
          if (PlaybackBehaviorPolicy.isLeavingForeground(
                previousState: previous,
                nextState: next,
              ) &&
              PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
                enabled: true,
                isMobilePlatform: true,
                transportPlaying: transportPlaying,
              )) {
            transportPlaying = false;
            pauseCount++;
          }
          previous = next;
        }

        transition(AppLifecycleState.inactive);
        expect(transportPlaying, isTrue);
        transition(AppLifecycleState.hidden);
        expect(transportPlaying, isFalse);
        expect(pauseCount, 1);
        transition(AppLifecycleState.paused);
        // The user explicitly resumes audio from the background notification.
        transportPlaying = true;
        transition(AppLifecycleState.hidden);
        transition(AppLifecycleState.inactive);
        transition(AppLifecycleState.resumed);
        expect(transportPlaying, isTrue);
        expect(pauseCount, 1);
      },
    );

    test('hidden on the return path is not a second foreground exit', () {
      expect(
        PlaybackBehaviorPolicy.isLeavingForeground(
          previousState: AppLifecycleState.paused,
          nextState: AppLifecycleState.hidden,
        ),
        isFalse,
      );
      for (final previous in <AppLifecycleState?>[
        null,
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.detached,
      ]) {
        expect(
          PlaybackBehaviorPolicy.isLeavingForeground(
            previousState: previous,
            nextState: AppLifecycleState.hidden,
          ),
          isTrue,
        );
      }
    });

    test(
      'direct paused and detached callbacks keep their existing meaning',
      () {
        for (final previous in <AppLifecycleState?>[
          null,
          AppLifecycleState.resumed,
          AppLifecycleState.inactive,
          AppLifecycleState.paused,
          AppLifecycleState.detached,
        ]) {
          expect(
            PlaybackBehaviorPolicy.isLeavingForeground(
              previousState: previous,
              nextState: AppLifecycleState.paused,
            ),
            isTrue,
          );
        }
        expect(
          PlaybackBehaviorPolicy.isLeavingForeground(
            previousState: AppLifecycleState.hidden,
            nextState: AppLifecycleState.paused,
          ),
          isFalse,
        );
        for (final previous in <AppLifecycleState?>[
          null,
          ...AppLifecycleState.values,
        ]) {
          expect(
            PlaybackBehaviorPolicy.isLeavingForeground(
              previousState: previous,
              nextState: AppLifecycleState.detached,
            ),
            isTrue,
          );
          for (final next in <AppLifecycleState?>[
            null,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            expect(
              PlaybackBehaviorPolicy.isLeavingForeground(
                previousState: previous,
                nextState: next,
              ),
              isFalse,
            );
          }
        }
      },
    );

    test('lifecycle exits still honor mobile setting and transport guards', () {
      for (final enabled in [false, true]) {
        for (final mobile in [false, true]) {
          for (final playing in [false, true]) {
            expect(
              PlaybackBehaviorPolicy.isLeavingForeground(
                    previousState: AppLifecycleState.inactive,
                    nextState: AppLifecycleState.hidden,
                  ) &&
                  PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
                    enabled: enabled,
                    isMobilePlatform: mobile,
                    transportPlaying: playing,
                  ),
              enabled && mobile && playing,
            );
          }
        }
      }
    });
  });

  group('PlaybackBehaviorPolicy.normalizeEpisodeStartPosition', () {
    test('keeps a normal saved position', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
        ),
        const Duration(seconds: 30),
      );
    });

    test('restarts completed and near-end media', () {
      for (final savedPosition in <Duration>[
        const Duration(minutes: 2),
        const Duration(seconds: 119),
      ]) {
        expect(
          PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
            savedPosition: savedPosition,
            duration: const Duration(minutes: 2),
          ),
          Duration.zero,
        );
      }
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(seconds: 117),
          duration: const Duration(minutes: 2),
        ),
        const Duration(seconds: 117),
      );
    });

    test('bounds the near-end window for very long media', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(hours: 2) - const Duration(seconds: 9),
          duration: const Duration(hours: 2),
        ),
        Duration.zero,
      );
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(hours: 2) - const Duration(seconds: 11),
          duration: const Duration(hours: 2),
        ),
        const Duration(hours: 2) - const Duration(seconds: 11),
      );
    });

    test('force-from-start wins over saved progress', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
          forceFromStart: true,
        ),
        Duration.zero,
      );
    });

    test('keeps progress when duration is not known yet', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(seconds: 30),
          duration: Duration.zero,
        ),
        const Duration(seconds: 30),
      );
    });

    test('keeps progress when reported duration is far shorter than saved', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(minutes: 5),
          duration: const Duration(seconds: 2),
        ),
        const Duration(minutes: 5),
      );
    });

    test('prefers library duration over a short native probe', () {
      expect(
        PlaybackBehaviorPolicy.trustedDurationForResume(
          nativeDuration: const Duration(seconds: 2),
          metadataDuration: const Duration(minutes: 20),
          savedPosition: const Duration(minutes: 5),
        ),
        const Duration(minutes: 20),
      );
    });
  });

  group('PlaybackBehaviorPolicy playback-setting rules', () {
    test('page-exit pause follows the live transport, not Dart isPlaying', () {
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: true,
          explicitExit: true,
          suppressRouteCleanup: false,
          transportPlaying: true,
        ),
        isTrue,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: false,
          explicitExit: true,
          suppressRouteCleanup: false,
          transportPlaying: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: true,
          explicitExit: false,
          suppressRouteCleanup: false,
          transportPlaying: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: true,
          explicitExit: true,
          suppressRouteCleanup: true,
          transportPlaying: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: true,
          explicitExit: true,
          suppressRouteCleanup: false,
          transportPlaying: false,
        ),
        isFalse,
      );
    });

    test('background pause uses the Bilibili transport intent', () {
      expect(
        PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
          enabled: true,
          isMobilePlatform: true,
          transportPlaying: true,
        ),
        isTrue,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
          enabled: true,
          isMobilePlatform: true,
          transportPlaying: false,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
          enabled: true,
          isMobilePlatform: false,
          transportPlaying: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
          enabled: false,
          isMobilePlatform: true,
          transportPlaying: true,
        ),
        isFalse,
      );
    });

    test('Bilibili completion trusts the service clock when native lags', () {
      const duration = Duration(minutes: 4);
      expect(
        PlaybackBehaviorPolicy.isConfirmedPlaybackCompletion(
          servicePosition: duration,
          serviceDuration: duration,
          nativePosition: duration - const Duration(seconds: 2),
          nativeDuration: duration,
          nativePlaying: false,
          isOnlineBilibiliStream: true,
        ),
        isTrue,
      );
      expect(
        PlaybackBehaviorPolicy.isConfirmedPlaybackCompletion(
          servicePosition: const Duration(minutes: 2),
          serviceDuration: duration,
          nativePosition: const Duration(minutes: 2),
          nativeDuration: duration,
          nativePlaying: false,
          isOnlineBilibiliStream: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.isConfirmedPlaybackCompletion(
          servicePosition: duration,
          serviceDuration: duration,
          nativePosition: const Duration(minutes: 2),
          nativeDuration: duration,
          nativePlaying: true,
          isOnlineBilibiliStream: false,
        ),
        isFalse,
      );
    });
  });

  group('PlaybackBehaviorPolicy progress chrome', () {
    test('holds the bookmark while native is still the open probe', () {
      const bookmark = Duration(minutes: 12);
      final held = PlaybackBehaviorPolicy.progressChromeHeldPosition(
        servicePosition: Duration.zero,
        libraryBookmark: bookmark,
        allowLibraryBookmarkFallback: true,
      );
      expect(held, bookmark);
      expect(
        PlaybackBehaviorPolicy.progressChromeShouldFollowNative(
          controllerReady: true,
          transportSeekPending: false,
          nativePosition: Duration.zero,
          heldPosition: held,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.progressChromePosition(
          nativePosition: Duration.zero,
          heldPosition: held,
          followNative: false,
        ),
        bookmark,
      );
    });

    test('ignores a short intro probe while the session is still opening', () {
      expect(
        PlaybackBehaviorPolicy.progressChromeShouldFollowNative(
          controllerReady: true,
          transportSeekPending: false,
          sessionStillOpening: true,
          nativePosition: const Duration(seconds: 2),
          heldPosition: const Duration(minutes: 12),
        ),
        isFalse,
      );
    });

    test('follows native once it has landed on the bookmark', () {
      const bookmark = Duration(minutes: 12);
      expect(
        PlaybackBehaviorPolicy.progressChromeShouldFollowNative(
          controllerReady: true,
          transportSeekPending: false,
          nativePosition: bookmark,
          heldPosition: bookmark,
        ),
        isTrue,
      );
      expect(
        PlaybackBehaviorPolicy.progressChromePosition(
          nativePosition: bookmark + const Duration(milliseconds: 200),
          heldPosition: bookmark,
          followNative: true,
        ),
        bookmark + const Duration(milliseconds: 200),
      );
    });

    test(
      'does not let a zero service clock hide a saved bookmark while opening',
      () {
        expect(
          PlaybackBehaviorPolicy.progressChromeHeldPosition(
            servicePosition: Duration.zero,
            libraryBookmark: const Duration(seconds: 90),
            allowLibraryBookmarkFallback: true,
          ),
          const Duration(seconds: 90),
        );
        expect(
          PlaybackBehaviorPolicy.progressChromeHeldPosition(
            servicePosition: Duration.zero,
            libraryBookmark: const Duration(seconds: 90),
            allowLibraryBookmarkFallback: false,
          ),
          Duration.zero,
        );
      },
    );

    test('keeps a known duration when native only has a short probe', () {
      expect(
        PlaybackBehaviorPolicy.progressChromeDuration(
          nativeDuration: const Duration(seconds: 3),
          serviceDuration: const Duration(seconds: 3),
          metadataDuration: const Duration(minutes: 20),
          controllerReady: true,
        ),
        const Duration(minutes: 20),
      );
      expect(
        PlaybackBehaviorPolicy.progressChromeDuration(
          nativeDuration: Duration.zero,
          serviceDuration: Duration.zero,
          metadataDuration: const Duration(minutes: 20),
          controllerReady: false,
        ),
        const Duration(minutes: 20),
      );
    });

    test(
      'adopts a real native duration and keeps the configured speed until settled',
      () {
        expect(
          PlaybackBehaviorPolicy.progressChromeDuration(
            nativeDuration: const Duration(minutes: 20, seconds: 1),
            serviceDuration: const Duration(minutes: 20),
            metadataDuration: const Duration(minutes: 20),
            controllerReady: true,
          ),
          const Duration(minutes: 20, seconds: 1),
        );
        expect(
          PlaybackBehaviorPolicy.progressChromeSpeed(
            nativeSpeed: 1,
            configuredSpeed: 1.5,
            speedSettled: false,
          ),
          1.5,
        );
        expect(
          PlaybackBehaviorPolicy.progressChromeSpeed(
            nativeSpeed: 1.25,
            configuredSpeed: 1.5,
            speedSettled: true,
          ),
          1.25,
        );
      },
    );
  });
}
