import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'cloud_drive_playback_workflow_test.dart' show CloudPlaybackFake;

class _Platform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final clocks = <int, Stopwatch>{};
  final playing = <int>{};
  var nextId = 1;

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = nextId++;
    events[id] = StreamController<VideoEvent>();
    positions[id] = Duration.zero;
    clocks[id] = Stopwatch();
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    scheduleMicrotask(
      () => events[playerId]?.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 2),
          size: const Size(1280, 720),
        ),
      ),
    );
    return events[playerId]!.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    playing.remove(playerId);
    clocks.remove(playerId)?.stop();
    positions.remove(playerId);
    await events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    playing.add(playerId);
    clocks[playerId]?.start();
  }

  @override
  Future<void> pause(int playerId) async {
    playing.remove(playerId);
    clocks[playerId]?.stop();
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    positions[playerId] = position;
    clocks[playerId]?.reset();
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      (positions[playerId] ?? Duration.zero) +
      (clocks[playerId]?.elapsed ?? Duration.zero);
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}
  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

class _Api extends BilibiliApiService {
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async =>
      BilibiliStreamInfo(
        durationMs: 120000,
        qualityMap: const {80: '1080P'},
        videoStreams: [
          StreamItem(
            id: 80,
            baseUrl: 'https://upos-test.bilivideo.com/video-$cid.m4s',
            bandwidth: 1000000,
            codecs: 'avc1.640028',
            codecid: 7,
            mimeType: 'video/mp4',
            qualityName: '1080P',
            width: 1920,
            height: 1080,
            initializationRange: '0-999',
            indexRange: '1000-1999',
          ),
        ],
        audioStreams: [
          StreamItem(
            id: 30280,
            baseUrl: 'https://upos-test.bilivideo.com/audio-$cid.m4s',
            bandwidth: 128000,
            codecs: 'mp4a.40.2',
            codecid: 0,
            mimeType: 'audio/mp4',
            initializationRange: '0-999',
            indexRange: '1000-1999',
          ),
        ],
      );
}

class _StateStore extends PlaybackStateStore {
  Map<String, dynamic>? snapshot;
  @override
  Future<void> write(Map<String, dynamic> value) async =>
      snapshot = Map.of(value);
  @override
  Future<Map<String, dynamic>?> read() async => snapshot;
}

VideoItem _item(String id, MediaSourceKind kind) {
  final cloud = CloudDriveSourceRef(
    providerId: 'baidu',
    remoteAccountId: '42',
    driveId: '0',
    fileId: id,
    revision: 'rev',
  );
  final isCloud = kind == MediaSourceKind.cloudDrive;
  return VideoItem(
    id: id,
    path: isCloud
        ? cloud.logicalUri
        : 'bilibili://stream/BV1xx411c7mD?cid=${id.hashCode.abs() + 1}',
    title: id,
    durationMs: 120000,
    lastUpdated: 1,
    sourceRef: MediaSourceRef(
      value: isCloud ? cloud.logicalUri : 'BV1xx411c7mD',
      kind: kind,
      cloudDrive: isCloud ? cloud : null,
      bvid: isCloud ? null : 'BV1xx411c7mD',
      cid: isCloud ? null : id.hashCode.abs() + 1,
    ),
  );
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform originalPlatform;
  late _Platform platform;
  late LibraryService library;
  late MediaPlaybackService playback;
  late PlaylistManager playlist;
  late _StateStore stateStore;
  late CloudPlaybackFake cloud;
  late BilibiliStreamingService bilibili;
  final gates = <Completer<void>>[];

  Completer<void> gate() {
    final value = Completer<void>();
    gates.add(value);
    return value;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    settings.autoPlayOnCompletion = true;
    settings.autoPlayOnCompletionFromStart = false;
    settings.playlistWrapToFirst = false;
    originalPlatform = VideoPlayerPlatform.instance;
    platform = _Platform();
    VideoPlayerPlatform.instance = platform;
    library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    playlist = PlaylistManager();
    cloud = CloudPlaybackFake();
    bilibili = BilibiliStreamingService(_Api());
    playback = MediaPlaybackService.forTesting();
    stateStore = _StateStore();
    await playback.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(playbackStateStore: stateStore)
        ..initialize(libraryService: library),
      libraryService: library,
      bilibiliStreamingService: bilibili,
    );
    playback.attachCloudDrivePlayback(cloud);
  });

  tearDown(() async {
    for (final value in gates) {
      if (!value.isCompleted) value.complete();
    }
    gates.clear();
    await playback.stop();
    playback.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await bilibili.shutdown();
    await cloud.gatewayImpl.close();
    VideoPlayerPlatform.instance = originalPlatform;
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
  });

  Future<List<VideoItem>> start(
    MediaSourceKind kind, {
    bool onlyFirst = false,
  }) async {
    final first = _item('first', kind);
    final second = _item('second', MediaSourceKind.bilibiliStream)
      ..lastPositionMs = 30000;
    for (final item in [first, second]) {
      library.seedVideoForTesting(item);
    }
    playlist.setPlaylist(onlyFirst ? [first] : [first, second]);
    await playback.play(first);
    return [first, second];
  }

  void finish() {
    final controller = playback.controller!;
    final playerId = platform.events.keys.single;
    platform.positions[playerId] = const Duration(seconds: 119);
    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 119),
    );
    playback.updatePlaybackStateFromController();
    platform.events[playerId]!.add(
      VideoEvent(eventType: VideoEventType.completed),
    );
  }

  for (final mode in PlaybackMode.values) {
    for (final paused in [true, false]) {
      test(
        'adding while $mode / paused=$paused preserves the live controller',
        () async {
          final items = await start(
            MediaSourceKind.bilibiliStream,
            onlyFirst: true,
          );
          playlist.setPlaybackMode(mode);
          await playback.seekTo(const Duration(seconds: 17));
          if (paused) await playback.pause();
          final controller = playback.controller;
          final position = playback.position;
          final nativePlayers = platform.nextId;
          final automatic = SettingsService().autoPlayOnCompletion;
          playlist.addToPlaybackQueue([items.last]);
          expect(playback.controller, same(controller));
          expect(platform.nextId, nativePlayers);
          expect(playback.currentItem, same(items.first));
          expect(playback.position, position);
          expect(playback.isPlaying, !paused);
          expect(playback.playbackMode, mode);
          expect(SettingsService().autoPlayOnCompletion, automatic);
          expect(playback.nextPlayableItem?.id, items.last.id);
        },
      );
    }
  }

  for (final automatic in [true, false]) {
    test(
      'newly appended media respects automatic continuation=$automatic',
      () async {
        final items = await start(
          MediaSourceKind.bilibiliStream,
          onlyFirst: true,
        );
        SettingsService().autoPlayOnCompletion = automatic;
        playlist.addToPlaybackQueue([items.last]);
        finish();
        await _until(
          () => automatic
              ? playback.currentItem?.id == items.last.id && playback.isPlaying
              : playback.state == PlaybackState.paused &&
                    playback.position == playback.duration,
        );
        expect(
          playback.currentItem?.id,
          automatic ? items.last.id : items.first.id,
        );
      },
    );
  }

  test(
    'adding to an idle session exposes Mini without loading or starting a player',
    () {
      final queued = _item('queued', MediaSourceKind.bilibiliStream);
      playlist.addToPlaybackQueue([queued]);
      expect(playback.currentItem, isNull);
      expect(playback.queuedPreviewItem, same(queued));
      expect(playback.shouldShowMiniPlaybackCard, isTrue);
      expect(playback.controller, isNull);
      expect(playback.isPlaying, isFalse);
      expect(platform.events, isEmpty);
    },
  );

  test(
    'new additions do not interrupt repeat-one when automatic continuation is off',
    () async {
      final items = await start(
        MediaSourceKind.bilibiliStream,
        onlyFirst: true,
      );
      playlist.setPlaybackMode(PlaybackMode.repeatOne);
      SettingsService().autoPlayOnCompletion = false;
      playlist.addToPlaybackQueue([items.last]);
      finish();
      await _until(
        () =>
            playback.position < const Duration(seconds: 1) &&
            playback.isPlaying,
      );
      expect(playback.currentItem?.id, items.first.id);
      expect(playlist.playlist.length, 2);
      expect(playback.playbackMode, PlaybackMode.repeatOne);
    },
  );

  test(
    'list looping includes the newly appended media before returning to the start',
    () async {
      final items = await start(
        MediaSourceKind.bilibiliStream,
        onlyFirst: true,
      );
      SettingsService().playlistWrapToFirst = true;
      playlist.addToPlaybackQueue([items.last]);
      finish();
      await _until(
        () => playback.currentItem?.id == items.last.id && playback.isPlaying,
      );
      finish();
      await _until(
        () => playback.currentItem?.id == items.first.id && playback.isPlaying,
      );
      expect(playlist.playlist.map((e) => e.id), ['first', 'second']);
    },
  );

  test(
    'play on an unplayed random queue starts its displayed first item',
    () async {
      final items = [
        _item('queued1', MediaSourceKind.bilibiliStream),
        _item('queued2', MediaSourceKind.bilibiliStream),
      ];
      for (final item in items) {
        library.seedVideoForTesting(item);
      }
      playlist.addToPlaybackQueue(items);
      playlist.setPlaybackMode(PlaybackMode.shuffle);
      final first = playlist.playbackQueue.first;
      expect(playback.queuedPreviewItem, same(first));
      await playback.resume();
      expect(playback.currentItem?.id, first.id);
      expect(playback.isPlaying, isTrue);
      expect(playback.playbackMode, PlaybackMode.shuffle);
    },
  );

  for (final kind in [
    MediaSourceKind.cloudDrive,
    MediaSourceKind.bilibiliStream,
  ]) {
    for (final autoPlay in [true, false]) {
      test(
        '${kind.name} completion respects autoplay=$autoPlay in a mixed queue',
        () async {
          SettingsService().autoPlayOnCompletion = autoPlay;
          final items = await start(kind);
          await playback.pause();
          finish();
          await _until(
            () => library.mediaActivity(items.first.id)?.completed == true,
          );
          await _until(
            () => autoPlay
                ? playback.currentItem?.id == 'second' && playback.isPlaying
                : playback.state == PlaybackState.paused &&
                      playback.position == playback.duration,
          );
          expect(items.first.lastPositionMs, 0);
          if (!autoPlay) {
            final controller = playback.controller;
            expect(playback.position, const Duration(minutes: 2));
            expect(playback.positionNotifier.value, playback.duration);
            expect(playback.coarsePositionNotifier.value, playback.duration);
            expect(
              playback.positionForProgressChrome(Duration.zero),
              playback.duration,
            );
            expect(controller!.value.isPlaying, isFalse);
            await playback.persistCurrentProgress();
            expect(items.first.lastPositionMs, 0);
            expect(stateStore.snapshot?['positionMs'], 0);
            expect(stateStore.snapshot?['wasPlaying'], isFalse);

            await playback.resume();
            expect(playback.controller, same(controller));
            expect(playback.currentItem?.id, items.first.id);
            expect(playback.isPlaying, isTrue);
            expect(playback.position, lessThan(const Duration(seconds: 1)));
          }
          if (autoPlay) {
            expect(playback.position.inSeconds, 30);
            await playback.playPlaylistItem(items.first, autoPlay: true);
            expect(playback.position, lessThan(const Duration(seconds: 1)));
            await playback.seekTo(const Duration(seconds: 3));
            await playback.persistCurrentProgress();
            expect(library.mediaActivity('first')!.completed, isTrue);
          }
        },
      );
    }

    test(
      '${kind.name} rejects completion at the end of a short native probe',
      () async {
        await start(kind);
        final controller = playback.controller!;
        final playerId = platform.events.keys.single;
        platform.positions[playerId] = const Duration(seconds: 2);
        platform.playing.remove(playerId);
        controller.value = controller.value.copyWith(
          position: const Duration(seconds: 2),
          duration: const Duration(seconds: 2),
          isPlaying: false,
          isCompleted: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(library.mediaActivity('first')?.completed, isNot(true));
        expect(playback.currentItem?.id, 'first');
        expect(playback.duration, const Duration(minutes: 2));
      },
    );
  }

  for (final timerQueue in [false, true]) {
    test(
      'cloud completion loads the next queue page with timer=$timerQueue',
      () async {
        final items = await start(MediaSourceKind.cloudDrive, onlyFirst: true);
        var pages = 0;
        playback.cloudDriveLoadNextPlaylistPage = () async {
          pages++;
          playlist.appendPlaylistItems([items.last]);
          return [items.last];
        };
        if (timerQueue) {
          SettingsService().autoPlayOnCompletion = false;
          await playback.sleepTimer.scheduleAtEndOfQueue();
        }
        finish();
        await _until(
          () => playback.currentItem?.id == 'second' && playback.isPlaying,
        );
        expect(pages, 1);
        expect(playback.position.inSeconds, 30);
      },
    );
  }

  test(
    'a failed old cloud queue request cannot park a new selection',
    () async {
      final items = await start(MediaSourceKind.cloudDrive);
      final entered = gate(), release = gate();
      playback.cloudDriveQueueNeedsCompletion = () => true;
      playback.cloudDrivePreparePlaylist = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        throw StateError('directory unavailable');
      };
      finish();
      await entered.future.timeout(const Duration(seconds: 4));
      await playback.playPlaylistItem(items.last, autoPlay: true);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(playback.currentItem?.id, 'second');
      expect(playback.isPlaying, isTrue);
      expect(playback.position.inSeconds, 30);
      expect(items.last.lastPositionMs, greaterThanOrEqualTo(30000));
      expect(playback.cloudDriveNotice, isNot('目录读取未完成，请重试上一集或下一集'));
    },
  );

  test(
    'an old pending cloud completion cannot swallow a new item completion',
    () async {
      final items = await start(MediaSourceKind.cloudDrive);
      final entered = gate(), release = gate();
      playback.cloudDriveQueueNeedsCompletion = () => true;
      playback.cloudDrivePreparePlaylist = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      finish();
      await entered.future.timeout(const Duration(seconds: 4));
      await playback.playPlaylistItem(items.last, autoPlay: true);
      finish();
      await _until(() => library.mediaActivity('second')?.completed == true);
      release.complete();
      await _until(() => playback.state == PlaybackState.paused);
      expect(playback.currentItem?.id, 'second');
      expect(playback.position, const Duration(minutes: 2));
    },
  );

  test(
    'a slow completion save cannot overwrite the new item bookmark',
    () async {
      final items = await start(MediaSourceKind.cloudDrive);
      final entered = gate(), release = gate();
      library.writeLibrarySnapshotOverrideForTesting = () async {
        if (library.mediaActivity('first')?.completed == true &&
            !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      finish();
      await entered.future.timeout(const Duration(seconds: 4));
      await playback.playPlaylistItem(items.last, autoPlay: true);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(playback.currentItem?.id, 'second');
      expect(playback.position.inSeconds, 30);
      expect(items.last.lastPositionMs, inInclusiveRange(30000, 31000));
      expect(library.mediaActivity('second')?.completed, isNot(true));
    },
  );

  test(
    'pause while waiting for a cloud queue cancels automatic advance',
    () async {
      await start(MediaSourceKind.cloudDrive);
      final entered = gate(), release = gate();
      playback.cloudDriveQueueNeedsCompletion = () => !release.isCompleted;
      playback.cloudDrivePreparePlaylist = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      finish();
      await entered.future.timeout(const Duration(seconds: 4));
      await playback.pause();
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(playback.currentItem?.id, 'first');
      expect(playback.state, PlaybackState.paused);
      expect(library.getVideo('first')!.lastPositionMs, 0);
      expect(stateStore.snapshot?['positionMs'], 0);
      expect(stateStore.snapshot?['wasPlaying'], isFalse);
    },
  );

  test(
    'stop during a pending cloud completion keeps the restart bookmark',
    () async {
      await start(MediaSourceKind.cloudDrive);
      final entered = gate(), release = gate();
      playback.cloudDriveQueueNeedsCompletion = () => !release.isCompleted;
      playback.cloudDrivePreparePlaylist = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      finish();
      await entered.future.timeout(const Duration(seconds: 4));
      await playback.stop();
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(playback.currentItem, isNull);
      expect(library.getVideo('first')!.lastPositionMs, 0);
      expect(library.mediaActivity('first')!.completed, isTrue);
    },
  );

  test('foreground restore does not restart a completed cloud item', () async {
    await start(MediaSourceKind.cloudDrive);
    final entered = gate(), release = gate();
    playback.cloudDriveQueueNeedsCompletion = () => !release.isCompleted;
    playback.cloudDrivePreparePlaylist = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    finish();
    await entered.future.timeout(const Duration(seconds: 4));
    final playerId = platform.events.keys.single;
    expect(platform.playing, isNot(contains(playerId)));
    playback.handleAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(platform.playing, isNot(contains(playerId)));
    expect(library.mediaActivity('first')!.completed, isTrue);
  });

  test('autoplay off does not wait for an unfinished cloud listing', () async {
    await start(MediaSourceKind.cloudDrive);
    SettingsService().autoPlayOnCompletion = false;
    var reads = 0;
    final release = gate();
    playback.cloudDriveQueueNeedsCompletion = () => true;
    playback.cloudDrivePreparePlaylist = () async {
      reads++;
      await release.future;
    };
    finish();
    await _until(
      () =>
          playback.state == PlaybackState.paused &&
          playback.position == playback.duration,
    );
    expect(reads, 0);
    expect(playback.currentItem?.id, 'first');
  });

  test(
    'end-of-current sleep timer stops without waiting for cloud listing',
    () async {
      await start(MediaSourceKind.cloudDrive);
      final release = gate();
      var reads = 0;
      playback.cloudDriveQueueNeedsCompletion = () => true;
      playback.cloudDrivePreparePlaylist = () async {
        reads++;
        await release.future;
      };
      await playback.sleepTimer.scheduleAtEndOfCurrentItem();
      finish();
      await _until(() => !playback.sleepTimer.isActive);
      expect(playback.currentItem?.id, 'first');
      expect(playback.state, PlaybackState.paused);
      expect(reads, 0);
    },
  );
}
