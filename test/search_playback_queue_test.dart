import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'opening a search hit keeps the original folder playback order',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      final root = await Directory.systemTemp.createTemp(
        'search_playback_queue_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        SettingsService().resetForTest();
        if (await root.exists()) await root.delete(recursive: true);
      });

      Future<File> media(String name) {
        return File(
          p.join(root.path, name),
        ).writeAsBytes(List<int>.generate(1024, (index) => index & 0xff));
      }

      final fileA1 = await media('alpha-ep1.mp4');
      final fileA2 = await media('alpha-ep2.mp4');
      final fileB1 = await media('beta-ep1.mp4');

      final library = LibraryService();
      await library.init();
      final seriesA = await library.createCollection(
        'search-queue-policy-alpha',
        null,
      );
      final seriesB = await library.createCollection(
        'search-queue-policy-beta',
        null,
      );

      const marker = 'search-queue-policy-hit-marker';
      Future<VideoItem> addClip(
        File file,
        String title,
        String parentId,
      ) async {
        final item = VideoItem(
          id: 'search-queue-$title',
          path: file.path,
          title: title,
          durationMs: 1000,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          parentId: parentId,
          hasProbedChapters: true,
        );
        await library.addSingleVideo(
          item,
          useOriginalPath: true,
          reuseExistingItem: false,
        );
        return library.getVideo(item.id)!;
      }

      final alphaEp1 = await addClip(
        fileA1,
        '课程A 第1集 $marker',
        seriesA.id,
      );
      final alphaEp2 = await addClip(
        fileA2,
        '课程A 第2集',
        seriesA.id,
      );
      final betaEp1 = await addClip(
        fileB1,
        '课程B 第1集 $marker',
        seriesB.id,
      );

      final searchHits = library
          .searchContents(marker)
          .whereType<VideoItem>()
          .toList(growable: false);
      expect(searchHits.map((item) => item.id), containsAll(<String>[
        alphaEp1.id,
        betaEp1.id,
      ]));
      expect(searchHits.any((item) => item.id == alphaEp2.id), isFalse);

      // Using search hits as a queue would jump from 课程A to 课程B.
      final searchQueue = PlaylistManager(
        queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
      );
      searchQueue.setPlaylist(searchHits, currentItemId: alphaEp1.id);
      expect(searchQueue.getNext()?.id, isNot(alphaEp2.id));

      final manager = PlaylistManager(
        queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
      );
      manager.initialize(libraryService: library);
      manager.prepareLibraryPlayback(alphaEp1);

      expect(manager.playlist.map((item) => item.id), <String>[
        alphaEp1.id,
        alphaEp2.id,
      ]);
      expect(manager.getNext()?.id, alphaEp2.id);

      manager.prepareLibraryPlayback(
        alphaEp1,
        searchItems: searchHits,
        useSearchResultsAsQueue: true,
      );
      expect(manager.getNext()?.id, isNot(alphaEp2.id));
      expect(
        manager.playlist.map((item) => item.id),
        containsAll(<String>[alphaEp1.id, betaEp1.id]),
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
