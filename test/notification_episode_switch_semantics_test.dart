import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Contracts for the notification-controlled episode switch fix.
///
/// These are source-contract tests (the established pattern in this suite for
/// platform-coupled playback concerns): they pin the exact code shapes that
/// make the notification-card previous/next path behave identically to the
/// in-app buttons — readiness degradation instead of retry storms, a single
/// serialized media-switch entry, a guarded reopen fallback for foreground
/// recovery, and honest loading/paused reporting on the notification.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String method(String source, String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startMarker');
    final end = source.indexOf(endMarker, start);
    expect(end, greaterThan(start), reason: 'missing $endMarker');
    return source.substring(start, end);
  }

  test('background clock timeout degrades instead of failing the switch', () {
    final source = read('lib/services/media_playback_service.dart');
    final readiness = method(
      source,
      '_PlaybackReadinessResult> _awaitPlaybackReadinessResult',
      'void _primeDeferredVideoOutput',
    );
    // Podcast startup must still report a decoder that never begins playing.
    // The background native-clock branch degrades without reopening media.
    final background = readiness.substring(
      readiness.indexOf('if (!_hasVisiblePlaybackPage'),
    );
    expect(background, isNot(contains('throw TimeoutException')));
    expect(readiness, contains('播客未能开始播放'));
    expect(
      readiness,
      contains('background playback clock unconfirmed; keeping play intent'),
    );
    expect(
      readiness,
      isNot(contains('parking session as paused at the seek target')),
    );
    expect(readiness, contains('onTimeout: () => true'));
  });

  test(
    'readiness degradation commits a paused session with cleared intent',
    () {
      final source = read('lib/services/media_playback_service.dart');
      final playMethod = method(
        source,
        'Future<void> play(',
        'Future<void> resume(',
      );
      // Both switch paths (reused/preloaded controller and fresh controller)
      // must react to a degraded readiness by parking paused and clearing the
      // play intent, so the final intent commit cannot re-play the transport.
      final degradedCount = 'Readiness degraded'.allMatches(playMethod).length;
      expect(
        degradedCount,
        2,
        reason: 'both play() switch paths handle degrade',
      );
      expect(playMethod, contains('_setDesiredPlaying(false)'));
    },
  );

  test('media switch retries are capped at one', () {
    final source = read('lib/services/media_playback_service.dart');
    expect(
      source,
      contains('static const int _mediaSwitchMaxAttempts = 2;'),
      reason:
          'readiness timeouts no longer land here, so three attempts '
          'were pure reopen overhead',
    );
    expect(
      source,
      isNot(contains('static const int _mediaSwitchMaxAttempts = 3;')),
    );
  });

  test('all media-switch entries share one serialization lock', () {
    final source = read('lib/services/media_playback_service.dart');
    expect(source, contains('Future<void> _mediaSwitchLock'));
    final playListItem = method(
      source,
      'Future<void> _playPlaylistItem(',
      'Future<void> _playPlaylistItemLocked(',
    );
    expect(playListItem, contains('_runInMediaSwitchLock'));
    // Episode navigation, completion auto-advance and errored-controller
    // recovery all funnel through _playPlaylistItem.
    expect(
      RegExp('_playPlaylistItem\\(\\s*targetItem').hasMatch(source),
      isTrue,
      reason: 'completion auto-advance goes through the switch lock',
    );
    expect(
      RegExp('_playPlaylistItem\\(\\s*target,').hasMatch(source),
      isTrue,
      reason: 'episode navigation goes through the switch lock',
    );
    expect(
      RegExp('_playPlaylistItem\\(\\s*item,').hasMatch(source),
      isTrue,
      reason: 'errored-controller recovery goes through the switch lock',
    );
  });

  test(
    'navigation opens the playback page without waiting for video recovery',
    () {
      final source = read('lib/services/playback_navigation_service.dart');
      final open = method(
        source,
        'Future<void> openCurrentPlaybackSession(',
        'Future<void> _openPlaybackInternal(',
      );
      // Mini→page must push immediately. Waiting for video attach/enable
      // froze the user on Mini while audio played under a black texture.
      expect(open, contains('_openPlaybackInternal(item)'));
      expect(
        open,
        contains(
          'unawaited(playbackService.ensureVisibleVideoOutput(item.id))',
        ),
      );
      expect(
        open,
        isNot(contains('_waitForPresentableSession(playbackService, item.id)')),
      );
      expect(open, isNot(contains('.timeout(const Duration(seconds: 25)')));
    },
  );

  test('notification tap navigates immediately without reopening media', () {
    final navigation = read('lib/services/playback_navigation_service.dart');
    final methodSource = method(
      navigation,
      'Future<void> openCurrentPlaybackSessionFromNotification(',
      'Future<void> _openPlaybackInternal(',
    );
    expect(
      methodSource,
      contains('_openPlaybackInternal(item, notificationEntry: true)'),
    );
    expect(methodSource, contains('needsVisibleVideoOutputRecovery'));
    expect(methodSource, isNot(contains('playbackService.play(')));

    final mainSource = read('lib/main.dart');
    expect(mainSource, contains('openCurrentPlaybackSessionFromNotification('));
  });

  test('notification play/pause button follows the session intent alone', () {
    final source = read('lib/services/system_media_session_service.dart');
    final buildState = method(
      source,
      'audio_service.PlaybackState _buildPlaybackState(',
      'bool _canStepWithinMedia(',
    );
    // The intent is the single source of truth; transient isPlaying or the
    // loading state never participates, so the button cannot flicker while a
    // background episode switch settles.
    expect(
      buildState,
      contains(
        'final bool effectivePlaying = forcePlaying || snapshot.desiredPlaying;',
      ),
    );
    expect(buildState, isNot(contains('snapshot.isPlaying ||')));
    expect(
      buildState,
      isNot(contains('PlaybackState.loading && snapshot.desiredPlaying')),
    );
    // The snapshot carries the service play intent.
    expect(source, contains('desiredPlaying: playbackService?.desiredPlaying'));
  });

  test('transport intent bypasses a loading episode-switch barrier', () {
    final source = read('lib/services/system_media_session_service.dart');
    final play = method(
      source,
      'Future<void> play() async {',
      'Future<void> pause() async {',
    );
    final pause = method(
      source,
      'Future<void> pause() async {',
      'Future<void> stop() async {',
    );
    expect(play, contains('await _playbackService?.resume();'));
    expect(pause, contains('await _playbackService?.pause();'));
    expect(play, isNot(contains('_runSerialized')));
    expect(pause, isNot(contains('_runSerialized')));

    final playback = read('lib/services/media_playback_service.dart');
    final pauseMethod = method(
      playback,
      'Future<void> pause({',
      'Future<void> resume() async {',
    );
    final resumeMethod = method(
      playback,
      'Future<void> resume() async {',
      'bool updatePlaybackStateFromController({',
    );
    expect(
      pauseMethod.indexOf('notifyListeners();'),
      lessThan(pauseMethod.indexOf('await nativePause;')),
    );
    expect(
      resumeMethod.indexOf('notifyListeners();'),
      lessThan(resumeMethod.indexOf('await nativePlay;')),
    );
    expect(
      resumeMethod,
      isNot(contains('Bilibili resume did not start; recreating stream')),
    );
  });

  test(
    'play intent changes are published immediately and primes cannot win',
    () {
      final source = read('lib/services/system_media_session_service.dart');
      final immediate = method(
        source,
        'bool _shouldPublishImmediately(',
        'Future<void> _publishSnapshot({',
      );
      expect(
        immediate,
        contains('previous.desiredPlaying != snapshot.desiredPlaying'),
      );

      final prime = method(
        source,
        'Future<void> _ensureAndroidNotificationVisible(',
        'bool _shouldRefreshMediaItem(',
      );
      expect(
        prime,
        contains('primeRevision != _notificationVisibilityPrimeRevision'),
      );
      expect(prime, contains('final currentSnapshot = _buildSnapshot();'));
      expect(prime, isNot(contains('_buildPlaybackState(snapshot);')));
    },
  );

  test('notification entry resets to library and honors skip-portrait', () {
    final source = read('lib/services/playback_navigation_service.dart');
    final open = method(
      source,
      'Future<void> _openPlaybackInternal(',
      'Future<NavigatorState?> _waitForNavigator()',
    );
    expect(open, contains('trackedRoutes.skip(1)'));
    expect(open, contains('? buildNotificationPlaybackRoute(item)'));
    expect(
      open,
      contains(': buildPlaybackEntryRoute(item, entryAutoPlay: entryAutoPlay)'),
    );
    expect(open, contains('entrySkipsPortraitPlayer'));
    expect(
      open.indexOf('trackedRoutes.skip(1)'),
      lessThan(open.indexOf('navigator.push(route)')),
    );

    final notificationRoute = method(
      source,
      'Route<void> buildNotificationPlaybackRoute(',
      '/// 桌面端以及开启"跳过竖屏播放页"的移动端',
    );
    expect(notificationRoute, contains('if (entrySkipsPortraitPlayer)'));
    expect(notificationRoute, contains('VideoPlayerScreen(videoItem: item)'));
    expect(notificationRoute, contains('return buildPortraitRoute(item);'));
  });

  test('paused-notification priming starts the Android foreground service', () {
    final source = read('lib/services/system_media_session_service.dart');
    final prime = method(
      source,
      'Future<void> _ensureAndroidNotificationVisible(',
      'bool _shouldRefreshMediaItem(',
    );
    // audio_service creates its Android notification on a transition into the
    // playing state. Restore the stable one-shot prime before publishing the
    // actual paused state.
    expect(prime, contains('forcePlaying: true'));
    expect(
      '_buildPlaybackState(currentSnapshot)'.allMatches(prime).length,
      1,
      reason: 'the primed state must be followed by the latest truthful state',
    );
  });

  test(
    'page adopt repair follows intent and never fights an in-flight switch',
    () {
      for (final path in <String>[
        'lib/screens/video_player_screen.dart',
        'lib/screens/portrait_video_screen.dart',
      ]) {
        final source = read(path);
        // Every service-controller adoption that repairs play/pause must (a) be
        // skipped while the service is loading a switch and (b) use the session
        // intent (desiredPlaying), not the transient isPlaying flag.
        final repairGuards = RegExp(
          r'playbackService\.state != PlaybackState\.loading',
        ).allMatches(source).length;
        final desiredRefs = RegExp(
          r'playbackService\.desiredPlaying',
        ).allMatches(source).length;
        final isPlayingRefs = RegExp(
          r'if \(playbackService\.isPlaying\) \{',
        ).allMatches(source).length;
        expect(
          repairGuards,
          greaterThanOrEqualTo(1),
          reason: '$path repair sites must be skipped during loading',
        );
        expect(
          desiredRefs,
          greaterThanOrEqualTo(2),
          reason: '$path repair sites must compare against the session intent',
        );
        expect(
          isPlayingRefs,
          0,
          reason: '$path must never branch a transport repair on isPlaying',
        );
      }
    },
  );

  test('controller sync cannot flip the public state against the intent', () {
    final source = read('lib/services/media_playback_service.dart');
    final sync = method(
      source,
      'bool updatePlaybackStateFromController(',
      '/// 停止播放',
    );
    expect(
      sync,
      contains('controllerIsPlaying != _session.desiredPlaying'),
      reason:
          'a controller sample disagreeing with the intent must not '
          'flip state/notification',
    );
    final intentGuard = sync.indexOf(
      'controllerIsPlaying != _session.desiredPlaying',
    );
    final completionDetect = sync.indexOf('_onPlaybackCompleted()');
    expect(
      intentGuard,
      greaterThan(completionDetect),
      reason: 'completion detection must run before the intent guard',
    );
  });

  test('episode skip settings are read on both command chains', () {
    final serviceSource = read('lib/services/media_playback_service.dart');
    final playNext = method(
      serviceSource,
      'Future<void> playNext(',
      'Future<void> playPrevious(',
    );
    final playPrevious = method(
      serviceSource,
      'Future<void> playPrevious(',
      'Future<void> _enqueueEpisodeNavigation(',
    );
    // The notification handler calls the very same playNext/playPrevious the
    // in-app buttons use, so the「切换上下集后自动播放」setting applies to both.
    expect(playNext, contains('SettingsService().autoPlayNextVideo'));
    expect(playPrevious, contains('SettingsService().autoPlayNextVideo'));

    final handlerSource = read(
      'lib/services/system_media_session_service.dart',
    );
    // The notification invokes the exact same public methods as the in-app
    // controls; there is no notification-only player path.
    expect(playNext, isNot(contains('playNextFromSystemMedia')));
    expect(playPrevious, isNot(contains('playPreviousFromSystemMedia')));
    expect(handlerSource, contains('playbackService.playNext()'));
    expect(handlerSource, contains('playbackService.playPrevious()'));
  });

  test('notification has no divergent local playback path', () {
    final source = read('lib/services/media_playback_service.dart');
    expect(source, isNot(contains('useStableBackgroundLocalPath')));
    expect(source, isNot(contains('fromSystemMedia')));
    expect(
      source,
      contains('final int maxAttempts = _mediaSwitchMaxAttempts;'),
    );
  });

  test('background completion uses the canonical media-switch path', () {
    final source = read('lib/services/media_playback_service.dart');
    final completion = method(
      source,
      'Future<void> _handlePlaybackCompleted(',
      'bool _hasReachedPlaybackEnd(',
    );
    expect(completion, contains('settings.autoPlayOnCompletion'));
    expect(completion, contains('settings.autoPlayOnCompletionFromStart'));
    expect(completion, contains('isConfirmedPlaybackCompletion('));
    expect(completion, contains('await _playPlaylistItem('));
    expect(completion, isNot(contains('useStableBackgroundLocalPath')));
  });

  test(
    'pages never force a second play while the service is still loading',
    () {
      for (final path in <String>['lib/screens/video_player_screen.dart']) {
        final source = read(path);
        final initVideo = method(
          source,
          'Future<void> _initVideoInternal() async {',
          'void _videoListener() {',
        );
        expect(
          initVideo,
          contains("playbackService.state == PlaybackState.loading"),
        );
        expect(
          initVideo.indexOf('playbackService.state == PlaybackState.loading'),
          lessThan(initVideo.indexOf('playbackService.play(')),
          reason:
              'the forced-play fallback must be skipped for an in-flight '
              'load of the same item',
        );
      }
    },
  );

  test('page initialization is single-flight across service notifications', () {
    final source = read('lib/screens/video_player_screen.dart');
    expect(source, contains('Future<void>? _initVideoInFlight;'));
    expect(source, contains('_initVideoRerunPending'));
    expect(source, contains('Future<void> _runInitVideoGuarded()'));
  });
}
