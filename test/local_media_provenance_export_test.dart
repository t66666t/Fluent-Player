import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/features/portable_transfer/zip_export_plan.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => p.join(root, 'cache');
}

const _bili = MediaSourceRef(
  value: 'BVlocal',
  kind: MediaSourceKind.bilibiliStream,
  bvid: 'BVlocal',
  cid: 1,
);
const _cloud = MediaSourceRef(
  value: 'cloud-drive://old/file',
  kind: MediaSourceKind.cloudDrive,
  cloudDrive: CloudDriveSourceRef(
    providerId: 'aliyun',
    remoteAccountId: 'old',
    driveId: 'drive',
    fileId: 'file',
  ),
);
const _podcast = MediaSourceRef(
  value: 'podcast:old',
  kind: MediaSourceKind.podcastEpisode,
  podcast: PodcastEpisodeRef(
    channelId: 'old',
    episodeId: 'episode',
    feedUrl: 'https://publisher.invalid/rss',
    mediaUrl: 'https://publisher.invalid/episode.mp3',
  ),
);

Future<void> _wait(PortableTransferTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (task.isActive && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(
    task.status,
    PortableTransferStatus.completed,
    reason: task.error ?? task.subtitle,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService(), settings = SettingsService();
  late Directory root;
  late PathProviderPlatform previous;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    root = await Directory.systemTemp.createTemp('local-provenance-export-');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    settings.largeDataRootPath = root.path;
    settings.copyImportedMediaToPrivateStorage = false;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    await library.init(deferMaintenance: true);
  });
  tearDown(() async {
    await library.prepareStorageMigration();
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = previous;
    await root.delete(recursive: true);
  });

  test(
    'local Bili cloud and podcast histories pack, import and ZIP actual bytes with subtitles',
    () async {
      final originals = <VideoItem>[];
      final expectedBytes = <String, List<int>>{};
      for (final entry in {
        'bili': _bili,
        'cloud': _cloud,
        'podcast': _podcast,
      }.entries) {
        final file = await File(
          p.join(root.path, '${entry.key}.mp4'),
        ).writeAsBytes(utf8.encode('local ${entry.key} bytes'));
        final subtitle = await File(p.join(root.path, '${entry.key}.srt'))
            .writeAsString(
              '1\n00:00:00,000 --> 00:00:01,000\nMy ${entry.key} learning note\n',
            );
        final item = VideoItem(
          id: entry.key,
          path: file.path,
          title: entry.key,
          sourceRef: entry.value,
          durationMs: 60000,
          lastPositionMs: 12345,
          lastUpdated: 1,
          subtitlePath: subtitle.path,
          hasProbedChapters: true,
        );
        await library.addSingleVideo(
          item,
          useOriginalPath: true,
          reuseExistingItem: false,
        );
        originals.add(item);
        expectedBytes[item.title] = await file.readAsBytes();
      }
      final service = PortableTransferService.forTesting();
      final package = p.join(root.path, 'local.fluentpack');
      await _wait(
        await service.exportSelection(
          library: library,
          rootIds: originals.map((e) => e.id).toList(),
          outputPath: package,
          options: const PortableExportOptions(
            packageName: 'Local histories',
            includeSidecars: true,
          ),
        ),
      );
      final preview = await service.inspectPackage(package);
      expect(preview.mediaCount, 3);
      await _wait(
        await service.importPackage(
          library: library,
          packagePath: package,
          preview: preview,
        ),
      );
      final restored = library.storageVideos
          .where((item) => !originals.any((old) => old.id == item.id))
          .toList();
      expect(restored, hasLength(3));
      for (final item in restored) {
        expect(await File(item.path).readAsBytes(), expectedBytes[item.title]);
        expect(item.path.contains('://'), isFalse);
        expect(item.lastPositionMs, 12345);
        expect(
          item.sourceRef!.toJson(),
          originals
              .singleWhere((old) => old.title == item.title)
              .sourceRef!
              .toJson(),
        );
        expect(
          await File(item.subtitlePath!).readAsString(),
          contains('My ${item.title} learning note'),
        );
      }
      final zip = p.join(root.path, 'local.zip');
      await _wait(
        await service.exportSelection(
          library: library,
          rootIds: originals.map((e) => e.id).toList(),
          outputPath: zip,
          options: const PortableExportOptions(
            packageName: 'Local ZIP',
            format: PortableExportFormat.zip,
            wrapInFolder: false,
            zipEmbedSubtitles: false,
            zipExternalSubtitles: true,
            includeDanmaku: false,
          ),
        ),
      );
      final archive = ZipDecoder().decodeBytes(await File(zip).readAsBytes());
      for (final item in originals) {
        expect(
          archive.files
              .singleWhere((file) => file.name == '${item.title}.mp4')
              .content,
          expectedBytes[item.title],
        );
        expect(
          archive.files.any((file) => file.name == '${item.title}.srt'),
          isTrue,
        );
        expect(await File(item.path).exists(), isTrue);
      }
      expect(
        archive.files.any(
          (file) =>
              file.name.endsWith('.url') ||
              file.name == zipPodcastReferencesPath,
        ),
        isFalse,
      );
    },
  );

  test(
    'only explicit complete promoted Bili files normalize on load; missing and stream fragments stay blocked',
    () async {
      final complete = await File(
        p.join(root.path, 'completed.mp4'),
      ).writeAsBytes([1, 2, 3, 4]);
      final fragment = await File(
        p.join(root.path, 'fragment.m4s'),
      ).writeAsBytes([1, 2]);
      VideoItem saved(String id, String? owned) => VideoItem(
        id: id,
        path: 'bilibili://stream/BVlocal?cid=1',
        bilibiliDownloadPath: owned,
        sourceRef: _bili,
        title: id,
        durationMs: 60000,
        lastPositionMs: 18000,
        lastUpdated: 1,
        hasProbedChapters: true,
      );
      final records = [
        saved('complete', complete.path),
        saved('missing', p.join(root.path, 'missing.mp4')),
        saved('fragment', fragment.path),
      ];
      final data = library.dataRootDirOrNull!;
      await File(p.join(data.path, 'library.json')).writeAsString(
        jsonEncode({
          'schemaVersion': 2,
          'videos': records.map((e) => e.toJson()).toList(),
          'collections': [],
          'rootChildrenIds': records.map((e) => e.id).toList(),
        }),
      );
      library.resetLibraryForTesting();
      library.skipImportSidecarWorkForTesting = true;
      await library.init(deferMaintenance: true);
      final item = library.getVideo('complete')!;
      expect(item.path, complete.path);
      expect(item.sourceRef!.toJson(), _bili.toJson());
      expect(item.lastPositionMs, 18000);
      expect(
        library.getContents(null).whereType<VideoItem>().map((e) => e.id),
        ['complete'],
      );
      expect(library.storageVideos, hasLength(3));
      expect(library.getVideo('missing')!.path, startsWith('bilibili://'));
      expect(library.getVideo('fragment')!.path, startsWith('bilibili://'));
      expect(await library.promoteBilibiliDownloadCards([item.id]), 0);
      expect(item.path, complete.path);
      final service = PortableTransferService.forTesting();
      final zip = p.join(root.path, 'promoted.zip');
      await _wait(
        await service.exportSelection(
          library: library,
          rootIds: [item.id],
          outputPath: zip,
          options: const PortableExportOptions(
            packageName: 'Owned local',
            format: PortableExportFormat.zip,
            wrapInFolder: false,
            zipEmbedSubtitles: false,
            zipExternalSubtitles: false,
          ),
        ),
      );
      final archive = ZipDecoder().decodeBytes(await File(zip).readAsBytes());
      expect(archive.files.single.content, [1, 2, 3, 4]);
      expect(await complete.exists(), isTrue);
      expect(await fragment.exists(), isTrue);
    },
  );
}
