import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/features/media_cache/media_cache_hooks.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/community_media_input.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';

const _podcast = MediaSourceRef(
  value: 'podcast:old',
  kind: MediaSourceKind.podcastEpisode,
  podcast: PodcastEpisodeRef(
    channelId: 'old-channel',
    episodeId: 'old',
    feedUrl: 'https://publisher.invalid/rss',
    mediaUrl: 'https://publisher.invalid/episode.mp3',
  ),
);

class _Api extends BilibiliApiService {
  int requests = 0;
  @override
  Future<BilibiliStreamInfo> fetchMediaPlayUrl(
    String bvid,
    int cid, {
    int? courseEpisodeId,
  }) async {
    requests++;
    throw StateError('Remote resolver must never be called');
  }
}

class _Player extends VideoPlayerPlatform {
  final sources = <DataSource>[];
  final streams = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options.dataSource);
    final id = sources.length;
    streams[id] = StreamController<VideoEvent>();
    positions[id] = Duration.zero;
    scheduleMicrotask(
      () => streams[id]?.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 2),
          size: const Size(640, 360),
        ),
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) => streams[id]!.stream;
  @override
  Future<Duration> getPosition(int id) async => positions[id] ?? Duration.zero;
  @override
  Future<void> seekTo(int id, Duration position) async {
    positions[id] = position;
  }

  @override
  Future<void> play(int id) async {}
  @override
  Future<void> pause(int id) async {}
  @override
  Future<void> dispose(int id) async {
    await streams.remove(id)?.close();
  }

  @override
  Future<void> setVolume(int id, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int id, double speed) async {}
  @override
  Future<void> setLooping(int id, bool looping) async {}
  @override
  Future<void> setMixWithOthers(bool mix) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool allow) async {}
  @override
  Widget buildView(int id) => const SizedBox.shrink();
}

VideoItem _item(String id, String path, {MediaSourceRef? source}) => VideoItem(
  id: id,
  path: path,
  title: id,
  durationMs: 120000,
  lastUpdated: 0,
  sourceRef: source,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('all remote media contracts fail even with saved RSS provenance', () {
    for (final path in [
      'https://publisher.invalid/episode.mp3',
      'http://127.0.0.1:54321/stream',
      'podcast:old',
      'bilibili://stream/BVold/1',
      'cloud-drive://old/file',
      'ftp://media.invalid/file',
      'file://remote-server/share/episode.mp3',
    ]) {
      expect(
        () => requireCommunityProcessingSource(path, source: _podcast),
        throwsUnsupportedError,
      );
      expect(
        PlaybackQueuePolicy(
          sourceExists: (_) => true,
        ).isEligible(_item('remote', path, source: _podcast)),
        isFalse,
      );
      expect(
        MediaPlaybackService.shouldPrepareNativePlayerOnRestore(
          _item('remote', path, source: _podcast),
        ),
        isFalse,
      );
    }
  });

  test(
    'legacy play, restore and resume never resolve or open remote input',
    () async {
      final player = _Player(), previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = player;
      final service = MediaPlaybackService.forTesting();
      var resolutions = 0;
      final previousResolver = PodcastPlaybackHooks.resolve;
      PodcastPlaybackHooks.resolve = (_) async {
        resolutions++;
        return Uri.parse('https://publisher.invalid/audio.mp3');
      };
      try {
        for (final path in [
          'podcast:old',
          'https://publisher.invalid/audio.mp3',
          'bilibili://stream/BVold/1',
          'cloud-drive://old/file',
        ]) {
          final item = _item(path, path, source: _podcast);
          await expectLater(service.play(item), throwsUnsupportedError);
          await expectLater(
            service.playPlaylistItem(item),
            throwsUnsupportedError,
          );
          service.publishRestoredSessionPreview(
            item,
            const Duration(seconds: 28),
          );
          await service.warmRestoredOnlinePlayback(
            item,
            const Duration(seconds: 28),
          );
          await service.resume();
        }
        expect(service.currentItem, isNull);
        expect(resolutions, 0);
        expect(player.sources, isEmpty);
      } finally {
        await service.stop();
        service.dispose();
        PodcastPlaybackHooks.resolve = previousResolver;
        VideoPlayerPlatform.instance = previous;
      }
    },
  );

  test(
    'materialization and legacy cache recovery reject before a resolver',
    () async {
      final api = _Api(), service = MediaMaterializationService(_Api());
      final guarded = MediaMaterializationService(api);
      try {
        for (final path in [
          'podcast:old',
          'https://publisher.invalid/audio.mp3',
          'bilibili://stream/BVold/1',
        ]) {
          final item = _item(path, path, source: _podcast);
          await expectLater(
            guarded.videoQualities(item),
            throwsUnsupportedError,
          );
          await expectLater(
            guarded.getVerifiedPlaybackFile(item),
            throwsUnsupportedError,
          );
          await expectLater(
            guarded.acquireExistingPlayback(item),
            throwsUnsupportedError,
          );
          await expectLater(
            guarded.ensurePlaybackFileReady(item),
            throwsUnsupportedError,
          );
          for (final requirement in MediaMaterializationRequirement.values) {
            await expectLater(
              guarded.estimate(item, requirement),
              throwsUnsupportedError,
            );
            await expectLater(
              guarded.acquire(item, requirement),
              throwsUnsupportedError,
            );
          }
        }
        expect(api.requests, 0);
        expect(guarded.activeTasks, isEmpty);
      } finally {
        guarded.dispose();
        service.dispose();
      }
    },
  );

  test(
    'library local fast paths and visible projections retain historical records',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'local-library-boundary-',
      );
      final file = await File(
        '${root.path}${Platform.pathSeparator}downloaded.mp4',
      ).writeAsBytes([0]);
      final library = LibraryService()..resetLibraryForTesting();
      final local = _item('downloaded', file.path, source: _podcast);
      final cloudLocal = _item(
        'cloud-downloaded',
        file.path,
        source: _podcast.copyWith(kind: MediaSourceKind.cloudDrive),
      );
      final remote = _item('remote', 'podcast:remote', source: _podcast);
      final folder = VideoCollection(
        id: 'mixed',
        name: 'Mixed',
        createTime: 0,
        childrenIds: [local.id, cloudLocal.id, remote.id],
      );
      final retired = VideoCollection(
        id: 'retired',
        name: 'Retired',
        createTime: 0,
        podcastRef: const PodcastChannelRef(
          channelId: 'old',
          feedUrl: 'https://publisher.invalid/rss',
        ),
      );
      var hooks = 0;
      final previous = MediaCacheHooks.acquire;
      MediaCacheHooks.acquire = (item, {qualityId}) async {
        hooks++;
        throw StateError('Local file must bypass the retired cache runtime');
      };
      try {
        for (final item in [local, cloudLocal, remote]) {
          library.seedVideoForTesting(item);
        }
        library.seedCollectionForTesting(folder);
        library.seedCollectionForTesting(retired);
        expect(
          library
              .browseContents(folder.id)
              .map((item) => (item as VideoItem).id),
          [local.id, cloudLocal.id],
        );
        expect(library.searchContents('remote'), isEmpty);
        expect(
          library.collections.map((item) => item.id),
          isNot(contains(retired.id)),
        );
        expect(library.activityProjection.isVisibleMedia(remote.id), isFalse);
        expect(
          library.activityProjection
              .recentAddedMediaIds()
              .unknownAddedIds
              .toSet(),
          {local.id, cloudLocal.id},
        );
        expect(library.storageVideos.map((item) => item.id).toSet(), {
          local.id,
          cloudLocal.id,
          remote.id,
        });
        expect(library.getVideo(remote.id), same(remote));
        for (final item in [local, cloudLocal]) {
          final estimate = await library.estimateOnlineMediaMaterialization(
            item.id,
            MediaMaterializationRequirement.completeMedia,
          );
          expect(estimate.alreadyAvailable, isTrue);
          final lease = await library.acquireMaterializedMedia(
            item.id,
            MediaMaterializationRequirement.completeMedia,
          );
          expect(lease.requiredVideoPath, file.path);
          await lease.release();
          expect(
            await library.acquireExistingMaterializedPlayback(item),
            isNull,
          );
          expect(library.canRelocateLocalMediaSource(item), isTrue);
        }
        await expectLater(
          library.acquireMaterializedMedia(
            remote.id,
            MediaMaterializationRequirement.completeMedia,
          ),
          throwsUnsupportedError,
        );
        expect(await library.ensureThumbnailForVideo(remote.id), isNull);
        await expectLater(
          library.ensureCompatiblePlaybackFile(remote),
          throwsUnsupportedError,
        );
        expect(hooks, 0);
        expect(local.sourceRef, same(_podcast));
        expect(await file.exists(), isTrue);
      } finally {
        MediaCacheHooks.acquire = previous;
        library.resetLibraryForTesting();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'visible reorder indices and selections preserve hidden remote rows',
    () async {
      final library = LibraryService()..resetLibraryForTesting();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      final folder = VideoCollection(
        id: 'reorder',
        name: 'Reorder',
        createTime: 0,
        childrenIds: [
          'remote-0',
          'a',
          'remote-1',
          'b',
          'c',
          'd',
          'e',
          'remote-2',
        ],
      );
      try {
        library.seedCollectionForTesting(folder);
        for (final id in ['a', 'b', 'c', 'd', 'e']) {
          library.seedVideoForTesting(_item(id, '/local/$id.mp4'));
        }
        for (final id in ['remote-0', 'remote-1', 'remote-2']) {
          library.seedVideoForTesting(
            _item(id, 'podcast:$id', source: _podcast),
          );
        }
        await library.reorderMultipleItems(
          folder.id,
          ['remote-1', 'd', 'a'],
          0,
          2,
        );
        expect(
          library
              .browseContents(folder.id)
              .map((item) => (item as VideoItem).id),
          ['b', 'c', 'a', 'd', 'e'],
        );
        expect(folder.childrenIds.where((id) => id.startsWith('remote-')), [
          'remote-0',
          'remote-1',
          'remote-2',
        ]);
        expect(folder.childrenIds.toSet(), {
          'remote-0',
          'remote-1',
          'remote-2',
          'a',
          'b',
          'c',
          'd',
          'e',
        });
        await library.reorderItems(folder.id, 4, 0);
        expect(
          library
              .browseContents(folder.id)
              .map((item) => (item as VideoItem).id),
          ['e', 'b', 'c', 'a', 'd'],
        );
        expect(folder.childrenIds.where((id) => id.startsWith('remote-')), [
          'remote-0',
          'remote-1',
          'remote-2',
        ]);
        final saved = List<String>.of(folder.childrenIds);
        await library.reorderItems(folder.id, -1, 0);
        await library.reorderMultipleItems(folder.id, ['remote-0'], 0, 1);
        expect(folder.childrenIds, saved);
      } finally {
        library.resetLibraryForTesting();
      }
    },
  );

  test(
    'existing local files play and materialize regardless of historical source kind',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'community-local-runtime-',
      );
      final file = await File(
        '${root.path}${Platform.pathSeparator}downloaded.mp4',
      ).writeAsBytes([0]);
      final previous = VideoPlayerPlatform.instance, player = _Player();
      VideoPlayerPlatform.instance = player;
      final playback = MediaPlaybackService.forTesting();
      final playlist = PlaylistManager();
      final api = _Api();
      final materialization = MediaMaterializationService(api);
      try {
        await playback.initialize(
          playlistManager: playlist,
          progressTracker: ProgressTracker(),
        );
        for (final kind in MediaSourceKind.values) {
          final original = _item(
            kind.name,
            file.path,
            source: _podcast.copyWith(kind: kind),
          );
          final originalSource = original.sourceRef;
          expect(PlaybackQueuePolicy().isEligible(original), isTrue);
          expect(
            MediaPlaybackService.shouldPrepareNativePlayerOnRestore(original),
            isTrue,
          );
          await playback.play(original, autoPlay: false);
          expect(player.sources.last.sourceType, DataSourceType.file);
          expect(
            File.fromUri(Uri.parse(player.sources.last.uri!)).path,
            file.path,
          );
          expect(original.sourceRef, same(originalSource));
          final estimate = await materialization.estimate(
            original,
            MediaMaterializationRequirement.completeMedia,
          );
          expect(estimate.alreadyAvailable, isTrue);
          final lease = await materialization.acquire(
            original,
            MediaMaterializationRequirement.completeMedia,
          );
          expect(lease.requiredVideoPath, file.path);
          await lease.release();
        }
        final uriItem = _item(
          'file-uri',
          file.uri.toString(),
          source: _podcast,
        );
        final lease = await materialization.acquire(
          uriItem,
          MediaMaterializationRequirement.audioOnly,
        );
        expect(lease.requiredAudioPath, file.path);
        await lease.release();
        expect(api.requests, 0);
        expect(await file.exists(), isTrue);
      } finally {
        await playback.stop();
        playback.dispose();
        materialization.dispose();
        VideoPlayerPlatform.instance = previous;
        await root.delete(recursive: true);
      }
    },
  );
}
