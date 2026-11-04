import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/media_cache/media_cache_backend.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'media_cache_service_test.dart' show FakeBackend;

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => p.join(root, 'temporary');
}

/// A deleted public source must never be queried to export its local bytes.
class _OfflineBackend extends FakeBackend {
  _OfflineBackend(super.root);
  int networkCalls = 0;
  Never _network() {
    networkCalls++;
    throw StateError('the online source was removed');
  }

  @override
  Future<List<CacheQuality>> qualities(CacheSource source) async => _network();
  @override
  Future<CacheDownloadPlan> resolve(CacheTask task, CancelToken cancel) async =>
      _network();
  @override
  Future<File> download(
    CacheTask task,
    CacheDownloadPlan plan,
    MediaCachePreferences preferences,
    CancelToken cancel,
    void Function(CacheTransferProgress) onProgress,
  ) async => _network();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform previousPaths;
  late _OfflineBackend backend;
  late MediaCacheService cache;
  late PortableTransferService transfer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('bilibili_export_option_');
    previousPaths = PathProviderPlatform.instance;
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
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 120000;
    backend = _OfflineBackend(root);
    cache = MediaCacheService(
      backend: backend,
      journal: File(p.join(root.path, 'media_cache.json')),
      observeNetwork: false,
    );
    MediaCacheService.instance = cache;
    await cache.initialize();
    transfer = PortableTransferService.forTesting();
  });

  tearDown(() async {
    transfer.dispose();
    await cache.shutdown();
    MediaCacheService.instance = null;
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = previousPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/yt_dlp'),
          null,
        );
    await root.delete(recursive: true);
  });

  Future<File> file(String name, String bytes) =>
      File(p.join(root.path, name)).writeAsString(bytes);

  Future<void> register(VideoItem item, File media, {int height = 1080}) async {
    await cache.registerLegacy(
      CacheVariant(
        source: CacheSource.fromItem(item)!,
        quality: CacheQuality(
          id: '$height',
          label: '${height}P',
          height: height,
        ),
        path: media.path,
        bytes: await media.length(),
        createdAt: 17,
        // Imported optional caches also use managed=false; it is not provenance.
        managed: false,
      ),
    );
  }

  Future<(PortableTransferTask, String)> export(
    VideoItem item, {
    bool includeCache = true,
  }) async {
    final output = p.join(
      root.path,
      '${item.id}_${transfer.tasks.length}.fluentpack',
    );
    final task = await transfer.exportSelection(
      library: library,
      rootIds: [item.id],
      outputPath: output,
      options: PortableExportOptions(
        packageName: '离线备份',
        includeBilibiliCache: includeCache,
      ),
    );
    await _wait(task);
    return (task, output);
  }

  Future<String> completedExport(
    VideoItem item, {
    bool includeCache = true,
  }) async {
    final (task, output) = await export(item, includeCache: includeCache);
    expect(task.status, PortableTransferStatus.completed, reason: task.error);
    expect(backend.networkCalls, 0);
    return output;
  }

  Future<VideoItem> import(String package) async {
    final prior = library.storageVideos.map((item) => item.id).toSet();
    final task = await transfer.importPackage(
      library: library,
      packagePath: package,
      preview: await transfer.inspectPackage(package),
    );
    await _wait(task);
    expect(task.status, PortableTransferStatus.completed, reason: task.error);
    expect(backend.networkCalls, 0);
    return library.storageVideos.singleWhere(
      (item) => !prior.contains(item.id),
    );
  }

  test(
    'cache inclusion defaults on and explicit false survives serialization',
    () {
      const options = PortableExportOptions(packageName: 'default');
      expect(options.includeBilibiliCache, isTrue);
      expect(
        PortableExportOptions.fromJson({
          'packageName': 'old',
        }).includeBilibiliCache,
        isTrue,
      );
      expect(
        PortableExportOptions.fromJson(
          const PortableExportOptions(
            packageName: 'links',
            includeBilibiliCache: false,
          ).toJson(),
        ).includeBilibiliCache,
        isFalse,
      );
    },
  );

  test(
    'optional cache off keeps online source and exact subtitle/danmaku attachments',
    () async {
      final item = _bilibili('optional-off');
      final subtitle = await file(
        'zh.srt',
        '1\r\n00:00:01,000 --> 00:00:02,000\r\n字幕\r\n',
      );
      final danmaku = await file(
        'comments.ass',
        '[Script Info]\r\nTitle: 弹幕\r\n',
      );
      item.subtitlePath = subtitle.path;
      item.danmakuPath = danmaku.path;
      await library.addSingleVideo(item, reuseExistingItem: false);
      await register(item, await file('optional.mp4', 'optional full video'));
      final package = await completedExport(item, includeCache: false);
      final record = await _record(package);
      expect(record['isOnline'], isTrue);
      expect(record['cachedBilibiliMedia'], isNull);
      expect(await _mediaNames(package), isEmpty);
      final restored = await import(package);
      expect(restored.sourceRef?.bvid, item.sourceRef?.bvid);
      expect(restored.bilibiliDownloadPath, isNull);
      expect(
        await File(restored.subtitlePath!).readAsBytes(),
        await subtitle.readAsBytes(),
      );
      expect(
        await File(restored.danmakuPath!).readAsBytes(),
        await danmaku.readAsBytes(),
      );
    },
  );

  test(
    'default exports complete optional cache and re-export off does not mistake it for a download',
    () async {
      final item = _bilibili('optional-on');
      await library.addSingleVideo(item, reuseExistingItem: false);
      final media = await file(
        'optional.mp4',
        'complete content after public deletion',
      );
      await register(item, media);
      final package = await completedExport(item);
      expect(
        (await _record(package))['cachedBilibiliMedia']['downloadOrigin'],
        isFalse,
      );
      await media.delete();
      final restored = await import(package);
      expect(restored.bilibiliDownloadPath, isNull);
      final lease = await cache.acquire(restored);
      expect(lease, isNotNull);
      expect(
        await File(lease!.completePath!).readAsString(),
        'complete content after public deletion',
      );
      await lease.release();
      final links = await completedExport(restored, includeCache: false);
      expect((await _record(links))['cachedBilibiliMedia'], isNull);
      expect(await _mediaNames(links), isEmpty);
    },
  );

  test(
    'download-page owned file always survives cache off and preserves origin on repeated import',
    () async {
      final item = _bilibili('download');
      await library.addSingleVideo(item, reuseExistingItem: false);
      final owned = await file(
        'downloaded.mp4',
        'owned download from download page',
      );
      item.bilibiliDownloadPath = owned.path;
      await register(item, owned, height: 720);
      await register(
        item,
        await file('higher.mp4', 'optional higher rendition'),
        height: 2160,
      );
      final package = await completedExport(item, includeCache: false);
      final descriptor = (await _record(package))['cachedBilibiliMedia'];
      expect(descriptor['quality']['id'], '720');
      expect(descriptor['downloadOrigin'], isTrue);
      await owned.delete();
      final restored = await import(package);
      expect(
        await File(restored.bilibiliDownloadPath!).readAsString(),
        'owned download from download page',
      );
      final lease = await cache.acquire(restored, qualityId: '720');
      expect(lease, isNotNull);
      await lease!.release();
      final repeated = await completedExport(restored, includeCache: false);
      expect(
        (await _record(repeated))['cachedBilibiliMedia']['downloadOrigin'],
        isTrue,
      );
      expect(await _mediaNames(repeated), hasLength(1));
    },
  );

  test(
    'same-source online card does not inherit a different card download provenance',
    () async {
      final downloaded = _bilibili('download-owner');
      final online = _bilibili('online-peer');
      await library.addSingleVideo(downloaded, reuseExistingItem: false);
      await library.addSingleVideo(online, reuseExistingItem: false);
      final media = await file('owned.mp4', 'owned shared source');
      downloaded.bilibiliDownloadPath = media.path;
      await register(downloaded, media);
      final package = await completedExport(online, includeCache: false);
      expect((await _record(package))['cachedBilibiliMedia'], isNull);
      expect(await _mediaNames(package), isEmpty);
      expect(online.bilibiliDownloadPath, isNull);
    },
  );

  for (final includeCache in [false, true]) {
    test(
      'missing owned download fails explicitly with optional cache $includeCache instead of replacing it',
      () async {
        final item = _bilibili('missing-owned')
          ..bilibiliDownloadPath = p.join(root.path, 'deleted-owned.mp4');
        await library.addSingleVideo(item, reuseExistingItem: false);
        await register(
          item,
          await file('other.mp4', 'other complete rendition'),
        );
        final (task, output) = await export(item, includeCache: includeCache);
        expect(task.status, PortableTransferStatus.failed);
        expect(task.error, contains('下载成品'));
        expect(await File(output).exists(), isFalse);
        expect(await File('$output.part').exists(), isFalse);
        expect(backend.networkCalls, 0);
      },
    );
  }

  test(
    'missing cache catalog cannot silently export a known download as links',
    () async {
      final item = _bilibili('catalog-unavailable')
        ..bilibiliDownloadPath = (await file(
          'owned.mp4',
          'download exists',
        )).path;
      await library.addSingleVideo(item, reuseExistingItem: false);
      MediaCacheService.instance = null;
      final (task, output) = await export(item, includeCache: false);
      expect(task.status, PortableTransferStatus.failed);
      expect(task.error, contains('下载成品'));
      expect(await File(output).exists(), isFalse);
    },
  );

  test(
    'HTTP Bilibili stream never exports transient playback bytes when optional cache is off',
    () async {
      final item = _bilibili('http-stream')
        ..path = 'https://example.invalid/deleted.mp4'
        ..playbackPath = (await file(
          'playback.mp4',
          'incomplete playback temporary bytes',
        )).path;
      await library.addSingleVideo(item, reuseExistingItem: false);
      final package = await completedExport(item, includeCache: false);
      expect((await _record(package))['isOnline'], isTrue);
      expect((await _record(package))['cachedBilibiliMedia'], isNull);
      expect(await _mediaNames(package), isEmpty);
    },
  );

  test(
    'missing pre-unification local download fails instead of silently omitting the video',
    () async {
      final item = _bilibili('missing-legacy')
        ..path = p.join(root.path, 'deleted-legacy.mp4')
        ..sourceRef = _bilibili(
          'source',
        ).sourceRef!.copyWith(kind: MediaSourceKind.url)
        ..isBilibiliExported = true;
      await library.addSingleVideo(item, reuseExistingItem: false);
      final (task, output) = await export(item, includeCache: false);
      expect(task.status, PortableTransferStatus.failed);
      expect(task.error, contains('下载成品'));
      expect(await File(output).exists(), isFalse);
      expect(backend.networkCalls, 0);
    },
  );

  test(
    'pre-unification local downloaded video remains real media when optional cache is off',
    () async {
      final media = await file('old-download.mp4', 'legacy offline media');
      final item = _bilibili('legacy')
        ..path = media.path
        ..sourceRef = _bilibili(
          'source',
        ).sourceRef!.copyWith(kind: MediaSourceKind.url)
        ..isBilibiliExported = true;
      await library.addSingleVideo(item, reuseExistingItem: false);
      final package = await completedExport(item, includeCache: false);
      expect((await _record(package))['isOnline'], isFalse);
      expect(await _mediaNames(package), hasLength(1));
      final restored = await import(package);
      expect(await File(restored.path).readAsString(), 'legacy offline media');
      final repeated = await completedExport(restored, includeCache: false);
      expect(await _mediaNames(repeated), hasLength(1));
    },
  );
}

VideoItem _bilibili(String id) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1xx411c7mD?cid=123',
  title: '已失效来源的本地视频',
  durationMs: 120000,
  lastUpdated: 17,
  sourceRef: const MediaSourceRef(
    value: 'https://example.invalid/deleted',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV1xx411c7mD',
    cid: 123,
  ),
  hasProbedChapters: true,
);

Future<void> _wait(PortableTransferTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (task.isActive && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (task.isActive) throw TimeoutException('transfer did not finish');
}

Future<Map> _record(String package) async {
  final input = InputFileStream(package);
  final archive = ZipDecoder().decodeStream(input);
  try {
    final entry = archive.files.singleWhere(
      (e) => p.posix.basename(e.name) == 'manifest.json',
    );
    final manifest = jsonDecode(utf8.decode(entry.content)) as Map;
    return (manifest['snapshot']['videos'] as List).single as Map;
  } finally {
    archive.clear();
    await input.close();
  }
}

Future<List<String>> _mediaNames(String package) async {
  final input = InputFileStream(package);
  final archive = ZipDecoder().decodeStream(input);
  try {
    return archive.files
        .where((e) => ['.mp4', '.mkv'].contains(p.extension(e.name)))
        .map((e) => e.name)
        .toList();
  } finally {
    archive.clear();
    await input.close();
  }
}
