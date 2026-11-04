import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_editor_persistence.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

List<SubtitleItem> _timedCues(String text) => [
  SubtitleItem(
    index: 1,
    startTime: const Duration(seconds: 1),
    endTime: const Duration(seconds: 3),
    text: text,
    timedSpans: [
      SubtitleTimedSpan(
        textStart: 0,
        textEnd: text.length,
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 3),
      ),
    ],
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'external ASS edits register one real managed SRT and survive a library restart with word timing',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      final previousStorage = AppStorageService.instance;
      final sandbox = await Directory.systemTemp.createTemp(
        'subtitle_editor_real_library_',
      );
      final data = Directory(p.join(sandbox.path, 'data'));
      final locations = StorageLocations(
        platform: StoragePlatform.windows,
        support: Directory(p.join(sandbox.path, 'support')),
        documents: Directory(p.join(sandbox.path, 'documents')),
        defaultData: data,
        executable: Directory(p.join(sandbox.path, 'program')),
      );
      final storage = AppStorageService(locations: () async => locations);
      final library = LibraryService()..resetLibraryForTesting();
      AppStorageService? restartedStorage;
      addTearDown(() async {
        library.resetLibraryForTesting();
        await storage.releaseForegroundLease();
        await restartedStorage?.releaseForegroundLease();
        AppStorageService.instance = previousStorage;
        settings.resetForTest();
        await sandbox.delete(recursive: true);
      });
      AppStorageService.instance = storage;
      await storage.initialize();
      settings.largeDataRootPath = data.path;
      await library.init(deferMaintenance: true);

      // No decoder or download is involved: this test exercises the real
      // subtitle ownership, registration, disk writer and library reload.
      final userFiles = await Directory(
        p.join(sandbox.path, 'user-originals'),
      ).create();
      final media = await File(
        p.join(userFiles.path, 'movie.mp4'),
      ).writeAsString('media fixture; never decoded by this test');
      final source = await File(p.join(userFiles.path, 'original.ass'))
          .writeAsString(
            '[Script Info]\nTitle: External original\n'
            '[Events]\nFormat: Layer, Start, End, Style, Text\n'
            'Dialogue: 0,0:00:01.00,0:00:03.00,Default,Original subtitle\n',
          );
      final sourceBytes = await source.readAsBytes();
      const videoId = 'editor-real-card';
      library.seedVideoForTesting(
        VideoItem(
          id: videoId,
          path: media.path,
          title: 'Editor integration fixture',
          durationMs: 10000,
          lastUpdated: 1,
          subtitlePath: source.path,
          hasProbedChapters: true,
        ),
      );

      expect(
        await library.subtitleFileBelongsToCard(videoId, source.path),
        isFalse,
      );
      final first = await SubtitleEditorPersistence.save(
        library: library,
        videoId: videoId,
        sourcePath: source.path,
        subtitles: _timedCues('first edit'),
      );
      final latest = _timedCues('latest persisted edit');
      final second = await SubtitleEditorPersistence.save(
        library: library,
        videoId: videoId,
        sourcePath: source.path,
        subtitles: latest,
      );
      expect(second, first);
      expect(p.extension(first), '.srt');
      expect(
        p.isWithin(p.join(data.path, 'subtitles', 'tasks', videoId), first),
        isTrue,
      );
      expect(await library.subtitleFileBelongsToCard(videoId, first), isTrue);
      expect(await source.readAsBytes(), sourceBytes);

      final item = library.getVideo(videoId)!;
      expect(item.localSubtitles!.values, [first]);
      expect(item.managedSubtitleAssets, hasLength(1));
      final asset = item.managedSubtitleAssets.single;
      expect(asset.kind, ManagedSubtitleAssetKind.manual);
      expect(asset.path, first);
      expect(asset.wordTimingPath, SubtitleWordTimingStore.pathFor(first));
      expect(await File(asset.wordTimingPath!).exists(), isTrue);
      final taskFiles = await File(first).parent
          .list()
          .where(
            (entity) =>
                entity is File &&
                p.extension(entity.path).toLowerCase() == '.srt',
          )
          .toList();
      expect(
        taskFiles,
        hasLength(1),
        reason: 'repeated edits must reuse one copy',
      );

      await library.updateVideoSubtitles(videoId, first, false);
      await library.saveProgress();
      expect(library.hasPersistenceFailure, isFalse);
      final assetId = asset.assetId;
      library.resetLibraryForTesting();

      // Reopen the persisted storage catalog too; no mocked snapshot writer or
      // manually reconstructed VideoItem bypasses the real library read.
      restartedStorage = AppStorageService(locations: () async => locations);
      AppStorageService.instance = restartedStorage;
      await restartedStorage.initialize();
      await library.init(deferMaintenance: true);
      final restored = library.getVideo(videoId)!;
      expect(restored.subtitlePath, first);
      expect(restored.localSubtitles!.values, [first]);
      expect(restored.managedSubtitleAssets, hasLength(1));
      expect(restored.managedSubtitleAssets.single.assetId, assetId);
      expect(
        restored.managedSubtitleAssets.single.kind,
        ManagedSubtitleAssetKind.manual,
      );
      expect(
        restored.managedSubtitleAssets.single.wordTimingPath,
        SubtitleWordTimingStore.pathFor(first),
      );
      final srt = await File(first).readAsString();
      final parsed = await SubtitleWordTimingStore.attach(
        first,
        srt,
        SubtitleParser.parseSrt(srt),
        companionPath: restored.managedSubtitleAssets.single.wordTimingPath,
      );
      expect(parsed.single.text, latest.single.text);
      expect(parsed.single.timedSpans, latest.single.timedSpans);
      expect(await source.readAsBytes(), sourceBytes);

      // Editing the restored primary track stays in that same managed file.
      expect(
        await SubtitleEditorPersistence.save(
          library: library,
          videoId: videoId,
          sourcePath: restored.subtitlePath!,
          subtitles: _timedCues('edit after restart'),
        ),
        first,
      );
      expect(library.getVideo(videoId)!.managedSubtitleAssets, hasLength(1));
      expect(await source.readAsBytes(), sourceBytes);
      await library.saveProgress();
      expect(library.hasPersistenceFailure, isFalse);
    },
  );
}
