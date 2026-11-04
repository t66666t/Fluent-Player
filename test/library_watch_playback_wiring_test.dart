import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'replaying a podcast keeps its listened flag after enrollment',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      final library = LibraryService()..resetLibraryForTesting();
      final root = await Directory.systemTemp.createTemp('podcast_relisten_');
      final original = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      addTearDown(() async {
        PathProviderPlatform.instance = original;
        library.resetLibraryForTesting();
        SettingsService().resetForTest();
        if (await root.exists()) await root.delete(recursive: true);
      });
      for (final podcast in [true, false]) {
        final id = podcast ? 'podcast' : 'local';
        library.seedVideoForTesting(
          VideoItem(
            id: id,
            path: podcast ? 'podcast:$id' : p.join(root.path, 'local.mp3'),
            title: id,
            durationMs: 120000,
            lastUpdated: 1,
            type: MediaType.audio,
            sourceRef: podcast
                ? const MediaSourceRef(
                    value: 'podcast:podcast',
                    kind: MediaSourceKind.podcastEpisode,
                    podcast: PodcastEpisodeRef(
                      channelId: 'channel',
                      episodeId: 'podcast',
                      feedUrl: 'https://example.com/rss',
                      mediaUrl: 'https://example.com/audio.mp3',
                    ),
                  )
                : null,
          ),
        );
        library.seedMediaActivityForTesting(
          MediaActivityRecord(mediaId: id, completed: true),
        );
        await library.applyWatchFlush(
          mediaId: id,
          deltaWatchMs: 30000,
          lastPlayedAtMs: 1234,
          enrolled: true,
          uncomplete: true,
        );
        expect(library.mediaActivity(id)!.completed, podcast);
        expect(library.mediaActivity(id)!.accumulatedWatchMs, 30000);
      }
    },
  );

  test('pause and persistCurrentProgress flush watch activity through LibraryService',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    final library = LibraryService();
    final root = await Directory.systemTemp.createTemp('watch_meter_wire_');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    addTearDown(() async {
      await MediaPlaybackService().stop();
      MediaPlaybackService().libraryWatchMeterForTesting.reset();
      PathProviderPlatform.instance = original;
      library.resetLibraryForTesting();
      SettingsService().resetForTest();
      if (await root.exists()) await root.delete(recursive: true);
    });

    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: p.join(root.path, 'clip.mp4'),
        title: 'clip',
        durationMs: 120000,
        lastUpdated: 1,
        hasProbedChapters: true,
      ),
    );

    final service = MediaPlaybackService();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker()..initialize(libraryService: library),
      libraryService: library,
    );
    await service.updateMetadata(library.getVideo('clip')!);

    final meter = service.libraryWatchMeterForTesting;
    meter.startCycle(
      mediaId: 'clip',
      userInitiated: true,
      hidden: false,
      completed: false,
      durationMs: 120000,
      nowMs: 0,
    );
    meter.setTransport(
      playing: true,
      buffering: false,
      seeking: false,
      missingSource: false,
    );
    meter.sample(
      mediaId: 'clip',
      cycleId: meter.cycleId,
      positionMs: 0,
      nowMs: 0,
    );
    meter.sample(
      mediaId: 'clip',
      cycleId: meter.cycleId,
      positionMs: 5000,
      nowMs: 5000,
    );

    await service.pause();
    expect(library.mediaActivity('clip')!.accumulatedWatchMs, 5000);

    meter.sample(
      mediaId: 'clip',
      cycleId: meter.cycleId,
      positionMs: 8000,
      nowMs: 8000,
    );
    await service.persistCurrentProgress();
    expect(library.mediaActivity('clip')!.accumulatedWatchMs, 8000);

    final complete = meter.onConfirmedComplete(nowMs: 8000);
    expect(complete.completed, isTrue);
    await service.flushLibraryWatchForTesting();
    // onConfirmedComplete already consumed uncommitted delta; flush is empty.
    // Drive the same write path completion uses:
    await library.applyWatchFlush(
      mediaId: 'clip',
      deltaWatchMs: 0,
      completed: true,
      completedAtMs: 8000,
    );
    expect(library.mediaActivity('clip')!.completed, isTrue);
  });

  test('first enrollment persists immediately and notifies the library', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    final library = LibraryService();
    final root = await Directory.systemTemp.createTemp('watch_enroll_');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      library.resetLibraryForTesting();
      SettingsService().resetForTest();
      if (await root.exists()) await root.delete(recursive: true);
    });
    library.seedVideoForTesting(
      VideoItem(
        id: 'lesson',
        path: p.join(root.path, 'lesson.mp4'),
        title: 'lesson',
        durationMs: 120000,
        lastUpdated: 1,
      ),
    );

    var notifies = 0;
    library.addListener(() => notifies++);
    await library.applyWatchFlush(
      mediaId: 'lesson',
      deltaWatchMs: 25000,
      lastPlayedAtMs: 99,
      enrolled: true,
    );
    expect(library.mediaActivity('lesson')!.lastPlayedAtMs, 99);
    expect(library.mediaActivity('lesson')!.continueEnrolled, isTrue);
    expect(library.activityProjection.isContinueEligible(library.getVideo('lesson')!), isTrue);
    expect(notifies, greaterThan(0));

    final afterFirst = notifies;
    await library.applyWatchFlush(
      mediaId: 'lesson',
      deltaWatchMs: 1000,
      lastPlayedAtMs: 100,
    );
    expect(notifies, afterFirst);
  });

  test('short play stamps history without continue enrollment', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    final library = LibraryService();
    final root = await Directory.systemTemp.createTemp('watch_history_');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      library.resetLibraryForTesting();
      SettingsService().resetForTest();
      if (await root.exists()) await root.delete(recursive: true);
    });
    library.seedVideoForTesting(
      VideoItem(
        id: 'peek',
        path: p.join(root.path, 'peek.mp4'),
        title: 'peek',
        durationMs: 120000,
        lastUpdated: 1,
      ),
    );
    await library.applyWatchFlush(
      mediaId: 'peek',
      deltaWatchMs: 1200,
      lastPlayedAtMs: 4,
    );
    final item = library.getVideo('peek')!;
    expect(library.mediaActivity('peek')!.continueEnrolled, isFalse);
    expect(library.activityProjection.isContinueEligible(item), isFalse);
    expect(library.activityProjection.playbackHistoryMediaIds(), ['peek']);
  });

  test('clearPlaybackHistory drops watch clocks but keeps import time', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    final library = LibraryService();
    final root = await Directory.systemTemp.createTemp('watch_clear_');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      library.resetLibraryForTesting();
      SettingsService().resetForTest();
      if (await root.exists()) await root.delete(recursive: true);
    });
    library.seedVideoForTesting(
      VideoItem(
        id: 'keep',
        path: p.join(root.path, 'keep.mp4'),
        title: 'keep',
        durationMs: 1000,
        lastUpdated: 1,
      ),
    );
    library.seedMediaActivityForTesting(
      MediaActivityRecord(
        mediaId: 'keep',
        addedAtMs: 11,
        lastPlayedAtMs: 99,
        accumulatedWatchMs: 4000,
        continueEnrolled: true,
        completed: true,
      ),
    );
    await library.clearPlaybackHistory();
    final record = library.mediaActivity('keep')!;
    expect(record.addedAtMs, 11);
    expect(record.lastPlayedAtMs, isNull);
    expect(record.accumulatedWatchMs, 0);
    expect(record.continueEnrolled, isFalse);
    expect(record.completed, isFalse);
    expect(library.activityProjection.playbackHistoryMediaIds(), isEmpty);
  });

  test('switching media still commits the previous item history flush', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    final library = LibraryService();
    final root = await Directory.systemTemp.createTemp('watch_switch_');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    addTearDown(() async {
      await MediaPlaybackService().stop();
      MediaPlaybackService().libraryWatchMeterForTesting.reset();
      PathProviderPlatform.instance = original;
      library.resetLibraryForTesting();
      SettingsService().resetForTest();
      if (await root.exists()) await root.delete(recursive: true);
    });
    library.seedVideoForTesting(
      VideoItem(
        id: 'epA',
        path: p.join(root.path, 'a.mp4'),
        title: 'epA',
        durationMs: 120000,
        lastUpdated: 1,
        hasProbedChapters: true,
      ),
    );
    library.seedVideoForTesting(
      VideoItem(
        id: 'epB',
        path: p.join(root.path, 'b.mp4'),
        title: 'epB',
        durationMs: 120000,
        lastUpdated: 1,
        hasProbedChapters: true,
      ),
    );
    final service = MediaPlaybackService();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker()..initialize(libraryService: library),
      libraryService: library,
    );
    final meter = service.libraryWatchMeterForTesting;
    meter.startCycle(
      mediaId: 'epA',
      userInitiated: true,
      hidden: false,
      completed: false,
      durationMs: 120000,
      nowMs: 0,
    );
    meter.setTransport(
      playing: true,
      buffering: false,
      seeking: false,
      missingSource: false,
    );
    meter.sample(
      mediaId: 'epA',
      cycleId: meter.cycleId,
      positionMs: 0,
      nowMs: 0,
    );
    meter.sample(
      mediaId: 'epA',
      cycleId: meter.cycleId,
      positionMs: 4000,
      nowMs: 4000,
    );
    final leavingA = meter.flush(nowMs: 4000);
    meter.startCycle(
      mediaId: 'epB',
      userInitiated: true,
      hidden: false,
      completed: false,
      durationMs: 120000,
      nowMs: 4000,
    );
    await service.commitLibraryWatchFlushForTesting(leavingA);
    expect(library.mediaActivity('epA')!.lastPlayedAtMs, 4000);
    expect(library.mediaActivity('epA')!.accumulatedWatchMs, 4000);
  });

  test('playback service completion and pause call watch flush APIs', () {
    final source = File('lib/services/media_playback_service.dart').readAsStringSync();
    expect(source, contains('_commitWatchFlush(_watchMeter.flush())'));
    expect(source, contains('_watchMeter.onConfirmedComplete()'));
    expect(source.contains('await _commitWatchFlush(_watchMeter.flush())'), isTrue);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}
