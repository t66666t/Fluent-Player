import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/lyrics/lyric_search_importer.dart';
import 'package:video_player_app/features/lyrics/lyric_search_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import 'package:video_player_app/services/task_subtitle_storage_service.dart';
import 'package:video_player_app/utils/timed_subtitle_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late SettingsService settings;
  late LibraryService library;
  late MediaPlaybackService playback;
  late VideoItem item;
  late LyricSearchImporter importer;
  late DownloadedLyrics lyrics;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('lyric_search_import_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    settings = SettingsService()..resetForTest();
    settings.largeDataRootPath = root.path;
    await settings.init();
    await settings.setLargeDataRootPath(root.path);
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    item = VideoItem(
      id: 'lyric-search-test',
      path: p.join(root.path, 'Song.mp3'),
      title: 'Song',
      type: MediaType.audio,
      durationMs: 20000,
      lastUpdated: 0,
    );
    library.seedVideoForTesting(item);
    playback = MediaPlaybackService()
      ..debugOverrideStreamQualityChrome(item: item);
    playback.setSubtitleState(paths: [], primary: [], secondary: []);
    importer = const LyricSearchImporter();
    lyrics = DownloadedLyrics(
      track: const LyricSearchTrack(
        source: LyricSource.netease,
        id: '42',
        title: 'Song',
      ),
      original: TimedSubtitleParser.parsePlatform(
        '[1000,2000](1000,500,0)Hello (1500,1500,0)world',
      ),
      translation: TimedSubtitleParser.parseLrc(
        '[00:01]你好世界',
        mediaDuration: const Duration(seconds: 3),
      ),
    );
  });

  tearDown(() async {
    playback.debugOverrideStreamQualityChrome();
    playback.setSubtitleState(paths: [], primary: [], secondary: []);
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = originalPaths;
    // Delete only this test's newly allocated temporary directory.
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test(
    'import persists two managed tracks and real words survive playback reload',
    () async {
      final applied = await importer.import(
        itemId: item.id,
        request: LyricImportRequest(
          lyrics,
          includeTranslation: true,
          offset: const Duration(milliseconds: 250),
        ),
        library: library,
        playback: playback,
      );
      expect(applied, isTrue);
      expect(item.managedSubtitleAssets.length, 2);
      expect(item.secondarySubtitlePath, isNotNull);
      expect(
        playback.subtitles.single.startTime,
        const Duration(milliseconds: 1250),
      );
      expect(playback.subtitles.single.timedSpans.length, 2);
      expect(playback.secondarySubtitles.single.text, '你好世界');
      expect(
        playback.secondarySubtitles.single.startTime,
        const Duration(milliseconds: 1250),
      );
      final originalAsset = library.managedSubtitleAssetForPath(
        item.id,
        item.subtitlePath!,
      )!;
      final translationAsset = library.managedSubtitleAssetForPath(
        item.id,
        item.secondarySubtitlePath!,
      )!;
      expect(translationAsset.sourceAssetId, originalAsset.assetId);
      expect(translationAsset.language, 'zh');
      expect(
        File(SubtitleWordTimingStore.pathFor(item.subtitlePath!)).existsSync(),
        isTrue,
      );
      playback.setSubtitleState(paths: [], primary: [], secondary: []);
      await playback.loadSubtitlePathsForCurrentItem(
        itemId: item.id,
        paths: [item.subtitlePath!, item.secondarySubtitlePath!],
      );
      expect(
        playback.subtitles.single.timedSpans.last.startTime,
        const Duration(milliseconds: 1750),
      );
    },
  );

  test(
    'translation is optional and reimports keep both saved versions',
    () async {
      Future<bool> apply(bool translated) => importer.import(
        itemId: item.id,
        request: LyricImportRequest(lyrics, includeTranslation: translated),
        library: library,
        playback: playback,
      );
      await apply(true);
      final oldTranslation = item.secondarySubtitlePath!;
      await apply(false);
      expect(playback.secondarySubtitles, isEmpty);
      expect(item.secondarySubtitlePath, isNull);
      expect(File(oldTranslation).existsSync(), isTrue);
      expect(item.managedSubtitleAssets.length, 3);
    },
  );

  test(
    'switching songs before import rejects the stale dialog without writing files',
    () async {
      playback.debugOverrideStreamQualityChrome(
        item: VideoItem(
          id: 'other-song',
          path: 'other.mp3',
          title: 'Other',
          durationMs: 1,
          lastUpdated: 0,
        ),
      );
      await expectLater(
        importer.import(
          itemId: item.id,
          request: LyricImportRequest(lyrics),
          library: library,
          playback: playback,
        ),
        throwsStateError,
      );
      expect(item.managedSubtitleAssets, isEmpty);
      expect(
        await TaskSubtitleStorageService(
          dataRootOverride: library.dataRootDirOrNull,
        ).listTaskSubtitles(item.id),
        isEmpty,
      );
    },
  );
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
