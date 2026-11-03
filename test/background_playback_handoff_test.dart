import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/media_playback_service.dart';

void main() {
  test('headless background video is playback-ready without a UI texture', () {
    expect(
      MediaPlaybackService.playbackRequestNeedsVideoOutput(
        isVideo: true,
        hasVisiblePlaybackPage: false,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.playbackRequestNeedsVideoOutput(
        isVideo: true,
        hasVisiblePlaybackPage: true,
      ),
      isTrue,
    );
    expect(
      MediaPlaybackService.playbackRequestNeedsVideoOutput(
        isVideo: false,
        hasVisiblePlaybackPage: true,
      ),
      isFalse,
    );
  });

  test('foreground handoff attaches first and only reopens after failure', () {
    final serviceSource = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    final methodStart = serviceSource.indexOf(
      'Future<bool> ensureVisibleVideoOutput',
    );
    final methodEnd = serviceSource.indexOf(
      '/// Whether an item can be opened',
      methodStart,
    );
    expect(methodStart, greaterThanOrEqualTo(0));
    expect(methodEnd, greaterThan(methodStart));
    final method = serviceSource.substring(methodStart, methodEnd);
    final attach = method.indexOf('attachVideoOutputFor');
    final attachFailed = method.indexOf('visible output attachment failed');
    final reopen = method.indexOf('reopening media with preserved position');
    expect(attach, greaterThanOrEqualTo(0));
    // The primary path is still a zero-reload attachment to the existing
    // native player; the reopen fallback must exist only after the explicit
    // attachment-failure marker.
    expect(attachFailed, greaterThan(attach));
    expect(reopen, greaterThan(attachFailed));
    final beforeFailure = method.substring(0, attachFailed);
    expect(beforeFailure, isNot(contains('await play(')));
    expect(beforeFailure, isNot(contains('forceRecreate: true')));
    // A reopen during an in-flight episode switch would cancel the switch, so
    // the fallback must be guarded by the media-switch busy check.
    expect(
      method.indexOf('isEpisodeNavigationBusy'),
      greaterThan(attachFailed),
    );
    expect(method.indexOf('isEpisodeNavigationBusy'), lessThan(reopen));

    final platformSource = File(
      'lib/platform/windows_video_player_media_kit.dart',
    ).readAsStringSync();
    final attachStart = platformSource.indexOf(
      'Future<bool> _attachVideoOutputFor',
    );
    final attachEnd = platformSource.indexOf(
      'Future<bool>? _playbackReadyFor',
      attachStart,
    );
    final attachMethod = platformSource.substring(attachStart, attachEnd);
    expect(attachMethod, contains('_players[textureId]'));
    expect(attachMethod, contains('_videoControllers[textureId]'));
    expect(attachMethod, isNot(contains('player.open(')));
    expect(attachMethod, isNot(contains('player.seek(')));
  });

  test('notification skip ignores duplicate callbacks while active', () {
    final source = File(
      'lib/services/system_media_session_service.dart',
    ).readAsStringSync();
    expect(source, contains('bool _episodeSkipInFlight = false;'));
    expect(source, contains('await _handleSingleEpisodeSkip(isNext: true);'));
    expect(source, contains('await _handleSingleEpisodeSkip(isNext: false);'));
    expect(source, contains('if (_episodeSkipInFlight)'));
    expect(
      source,
      contains('await _runSerialized(() => _handleQueueSkip(isNext: isNext));'),
    );
    expect(source, contains('await playbackService.playNext();'));
    expect(source, contains('await playbackService.playPrevious();'));
  });

  test('background output priming attaches to the existing player', () {
    final source = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('void _primeDeferredVideoOutput');
    final end = source.indexOf('Future<bool> ensureVisibleVideoOutput', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    expect(method, contains('attachVideoOutputFor'));
    expect(method, isNot(contains('play(')));
    expect(method, isNot(contains('seek')));
  });

  test('programmatic notification navigation cannot auto-pause playback', () {
    for (final path in <String>[
      'lib/screens/portrait_video_screen.dart',
      'lib/screens/video_player_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('bool _explicitPlaybackExitRequested = false;'));
      expect(
        source,
        contains('shouldPauseOnPlaybackPageExit('),
        reason: '$path may pause only after an explicit user exit',
      );
      expect(source, contains('explicitExit: _explicitPlaybackExitRequested'));
    }
  });

  test(
    'desktop playback page exit honors auto-pause without a platform gate',
    () {
      final source = File(
        'lib/screens/video_player_screen.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future<void> _handleExitOnce()');
      final end = source.indexOf('  @override', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final exitLogic = source.substring(start, end);
      expect(exitLogic, contains('settings.autoPauseOnExit'));
      expect(exitLogic, contains('await playbackService.pause('));
      expect(exitLogic, isNot(contains('Platform.isAndroid')));
      expect(exitLogic, isNot(contains('Platform.isIOS')));
    },
  );

  test('background clock is ready while a stream is still buffering', () {
    expect(
      NativeVideoPlayerMediaKit.isBackgroundPlaybackClockReady(
        playing: true,
        completed: false,
        positionAdvanced: true,
        bufferedAhead: false,
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.isBackgroundPlaybackClockReady(
        playing: true,
        completed: false,
        positionAdvanced: false,
        bufferedAhead: true,
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.isBackgroundPlaybackClockReady(
        playing: true,
        completed: false,
        positionAdvanced: false,
        bufferedAhead: false,
      ),
      isFalse,
    );
    expect(
      NativeVideoPlayerMediaKit.isBackgroundPlaybackClockReady(
        playing: false,
        completed: false,
        positionAdvanced: true,
        bufferedAhead: true,
      ),
      isTrue,
    );
  });

  test('audio-only Bilibili opens attach audio before waiting for video', () {
    final kit = File(
      'lib/platform/windows_video_player_media_kit.dart',
    ).readAsStringSync();
    final start = kit.indexOf('Future<void> _openMediaWithExternalAudio');
    final end = kit.indexOf(
      'Future<VideoTrack> _waitForPrimaryVideoTrack',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = kit.substring(start, end);
    expect(
      method.indexOf('_attachExternalAudio'),
      lessThan(method.indexOf('_waitForPrimaryVideoTrack')),
    );
    expect(method, contains('if (audioOnly)'));
    expect(method, contains('return;'));

    final waitStart = kit.indexOf(
      'Future<VideoTrack> _waitForPrimaryVideoTrack',
    );
    final waitEnd = kit.indexOf(
      'Future<void> _configureStreamingBuffer',
      waitStart,
    );
    final waitMethod = kit.substring(waitStart, waitEnd);
    expect(waitMethod, contains('milliseconds: 400'));
    expect(waitMethod, isNot(contains('seconds: 8')));
    expect(waitMethod, isNot(contains('seconds: 20')));
  });

  test('audio-only streaming uses a small readahead window', () {
    final kit = File(
      'lib/platform/windows_video_player_media_kit.dart',
    ).readAsStringSync();
    final start = kit.indexOf('Future<void> _configureStreamingBuffer');
    final end = kit.indexOf(
      'Future<void> _configureHighResolutionPlayback',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = kit.substring(start, end);
    expect(method, contains('audioOnly'));
    expect(method, contains("cacheSecs = audioOnly ? '6'"));
    expect(method, contains("readaheadSecs = audioOnly ? '4'"));
    expect(method, contains('demuxer-lavf-analyzeduration'));
    expect(method, contains('force-seekable'));
  });
}
