import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_snapshot_writer.dart';

class _BackgroundOnlyVideo extends VideoItem {
  _BackgroundOnlyVideo(String path)
    : caller = Isolate.current.controlPort,
      super(
        id: 'clip',
        path: path,
        title: '视频',
        durationMs: 1000,
        lastUpdated: 1,
      );

  final SendPort caller;

  @override
  Map<String, dynamic> toJson() {
    if (Isolate.current.controlPort == caller) {
      throw StateError('Library serialization blocked the caller isolate');
    }
    return super.toJson();
  }
}

void main() {
  late Directory root;
  late AppStorageService storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library_snapshot_');
    storage = AppStorageService()..roots['data'] = root;
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  LibrarySnapshot snapshot({
    List<VideoItem> videos = const [],
    List<VideoCollection> collections = const [],
    LibraryActivityStore? activity,
    Object? preservedActivity,
  }) => LibrarySnapshot(
    directory: root.path,
    schemaVersion: 2,
    videos: videos,
    collections: collections,
    rootChildrenIds: ['folder'],
    activity: activity ?? LibraryActivityStore.empty(),
    preservedActivity: preservedActivity,
    pathEncoding: storage.capturePathEncoding(),
  );

  test(
    'serialization runs off the caller and keeps paths and activity',
    () async {
      final clip = _BackgroundOnlyVideo(
        p.join(root.path, 'imported_media', '视频.mp4'),
      )..subtitlePath = p.join(root.path, 'subtitles', '中文.srt');
      final transient = VideoItem(
        id: 'watch-only',
        path: 'https://example.test/online.mp4',
        title: '在线',
        durationMs: 1000,
        lastUpdated: 1,
        isTransient: true,
      );
      final activity = LibraryActivityStore.empty();
      activity.ensureMedia(clip.id).addedAtMs = 12;
      activity.ensureMedia(transient.id).addedAtMs = 13;
      activity.pinnedIds.add(clip.id);
      final folder = VideoCollection(
        id: 'folder',
        name: '课程',
        createTime: 1,
        childrenIds: [clip.id],
      );

      final saving = writeLibrarySnapshot(
        snapshot(
          videos: [clip, transient],
          collections: [folder],
          activity: activity,
        ),
      );
      // The worker owns a copy; a later mutation must not alter this generation.
      folder.name = '下次保存';
      clip.title = '下次保存';
      activity.pinnedIds.clear();
      await saving;

      final saved = jsonDecode(
        await File(p.join(root.path, 'library.json')).readAsString(),
      );
      expect(saved['videos'], hasLength(1));
      final video = saved['videos'][0];
      expect(video['title'], '视频');
      expect(video['path'], clip.path);
      expect(video['_storagePaths']['path'], {
        'rootId': 'data',
        'relativePath': 'imported_media/视频.mp4',
      });
      expect(
        video['_storagePaths']['subtitlePath']['relativePath'],
        'subtitles/中文.srt',
      );
      expect(saved['collections'][0]['name'], '课程');
      expect(saved['collections'][0]['childrenIds'], [clip.id]);
      expect(saved['rootChildrenIds'], ['folder']);
      expect(saved['schemaVersion'], 2);
      expect(saved['activity']['pinnedIds'], [clip.id]);
      expect(saved['activity']['media'], hasLength(1));
      expect(saved['activity']['media'][0]['id'], clip.id);
    },
  );

  test(
    'a valid generation becomes the backup and corrupt data cannot replace it',
    () async {
      final file = File(p.join(root.path, 'library.json'));
      final backup = File('${file.path}.bak');
      const previous = '{"schemaVersion":2,"generation":"previous"}';
      await file.writeAsString(previous);
      await writeLibrarySnapshot(snapshot());
      expect(await backup.readAsString(), previous);
      expect(jsonDecode(await file.readAsString())['schemaVersion'], 2);

      await file.writeAsString('{truncated');
      await writeLibrarySnapshot(snapshot());
      expect(await backup.readAsString(), previous);
      expect(jsonDecode(await file.readAsString())['schemaVersion'], 2);
      expect(await File('${file.path}.tmp').exists(), isFalse);
    },
  );

  test('future activity formats remain unchanged', () async {
    final preserved = {
      'version': 100,
      'futureField': ['保留', 42],
    };
    await writeLibrarySnapshot(snapshot(preservedActivity: preserved));
    final saved = jsonDecode(
      await File(p.join(root.path, 'library.json')).readAsString(),
    );
    expect(saved['activity'], preserved);
  });
}
