import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_view_options.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_reference_import.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'support/cloud_drive_fixture.dart';
import 'cloud_drive_playback_workflow_test.dart' show CloudOfficialSubtitleFake;

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previousPaths;
  late CloudDriveRuntime runtime;
  late LibraryService library;
  final folder = cloudEntry(
    '/course',
    name: '课程',
    kind: CloudDriveEntryKind.folder,
  );
  final nested = cloudEntry(
    '/course/nested',
    name: '深入学习',
    kind: CloudDriveEntryKind.folder,
    parent: '/course',
  );
  final first = cloudEntry('one', name: '第1集.mp4', parent: '/course');
  final second = cloudEntry('two', name: '第2集.mp4', parent: '/course/nested');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    await SettingsService().init();
    root = await Directory.systemTemp.createTemp('cloud-reference-test-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SettingsService().largeDataRootPath = root.path;
    runtime = await cloudRuntime([
      FixtureCloudProvider('baidu', {
        '/course': [
          first,
          nested,
          cloudEntry('sub', kind: CloudDriveEntryKind.subtitle),
        ],
        '/course/nested': [second],
      }),
    ]);
    library = runtime.launch.library;
    library.writeLibrarySnapshotOverrideForTesting = null;
    await library.init();
  });
  tearDown(() async {
    await library.saveProgress();
    await runtime.shutdown();
    library.resetLibraryForTesting();
    PathProviderPlatform.instance = previousPaths;
    SettingsService().resetForTest();
    await root.delete(recursive: true);
  });

  test(
    'recursive references preserve hierarchy and repeated imports reuse placements',
    () async {
      final target = await library.createCollection('目标', null);
      final localConflict = await library.createCollection('课程', target.id);
      final job = CloudDriveReferenceImport(
        runtime: runtime,
        account: runtime.accounts.accounts.single,
        targetFolderId: target.id,
      );
      await job.run([folder]);
      expect(job.created, 2);
      expect(job.failed, 0);
      expect(job.folders, 2);
      final imported = library
          .getContents(target.id)
          .whereType<VideoCollection>()
          .singleWhere((f) => f.id != localConflict.id);
      expect(imported.name, '课程 (2)');
      expect(imported.sourceRef?.cloudDrive, isNotNull);
      final inner = library
          .getContents(imported.id)
          .whereType<VideoCollection>()
          .single;
      expect(library.getVideosInFolder(imported.id).single.title, first.name);
      expect(library.getVideosInFolder(inner.id).single.title, second.name);
      final repeat = CloudDriveReferenceImport(
        runtime: runtime,
        account: runtime.accounts.accounts.single,
        targetFolderId: target.id,
      );
      await repeat.run([folder]);
      expect(repeat.created, 0);
      expect(repeat.reused, 2);
      expect(repeat.folders, 0);
      expect(library.activityProjection.recentAddedEntries(), isEmpty);
      expect(
        library.storageVideos.where((v) => v.sourceRef?.cloudDrive != null),
        hasLength(2),
      );
      job.dispose();
      repeat.dispose();
    },
  );

  test(
    'renaming imported cloud cards preserves remote names and other placements',
    () async {
      final target = await library.createCollection('目标', null);
      final job = CloudDriveReferenceImport(
        runtime: runtime,
        account: runtime.accounts.accounts.single,
        targetFolderId: target.id,
      );
      await job.run([folder]);
      final imported = library
          .getContents(target.id)
          .whereType<VideoCollection>()
          .single;
      final media = library.getVideosInFolder(imported.id).single;
      final sourceKey = media.sourceRef!.cloudDrive!.sourceKey;
      final other = await library.upsertCloudDriveCard(
        source: media.sourceRef!,
        title: first.name,
        openedFromFolderId: target.id,
        explicitPlacement: true,
      );
      await library.renameItem(imported.id, '我的网盘课程');
      await library.renameItem(media.id, '重点复习第一集');
      final repeat = CloudDriveReferenceImport(
        runtime: runtime,
        account: runtime.accounts.accounts.single,
        targetFolderId: target.id,
      );
      await repeat.run([folder]);
      expect(imported.name, '我的网盘课程');
      expect(media.title, '重点复习第一集');
      expect(other.title, first.name);
      expect(folder.name, '课程');
      expect(first.name, '第1集.mp4');
      expect(media.sourceRef!.cloudDrive!.sourceKey, sourceKey);
      expect(repeat.created, 0);
      expect(repeat.folders, 0);
      final folderId = imported.id;
      final mediaId = media.id;
      library.resetLibraryForTesting();
      await library.init();
      expect(library.getCollection(folderId)!.name, '我的网盘课程');
      expect(library.getVideo(mediaId)!.title, '重点复习第一集');
      job.dispose();
      repeat.dispose();
    },
  );

  test(
    'queue adapter can become the persisted instance on explicit import',
    () async {
      final source = cloudDriveEntrySource(first);
      final queued = await library.upsertCloudDriveCard(
        source: source,
        title: first.name,
        persist: false,
      );
      expect(library.getVideo(queued.id), isNull);
      final registered = await library.upsertCloudDriveCard(
        source: source,
        title: first.name,
        libraryItemId: queued.id,
        playbackItem: queued,
        explicitPlacement: true,
      );
      expect(identical(registered, queued), isTrue);
      await library.updateVideoProgress(queued.id, 23000);
      expect(queued.lastPositionMs, 23000);
    },
  );

  test('cloud launch only persists after a manual reference import', () async {
    final target = await library.createCollection('手动入库位置', null);
    final selected = await runtime.launch.prepareEntry(
      entry: first,
      visibleEntries: [first, second],
      openedFromFolderId: target.id,
    );
    expect(library.storageVideos, isEmpty);
    expect(library.getContents(target.id), isEmpty);
    expect(runtime.launch.playlist.playlist, hasLength(2));
    await library.saveProgress();
    library.resetLibraryForTesting();
    await library.init();
    expect(library.storageVideos, isEmpty);
    expect(library.getVideo(selected.id), isNull);

    final job = CloudDriveReferenceImport(
      runtime: runtime,
      account: runtime.accounts.accounts.single,
      targetFolderId: target.id,
    );
    addTearDown(job.dispose);
    await job.run([first]);
    expect(job.created, 1);
    expect(job.persisted, isTrue);
    final imported = library.storageVideos.single;
    imported.title = '我修改的标题';
    imported.lastPositionMs = 42000;
    final reopened = await runtime.launch.prepareEntry(
      entry: first,
      visibleEntries: [first, second],
    );
    expect(reopened, same(imported));
    expect(reopened.title, '我修改的标题');
    expect(reopened.parentId, target.id);
    expect(reopened.lastPositionMs, 42000);
    expect(library.storageVideos, hasLength(1));
    await library.saveProgress();
    library.resetLibraryForTesting();
    await library.init();
    expect(library.storageVideos.single.id, imported.id);
    expect(library.getVideo(imported.id)!.parentId, target.id);
    expect(library.getVideo(imported.id)!.lastPositionMs, 42000);
  });

  test(
    'official subtitles work on a playback item without importing it',
    () async {
      final selected = await runtime.launch.prepareEntry(
        entry: first,
        visibleEntries: [first],
      );
      runtime.launch.playback.debugSeedCurrentItem(selected);
      addTearDown(() => runtime.launch.playback.debugSeedCurrentItem(null));
      final appTracks = CloudDriveSubtitleTracks.forApp(
        library: library,
        runtime: runtime,
      );
      addTearDown(appTracks.dispose);
      final source = CloudOfficialSubtitleFake();
      final tracks = CloudDriveSubtitleTracks(
        source: source,
        store: appTracks.store,
      );
      addTearDown(tracks.dispose);
      expect(tracks.store.itemOf(selected.id), same(selected));
      await tracks.ensureLoaded(selected.id);
      final track = tracks.listFor(selected.id).tracks.single;
      final path = await tracks.load(selected.id, track);
      expect(path, isNotNull);
      expect(await File(path!).exists(), isTrue);
      expect(selected.managedSubtitleAssets.single.path, path);
      expect(tracks.listFor(selected.id).tracks.single.savedPath, path);
      expect(source.calls, 1);
      expect(source.textCalls, 1);
      expect(library.storageVideos, isEmpty);
      await library.saveProgress();
      library.resetLibraryForTesting();
      await library.init();
      expect(library.storageVideos, isEmpty);
    },
  );

  test(
    'overlapping folder and file selections produce one hierarchical placement',
    () async {
      final job = CloudDriveReferenceImport(
        runtime: runtime,
        account: runtime.accounts.accounts.single,
        targetFolderId: null,
      );
      await job.run([first, folder, nested]);
      expect(job.created, 2);
      expect(library.getContents(null).whereType<VideoItem>(), isEmpty);
      job.dispose();
    },
  );

  test(
    'different folder placements share progress, history and subtitles after restart',
    () async {
      final a = await library.createCollection('第一处', null);
      final b = await library.createCollection('第二处', null);
      final source = cloudDriveEntrySource(first);
      final one = await library.upsertCloudDriveCard(
        source: source,
        title: '第一张卡片',
        explicitPlacement: true,
        openedFromFolderId: a.id,
      );
      final two = await library.upsertCloudDriveCard(
        source: source,
        title: '第二张卡片',
        explicitPlacement: true,
        openedFromFolderId: b.id,
      );
      expect(one.id, isNot(two.id));
      await library.updateVideoProgress(two.id, 42000);
      await library.applyWatchFlush(
        mediaId: two.id,
        deltaWatchMs: 40000,
        lastPlayedAtMs: 100,
        enrolled: true,
      );
      expect(one.lastPositionMs, 42000);
      expect(library.mediaActivity(one.id)?.accumulatedWatchMs, 40000);
      expect(library.activityProjection.playbackHistoryMediaIds(), [two.id]);
      expect(
        library.activityProjection.continueLearningGroups().single.mediaIds,
        [two.id],
      );
      final subtitle = await library.allocateSubtitleFile(one.id, 'lesson.srt');
      await File(
        subtitle,
      ).writeAsString('1\n00:00:00,000 --> 00:00:01,000\n共享字幕\n');
      await library.registerManagedLocalSubtitle(
        one.id,
        path: subtitle,
        kind: ManagedSubtitleAssetKind.imported,
        displayName: '中文字幕',
      );
      await library.updateVideoSubtitles(one.id, subtitle, false);
      expect(two.subtitlePath, one.subtitlePath);
      expect(two.localSubtitles?.values, contains(subtitle));
      await library.upsertCloudDriveCard(
        source: source,
        title: '网盘原始名称',
        libraryItemId: two.id,
        durationMs: 120000,
      );
      expect(two.title, '第二张卡片');
      expect(
        library.storageVideos.where((v) => v.sourceRef?.cloudDrive != null),
        hasLength(2),
      );
      await library.saveProgress();
      final saved =
          jsonDecode(await File('${root.path}/library.json').readAsString())
              as Map;
      expect(
        (saved['videos'] as List).where(
          (v) => (v as Map)['sourceRef']?['kind'] == 'cloudDrive',
        ),
        hasLength(2),
      );
      library.resetLibraryForTesting();
      await library.init();
      expect(library.getVideo(one.id)?.lastPositionMs, 42000);
      expect(library.getVideo(two.id)?.subtitlePath, subtitle);
      expect(library.activityProjection.playbackHistoryMediaIds(), [two.id]);
      await library.moveToRecycleBin([one.id]);
      await library.deleteFromRecycleBin([one.id]);
      expect(await File(subtitle).exists(), isTrue);
      expect(library.getVideo(two.id)?.subtitlePath, subtitle);
      await library.forgetSubtitleFiles(two.id, [subtitle]);
      expect(library.getVideo(two.id)?.subtitlePath, isNull);
    },
  );

  test(
    'cancel keeps committed references and retry does not duplicate them',
    () async {
      final job = CloudDriveReferenceImport(
        runtime: runtime,
        account: runtime.accounts.accounts.single,
        targetFolderId: null,
      );
      job.addListener(() {
        if (job.created >= 1 && !job.cancelled) job.cancel();
      });
      await job.run([first, second]);
      expect(job.created, 1);
      expect(job.cancelled, isTrue);
      final retry = CloudDriveReferenceImport(
        runtime: runtime,
        account: runtime.accounts.accounts.single,
        targetFolderId: null,
      );
      await retry.run([first, second]);
      expect(retry.created, 1);
      expect(retry.reused, 1);
      expect(library.getContents(null).whereType<VideoItem>(), hasLength(2));
      job.dispose();
      retry.dispose();
    },
  );
}
