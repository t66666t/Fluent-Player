import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

SubtitleItem _subtitle(String text) {
  return SubtitleItem(
    index: 0,
    startTime: Duration.zero,
    endTime: const Duration(seconds: 1),
    text: text,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'audio-only respects actual background visibility even with a retained page or cover',
    () {
      for (final cover in [false, true]) {
        expect(
          MediaPlaybackService.shouldEnableBilibiliVideoTrack(
            hasPlaybackPageOwner: true,
            backgroundAudioOnly: true,
            coverRequestsVideo: cover,
            isAppInForeground: false,
          ),
          isFalse,
        );
        expect(
          MediaPlaybackService.shouldEnableBilibiliVideoTrack(
            hasPlaybackPageOwner: true,
            backgroundAudioOnly: true,
            coverRequestsVideo: cover,
            isAppInForeground: true,
          ),
          isTrue,
        );
      }
      expect(
        MediaPlaybackService.shouldEnableBilibiliVideoTrack(
          hasPlaybackPageOwner: true,
          backgroundAudioOnly: false,
          isAppInForeground: false,
        ),
        isTrue,
      );
    },
  );

  test(
    'subtitle snapshots are immutable and revision detects same-size edits',
    () {
      final service = MediaPlaybackService();
      service.clearSubtitleState();
      final initialRevision = service.subtitleRevision;
      final source = <SubtitleItem>[_subtitle('before')];

      service.setSubtitleState(
        paths: const <String>['primary.srt'],
        primary: source,
        secondary: const <SubtitleItem>[],
      );
      final firstRevision = service.subtitleRevision;
      expect(firstRevision, greaterThan(initialRevision));
      expect(service.subtitles.single.text, 'before');

      source[0] = _subtitle('mutated outside service');
      expect(service.subtitles.single.text, 'before');
      expect(
        () => service.subtitles.add(_subtitle('not allowed')),
        throwsUnsupportedError,
      );

      service.setSubtitleState(
        paths: const <String>['primary.srt'],
        primary: <SubtitleItem>[_subtitle('after')],
        secondary: const <SubtitleItem>[],
      );
      expect(service.subtitleRevision, greaterThan(firstRevision));
      expect(service.subtitles.single.text, 'after');
    },
  );

  test('subtitle load commits only for the active media item', () async {
    final service = MediaPlaybackService();
    service.clearSubtitleState();
    await service.updateMetadata(
      VideoItem(
        id: 'active',
        path: 'active.mp4',
        title: 'Active',
        durationMs: 0,
        lastUpdated: 0,
      ),
    );
    final revisionBeforeRejectedLoad = service.subtitleRevision;

    final rejected = await service.loadSubtitlePathsForCurrentItem(
      itemId: 'stale',
      paths: const <String>[],
    );
    expect(rejected, isFalse);
    expect(service.subtitleRevision, revisionBeforeRejectedLoad);

    final committed = await service.loadSubtitlePathsForCurrentItem(
      itemId: 'active',
      paths: const <String>[],
    );
    expect(committed, isTrue);
    expect(service.subtitleRevision, greaterThan(revisionBeforeRejectedLoad));
  });

  test(
    'metadata hand-off publishes an empty transcript with the new item',
    () async {
      final service = MediaPlaybackService.forTesting();
      service.debugSeedCurrentItem(
        VideoItem(
          id: 'old',
          path: 'old.mp4',
          title: 'Old',
          durationMs: 1000,
          lastUpdated: 0,
        ),
      );
      service.setSubtitleState(
        paths: ['old.srt'],
        primary: [_subtitle('Old transcript')],
        secondary: const [],
      );
      final snapshots = <List<String>>[];
      service.addListener(() {
        if (service.currentItem?.id == 'new') {
          snapshots.add(service.subtitles.map((cue) => cue.text).toList());
        }
      });
      await service.updateMetadata(
        VideoItem(
          id: 'new',
          path: 'new.mp4',
          title: 'New',
          durationMs: 1000,
          lastUpdated: 0,
        ),
      );
      expect(snapshots, [isEmpty]);
      expect(service.subtitlePaths, isEmpty);
      expect(service.currentSubtitle, isNull);
    },
  );

  test('mini playback card is visible while a restored session is loading', () {
    final item = VideoItem(
      id: 'online',
      path: 'bilibili://stream/BV1xx411c7mD?cid=1',
      title: 'Online',
      durationMs: 120000,
      lastUpdated: 0,
    );
    expect(
      isMiniPlaybackCardVisible(
        currentItem: item,
        state: PlaybackState.loading,
      ),
      isTrue,
    );
    expect(
      isMiniPlaybackCardVisible(currentItem: item, state: PlaybackState.paused),
      isTrue,
    );
    expect(
      isMiniPlaybackCardVisible(
        currentItem: null,
        state: PlaybackState.loading,
      ),
      isFalse,
    );
    expect(
      isMiniPlaybackCardVisible(currentItem: item, state: PlaybackState.idle),
      isFalse,
    );
    expect(
      isMiniPlaybackCardVisible(currentItem: item, state: PlaybackState.error),
      isTrue,
    );
  });

  test('online Bilibili restore does not prepare the native player', () {
    final online = VideoItem(
      id: 'online',
      path: 'bilibili://stream/BV1xx411c7mD?cid=1',
      title: 'Online',
      durationMs: 120000,
      lastUpdated: 0,
      sourceRef: const MediaSourceRef(
        value: 'BV1xx411c7mD',
        kind: MediaSourceKind.bilibiliStream,
        bvid: 'BV1xx411c7mD',
        cid: 1,
      ),
    );
    final local = VideoItem(
      id: 'local',
      path: r'D:\media\clip.mp4',
      title: 'Local',
      durationMs: 1000,
      lastUpdated: 0,
    );
    expect(
      MediaPlaybackService.shouldPrepareNativePlayerOnRestore(online),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldPrepareNativePlayerOnRestore(local),
      isTrue,
    );
  });

  test('podcast, cloud and direct URL restores need no native player', () {
    for (final entry in <(String, MediaSourceKind?)>[
      ('podcast:saved-episode', MediaSourceKind.podcastEpisode),
      ('cloud-drive:saved-file', MediaSourceKind.cloudDrive),
      ('https://example.invalid/saved.mp3', MediaSourceKind.url),
      ('https://example.invalid/saved.mp4', null),
      ('bilibili://stream/saved', null),
    ]) {
      final item = VideoItem(
        id: 'offline-bookmark',
        path: entry.$1,
        title: 'Saved title',
        durationMs: 120000,
        lastUpdated: 0,
        sourceRef: entry.$2 == null
            ? null
            : MediaSourceRef(value: entry.$1, kind: entry.$2!),
      );
      expect(
        MediaPlaybackService.shouldPrepareNativePlayerOnRestore(item),
        isFalse,
        reason: entry.$1,
      );
    }
  });

  test(
    'offline bookmarks restore the selected local primary subtitle',
    () async {
      final root = await Directory.systemTemp.createTemp('mini-offline-');
      final subtitle = File('${root.path}/selected.srt');
      await subtitle.writeAsString(
        '1\n00:00:40,000 --> 00:00:45,000\nSaved primary subtitle\n',
      );
      final service = MediaPlaybackService.forTesting();
      addTearDown(() async {
        await service.stop();
        service.dispose();
        await root.delete(recursive: true);
      });
      final loaded = service.subtitles.isNotEmpty;
      expect(loaded, isFalse);
      final ready = Completer<void>();
      service.addListener(() {
        if (service.currentSubtitle?.text == 'Saved primary subtitle' &&
            !ready.isCompleted) {
          ready.complete();
        }
      });
      service.publishRestoredSessionPreview(
        VideoItem(
          id: 'offline-podcast',
          path: 'podcast:offline',
          title: 'Offline podcast',
          durationMs: 120000,
          lastUpdated: 0,
          subtitlePath: subtitle.path,
        ),
        const Duration(seconds: 42),
      );
      expect(service.currentItem?.title, 'Offline podcast');
      expect(service.position, const Duration(seconds: 42));
      expect(service.duration, const Duration(minutes: 2));
      expect(service.controller, isNull);
      await ready.future.timeout(const Duration(seconds: 5));
      expect(service.currentSubtitle?.text, 'Saved primary subtitle');
      expect(service.state, PlaybackState.paused);
      expect(service.controller, isNull);
    },
  );

  test(
    'restored session preview shows Mini chrome without a controller',
    () async {
      final service = MediaPlaybackService();
      await service.stop();
      addTearDown(service.stop);
      final item = VideoItem(
        id: 'online-preview',
        path: 'bilibili://stream/BV1xx411c7mD?cid=1',
        title: 'Online',
        durationMs: 120000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'BV1xx411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1xx411c7mD',
          cid: 1,
        ),
      );
      service.publishRestoredSessionPreview(item, const Duration(seconds: 42));
      expect(service.shouldShowMiniPlaybackCard, isTrue);
      expect(service.state, PlaybackState.paused);
      expect(service.controller, isNull);
      expect(service.currentItem?.id, item.id);
      expect(service.position, const Duration(seconds: 42));
    },
  );

  test(
    'failed restore warm keeps the Mini bookmark and its position',
    () async {
      final service = MediaPlaybackService();
      await service.stop();
      addTearDown(service.stop);
      final item = VideoItem(
        id: 'online-preview',
        path: 'bilibili://stream/BV1xx411c7mD?cid=1',
        title: 'Online',
        durationMs: 120000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'BV1xx411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1xx411c7mD',
          cid: 1,
        ),
      );
      service.publishRestoredSessionPreview(item, const Duration(seconds: 42));
      await service.warmRestoredOnlinePlayback(
        item,
        const Duration(seconds: 42),
      );
      expect(service.shouldShowMiniPlaybackCard, isTrue);
      expect(service.state, PlaybackState.paused);
      expect(service.controller, isNull);
      expect(service.position, const Duration(seconds: 42));
    },
  );

  test(
    'mini-card open does not start a second play while restore is loading',
    () {
      expect(
        MediaPlaybackService.shouldStartPlayWhenOpeningMiniSession(
          hasController: false,
          state: PlaybackState.loading,
        ),
        isFalse,
      );
      expect(
        MediaPlaybackService.shouldStartPlayWhenOpeningMiniSession(
          hasController: false,
          state: PlaybackState.paused,
        ),
        isTrue,
      );
      expect(
        MediaPlaybackService.shouldStartPlayWhenOpeningMiniSession(
          hasController: true,
          state: PlaybackState.paused,
        ),
        isFalse,
      );
    },
  );

  test(
    'play() keeps restored preview progress when startPosition is omitted',
    () {
      expect(
        MediaPlaybackService.resolvePlayStartPosition(
          startPosition: null,
          currentItemId: 'online-preview',
          itemId: 'online-preview',
          currentPosition: const Duration(seconds: 42),
          trackedProgress: null,
          lastPositionMs: 0,
        ),
        const Duration(seconds: 42),
      );
      expect(
        MediaPlaybackService.resolvePlayStartPosition(
          startPosition: null,
          currentItemId: 'online-preview',
          itemId: 'online-preview',
          currentPosition: Duration.zero,
          trackedProgress: null,
          lastPositionMs: 90000,
        ),
        const Duration(milliseconds: 90000),
      );
      expect(
        MediaPlaybackService.startPositionForCurrentSession(
          currentItemId: 'online-preview',
          itemId: 'online-preview',
          currentPosition: Duration.zero,
        ),
        isNull,
      );
      expect(
        MediaPlaybackService.startPositionForCurrentSession(
          currentItemId: 'online-preview',
          itemId: 'online-preview',
          currentPosition: const Duration(seconds: 42),
        ),
        const Duration(seconds: 42),
      );
      expect(
        MediaPlaybackService.resolvePlayStartPosition(
          startPosition: Duration.zero,
          currentItemId: 'online-preview',
          itemId: 'online-preview',
          currentPosition: const Duration(seconds: 42),
          trackedProgress: null,
          lastPositionMs: 90000,
        ),
        Duration.zero,
      );
    },
  );

  test(
    'non-zero resume always seeks even if Dart position already matches',
    () {
      expect(
        shouldSkipRedundantInitialSeek(
          target: const Duration(minutes: 5),
          actual: const Duration(minutes: 5),
        ),
        isFalse,
      );
      expect(
        shouldSkipRedundantInitialSeek(
          target: Duration.zero,
          actual: Duration.zero,
        ),
        isTrue,
      );
    },
  );

  test('online Bilibili clock resyncs a sudden byte-zero sample', () {
    expect(
      shouldResyncBilibiliClockFromZero(
        isOnlineBilibiliStream: true,
        expectedPosition: const Duration(minutes: 4),
        nativeSample: Duration.zero,
        now: DateTime(2026, 1, 1, 12),
        lastResyncAt: null,
      ),
      isTrue,
    );
    expect(
      shouldResyncBilibiliClockFromZero(
        isOnlineBilibiliStream: true,
        expectedPosition: const Duration(minutes: 4),
        nativeSample: Duration.zero,
        now: DateTime(2026, 1, 1, 12),
        lastResyncAt: DateTime(2026, 1, 1, 11, 59, 59),
      ),
      isFalse,
    );
    expect(
      shouldResyncBilibiliClockFromZero(
        isOnlineBilibiliStream: false,
        expectedPosition: const Duration(minutes: 4),
        nativeSample: Duration.zero,
        now: DateTime(2026, 1, 1, 12),
        lastResyncAt: null,
      ),
      isFalse,
    );
    expect(
      shouldResyncBilibiliClockFromZero(
        isOnlineBilibiliStream: true,
        expectedPosition: const Duration(minutes: 4),
        nativeSample: Duration.zero,
        now: DateTime(2026, 1, 1, 12),
        lastResyncAt: null,
        lastSeekSource: 'subtitle_hop',
        lastHopSeekAt: DateTime(2026, 1, 1, 11, 59, 59, 200),
      ),
      isFalse,
    );
    expect(
      shouldResyncBilibiliClockFromZero(
        isOnlineBilibiliStream: true,
        expectedPosition: const Duration(minutes: 4),
        nativeSample: Duration.zero,
        now: DateTime(2026, 1, 1, 12),
        lastResyncAt: null,
        duration: const Duration(minutes: 4),
      ),
      isFalse,
    );
  });

  test('a running clock is not parked when the visible frame is missing', () {
    expect(
      MediaPlaybackService.shouldParkWhenVisibleVideoFrameMissing(
        nativeClockPlaying: true,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldParkWhenVisibleVideoFrameMissing(
        nativeClockPlaying: false,
      ),
      isTrue,
    );
  });

  test(
    'Bilibili video track stays selected while a playback page is owned',
    () {
      expect(
        MediaPlaybackService.shouldEnableBilibiliVideoTrack(
          hasPlaybackPageOwner: true,
          backgroundAudioOnly: true,
        ),
        isTrue,
      );
      expect(
        MediaPlaybackService.shouldEnableBilibiliVideoTrack(
          hasPlaybackPageOwner: false,
          backgroundAudioOnly: true,
        ),
        isFalse,
      );
      expect(
        MediaPlaybackService.shouldEnableBilibiliVideoTrack(
          hasPlaybackPageOwner: false,
          backgroundAudioOnly: true,
          coverRequestsVideo: true,
        ),
        isTrue,
      );
      expect(
        MediaPlaybackService.shouldEnableBilibiliVideoTrack(
          hasPlaybackPageOwner: false,
          backgroundAudioOnly: false,
        ),
        isTrue,
      );
      expect(
        MediaPlaybackService.shouldDeferBilibiliVideoOnOpen(
          hasVisiblePlaybackPage: false,
          backgroundAudioOnly: true,
        ),
        isTrue,
      );
      expect(
        MediaPlaybackService.shouldDeferBilibiliVideoOnOpen(
          hasVisiblePlaybackPage: false,
          backgroundAudioOnly: false,
        ),
        isFalse,
      );
      expect(
        MediaPlaybackService.shouldDeferBilibiliVideoOnOpen(
          hasVisiblePlaybackPage: true,
          backgroundAudioOnly: true,
        ),
        isFalse,
      );
    },
  );

  test('Bilibili audio-only policy is applied on every native platform', () {
    final source = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('void _syncBilibiliVideoTrackPolicy()');
    final end = source.indexOf(
      'static bool shouldEnableBilibiliVideoTrack',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    expect(method, isNot(contains('Platform.isAndroid')));
    expect(method, isNot(contains('Platform.isIOS')));
    expect(method, contains('MediaSourceKind.bilibiliStream'));
  });

  test(
    'Mini/notification Bilibili sessions open the audio URL as primary media',
    () {
      final source = File(
        'lib/services/media_playback_service.dart',
      ).readAsStringSync();
      final start = source.indexOf(
        'VideoPlayerController _createBilibiliStreamController',
      );
      final end = source.indexOf(
        'bool _shouldFastStartBilibiliOnThisPlatform',
        start,
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final method = source.substring(start, end);
      expect(method, contains('playback.audioUri'));
      expect(
        method,
        contains('NativeVideoPlayerMediaKit.audioPrimaryStreamHeader'),
      );
      expect(
        method,
        contains('NativeVideoPlayerMediaKit.fastStreamStartHeader'),
      );
      expect(
        method,
        contains('NativeVideoPlayerMediaKit.deferVideoStreamHeader'),
      );
      expect(
        method,
        contains('NativeVideoPlayerMediaKit.startPositionMsHeader'),
      );
    },
  );

  test(
    'Mini Bilibili sessions keep the video URL and defer the video track',
    () {
      final playback = File(
        'lib/services/media_playback_service.dart',
      ).readAsStringSync();
      expect(
        playback,
        isNot(contains('bilibiliAudioPrimary = !_hasVisiblePlaybackPage')),
      );
      expect(playback, contains('shouldDeferBilibiliVideoOnOpen('));
      expect(
        playback,
        contains('NativeVideoPlayerMediaKit.deferVideoStreamHeader'),
      );
      final kit = File(
        'lib/platform/windows_video_player_media_kit.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(kit, contains('deferVideoStreamHeader'));
      expect(kit, contains('startWithoutVideo: audioPrimary || deferVideo'));
      expect(kit, contains("toStringAsFixed(3)"));
      expect(kit, contains('startPositionMsHeader'));
    },
  );

  test('desktop Bilibili skips the conservative 2s cache-pause-initial', () {
    final source = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'bool _shouldFastStartBilibiliOnThisPlatform()',
    );
    final end = source.indexOf(
      'Future<bool> _shouldFastStartCachedBilibiliStream',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    expect(method, contains('Platform.isWindows'));
    expect(method, contains('Platform.isLinux'));
  });

  test('initial start skips a redundant zero seek on a fresh stream', () {
    final source = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> _seekInitialPositionImpl');
    final end = source.indexOf('void _trackMobileControllerRelease', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    expect(method, contains('_seekVerificationToleranceMs'));
    expect(method, isNot(contains('attempt < 3')));
    expect(method, contains('StreamingSeekStyle.scrub'));
    expect(method, contains('shouldSkipRedundantInitialSeek('));
    expect(source, contains('_confirmInitialResumePosition('));
  });

  test('notification skips prefetch the adjacent Bilibili playurl', () {
    final source = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    expect(
      source,
      contains(
        'void _prefetchNeighborBilibiliStreams({bool replaceStale = true})',
      ),
    );
    expect(source, contains('streaming.prefetch(item)'));
    expect(
      source,
      contains('unawaited(_saveCurrentProgress(immediate: true))'),
    );
  });

  test(
    'Mini video promotion preserves the live clock and latest pause intent',
    () {
      // The native integration suite verifies the same-player texture join.
      // Here test the command policy rather than a private seek spelling.
      expect(
        NativeVideoPlayerMediaKit.shouldResumeExternalVideoTrack(
          playing: true,
          keepPlaying: true,
          keepPaused: false,
        ),
        isTrue,
      );
      expect(
        NativeVideoPlayerMediaKit.shouldResumeExternalVideoTrack(
          playing: true,
          keepPlaying: true,
          keepPaused: true,
        ),
        isFalse,
      );
      expect(
        MediaPlaybackService.shouldResumeOnPageAdopt(
          desiredPlaying: true,
          state: PlaybackState.playing,
        ),
        isFalse,
      );
      expect(
        MediaPlaybackService.shouldPauseOnPageAdopt(
          desiredPlaying: true,
          state: PlaybackState.playing,
          controllerPlaying: false,
        ),
        isFalse,
      );
      expect(
        MediaPlaybackService.shouldPauseOnPageAdopt(
          desiredPlaying: false,
          state: PlaybackState.paused,
          controllerPlaying: true,
        ),
        isTrue,
      );
    },
  );

  test('page adopt does not resume a live Mini or notification clock', () {
    expect(
      MediaPlaybackService.shouldResumeOnPageAdopt(
        desiredPlaying: true,
        state: PlaybackState.playing,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldResumeOnPageAdopt(
        desiredPlaying: true,
        state: PlaybackState.loading,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldResumeOnPageAdopt(
        desiredPlaying: true,
        state: PlaybackState.paused,
      ),
      isTrue,
    );
    expect(
      MediaPlaybackService.shouldPauseOnPageAdopt(
        desiredPlaying: true,
        state: PlaybackState.playing,
        controllerPlaying: false,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldRestoreTransportOnForeground(
        desiredPlaying: true,
        state: PlaybackState.playing,
        controllerReady: true,
        controllerPlaying: false,
      ),
      isTrue,
    );
    expect(
      MediaPlaybackService.shouldRestoreTransportOnForeground(
        desiredPlaying: false,
        state: PlaybackState.paused,
        controllerReady: true,
        controllerPlaying: true,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.shouldRestoreTransportOnForeground(
        desiredPlaying: true,
        state: PlaybackState.loading,
        controllerReady: true,
        controllerPlaying: false,
      ),
      isFalse,
    );
  });
}
