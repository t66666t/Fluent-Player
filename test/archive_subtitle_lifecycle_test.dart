import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'archive sidecar is managed with its video and deleted only permanently',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      final root = await Directory.systemTemp.createTemp(
        'archive_subtitle_lifecycle_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        SettingsService().resetForTest();
        if (await root.exists()) await root.delete(recursive: true);
      });

      final archiveFile = File(p.join(root.path, 'course.zip'));
      final archive = Archive()
        ..addFile(ArchiveFile.string('season/episode.mp4', 'media'))
        ..addFile(
          ArchiveFile.string(
            'season/episode.srt',
            '1\n00:00:00,000 --> 00:00:01,000\nSubtitle\n',
          ),
        );
      archiveFile.writeAsBytesSync(ZipEncoder().encode(archive), flush: true);

      final library = LibraryService();
      await library.init();
      final result = await library.importArchiveSelection(
        archiveFile.path,
        null,
        sortOptions: const StructuredImportSortOptions(
          field: StructuredImportSortField.fileName,
          direction: StructuredImportSortDirection.ascending,
        ),
      );
      final videoId = _firstVideoId(library, result.rootCollectionId);
      expect(videoId, isNotNull);

      final video = library.getVideo(videoId!)!;
      final managedSubtitlePath = video.subtitlePath;
      expect(managedSubtitlePath, isNotNull);
      expect(await File(managedSubtitlePath!).exists(), isTrue);
      expect(
        p.isWithin(
          p.join(root.path, 'subtitles', 'tasks', video.id),
          managedSubtitlePath,
        ),
        isTrue,
      );
      expect(video.localSubtitles?.values, contains(managedSubtitlePath));
      expect(
        video.managedSubtitleAssets.map((asset) => asset.path),
        contains(managedSubtitlePath),
      );

      await library.moveToRecycleBin(<String>[video.id]);
      expect(await File(managedSubtitlePath).exists(), isTrue);

      await library.deleteFromRecycleBin(<String>[video.id]);
      expect(await File(managedSubtitlePath).exists(), isFalse);
      expect(
        await Directory(
          p.join(root.path, 'subtitles', 'tasks', video.id),
        ).exists(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

String? _firstVideoId(LibraryService library, String collectionId) {
  final collection = library.getCollection(collectionId);
  if (collection == null) return null;
  for (final childId in collection.childrenIds) {
    if (library.getVideo(childId) != null) return childId;
    final nested = _firstVideoId(library, childId);
    if (nested != null) return nested;
  }
  return null;
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
