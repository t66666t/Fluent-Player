import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_snapshot_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File file;
  late AppStorageService storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-reader-');
    file = File(p.join(root.path, 'library.json'));
    // A callback deliberately cannot run in the worker. Only its captured path
    // metadata is sent, just as with the application's existing snapshot writer.
    storage = AppStorageService(
      locations: () async => throw StateError('plugin callback'),
    );
    storage.roots['data'] = root;
  });
  tearDown(() => root.delete(recursive: true));

  Future<LoadedLibrarySnapshot> read() => readLibrarySnapshot(
    file.path,
    pathEncoding: storage.capturePathEncoding(),
    maximumSchemaVersion: 2,
  );

  test('owned JSON mapping matches the nonmutating codec after relocation', () {
    final local = p.join(root.path, 'old', 'video.mp4');
    storage.roots['data'] = Directory(p.join(root.path, 'old'));
    final encoded = storage.encodePaths({
      'videos': [
        {
          'path': local,
          'title': local,
          'sourceRef': {'path': local, 'value': 'remote-id'},
          'additionalSubtitles': {'中文': p.join(root.path, 'old', 'one.srt')},
          'selectedSubtitlePaths': [
            local,
            'https://example.test/one.srt',
            null,
          ],
          'nested': {'file': local, 'url': 'https://example.test/media.mp4'},
        },
      ],
      'unrelated': [
        1,
        false,
        null,
        {'title': local},
      ],
    });
    final untouched = jsonEncode(encoded);
    storage.roots['data'] = Directory(p.join(root.path, 'new'));
    final paths = storage.capturePathEncoding();
    final expected = paths.decodePaths(encoded);
    expect(jsonEncode(encoded), untouched);
    final owned = jsonDecode(untouched);
    final result = paths.decodeOwnedJsonPaths(owned);
    expect(identical(owned, result), isTrue);
    expect(result, expected);
    expect(
      (result['videos'] as List).single['path'],
      p.join(root.path, 'new', 'video.mp4'),
    );
    expect((result['videos'] as List).single['sourceRef']['path'], local);
    expect((result['videos'] as List).single['title'], local);
  });

  test(
    'large snapshot preserves model fields, order and path references',
    () async {
      final folder = VideoCollection(
        id: 'folder',
        name: '文件夹',
        createTime: 7,
        childrenIds: List.generate(1000, (i) => 'v$i'),
      );
      final videos = List.generate(
        1000,
        (i) => VideoItem(
          id: 'v$i',
          path: p.join(root.path, 'videos', '$i.mp4'),
          title: 'https://example.test/标题/$i',
          parentId: 'folder',
          lastUpdated: i + 1,
          lastPositionMs: i,
          durationMs: 120000,
          additionalSubtitles: {'中文': p.join(root.path, 'subtitles', '$i.srt')},
        ),
      );
      final activity = LibraryActivityStore(
        media: {
          for (final item in videos)
            item.id: MediaActivityRecord(
              mediaId: item.id,
              addedAtMs: item.lastUpdated,
            ),
        },
      );
      final original = {
        'schemaVersion': 2,
        'collections': [folder.toJson()],
        'videos': videos.map((v) => v.toJson()).toList(),
        'rootChildrenIds': ['folder'],
        LibraryActivityStore.snapshotKey: activity.toJson(),
      };
      await file.writeAsString(jsonEncode(storage.encodePaths(original)));
      final snapshot = await read();
      expect(snapshot.collections!.values.map((v) => v.toJson()), [
        folder.toJson(),
      ]);
      expect(
        snapshot.videos!.values.map((v) => v.toJson()),
        videos.map((v) => v.toJson()),
      );
      expect(snapshot.rootChildrenIds, ['folder']);
      expect(snapshot.activity.store.toJson(), activity.toJson());
      expect(snapshot.schemaVersion, 2);
    },
  );

  test('worker uses the captured root even if the live root changes', () async {
    final savedPath = p.join(root.path, 'videos', 'one.mp4');
    await file.writeAsString(
      jsonEncode(
        storage.encodePaths({
          'videos': [
            VideoItem(
              id: 'one',
              path: savedPath,
              title: 'one',
              lastUpdated: 1,
              durationMs: 1,
            ).toJson(),
          ],
        }),
      ),
    );
    final paths = storage.capturePathEncoding();
    storage.roots['data'] = Directory(p.join(root.path, 'moved'));
    final snapshot = await readLibrarySnapshot(
      file.path,
      pathEncoding: paths,
      maximumSchemaVersion: 2,
    );
    expect(snapshot.videos!['one']!.path, savedPath);
  });

  test(
    'missing fields stay missing and duplicate ids keep their last value',
    () async {
      await file.writeAsString(
        jsonEncode({
          'videos': [
            VideoItem(
              id: 'same',
              path: 'a',
              title: 'old',
              lastUpdated: 1,
              durationMs: 1,
            ).toJson(),
            VideoItem(
              id: 'other',
              path: 'b',
              title: 'other',
              lastUpdated: 2,
              durationMs: 1,
            ).toJson(),
            VideoItem(
              id: 'same',
              path: 'c',
              title: 'new',
              lastUpdated: 3,
              durationMs: 1,
            ).toJson(),
          ],
          'recycleBin': [
            VideoCollection(id: 'bin', name: 'old', createTime: 1).toJson(),
          ],
        }),
      );
      final snapshot = await read();
      expect(snapshot.collections, isNull);
      expect(snapshot.rootChildrenIds, isNull);
      expect(snapshot.videos!.keys, ['same', 'other']);
      expect(snapshot.videos!['same']!.title, 'new');
      expect(snapshot.recycleBin!.single.isRecycled, isFalse);
      expect(snapshot.activity.wasMissing, isTrue);
    },
  );

  test('future activity is preserved verbatim without being applied', () async {
    final raw = {
      'version': 999,
      'futureField': ['keep', 42],
    };
    await file.writeAsString(
      jsonEncode({LibraryActivityStore.snapshotKey: raw}),
    );
    final snapshot = await read();
    expect(snapshot.activity.unsupportedFutureVersion, isTrue);
    expect(snapshot.activity.preservedRaw, raw);
    expect(snapshot.activity.store.media, isEmpty);
  });

  test(
    'unsupported schema keeps its storage error type across the isolate',
    () async {
      await file.writeAsString('{"schemaVersion":999}');
      await expectLater(read(), throwsA(isA<StorageUnavailableException>()));
      expect(await file.readAsString(), '{"schemaVersion":999}');
    },
  );

  test('corrupt input is rejected without changing a valid backup', () async {
    final backup = File('${file.path}.bak');
    await backup.writeAsString('{"schemaVersion":2}');
    for (final raw in ['', '{', '{"videos":[{}]}']) {
      await file.writeAsString(raw);
      await expectLater(read(), throwsA(anything));
      expect(await backup.readAsString(), '{"schemaVersion":2}');
    }
  });
}
