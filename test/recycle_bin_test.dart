import 'package:video_player_app/widgets/recycle_bin_deletion_dialog.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/recycle_bin_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform originalProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    root = await Directory.systemTemp.createTemp('recycle_bin_test_');
    originalProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Provider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
  });

  tearDown(() async {
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = originalProvider;
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> loadTree() async {
    final media = Directory(p.join(root.path, 'imported_videos'));
    await media.create();
    final videos = <VideoItem>[];
    for (final entry in {
      'selected': 'nested',
      'sibling': 'nested',
      'other': 'top',
      'branch-video': 'branch',
    }.entries) {
      final file = await File(
        p.join(media.path, '${entry.key}.mp4'),
      ).writeAsBytes([1, 2, 3]);
      videos.add(
        VideoItem(
          id: entry.key,
          path: file.path,
          title: entry.key,
          parentId: entry.value,
          durationMs: 1000,
          lastUpdated: 0,
          lastPositionMs: 200,
          hasProbedChapters: true,
        ),
      );
    }
    final collections = [
      VideoCollection(
        id: 'top',
        name: '原文件夹',
        createTime: 0,
        childrenIds: ['nested', 'other', 'branch'],
      ),
      VideoCollection(
        id: 'nested',
        name: '子文件夹',
        createTime: 0,
        parentId: 'top',
        childrenIds: ['selected', 'sibling'],
      ),
      VideoCollection(
        id: 'branch',
        name: '另一文件夹',
        createTime: 0,
        parentId: 'top',
        childrenIds: ['branch-video'],
      ),
    ];
    await File(p.join(root.path, 'library.json')).writeAsString(
      jsonEncode({
        // Load a supported library, so these tests reach the recycle-bin UI
        // and restore operations instead of the future-format guard.
        'schemaVersion': 2,
        'videos': videos.map((v) => v.toJson()).toList(),
        'collections': collections.map((c) => c.toJson()).toList(),
        'rootChildrenIds': ['top'],
      }),
    );
    await library.init();
  }

  List<String> ids(List<dynamic> contents) =>
      contents.map((item) => item.id as String).toList();

  test('recycling publishes the entire batch before a slow save', () async {
    await loadTree();
    final started = Completer<void>();
    final release = Completer<void>();
    library.writeLibrarySnapshotOverrideForTesting = () {
      started.complete();
      return release.future;
    };
    final visibleBatches = <List<String>>[];
    void onChanged() => visibleBatches.add(ids(library.getContents('nested')));
    library.addListener(onChanged);
    var saved = false;
    final saving = library
        .moveToRecycleBin(['selected', 'sibling', 'selected'])
        .then((_) => saved = true);
    try {
      expect(visibleBatches, [<String>[]]);
      expect(library.getVideo('selected')!.isRecycled, isTrue);
      expect(library.getVideo('sibling')!.isRecycled, isTrue);
      expect(library.getCollection('nested')!.childrenIds, isEmpty);
      await started.future;
      expect(saved, isFalse);
      expect(visibleBatches, hasLength(1));
    } finally {
      release.complete();
      await saving;
      library.removeListener(onChanged);
    }
    expect(saved, isTrue);
    expect(visibleBatches, hasLength(1));
  });

  test(
    'repeated recycling preserves subtitle recovery and skips saving',
    () async {
      await loadTree();
      final selected = library.getVideo('selected')!;
      selected.subtitlePath = p.join(root.path, 'selected.srt');
      await library.moveToRecycleBin(['selected']);
      final recycleTime = selected.recycleTime;
      final subtitlePaths = selected.recycledSelectedSubtitlePaths;
      selected.subtitlePath = null;
      var writes = 0;
      library.writeLibrarySnapshotOverrideForTesting = () async => writes++;

      await library.moveToRecycleBin(['selected', 'missing']);

      expect(selected.recycleTime, recycleTime);
      expect(selected.recycledSelectedSubtitlePaths, subtitlePaths);
      expect(writes, 0);
    },
  );

  test('legacy export ownership is saved after immediate removal', () async {
    if (!Platform.isWindows) return;
    await loadTree();
    final customPath = p.join(root.path, 'bilibili');
    SharedPreferences.setMockInitialValues({
      'bilibili_custom_download_path': customPath,
    });
    final selected = library.getVideo('selected')!;
    selected.path = p.join(
      customPath,
      'video_12345678-1234-4234-8234-123456789abc.mp4',
    );

    final saving = library.moveToRecycleBin(['selected']);
    expect(selected.isRecycled, isTrue);
    expect(ids(library.getContents('nested')), ['sibling']);
    await saving;

    expect(selected.isBilibiliExported, isTrue);
    final snapshot = jsonDecode(
      await File(p.join(root.path, 'library.json')).readAsString(),
    );
    final saved = (snapshot['videos'] as List).singleWhere(
      (item) => item['id'] == 'selected',
    );
    expect(saved['isBilibiliExported'], isTrue);
    expect(saved['isRecycled'], isTrue);
  });

  test(
    'partial restore preserves hierarchy, siblings, files and saved state',
    () async {
      await loadTree();
      final selected = library.getVideo('selected')!;
      final originalPath = selected.path;
      selected.subtitlePath = p.join(root.path, 'selected.srt');
      selected.localSubtitles = {'中文': selected.subtitlePath!};
      await library.moveToRecycleBin(['top']);
      final deletionTime = library.getCollection('top')!.recycleTime;
      expect(ids(library.getRecycledFolderContents('nested')), [
        'selected',
        'sibling',
      ]);

      await library.restoreFromRecycleBin(['selected']);

      expect(ids(library.getContents(null)), ['top']);
      expect(ids(library.getContents('top')), ['nested']);
      expect(ids(library.getContents('nested')), ['selected']);
      expect(selected.parentId, 'nested');
      expect(selected.path, originalPath);
      expect(await File(originalPath).exists(), true);
      expect(selected.lastPositionMs, 200);
      expect(selected.localSubtitles, {'中文': selected.subtitlePath});
      for (final id in ['sibling', 'other', 'branch', 'branch-video']) {
        expect(library.isStorageItemRecycled(id), true, reason: id);
      }
      expect(library.getVideo('sibling')!.recycleTime, deletionTime);
      expect(ids(library.getRecycledFolderContents('nested')), ['sibling']);
      expect(ids(library.getRecycledFolderContents('top')).toSet(), {
        'other',
        'branch',
      });

      library.resetLibraryForTesting();
      await library.init();
      expect(ids(library.getContents('nested')), ['selected']);
      expect(library.getVideo('selected')!.path, originalPath);
      expect(library.isStorageItemRecycled('sibling'), true);
      await library.restoreFromRecycleBin(['sibling']);
      expect(ids(library.getContents('nested')), ['selected', 'sibling']);
    },
  );

  test(
    'independently deleted child remains browseable and restores subtitles',
    () async {
      await loadTree();
      final selected = library.getVideo('selected')!;
      final primary = p.join(root.path, 'primary.srt');
      final secondary = p.join(root.path, 'secondary.srt');
      selected.subtitlePath = primary;
      selected.secondarySubtitlePath = secondary;
      selected.additionalSubtitles = {'下载': primary};
      selected.localSubtitles = {'本地': secondary};
      await library.moveToRecycleBin(['selected']);
      await library.moveToRecycleBin(['top']);
      expect(ids(library.getRecycledFolderContents('nested')).toSet(), {
        'selected',
        'sibling',
      });
      selected.subtitlePath = null;
      selected.secondarySubtitlePath = null;
      selected.additionalSubtitles = null;
      selected.localSubtitles = null;
      await library.restoreFromRecycleBin(['selected']);
      expect(selected.subtitlePath, primary);
      expect(selected.secondarySubtitlePath, secondary);
      expect(selected.additionalSubtitles, {'下载': primary});
      expect(selected.localSubtitles, {'本地': secondary});
      expect(selected.recycledSelectedSubtitlePaths, isNull);
      expect(ids(library.getContents('nested')), ['selected']);
    },
  );

  test(
    'restoring a nested folder restores its contents and only its ancestors',
    () async {
      await loadTree();
      await library.moveToRecycleBin(['top']);
      await library.restoreFromRecycleBin(['nested']);
      expect(ids(library.getContents('top')), ['nested']);
      expect(ids(library.getContents('nested')), ['selected', 'sibling']);
      expect(library.isStorageItemRecycled('other'), true);
      expect(library.isStorageItemRecycled('branch-video'), true);
    },
  );

  for (final selection in [
    ['selected', 'top'],
    ['top', 'selected'],
  ]) {
    test(
      'folder and descendant batch restores whole folder: $selection',
      () async {
        await loadTree();
        await library.moveToRecycleBin(['sibling']);
        await library.moveToRecycleBin(['top']);
        await library.restoreFromRecycleBin(selection);
        expect(ids(library.getContents('top')), ['nested', 'other', 'branch']);
        expect(ids(library.getContents('nested')), ['selected']);
        expect(library.isStorageItemRecycled('sibling'), true);
        expect(library.isStorageItemRecycled('branch-video'), false);
      },
    );
  }

  test(
    'batch across branches restores both original paths without other media',
    () async {
      await loadTree();
      await library.moveToRecycleBin(['top']);
      await library.restoreFromRecycleBin(['selected', 'branch-video']);
      expect(ids(library.getContents('top')), ['nested', 'branch']);
      expect(ids(library.getContents('branch')), ['branch-video']);
      expect(ids(library.getContents('nested')), ['selected']);
      expect(library.isStorageItemRecycled('other'), true);
      expect(library.isStorageItemRecycled('sibling'), true);
    },
  );

  test(
    'deleting remaining recycled branches keeps restored media intact',
    () async {
      await loadTree();
      await library.moveToRecycleBin(['top']);
      await library.restoreFromRecycleBin(['selected']);
      final restoredPath = library.getVideo('selected')!.path;
      await library.deleteFromRecycleBin(ids(library.getRecycleBinContents()));
      expect(await File(restoredPath).exists(), true);
      expect(ids(library.getContents('nested')), ['selected']);
      expect(library.getVideo('sibling'), isNull);
      expect(library.getVideo('other'), isNull);
      expect(library.getCollection('branch'), isNull);
      expect(library.getRecycleBinContents(), isEmpty);
    },
  );

  test(
    'permanent folder deletion includes independently deleted descendants',
    () async {
      await loadTree();
      final childPath = library.getVideo('selected')!.path;
      await library.moveToRecycleBin(['selected', 'branch']);
      await library.moveToRecycleBin(['top']);
      expect(
        await library.calculateItemSize(library.getCollection('top')!),
        12,
      );
      await library.deleteFromRecycleBin(['top']);
      expect(await File(childPath).exists(), false);
      expect(library.storageVideos, isEmpty);
      expect(library.storageCollections, isEmpty);
    },
  );

  test(
    'a queued permanent delete never removes an item restored while waiting',
    () async {
      await loadTree();
      await library.moveToRecycleBin(['selected', 'other']);
      final started = Completer<void>();
      final release = Completer<void>();
      library.deleteVideoFilesOverrideForTesting = (item) async {
        if (item.id == 'other') {
          started.complete();
          await release.future;
        }
      };
      final first = library.deleteFromRecycleBin(['other']);
      await started.future;
      final second = library.deleteFromRecycleBin(['selected']);
      await library.restoreFromRecycleBin(['selected']);
      final path = library.getVideo('selected')!.path;
      release.complete();
      await first;
      final result = await second;
      expect(result.deletedIds, isEmpty);
      expect(result.failedIds['selected'], contains('已恢复，未执行删除'));
      expect(library.getVideo('selected')!.isRecycled, isFalse);
      expect(await File(path).exists(), isTrue);
    },
  );

  test(
    'failed descendant keeps its recycled ancestors and can be retried',
    () async {
      await loadTree();
      await library.moveToRecycleBin(['top']);
      final failedPath = library.getVideo('selected')!.path;
      library.beforeOwnedFileDeletionForTesting = (file) async {
        if (file.path == failedPath) {
          throw const FileSystemException('injected lock');
        }
      };
      final progress = <int>[];
      final result = await library.deleteFromRecycleBin([
        'top',
      ], onProgress: (done, total) => progress.add(done));
      expect(result.failedIds.keys, ['top']);
      expect(result.deletedIds, isEmpty);
      expect(progress, [1]);
      expect(library.getCollection('top'), isNotNull);
      expect(library.getCollection('nested'), isNotNull);
      expect(library.getVideo('selected'), isNotNull);
      expect(await File(failedPath).exists(), isTrue);
      expect(library.getVideo('sibling'), isNull);
      library.beforeOwnedFileDeletionForTesting = null;
      final retry = await library.deleteFromRecycleBin(['top']);
      expect(retry.failedIds, isEmpty);
      expect(library.getRecycleBinContents(), isEmpty);
      expect(await File(failedPath).exists(), isFalse);
    },
  );

  test('supporting-file failure retains the primary media for retry', () async {
    await loadTree();
    final video = library.getVideo('selected')!;
    final cover = await File(
      p.join(root.path, 'imported_videos', 'cover.jpg'),
    ).writeAsBytes([1]);
    video.thumbnailPath = cover.path;
    await library.moveToRecycleBin(['selected']);
    library.beforeOwnedFileDeletionForTesting = (file) async {
      if (file.path == cover.path) {
        throw const FileSystemException('injected cover lock');
      }
    };
    final result = await library.deleteFromRecycleBin(['selected']);
    expect(result.failedIds.keys, ['selected']);
    expect(library.getVideo('selected'), isNotNull);
    expect(await File(video.path).exists(), isTrue);
    expect(await cover.exists(), isTrue);
  });

  test(
    'permanent deletion distinguishes removed files from unsaved records',
    () async {
      await loadTree();
      await library.moveToRecycleBin(['selected']);
      library.writeLibrarySnapshotOverrideForTesting = () async =>
          throw const FileSystemException('injected save failure');
      final result = await library.deleteFromRecycleBin(['selected']);
      expect(result.deletedIds, ['selected']);
      expect(result.failedIds, isEmpty);
      expect(result.saved, isFalse);
      expect(library.hasPersistenceFailure, isTrue);
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      await library.retryLibraryPersistence();
      expect(library.hasPersistenceFailure, isFalse);
    },
  );

  testWidgets(
    'permanent deletion stays open with progress and retryable failures',
    (tester) async {
      await tester.runAsync(() async {
        await loadTree();
        await library.moveToRecycleBin(['selected']);
      });
      final release = Completer<void>();
      library.deleteVideoFilesOverrideForTesting = (_) => release.future;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecycleBinDeletionDialog(library: library, ids: ['selected']),
          ),
        ),
      );
      expect(find.text('永久删除 1 项'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.text('永久删除')));
      await tester.pump();
      expect(find.text('正在处理'), findsOneWidget);
      expect(library.getVideo('selected'), isNotNull);
      release.completeError(const FileSystemException('injected lock'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('有 1 项未能删除，记录已保留。'), findsOneWidget);
      expect(find.text('重试未完成项'), findsOneWidget);
      expect(library.getVideo('selected'), isNotNull);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  test('each recycle-bin directory is its own video queue', () async {
    await loadTree();
    await library.moveToRecycleBin(['top']);

    expect(library.getRecycleBinDirectoryVideos(null), isEmpty);
    expect(
      library.getRecycleBinDirectoryVideos('top').map((item) => item.id),
      <String>['other'],
    );
    expect(
      library.getRecycleBinDirectoryVideos('nested').map((item) => item.id),
      <String>['selected', 'sibling'],
    );
    expect(
      library.getRecycleBinDirectoryVideos('branch').map((item) => item.id),
      <String>['branch-video'],
    );
  });

  testWidgets('opening a recycled video queues only that directory', (
    tester,
  ) async {
    late PlaylistManager playlist;
    await tester.runAsync(() async {
      await loadTree();
      await library.moveToRecycleBin(['selected', 'sibling']);
    });
    playlist = PlaylistManager();
    final playback = MediaPlaybackService();
    PlaybackNavigationService.entryRouteOverrideForTesting = (item) {
      return MaterialPageRoute<void>(
        builder: (_) => Text('preview ${item.id}'),
      );
    };
    addTearDown(() {
      PlaybackNavigationService.entryRouteOverrideForTesting = null;
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: const MaterialApp(home: RecycleBinScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('selected'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(playlist.playlist.map((item) => item.id), <String>[
      'selected',
      'sibling',
    ]);
    expect(playlist.currentIndex, 0);
    expect(playlist.getNext()?.id, 'sibling');
    expect(playlist.isQueueEligible(library.getVideo('selected')!), isTrue);
    expect(find.text('preview selected'), findsOneWidget);
  });

  testWidgets('opening a video inside a recycled folder queues that folder', (
    tester,
  ) async {
    late PlaylistManager playlist;
    await tester.runAsync(() async {
      await loadTree();
      await library.moveToRecycleBin(['top']);
    });
    playlist = PlaylistManager();
    final playback = MediaPlaybackService();
    PlaybackNavigationService.entryRouteOverrideForTesting = (item) {
      return MaterialPageRoute<void>(
        builder: (_) => Text('preview ${item.id}'),
      );
    };
    addTearDown(() {
      PlaybackNavigationService.entryRouteOverrideForTesting = null;
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
          home: RecycledFolderDetailScreen(
            collection: library.getCollection('nested')!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('selected'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(playlist.playlist.map((item) => item.id), <String>[
      'selected',
      'sibling',
    ]);
    expect(playlist.currentIndex, 0);
    expect(playlist.getNext()?.id, 'sibling');
    expect(playlist.snapshot.folderId, 'nested');
    expect(find.text('other'), findsNothing);
    expect(find.text('preview selected'), findsOneWidget);
  });

  testWidgets('folder detail offers individual restore and selection actions', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await loadTree();
      await library.moveToRecycleBin(['top']);
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: MaterialApp(
          home: RecycledFolderDetailScreen(
            collection: library.getCollection('nested')!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('还原'), findsNWidgets(2));
    expect(find.byTooltip('彻底删除'), findsNWidgets(2));
    expect(find.textContaining('请先还原该文件夹'), findsNothing);
    expect(find.textContaining('可单独还原或彻底删除'), findsNothing);
    await tester.runAsync(() async {
      final changed = Completer<void>();
      void onChanged() {
        if (!changed.isCompleted) changed.complete();
      }

      library.addListener(onChanged);
      try {
        await tester.tap(find.byTooltip('还原').first);
        await changed.future;
      } finally {
        library.removeListener(onChanged);
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('selected'), findsNothing);
    expect(find.text('sibling'), findsOneWidget);
    expect(ids(library.getContents('nested')), ['selected']);
    await tester.tap(find.byTooltip('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除'), findsOneWidget);
    await tester.tap(find.text('彻底删除'));
    await tester.pumpAndSettle();
    expect(find.text('永久删除 1 项'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(library.getVideo('sibling'), isNotNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    final restoredPath = library.getVideo('selected')!.path;
    final siblingPath = library.getVideo('sibling')!.path;
    await tester.tap(find.byTooltip('彻底删除'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final changed = Completer<void>();
      void onChanged() {
        if (library.getVideo('sibling') == null && !changed.isCompleted) {
          changed.complete();
        }
      }

      library.addListener(onChanged);
      try {
        await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
        await tester.pump();
        await changed.future.timeout(const Duration(seconds: 5));
        expect(await File(siblingPath).exists(), false);
        expect(await File(restoredPath).exists(), true);
      } finally {
        library.removeListener(onChanged);
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(RecycleBinDeletionDialog), findsNothing);
    expect(find.text('删除已完成'), findsNothing);
    expect(library.getVideo('sibling'), isNull);
    expect(find.text('sibling'), findsNothing);
    expect(find.text('没有待还原的内容'), findsOneWidget);
    expect(ids(library.getContents('nested')), ['selected']);
    expect(tester.takeException(), isNull);
  });
}

class _Provider extends PathProviderPlatform {
  _Provider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}
