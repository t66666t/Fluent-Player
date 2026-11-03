import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('schema v2 migrates only unambiguously task-owned subtitles', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    final root = await Directory.systemTemp.createTemp(
      'library_subtitle_schema_v2_',
    );
    final originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    addTearDown(() async {
      PathProviderPlatform.instance = originalPathProvider;
      SettingsService().resetForTest();
      if (await root.exists()) await root.delete(recursive: true);
    });

    final legacyDirectory = Directory(p.join(root.path, 'subtitles'));
    await legacyDirectory.create(recursive: true);
    final uniqueLocal = File(p.join(legacyDirectory.path, 'legacy-local.srt'));
    final idPrefixed = File(p.join(legacyDirectory.path, 'task-a.ai.srt'));
    final shared = File(p.join(legacyDirectory.path, 'shared-import.srt'));
    final ambiguous = File(p.join(legacyDirectory.path, 'movie.ai.srt'));
    final recycled = File(p.join(legacyDirectory.path, 'recycled-local.srt'));
    for (final file in <File>[
      uniqueLocal,
      idPrefixed,
      shared,
      ambiguous,
      recycled,
    ]) {
      await file.writeAsString(p.basename(file.path));
    }

    VideoItem item(
      String id, {
      Map<String, String>? local,
      Map<String, String>? recycledLocal,
      bool isRecycled = false,
    }) {
      return VideoItem(
        id: id,
        path: p.join(root.path, 'movie.mp4'),
        title: id,
        durationMs: 1,
        lastUpdated: 1,
        localSubtitles: local,
        recycledLocalSubtitles: recycledLocal,
        isRecycled: isRecycled,
      );
    }

    final items = <VideoItem>[
      item('task-a', local: <String, String>{'local': uniqueLocal.path}),
      item('task-b', local: <String, String>{'shared': shared.path}),
      item('task-c', local: <String, String>{'shared': shared.path}),
      item(
        'task-recycled',
        recycledLocal: <String, String>{'recycled': recycled.path},
        isRecycled: true,
      ),
    ];
    final libraryFile = File(p.join(root.path, 'library.json'));
    await libraryFile.writeAsString(
      jsonEncode(<String, Object>{
        'collections': <Object>[],
        'videos': items.map((video) => video.toJson()).toList(),
        'rootChildrenIds': items.map((video) => video.id).toList(),
        'schemaVersion': 1,
      }),
    );

    final library = LibraryService();
    await library.init();

    final taskA = library.getVideo('task-a')!;
    final migratedLocal = taskA.localSubtitles!['local']!;
    expect(
      p.isWithin(
        p.join(root.path, 'subtitles', 'tasks', 'task-a'),
        migratedLocal,
      ),
      isTrue,
    );
    expect(await uniqueLocal.exists(), isFalse);
    expect(await File(migratedLocal).exists(), isTrue);
    expect(
      taskA.managedSubtitleAssets.map((asset) => p.basename(asset.path)),
      containsAll(<String>['legacy-local.srt', 'task-a.ai.srt']),
    );
    expect(await idPrefixed.exists(), isFalse);

    expect(library.getVideo('task-b')!.localSubtitles!['shared'], shared.path);
    expect(library.getVideo('task-c')!.localSubtitles!['shared'], shared.path);
    expect(await shared.exists(), isTrue);
    expect(await ambiguous.exists(), isTrue);

    final recycledItem = library.getVideo('task-recycled')!;
    final migratedRecycled = recycledItem.recycledLocalSubtitles!['recycled']!;
    expect(
      p.isWithin(
        p.join(root.path, 'subtitles', 'tasks', 'task-recycled'),
        migratedRecycled,
      ),
      isTrue,
    );
    expect(await recycled.exists(), isFalse);

    final saved = jsonDecode(await libraryFile.readAsString());
    expect(saved['schemaVersion'], 2);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
