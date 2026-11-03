import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/media_cache/media_cache_variants_dialog.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_cache_dialog.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_readiness.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LibraryService library;
  late FakeBackend backend;
  late MediaCacheService cache;
  late PathProviderPlatform previousPaths;
  MediaCacheService? previousCache;
  var widgetDrained = false;

  setUp(() async {
    widgetDrained = false;
    root = await Directory.systemTemp.createTemp('portable-readiness-');
    previousPaths = PathProviderPlatform.instance;
    previousCache = MediaCacheService.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
    backend = FakeBackend(root);
    cache = MediaCacheService(
      backend: backend,
      journal: File(p.join(root.path, 'cache.json')),
      observeNetwork: false,
    );
    await cache.initialize();
    MediaCacheService.instance = cache;
  });

  tearDown(() async {
    MediaCacheService.instance = previousCache;
    if (!widgetDrained) await cache.shutdown();
    cache.dispose();
    if (!widgetDrained) await library.saveProgress();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  Future<VideoItem> cloud(
    String id, {
    String? parentId,
    String? localPath,
    String? playbackPath,
    String revision = 'v1',
  }) async {
    final ref = CloudDriveSourceRef(
      providerId: 'baidu',
      remoteAccountId: 'remote-account',
      driveId: 'drive',
      fileId: id,
      revision: revision,
    );
    final item = VideoItem(
      id: id,
      title: 'Cloud $id',
      durationMs: 1000,
      path: localPath ?? ref.logicalUri,
      playbackPath: playbackPath,
      parentId: parentId,
      sourceRef: MediaSourceRef(
        value: ref.logicalUri,
        kind: MediaSourceKind.cloudDrive,
        cloudDrive: ref,
      ),
      lastUpdated: 1,
    );
    await library.addSingleVideo(item, reuseExistingItem: false);
    return item;
  }

  Future<CacheVariant> complete(
    VideoItem item, {
    CacheContent content = CacheContent.media,
    String revision = 'v1',
  }) async {
    final file = await File(
      p.join(root.path, '${item.id}-${content.name}-$revision.mp4'),
    ).writeAsBytes([1, 2, 3, 4]);
    final variant = CacheVariant(
      source: CacheSource.fromItem(item)!,
      quality: CacheQuality(
        id: '1080',
        label: '1080P',
        height: 1080,
        revision: revision,
      ),
      path: file.path,
      bytes: 4,
      content: content,
      createdAt: 1,
    );
    await cache.registerMaterial([variant]);
    return variant;
  }

  test('uncached selection is reported without starting a download', () async {
    final item = await cloud('uncached');
    expect(await uncachedCloudExportItems(library, [item.id], cache: cache), [
      item,
    ]);
    expect(cache.tasks, isEmpty);
    expect(backend.calls, 0);
  });

  test(
    'a complete current cloud cache makes the selection exportable',
    () async {
      final item = await cloud('cached');
      await complete(item);
      expect(
        await uncachedCloudExportItems(library, [item.id], cache: cache),
        isEmpty,
      );
      expect(cache.tasks, isEmpty);
      expect(backend.calls, 0);
    },
  );

  for (final content in [CacheContent.video, CacheContent.audio]) {
    test('an isolated ${content.name} track is insufficient', () async {
      final item = await cloud('track-${content.name}');
      await complete(item, content: content);
      expect(await uncachedCloudExportItems(library, [item.id], cache: cache), [
        item,
      ]);
    });
  }

  test(
    'old cloud revision cannot satisfy an export of the current file',
    () async {
      final item = await cloud('changed');
      final variant = await complete(item, revision: 'v0');
      expect(cache.hasCache(variant.source.key), isTrue);
      expect(await uncachedCloudExportItems(library, [item.id], cache: cache), [
        item,
      ]);
      expect(await cache.acquireVariant(variant, item), isNull);
    },
  );

  for (final corruption in ['deleted', 'truncated', 'pending-delete']) {
    test('$corruption cache cannot satisfy preflight', () async {
      final item = await cloud(corruption);
      final variant = await complete(item);
      switch (corruption) {
        case 'deleted':
          await File(variant.path).delete();
        case 'truncated':
          await File(variant.path).writeAsBytes([1]);
        case 'pending-delete':
          variant.pendingDelete = true;
      }
      expect(await uncachedCloudExportItems(library, [item.id], cache: cache), [
        item,
      ]);
    });
  }

  test(
    'a transient playback file does not stand in for complete cache',
    () async {
      final file = await File(
        p.join(root.path, 'playback.mp4'),
      ).writeAsBytes([1, 2, 3]);
      final item = await cloud('transient', playbackPath: file.path);
      expect(await uncachedCloudExportItems(library, [item.id], cache: cache), [
        item,
      ]);
    },
  );

  test('an imported local cloud download already contains the bytes', () async {
    final file = await File(
      p.join(root.path, 'download.mp4'),
    ).writeAsBytes([1, 2, 3]);
    final item = await cloud('local', localPath: file.path);
    expect(
      await uncachedCloudExportItems(library, [item.id], cache: cache),
      isEmpty,
    );
    expect(cache.tasks, isEmpty);
  });

  test('empty local media is reported as unavailable', () async {
    final file = await File(p.join(root.path, 'empty.mp4')).writeAsBytes([]);
    final item = await cloud('empty', localPath: file.path);
    expect(await uncachedCloudExportItems(library, [item.id], cache: cache), [
      item,
    ]);
  });

  test(
    'folder selection checks selected descendants and ignores other cards',
    () async {
      final folder = await library.createCollection('selected', null);
      final inner = await library.createCollection('nested', folder.id);
      final missing = await cloud('nested-missing', parentId: inner.id);
      final cached = await cloud('nested-ready', parentId: inner.id);
      await complete(cached);
      await cloud('unselected');
      expect(
        await uncachedCloudExportItems(library, [folder.id], cache: cache),
        [missing],
      );
      expect(
        await uncachedCloudExportItems(library, [cached.id], cache: cache),
        isEmpty,
      );
    },
  );

  testWidgets(
    'export prompt opens actual cache quality picker without downloading',
    (tester) async {
      final item = await tester.runAsync(() => cloud('quality-picker'));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => PortableExportCacheDialog(
                    library: library,
                    rootIds: [item!.id],
                    missing: [item],
                  ),
                ),
                child: const Text('Export'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      expect(find.text('先缓存网盘媒体'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('选择缓存画质'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byType(MediaCacheVariantsDialog), findsOneWidget);
      expect(find.text('360P'), findsOneWidget);
      expect(find.text('1080P'), findsOneWidget);
      expect(cache.tasks, isEmpty);
      expect(backend.calls, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('cache-variants-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('稍后导出'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      unawaited(
        Future.wait([cache.shutdown(), library.saveProgress()]).then((_) {
          widgetDrained = true;
        }),
      );
      for (var i = 0; i < 100 && !widgetDrained; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(widgetDrained, isTrue);
    },
  );
}
