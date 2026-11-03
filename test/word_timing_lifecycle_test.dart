import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

const srt = '1\n00:00:01,000 --> 00:00:03,000\nHello world\n';
const lrc = '[00:01.000]<00:01.000>Hello <00:02.000>world<00:03.000>';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previous;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    root = await Directory.systemTemp.createTemp('word_lifecycle_');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SettingsService().largeDataRootPath = root.path;
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = previous;
    SettingsService().resetForTest();
    if (await root.exists()) await root.delete(recursive: true);
  });
  test(
    'binding survives restart and adds the companion to deletion and storage accounting',
    () async {
      final media = File(p.join(root.path, 'media.mp4'))
        ..writeAsStringSync('media');
      final directory = Directory(
        p.join(root.path, 'subtitles', 'tasks', 'card-a'),
      )..createSync(recursive: true);
      final primary = File(p.join(directory.path, 'ai.srt'))
        ..writeAsStringSync(srt);
      final companion = await SubtitleWordTimingStore.write(
        primary.path,
        SubtitleParser.parse(lrc),
      );
      final video = VideoItem(
        id: 'card-a',
        path: media.path,
        title: 'Test',
        durationMs: 5000,
        lastUpdated: 1,
      );
      await File(p.join(root.path, 'library.json')).writeAsString(
        jsonEncode({
          'schemaVersion': 2,
          'videos': [video.toJson()],
          'collections': [],
          'rootChildrenIds': ['card-a'],
        }),
      );
      final library = LibraryService();
      await library.init();
      await library.registerManagedLocalSubtitle(
        'card-a',
        path: primary.path,
        kind: ManagedSubtitleAssetKind.ai,
        displayName: 'AI 字幕',
      );
      expect(library.getManagedSubtitleAssets('card-a').length, 1);
      expect(
        library.getManagedSubtitleAssets('card-a').single.wordTimingPath,
        companion,
      );
      expect(
        library.managedSubtitleDeletionPaths('card-a', primary.path),
        unorderedEquals([primary.path, companion]),
      );
      final saved = jsonDecode(
        await File(p.join(root.path, 'library.json')).readAsString(),
      );
      final restored = VideoItem.fromJson(
        Map<String, dynamic>.from(saved['videos'][0]),
      );
      expect(restored.managedSubtitleAssets.single.wordTimingPath, companion);
      expect(
        await library.calculateItemsTotalSize([restored]),
        greaterThanOrEqualTo(
          await primary.length() + await File(companion!).length(),
        ),
      );
      await library.moveToRecycleBin(['card-a']);
      expect(await File(companion).exists(), isTrue);
      await library.deleteFromRecycleBin(['card-a']);
      expect(await primary.exists(), isFalse);
      expect(await File(companion).exists(), isFalse);
    },
  );
  test(
    'archive adoption copies the hidden companion without an extra managed row',
    () async {
      final archive = Archive()
        ..addFile(ArchiveFile.string('season/episode.mp4', 'media'))
        ..addFile(ArchiveFile.string('season/episode.srt', srt))
        ..addFile(
          ArchiveFile.string(
            'season/episode.srt.wordtiming.json',
            SubtitleWordTimingStore.encode(srt, SubtitleParser.parse(lrc)),
          ),
        );
      final zip = File(p.join(root.path, 'course.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      final library = LibraryService();
      await library.init();
      final result = await library.importArchiveSelection(
        zip.path,
        null,
        sortOptions: const StructuredImportSortOptions(
          field: StructuredImportSortField.fileName,
          direction: StructuredImportSortDirection.ascending,
        ),
      );
      String? firstVideo(String id) {
        final collection = library.getCollection(id)!;
        for (final child in collection.childrenIds) {
          if (library.getVideo(child) != null) return child;
          final found = firstVideo(child);
          if (found != null) return found;
        }
        return null;
      }

      final video = library.getVideo(firstVideo(result.rootCollectionId)!)!;
      expect(video.managedSubtitleAssets.length, 1);
      final asset = video.managedSubtitleAssets.single;
      expect(asset.wordTimingPath, isNotNull);
      expect(await File(asset.wordTimingPath!).exists(), isTrue);
      final attached = await SubtitleWordTimingStore.attach(
        asset.path,
        await File(asset.path).readAsString(),
        SubtitleParser.parse(srt),
      );
      expect(attached.single.timedSpans.length, 2);
      await library.moveToRecycleBin([video.id]);
      expect(await File(asset.wordTimingPath!).exists(), isTrue);
      await library.deleteFromRecycleBin([video.id]);
      expect(await File(asset.wordTimingPath!).exists(), isFalse);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

class _Paths extends PathProviderPlatform {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}
