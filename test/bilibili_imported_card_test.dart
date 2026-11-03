import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
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
  Future<String?> getTemporaryPath() async => p.join(root, 'tmp');
}

BilibiliDownloadTask _task(String id, String output) {
  final page = BilibiliPage(cid: 1, page: 1, part: 'Part', duration: 1);
  final video = BilibiliVideoInfo(
    title: id,
    desc: '',
    pic: '',
    bvid: '',
    aid: '',
    ownerName: '',
    ownerMid: '',
    pubDate: 0,
    pages: [page],
  );
  return BilibiliDownloadTask(
    taskId: id,
    singleVideoInfo: video,
    videos: [
      BilibiliVideoItem(
        videoInfo: video,
        episodes: [
          BilibiliDownloadEpisode(
            page: page,
            bvid: '',
            status: DownloadStatus.completed,
            outputPath: output,
          ),
        ],
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform previous;
  late BilibiliDownloadService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('bilibili_imported_card_');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/yt_dlp'),
          (call) async =>
              call.method == 'getLocalAppDataPath' ? root.path : null,
        );
    final settings = SettingsService()..resetForTest();
    settings.largeDataRootPath = root.path;
    settings.copyImportedMediaToPrivateStorage = false;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 1000;
    await library.init();
    service = BilibiliDownloadService()
      ..customDownloadPath = p.join(root.path, 'imports');
  });
  tearDown(() async {
    await service.shutdown();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/yt_dlp'),
          null,
        );
    await root.delete(recursive: true);
  });

  test(
    'duplicate task output paths bind only the exact episode being imported',
    () async {
      final output = File(p.join(root.path, 'download.mp4'));
      await output.writeAsBytes(List.generate(2048, (i) => i % 256));
      final firstTask = _task('first', output.path);
      final secondTask = _task('second', output.path);
      final first = firstTask.videos.single.episodes.single;
      final second = secondTask.videos.single.episodes.single;
      service.replaceTasksForTesting([firstTask, secondTask]);
      expect(await service.importToLibrary(library, episode: second), 1);
      expect(first.importedVideoIds, isEmpty);
      expect(first.isExported, isFalse);
      expect(second.isExported, isTrue);
      final firstId = second.latestImportedVideoId!;
      expect(library.getVideo(firstId)?.title, 'second');
      await output.writeAsBytes(List.generate(2048, (i) => (i + 1) % 256));
      expect(await service.importToLibrary(library, episode: second), 1);
      final latest = second.latestImportedVideoId!;
      expect(latest, isNot(firstId));
      expect(library.getVideo(firstId), isNotNull);
      expect(library.getVideo(latest), isNotNull);
      final restored = BilibiliDownloadEpisode.fromJson(second.toJson());
      expect(restored.latestImportedVideoId, latest);
    },
  );

  test(
    'completed members publish immediately and retain batch order after record cleanup',
    () async {
      service.libraryService = library;
      service.autoDeleteTaskAfterImport = true;
      final firstFile = File(p.join(root.path, 'first.mp4'));
      final secondFile = File(p.join(root.path, 'second.mp4'));
      await firstFile.writeAsBytes(List.filled(2048, 1));
      await secondFile.writeAsBytes(List.filled(2048, 2));
      final firstTask = _task('first', firstFile.path);
      final secondTask = _task('second', secondFile.path);
      final first = firstTask.videos.single.episodes.single
        ..status = DownloadStatus.downloading;
      final second = secondTask.videos.single.episodes.single;
      service.replaceTasksForTesting([firstTask, secondTask]);
      service.freezeImportBatchForTesting([first, second]);
      final batchId = first.importContext!.batchId;
      expect(await service.ensureEpisodeImported(second), 1);
      expect(service.tasks, [firstTask]);
      expect(first.status, DownloadStatus.downloading);
      expect(library.getVideo(second.latestImportedVideoId!), isNotNull);
      first.status = DownloadStatus.completed;
      expect(await service.ensureEpisodeImported(first), 1);
      expect(service.tasks, isEmpty);
      expect(first.importContext!.batchId, batchId);
      final batch = library.importBatches.singleWhere(
        (batch) => batch.id == batchId,
      );
      expect(batch.createdMediaIds, [
        first.latestImportedVideoId,
        second.latestImportedVideoId,
      ]);
      expect(library.getContents(null).map((item) => item.id), [
        first.latestImportedVideoId,
        second.latestImportedVideoId,
      ]);
    },
  );

  test(
    'failed publication preserves completed media and retries one reserved card',
    () async {
      service.libraryService = library;
      service.autoDeleteTaskAfterImport = true;
      final output = File(p.join(root.path, 'retry.mp4'));
      await output.writeAsBytes(List.filled(2048, 3));
      final task = _task('retry', output.path);
      final episode = task.videos.single.episodes.single;
      service.replaceTasksForTesting([task]);
      library.saveRetryDelaysForTesting = [];
      library.writeLibrarySnapshotOverrideForTesting = () async {
        throw const FileSystemException('disk unavailable');
      };
      expect(await service.ensureEpisodeImported(episode), 0);
      final reservedId = episode.importContext!.mediaId;
      expect(episode.status, DownloadStatus.completed);
      expect(episode.importState, BilibiliImportState.failed);
      expect(service.tasks, [task]);
      expect(await File(episode.publishedMediaPath!).exists(), isTrue);
      library.writeLibrarySnapshotOverrideForTesting = null;
      expect(await service.ensureEpisodeImported(episode), 1);
      expect(episode.latestImportedVideoId, reservedId);
      expect(library.getContents(null), hasLength(1));
      expect(service.tasks, isEmpty);
    },
  );

  test(
    'missing completed file fails publication once without restarting transfer',
    () async {
      service.libraryService = library;
      final task = _task('missing', p.join(root.path, 'missing.mp4'));
      final episode = task.videos.single.episodes.single;
      service.replaceTasksForTesting([task]);
      expect(
        await service
            .ensureEpisodeImported(episode)
            .timeout(const Duration(seconds: 2)),
        0,
      );
      expect(episode.status, DownloadStatus.completed);
      expect(episode.importState, BilibiliImportState.failed);
      expect(episode.importError, contains('重新下载'));
      expect(service.tasks, [task]);
    },
  );

  test(
    'durable receipt recovers an older queue journal before checking its moved output',
    () async {
      service.libraryService = library;
      final output = File(p.join(root.path, 'journal-old.mp4'));
      await output.writeAsBytes(List.filled(2048, 4));
      final task = _task('journal', output.path);
      final episode = task.videos.single.episodes.single;
      service.replaceTasksForTesting([task]);
      service.freezeImportBatchForTesting([episode]);
      final oldJournal = task.toJson();
      expect(await service.ensureEpisodeImported(episode), 1);
      final receiptId = episode.latestImportedVideoId;
      expect(await output.exists(), isFalse);
      library.resetLibraryForTesting();
      library.skipImportSidecarWorkForTesting = true;
      await library.init();
      expect(library.getVideo(receiptId!), isNotNull);
      final restoredTask = BilibiliDownloadTask.fromJson(oldJournal);
      final restoredEpisode = restoredTask.videos.single.episodes.single;
      expect(restoredEpisode.publishedMediaPath, isNull);
      expect(restoredEpisode.isExported, isFalse);
      service.replaceTasksForTesting([restoredTask]);
      expect(await service.ensureEpisodeImported(restoredEpisode), 1);
      expect(restoredEpisode.latestImportedVideoId, receiptId);
      expect(restoredEpisode.importState, BilibiliImportState.imported);
      expect(library.getContents(null), hasLength(1));
    },
  );
}
