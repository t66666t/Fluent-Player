import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform previousPaths;
  late MediaCacheService cache;
  late PortableTransferService transfer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('portable_cache_roundtrip_');
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
    cache = MediaCacheService(
      backend: FakeBackend(root),
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

  Future<CacheVariant> register(
    VideoItem item,
    File media, {
    String id = '80',
    int height = 1080,
    String revision = '',
    CacheContent content = CacheContent.media,
  }) async {
    final variant = CacheVariant(
      source: CacheSource.fromItem(item)!,
      quality: CacheQuality(
        id: id,
        label: '${height}P',
        height: height,
        revision: revision,
      ),
      path: media.path,
      bytes: await media.length(),
      createdAt: 1,
      managed: false,
      content: content,
    );
    await cache.registerLegacy(variant);
    return variant;
  }

  Future<String> export(VideoItem item) async {
    final output = p.join(root.path, '${item.id}.fluentpack');
    final task = await transfer.exportSelection(
      library: library,
      rootIds: [item.id],
      outputPath: output,
      options: const PortableExportOptions(
        packageName: '迁移',
        wrapInFolder: true,
      ),
    );
    await _wait(task);
    expect(task.status, PortableTransferStatus.completed, reason: task.error);
    return output;
  }

  Future<VideoItem> import(String path) async {
    final prior = library.storageVideos.map((item) => item.id).toSet();
    final task = await transfer.importPackage(
      library: library,
      packagePath: path,
      preview: await transfer.inspectPackage(path),
    );
    await _wait(task);
    expect(task.status, PortableTransferStatus.completed, reason: task.error);
    return library.storageVideos.singleWhere(
      (item) => !prior.contains(item.id),
    );
  }

  for (final downloaded in [false, true]) {
    test(
      'Bilibili ${downloaded ? 'downloaded' : 'online'} card restores complete owned rendition and exact sidecars',
      () async {
        final item = _bilibili('bili');
        final primary = await file(
          'zh.srt',
          '1\r\n00:00:00,100 --> 00:00:03,000\r\n你好\r\n',
        );
        final secondary = await file(
          'en.ass',
          '[Script Info]\r\nTitle: English\r\n',
        );
        final danmaku = await file(
          'comments.xml',
          '<i><d p="1,1,25,16777215">弹幕</d></i>',
        );
        final words = await File(
          SubtitleWordTimingStore.pathFor(primary.path),
        ).writeAsString('{"version":1,"cues":[],"exact":"原始数据"}');
        item.subtitlePath = primary.path;
        item.secondarySubtitlePath = secondary.path;
        item.danmakuPath = danmaku.path;
        item.additionalSubtitles = {'中文': primary.path};
        item.localSubtitles = {'English': secondary.path};
        item.managedSubtitleAssets = [
          ManagedSubtitleAsset(
            assetId: 'original',
            path: primary.path,
            wordTimingPath: words.path,
            kind: ManagedSubtitleAssetKind.downloaded,
            displayName: '中文',
            language: 'zh-CN',
            createdAt: 17,
            offsetMs: 650,
            contentHash: 'kept',
            sourceLabel: '手动选用',
            machineGenerated: true,
          ),
        ];
        await library.addSingleVideo(item, reuseExistingItem: false);
        final cached = await file('cached.mp4', 'complete audio plus video');
        final high = await file('higher.mp4', 'higher rendition');
        await register(item, cached);
        await register(item, high, id: '120', height: 2160);
        if (downloaded) item.bilibiliDownloadPath = cached.path;
        item.playbackPath = (await file(
          'transient.mp4',
          'transient playback must not export',
        )).path;
        final package = await export(item);
        final manifest = await _manifest(package);
        final record =
            ((manifest['snapshot'] as Map)['videos'] as List).single as Map;
        expect(record['isOnline'], isTrue);
        expect(
          record['cachedBilibiliMedia']['quality']['id'],
          downloaded ? '80' : '120',
        );
        final restored = await import(package);
        expect(restored.path, startsWith('bilibili://'));
        expect(restored.playbackPath, isNull);
        expect(restored.lastPositionMs, item.lastPositionMs);
        expect(
          await File(restored.subtitlePath!).readAsBytes(),
          await primary.readAsBytes(),
        );
        expect(
          await File(restored.secondarySubtitlePath!).readAsBytes(),
          await secondary.readAsBytes(),
        );
        expect(
          await File(restored.danmakuPath!).readAsBytes(),
          await danmaku.readAsBytes(),
        );
        expect(restored.subtitlePath, isNot(contains('fluent_transfer')));
        final asset = restored.managedSubtitleAssets.singleWhere(
          (a) => a.displayName == '中文',
        );
        expect(asset.offsetMs, 650);
        expect(asset.machineGenerated, isTrue);
        expect(asset.language, 'zh-CN');
        expect(asset.contentHash, 'kept');
        expect(
          await File(asset.wordTimingPath!).readAsBytes(),
          await words.readAsBytes(),
        );
        expect(
          asset.wordTimingPath,
          SubtitleWordTimingStore.pathFor(asset.path),
        );
        final lease = await cache.acquire(
          restored,
          qualityId: downloaded ? '80' : '120',
        );
        expect(lease, isNotNull);
        await lease!.release();
        if (downloaded) {
          expect(
            await File(restored.bilibiliDownloadPath!).readAsBytes(),
            await cached.readAsBytes(),
          );
        }
      },
    );
  }

  test(
    'current complete cloud cache survives package import without login',
    () async {
      final item = _cloud('cloud');
      await library.addSingleVideo(item, reuseExistingItem: false);
      final original = await file('cloud.mp4', 'cloud complete source');
      await register(item, original, id: 'original', revision: 'r2');
      await register(
        item,
        await file('old.mp4', 'old revision'),
        id: 'old',
        revision: 'r1',
        height: 2160,
      );
      await register(
        item,
        await file('track.mp4', 'isolated video'),
        id: 'track',
        revision: 'r2',
        height: 4320,
        content: CacheContent.video,
      );
      final package = await export(item);
      expect((await _manifest(package))['formatVersion'], 6);
      final restored = await import(package);
      final imported = cache.variants
          .where((v) => v.source.itemId == restored.id)
          .single;
      expect(imported.quality.id, 'original');
      expect(imported.quality.revision, 'r2');
      expect(imported.path, isNot(original.path));
      expect(
        await File(imported.path).readAsBytes(),
        await original.readAsBytes(),
      );
      expect(
        restored.sourceRef!.cloudDrive!.sourceKey,
        item.sourceRef!.cloudDrive!.sourceKey,
      );
      final lease = await cache.acquire(restored);
      expect(lease, isNotNull);
      await lease!.release();
    },
  );

  test('uncached cloud export fails explicitly with no archive', () async {
    final item = _cloud('missing-cloud');
    await library.addSingleVideo(item, reuseExistingItem: false);
    await register(
      item,
      await file('video.mp4', 'video only'),
      revision: 'r2',
      content: CacheContent.video,
    );
    await register(
      item,
      await file('stale.mp4', 'old source'),
      id: 'original',
      revision: 'r1',
    );
    final output = p.join(root.path, 'rejected.fluentpack');
    final task = await transfer.exportSelection(
      library: library,
      rootIds: [item.id],
      outputPath: output,
      options: const PortableExportOptions(packageName: '不可导出'),
    );
    await _wait(task);
    expect(task.status, PortableTransferStatus.failed);
    expect(task.error, contains('完整缓存'));
    expect(await File(output).exists(), isFalse);
    expect(await File('$output.part').exists(), isFalse);
  });

  test(
    'missing explicit subtitle and danmaku attachments are reported without warning for unselected attachments',
    () async {
      final missing = _bilibili('missing-sidecars')
        ..subtitlePath = p.join(root.path, 'missing.srt')
        ..danmakuPath = p.join(root.path, 'missing.ass');
      await library.addSingleVideo(missing, reuseExistingItem: false);
      final package = await export(missing);
      final manifest = await _manifest(package);
      expect(manifest['missingSidecarCount'], 2);
      expect(
        (manifest['warnings'] as List).map((row) => row['fileName']),
        containsAll(['missing.srt', 'missing.ass']),
      );
      expect(transfer.tasks.first.subtitle, contains('缺少 2 个字幕/弹幕附件'));
      final noAttachments = _bilibili('without-sidecars');
      await library.addSingleVideo(noAttachments, reuseExistingItem: false);
      final clean = await _manifest(await export(noAttachments));
      expect(clean['warnings'], isNull);
      expect(clean['missingSidecarCount'], isNull);
      expect(transfer.tasks.first.subtitle, isNot(contains('缺少')));
    },
  );

  test(
    'FluentPack renamed ZIP retains online card and complete cache on import',
    () async {
      final item = _bilibili('renamed');
      await library.addSingleVideo(item, reuseExistingItem: false);
      await register(
        item,
        await file('renamed-source.mp4', 'renamed cached content'),
      );
      final archive = await File(
        await export(item),
      ).copy(p.join(root.path, 'renamed.zip'));
      final task = await transfer.importArchive(
        library: library,
        archivePath: archive.path,
        displayName: 'renamed.zip',
      );
      await _wait(task);
      expect(task.status, PortableTransferStatus.completed, reason: task.error);
      final restored = library.storageVideos.singleWhere(
        (v) => v.id != item.id,
      );
      expect(restored.sourceRef?.bvid, item.sourceRef?.bvid);
      expect(restored.path, startsWith('bilibili://'));
      expect(cache.variants.any((v) => v.source.itemId == restored.id), isTrue);
    },
  );
}

VideoItem _bilibili(String id) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1xx411c7mD?cid=123',
  title: '缓存视频',
  durationMs: 120000,
  lastPositionMs: 34567,
  lastUpdated: 17,
  sourceRef: const MediaSourceRef(
    value: 'BV1xx411c7mD',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV1xx411c7mD',
    cid: 123,
  ),
  hasProbedChapters: true,
);

VideoItem _cloud(String id) {
  const cloud = CloudDriveSourceRef(
    providerId: 'baidu',
    remoteAccountId: 'account',
    driveId: 'drive',
    fileId: 'file',
    revision: 'r2',
  );
  return VideoItem(
    id: id,
    path: cloud.logicalUri,
    title: '网盘视频',
    durationMs: 120000,
    lastUpdated: 17,
    hasProbedChapters: true,
    sourceRef: MediaSourceRef(
      value: cloud.logicalUri,
      kind: MediaSourceKind.cloudDrive,
      cloudDrive: cloud,
    ),
  );
}

Future<void> _wait(PortableTransferTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (task.isActive && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (task.isActive) throw TimeoutException('transfer did not finish');
}

Future<Map> _manifest(String path) async {
  final input = InputFileStream(path);
  final archive = ZipDecoder().decodeStream(input);
  try {
    final entry = archive.files.singleWhere(
      (e) => p.posix.basename(e.name) == 'manifest.json',
    );
    return jsonDecode(utf8.decode(entry.content)) as Map;
  } finally {
    archive.clear();
    await input.close();
  }
}
