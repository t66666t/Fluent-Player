import 'dart:math' as math;
import 'dart:ui' show AppLifecycleState;

/// Pure playback-behavior rules shared by every previous/next entry point.
class PlaybackBehaviorPolicy {
  const PlaybackBehaviorPolicy._();

  static const Duration minimumNearEndWindow = Duration(seconds: 2);
  static const Duration maximumNearEndWindow = Duration(seconds: 10);
  static const Duration completionTolerance = Duration(milliseconds: 200);

  /// Native clocks can trail the interpolated service timeline by a few
  /// hundred milliseconds. Treat either clock as having finished.
  static bool hasReachedPlaybackEnd({
    required Duration position,
    required Duration duration,
  }) {
    if (duration <= Duration.zero) return false;
    return position + completionTolerance >= duration;
  }

  /// A saved point that would immediately complete again is treated as a
  /// completed item and restarted. The window scales to 1% of the media while
  /// remaining bounded for very short and very long content.
  static Duration normalizeEpisodeStartPosition({
    required Duration savedPosition,
    required Duration duration,
    bool forceFromStart = false,
  }) {
    if (forceFromStart || savedPosition <= Duration.zero) {
      return Duration.zero;
    }
    if (duration <= Duration.zero) return savedPosition;
    if (savedPosition >= duration) {
      // Completing past a known duration restarts. A saved point far beyond
      // the reported length is corrupt/short metadata, not end-of-file.
      final overshoot = savedPosition - duration;
      return overshoot <= maximumNearEndWindow ? Duration.zero : savedPosition;
    }

    final scaledWindowMs = duration.inMilliseconds ~/ 100;
    final nearEndWindowMs = math.max(
      minimumNearEndWindow.inMilliseconds,
      math.min(maximumNearEndWindow.inMilliseconds, scaledWindowMs),
    );
    final remainingMs = duration.inMilliseconds - savedPosition.inMilliseconds;
    return remainingMs <= nearEndWindowMs ? Duration.zero : savedPosition;
  }

  /// Probe durations from a just-opened Bilibili stream can be a few seconds
  /// while library metadata still has the real length. Prefer the longer
  /// trusted value so a mid-file resume is not treated as "already finished".
  static Duration trustedDurationForResume({
    required Duration nativeDuration,
    required Duration metadataDuration,
    Duration savedPosition = Duration.zero,
  }) {
    var best = Duration.zero;
    if (metadataDuration > best) best = metadataDuration;
    if (nativeDuration > best) best = nativeDuration;
    if (metadataDuration > Duration.zero &&
        nativeDuration > Duration.zero &&
        nativeDuration < metadataDuration ~/ 2) {
      best = metadataDuration;
    }
    if (savedPosition > Duration.zero && best <= savedPosition) {
      return savedPosition + maximumNearEndWindow + const Duration(seconds: 1);
    }
    return best;
  }

  /// Leaving a playback page pauses only an explicit user exit of a live
  /// transport. Bilibili Mini/notification sessions use [transportPlaying]
  /// because Dart `isPlaying` stays false under cache-pause.
  static bool shouldPauseOnPlaybackPageExit({
    required bool autoPauseOnExit,
    required bool explicitExit,
    required bool suppressRouteCleanup,
    required bool transportPlaying,
  }) {
    return autoPauseOnExit &&
        explicitExit &&
        !suppressRouteCleanup &&
        transportPlaying;
  }

  /// Mobile "leave the app" pause. Loading Bilibili audio already has a play
  /// intent, so the transport flag is the authority rather than `_state`.
  static bool shouldPauseWhenAppBackgrounded({
    required bool enabled,
    required bool isMobilePlatform,
    required bool transportPlaying,
  }) {
    return enabled && isMobilePlatform && transportPlaying;
  }

  /// Whether this transition begins leaving the visible application.
  ///
  /// Flutter synthesizes `hidden` in both directions on Android and iOS:
  /// inactive -> hidden -> paused, and paused -> hidden -> inactive.
  /// https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html
  static bool isLeavingForeground({
    required AppLifecycleState? previousState,
    required AppLifecycleState? nextState,
  }) {
    return (nextState == AppLifecycleState.hidden &&
            previousState != AppLifecycleState.paused) ||
        nextState == AppLifecycleState.detached ||
        (nextState == AppLifecycleState.paused &&
            previousState != AppLifecycleState.hidden);
  }

  /// Split Bilibili streams often leave native `time-pos` behind the service
  /// clock, or keep Dart `isPlaying` false the whole session. Confirm the end
  /// from either clock; local files still reject a playing mid-file pulse.
  static bool isConfirmedPlaybackCompletion({
    required Duration servicePosition,
    required Duration serviceDuration,
    required Duration nativePosition,
    required Duration nativeDuration,
    required bool nativePlaying,
    required bool isOnlineBilibiliStream,
    bool isOnlineCloudDrive = false,
  }) {
    // A short network probe or truncated representation can report its own
    // EOF long before the duration already known for the actual media.
    final nativeCompletionDuration =
        (isOnlineBilibiliStream || isOnlineCloudDrive) &&
            nativeDuration < serviceDuration ~/ 2
        ? serviceDuration
        : nativeDuration;
    final nativeEnd = hasReachedPlaybackEnd(
      position: nativePosition,
      duration: nativeCompletionDuration,
    );
    final serviceEnd = hasReachedPlaybackEnd(
      position: servicePosition,
      duration: serviceDuration,
    );
    if (!nativeEnd && !serviceEnd) return false;
    if (isOnlineBilibiliStream) return true;
    return !nativePlaying || nativeEnd;
  }

  /// Native open/probe samples sit at the file start. Anything within this
  /// window while the bookmark is elsewhere is not real playback yet.
  static const int progressChromeProbeToleranceMs = 750;

  /// Clock shown by portrait progress chrome.
  ///
  /// [followNative] is false while the controller is still the pre-seek
  /// probe. Painting [nativePosition] in that window draws the bookmark,
  /// snaps the thumb to zero, then snaps it back when the resume seek lands.
  static Duration progressChromePosition({
    required Duration nativePosition,
    required Duration heldPosition,
    required bool followNative,
  }) {
    if (!followNative) {
      return heldPosition < Duration.zero ? Duration.zero : heldPosition;
    }
    return nativePosition < Duration.zero ? Duration.zero : nativePosition;
  }

  /// Bookmark to hold before the native clock is trustworthy.
  ///
  /// [allowLibraryBookmarkFallback] covers the opening frame, when the
  /// service clock has not been published yet and is still zero.
  static Duration progressChromeHeldPosition({
    required Duration servicePosition,
    required Duration libraryBookmark,
    required bool allowLibraryBookmarkFallback,
  }) {
    final service = servicePosition < Duration.zero
        ? Duration.zero
        : servicePosition;
    final library = libraryBookmark < Duration.zero
        ? Duration.zero
        : libraryBookmark;
    if (allowLibraryBookmarkFallback &&
        service.inMilliseconds <= progressChromeProbeToleranceMs &&
        library.inMilliseconds > progressChromeProbeToleranceMs) {
      return library;
    }
    return service;
  }

  /// Whether progress chrome may paint [nativePosition].
  ///
  /// The player view is mounted before the resume seek finishes. Online
  /// streams also report t=0 while that seek is in flight. Both cases must
  /// keep [heldPosition] so the thumb does not travel to zero and back.
  static bool progressChromeShouldFollowNative({
    required bool controllerReady,
    required bool transportSeekPending,
    required Duration nativePosition,
    required Duration heldPosition,
    bool sessionStillOpening = false,
    int probeToleranceMs = progressChromeProbeToleranceMs,
  }) {
    if (!controllerReady || transportSeekPending) return false;
    if (heldPosition <= Duration.zero) return true;
    final nativeMs = nativePosition.inMilliseconds;
    final heldMs = heldPosition.inMilliseconds;
    final deltaMs = (heldMs - nativeMs).abs();
    // The controller is mounted before the resume seek. Any sample that is
    // not already the bookmark — zero or a short intro probe — stays hidden
    // until the session leaves loading.
    if (sessionStillOpening && deltaMs > probeToleranceMs) return false;
    if (nativeMs <= probeToleranceMs && deltaMs > probeToleranceMs) {
      return false;
    }
    return true;
  }

  /// Track scale for portrait progress chrome.
  ///
  /// A just-opened stream can report a few seconds of duration. Replacing a
  /// known library length with that probe collapses the track, then stretches
  /// it again when the real duration arrives.
  static Duration progressChromeDuration({
    required Duration nativeDuration,
    required Duration serviceDuration,
    required Duration metadataDuration,
    required bool controllerReady,
  }) {
    var known = Duration.zero;
    if (metadataDuration > known) known = metadataDuration;
    if (serviceDuration > known) known = serviceDuration;
    if (metadataDuration > Duration.zero &&
        serviceDuration > Duration.zero &&
        serviceDuration < metadataDuration ~/ 2) {
      known = metadataDuration;
    }
    if (!controllerReady || nativeDuration <= Duration.zero) return known;
    if (known > Duration.zero && nativeDuration < known ~/ 2) return known;
    return nativeDuration;
  }

  /// Speed label for portrait progress chrome.
  ///
  /// The controller is published before the configured rate is applied, so
  /// its default `1.0` must not replace the label the loading bar already
  /// showed.
  static double progressChromeSpeed({
    required double nativeSpeed,
    required double configuredSpeed,
    required bool speedSettled,
  }) {
    final configured = configuredSpeed.isFinite && configuredSpeed > 0
        ? configuredSpeed
        : 1.0;
    if (!speedSettled || !nativeSpeed.isFinite || nativeSpeed <= 0) {
      return configured;
    }
    return nativeSpeed;
  }
}
