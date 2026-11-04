import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_view_options.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/services/transcription_media_selection.dart';

import 'support/cloud_drive_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final settings = SettingsService();
  late TranscriptionManager manager;
  CloudDriveRuntime? runtime;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    await settings.init();
    library.resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    manager = TranscriptionManager(settings: settings);
  });
  tearDown(() async {
    manager.dispose();
    await runtime?.shutdown();
    runtime = null;
    library.resetLibraryForTesting();
    settings.resetForTest();
  });

  test(
    'nested selections retain order, deduplicate and preserve folders',
    () async {
      final root = VideoCollection(
        id: 'root',
        name: 'Root',
        createTime: 0,
        childrenIds: ['nested', 'audio', 'root'],
      );
      final nested = VideoCollection(
        id: 'nested',
        name: 'Nested',
        createTime: 0,
        childrenIds: ['video', 'recycled'],
      );
      library
        ..seedCollectionForTesting(root)
        ..seedCollectionForTesting(nested);
      for (final id in ['video', 'audio', 'recycled']) {
        library.seedVideoForTesting(
          VideoItem(
            id: id,
            path: '/$id.mp4',
            title: id,
            durationMs: 62000,
            lastUpdated: 0,
            isRecycled: id == 'recycled',
            type: id == 'audio' ? MediaType.audio : MediaType.video,
          ),
        );
      }
      final selected = ['root', 'nested', 'video'];
      final selection = TranscriptionMediaSelection(libraryIds: selected);
      selected.clear();
      final resolver = TranscriptionMediaResolver(
        library: library,
        manager: manager,
      );
      await resolver.resolve(selection);
      expect(resolver.nodes.map((n) => n.videoId), ['video', 'audio']);
      expect(resolver.nodes.map((n) => n.videoDuration), ['01:02', '01:02']);
      expect(resolver.failures, isEmpty);
      expect(root.childrenIds, ['nested', 'audio', 'root']);
      expect(manager.getQueueSnapshot(), isEmpty);
    },
  );

  test(
    'confirmed cloud imports register stable subtitle targets only once',
    () async {
      final entry = cloudEntry('video');
      final resolver = TranscriptionMediaResolver(
        library: library,
        manager: manager,
      );
      await resolver.resolve(
        TranscriptionMediaSelection(cloudEntries: [entry]),
      );
      expect(library.storageVideos, isEmpty);
      await resolver.source.prepareSelection(resolver.nodes);
      final id = resolver.nodes.single.videoId!;
      expect(
        library.getVideo(id)?.sourceRef?.cloudDrive?.sourceKey,
        cloudDriveEntryKey(entry),
      );
      expect(library.getVideo(id)?.isTransient, isFalse);
      await resolver.source.prepareSelection(resolver.nodes);
      expect(library.storageVideos, hasLength(1));
    },
  );

  test(
    'cloud folders fully page audio/video and reuse existing library IDs',
    () async {
      final folder = cloudEntry('/course', kind: CloudDriveEntryKind.folder);
      final nested = cloudEntry(
        '/course/nested',
        parent: '/course',
        kind: CloudDriveEntryKind.folder,
      );
      final video = cloudEntry('video', parent: '/course');
      final audio = cloudEntry(
        'audio',
        parent: '/course/nested',
        kind: CloudDriveEntryKind.audio,
      );
      final provider = FixtureCloudProvider('baidu', {
        '/course': [
          video,
          nested,
          cloudEntry('subtitle', kind: CloudDriveEntryKind.subtitle),
        ],
        '/course/nested': [audio],
      }, pageSize: 1);
      runtime = await cloudRuntime([provider]);
      final existing = await library.upsertCloudDriveCard(
        source: cloudDriveEntrySource(video),
        title: 'My alias',
        explicitPlacement: true,
      );
      final before = library.storageVideos.length;
      final resolver = TranscriptionMediaResolver(
        library: library,
        manager: manager,
        cloudRuntime: runtime,
      );
      await resolver.resolve(
        TranscriptionMediaSelection(cloudEntries: [folder, video]),
      );
      expect(resolver.failures, isEmpty);
      expect(resolver.nodes.map((n) => n.mediaItem!.type).toSet(), {
        MediaType.audio,
        MediaType.video,
      });
      expect(
        resolver.nodes
            .singleWhere((n) => n.mediaItem!.type == MediaType.video)
            .videoId,
        existing.id,
      );
      expect(
        resolver.nodes
            .singleWhere((n) => n.mediaItem!.type == MediaType.video)
            .name,
        'My alias',
      );
      expect(provider.calls.where((c) => c.parent == '/course').length, 3);
      expect(provider.calls.any((c) => c.parent == '/course/nested'), isTrue);
      expect(library.storageVideos.length, before);
      expect(manager.getQueueSnapshot(), isEmpty);
    },
  );

  test(
    'library cloud folders retain local additions and aliases when expanded',
    () async {
      final remote = cloudEntry('/course', kind: CloudDriveEntryKind.folder);
      final video = cloudEntry('video', parent: '/course');
      final provider = FixtureCloudProvider('baidu', {
        '/course': [video],
      });
      runtime = await cloudRuntime([provider]);
      final folder = VideoCollection(
        id: 'library-folder',
        name: 'Courses',
        createTime: 0,
        sourceRef: cloudDriveEntrySource(remote),
        childrenIds: ['local', 'placed-video'],
      );
      library
        ..seedCollectionForTesting(folder)
        ..seedVideoForTesting(
          VideoItem(
            id: 'local',
            title: 'Local addition',
            path: '/local.mp4',
            durationMs: 0,
            lastUpdated: 0,
          ),
        )
        ..seedVideoForTesting(
          VideoItem(
            id: 'placed-video',
            title: 'Folder alias',
            sourceRef: cloudDriveEntrySource(video),
            path: cloudDriveEntrySource(video).cloudDrive!.logicalUri,
            durationMs: 0,
            lastUpdated: 0,
          ),
        );
      final resolver = TranscriptionMediaResolver(
        library: library,
        manager: manager,
        cloudRuntime: runtime,
      );
      await resolver.resolve(
        TranscriptionMediaSelection(libraryIds: [folder.id]),
      );
      expect(resolver.failures, isEmpty);
      expect(resolver.nodes.map((n) => n.videoId), ['local', 'placed-video']);
      expect(resolver.nodes.last.name, 'Folder alias');
    },
  );

  test(
    'cached Bilibili sources register subtitle targets without starting playback',
    () async {
      library.skipImportSidecarWorkForTesting = true;
      final item = VideoItem(
        id: 'cached-bilibili',
        path: 'bilibili://stream/BV1234567890/123',
        title: 'Cached lesson',
        durationMs: 62000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'BV1234567890',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1234567890',
          cid: 123,
        ),
      );
      final resolver = TranscriptionMediaResolver(
        library: library,
        manager: manager,
      );
      await resolver.resolve(TranscriptionMediaSelection(items: [item]));
      await resolver.source.prepareSelection(resolver.nodes);
      expect(library.getVideo(item.id)?.isTransient, isFalse);
      expect(library.getVideo(item.id)?.path, item.path);
      expect(manager.getQueueSnapshot(), isEmpty);
    },
  );

  test(
    'a failed directory does not lose selected siblings and can be retried',
    () async {
      final folder = cloudEntry('/course', kind: CloudDriveEntryKind.folder);
      final standalone = cloudEntry('standalone');
      final provider = FixtureCloudProvider('baidu', {
        '/course': [cloudEntry('inside', parent: '/course')],
      })..failOnce.add('/course|');
      runtime = await cloudRuntime([provider]);
      final selection = TranscriptionMediaSelection(
        cloudEntries: [folder, standalone],
      );
      final resolver = TranscriptionMediaResolver(
        library: library,
        manager: manager,
        cloudRuntime: runtime,
      );
      await resolver.resolve(selection);
      expect(resolver.failures, hasLength(1));
      expect(resolver.nodes.map((n) => n.name), ['standalone.mp4']);
      final retry = TranscriptionMediaResolver(
        library: library,
        manager: manager,
        cloudRuntime: runtime,
      );
      await retry.resolve(selection);
      expect(retry.failures, isEmpty);
      expect(retry.nodes, hasLength(2));
    },
  );

  test(
    'cancelling a remote read stops remaining selection resolution',
    () async {
      final gate = Completer<void>();
      final folder = cloudEntry('/course', kind: CloudDriveEntryKind.folder);
      final provider = FixtureCloudProvider('baidu', {
        '/course': [cloudEntry('inside', parent: '/course')],
      })..gates['/course|'] = gate;
      runtime = await cloudRuntime([provider]);
      final resolver = TranscriptionMediaResolver(
        library: library,
        manager: manager,
        cloudRuntime: runtime,
      );
      final resolving = resolver.resolve(
        TranscriptionMediaSelection(cloudEntries: [folder, cloudEntry('next')]),
      );
      while (provider.calls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      resolver.cancel();
      gate.complete();
      await resolving;
      expect(resolver.nodes, isEmpty);
      expect(resolver.failures, isEmpty);
    },
  );
}
