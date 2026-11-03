import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_importer.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_service.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform oldPaths;
  late LibraryService library;
  late SettingsService settings;
  late VideoItem item;
  late SubtitleSearchImportRequest request;
  const importer = SubtitleSearchImporter();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('subtitle_search_import_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    settings = SettingsService()..resetForTest();
    settings.largeDataRootPath = root.path;
    await settings.init();
    await settings.setLargeDataRootPath(root.path);
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    item = VideoItem(
      id: 'subtitle-search-video',
      path: p.join(root.path, 'movie.mkv'),
      title: 'Movie',
      durationMs: 120000,
      lastUpdated: 0,
    );
    library.seedVideoForTesting(item);
    final doc = decodeSubtitleSearchPayload((
      Uint8List.fromList(
        utf8.encode('1\n00:00:01,000 --> 00:00:03,000\nこんにちは。\n'),
      ),
      'movie.ja.srt',
    )).single;
    request = SubtitleSearchImportRequest(
      hit: const SubtitleSearchHit(
        source: SubtitleSearchSource.jimaku,
        id: '729',
        title: 'Movie',
        language: 'ja',
      ),
      document: doc,
      role: SubtitleSearchImportRole.primary,
    );
  });
  tearDown(() async {
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = oldPaths;
    if (root.existsSync()) await root.delete(recursive: true);
  });
  test(
    'saved subtitle uses the media lifecycle and keeps source and language',
    () async {
      final path = await importer.save(
        library: library,
        videoId: item.id,
        request: request,
      );
      expect(p.isWithin(root.path, path), isTrue);
      expect(await File(path).readAsString(), request.document.content);
      final asset = library.managedSubtitleAssetForPath(item.id, path)!;
      expect(asset.kind, ManagedSubtitleAssetKind.downloaded);
      expect(asset.language, 'ja');
      expect(asset.displayName, contains('Jimaku'));
      final selected = SubtitleSearchImporter.selectedPaths(
        [],
        path,
        request.role,
      );
      expect(selected, [path]);
      await library.updateVideoSubtitles(item.id, path, false);
      expect(library.getVideo(item.id)!.subtitlePath, path);
    },
  );
  test(
    'applying an already saved preview reuses its file and managed asset',
    () async {
      final path = await importer.save(
        library: library,
        videoId: item.id,
        request: request,
      );
      final again = await importer.save(
        library: library,
        videoId: item.id,
        request: request,
        existingPath: path,
      );
      expect(again, path);
      expect(item.managedSubtitleAssets, hasLength(1));
    },
  );
  test(
    'roles preserve the other track, prevent duplicates and allow saving without selection',
    () {
      expect(
        SubtitleSearchImporter.selectedPaths(
          ['old', 'translation'],
          'new',
          SubtitleSearchImportRole.primary,
        ),
        ['new', 'translation'],
      );
      expect(
        SubtitleSearchImporter.selectedPaths(
          ['old', 'translation'],
          'new',
          SubtitleSearchImportRole.secondary,
        ),
        ['old', 'new'],
      );
      expect(
        SubtitleSearchImporter.selectedPaths(
          ['old', 'translation'],
          'new',
          SubtitleSearchImportRole.saveOnly,
        ),
        ['old', 'translation'],
      );
      expect(
        () => SubtitleSearchImporter.selectedPaths(
          [],
          'new',
          SubtitleSearchImportRole.secondary,
        ),
        throwsStateError,
      );
      expect(
        () => SubtitleSearchImporter.selectedPaths(
          ['same'],
          'same',
          SubtitleSearchImportRole.secondary,
        ),
        throwsStateError,
      );
    },
  );
  test('persisted time shift is readable after reopening', () async {
    final shifted = SubtitleSearchImportRequest(
      hit: request.hit,
      document: request.document,
      role: request.role,
      offsetMs: 500,
    );
    final path = await importer.save(
      library: library,
      videoId: item.id,
      request: shifted,
    );
    final cues = SubtitleParser.parse(await File(path).readAsString());
    expect(cues.single.startTime.inMilliseconds, 1500);
    expect(cues.single.text, 'こんにちは。');
  });
  test('missing media is rejected before creating a subtitle', () async {
    await expectLater(
      importer.save(library: library, videoId: 'removed', request: request),
      throwsStateError,
    );
    expect(item.managedSubtitleAssets, isEmpty);
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getDownloadsPath() async => path;
}
