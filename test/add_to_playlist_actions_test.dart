import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/playback_queue_add_service.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/media_library_virtual_selection_actions.dart';
import 'package:video_player_app/widgets/add_to_playlist_button.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/widgets/playback_queue_add_actions.dart';

import 'test_dir_cleanup.dart';

const _bvid = 'BV1xx411c7mD';
VideoItem _local(String id) => VideoItem(
  id: id,
  path: '/$id.mp3',
  title: id,
  durationMs: 60000,
  type: MediaType.audio,
  lastUpdated: 0,
);

class _Api extends BilibiliApiService {
  Completer<void>? gate;
  int infoCalls = 0, extrasCalls = 0;
  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    infoCalls++;
    await gate?.future;
    return BilibiliVideoInfo(
      title: '分P测试',
      desc: '',
      pic: '',
      bvid: bvid,
      aid: '1',
      ownerName: 'UP',
      ownerMid: '7',
      pubDate: 0,
      pages: [
        BilibiliPage(cid: 102, page: 2, part: 'P2', duration: 60),
        BilibiliPage(cid: 101, page: 1, part: 'P1', duration: 60),
      ],
    );
  }

  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async {
    extrasCalls++;
    return const BilibiliPlayerMetadata();
  }

  @override
  Future<String> fetchDanmakuXml(int cid) async => '<i></i>';
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryService library;
  late PlaylistManager queue;
  late BilibiliDownloadService bili;
  late _Api api;
  late Directory root;
  late PathProviderPlatform originalPaths;
  late BuildContext actionContext;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    root = await Directory.systemTemp.createTemp('queue_add_actions_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    for (final id in ['a', 'b', 'c', 'missing']) {
      library.seedVideoForTesting(_local(id));
    }
    queue =
        PlaylistManager(
            queuePolicy: PlaybackQueuePolicy(
              sourceExists: (path) => !path.contains('missing'),
            ),
          )
          ..initialize(libraryService: library)
          ..setPlaylist([library.getVideo('a')!]);
    api = _Api();
    bili = BilibiliDownloadService(apiService: api);
  });

  tearDown(() async {
    await bili.shutdown();
    queue.dispose();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = null;
    PathProviderPlatform.instance = originalPaths;
    await deleteTestTempDir(root);
  });

  Future<void> pump(WidgetTester tester, {Widget? child}) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<PlaylistManager>.value(value: queue),
          ChangeNotifierProvider<BilibiliDownloadService>.value(value: bili),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                actionContext = context;
                return child ?? const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'single and batch additions are ordered, deduplicated and silent',
    (tester) async {
      await pump(tester);
      final result = await addLibrarySelectionToQueue(actionContext, [
        'c',
        'b',
        'a',
        'missing',
      ]);
      await tester.pumpAndSettle();
      expect(result.added, ['c', 'b']);
      expect(result.duplicates, 1);
      expect(result.failed, ['missing']);
      expect(queue.playlist.map((e) => e.id), ['a', 'c', 'b']);
      expect(queue.currentItem?.id, 'a');
      expect(find.byType(SnackBar), findsOneWidget);
      ScaffoldMessenger.of(actionContext).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      final repeated = await addLibrarySelectionToQueue(actionContext, [
        'c',
        'b',
      ]);
      await tester.pumpAndSettle();
      expect(repeated.duplicates, 2);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'Bilibili adds every part without import, history or extra downloads',
    (tester) async {
      await pump(tester);
      queue.setPlaybackMode(PlaybackMode.shuffle);
      final result = await tester.runAsync(
        () => addBilibiliVideoToQueue(actionContext, _bvid),
      );
      await tester.pumpAndSettle();
      expect(result!.added.length, 2);
      expect(queue.playlist.skip(1).map((e) => e.sourceRef!.page), [1, 2]);
      expect(queue.currentItem?.id, 'a');
      expect(queue.playbackMode, PlaybackMode.shuffle);
      expect(api.extrasCalls, 0);
      expect(bili.tasks, isEmpty);
      expect(
        library.storageVideos
            .where((e) => e.sourceRef?.bvid == _bvid)
            .every((e) => e.isTransient),
        isTrue,
      );
      expect(find.byType(SnackBar), findsNothing);
      final one = await tester.runAsync(
        () => addBilibiliVideoToQueue(actionContext, _bvid, page: 2),
      );
      expect(one!.duplicates, 1);
      expect(queue.playlist.length, 3);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('Bilibili part action adds only the selected part', (
    tester,
  ) async {
    await pump(tester);
    final result = await tester.runAsync(
      () => addBilibiliVideoToQueue(actionContext, _bvid, page: 2),
    );
    expect(result!.added.length, 1);
    expect(queue.playlist.last.sourceRef?.page, 2);
    expect(queue.playlist.last.sourceRef?.cid, 102);
  });

  testWidgets(
    'cancelled remote preparation leaves playback and the queue untouched',
    (tester) async {
      await pump(tester);
      final progress = QueueAddProgress();
      final result = await tester.runAsync(() async {
        api.gate = Completer<void>();
        final job = addBilibiliVideoToQueue(
          actionContext,
          _bvid,
          progress: progress,
        );
        while (api.infoCalls == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        progress.cancel();
        api.gate!.complete();
        return job;
      });
      expect(result!.cancelled, isTrue);
      expect(queue.playlist.map((e) => e.id), ['a']);
      expect(library.transientVideos, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      progress.dispose();
    },
  );

  testWidgets(
    'folder addition follows folder order and retains a partially failed folder',
    (tester) async {
      await pump(tester);
      library.seedCollectionForTesting(
        VideoCollection(
          id: 'folder',
          name: '文件夹',
          createTime: 0,
          childrenIds: ['c', 'missing', 'b'],
        ),
      );
      final result = await addLibrarySelectionToQueue(actionContext, [
        'folder',
      ]);
      expect(result.added, ['c', 'b']);
      expect(result.failed, ['folder']);
      expect(queue.playlist.map((e) => e.id), ['a', 'c', 'b']);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'restored lightweight Bilibili parts load extra data only when selected',
    (tester) async {
      await pump(tester);
      await tester.runAsync(
        () => addBilibiliVideoToQueue(actionContext, _bvid),
      );
      final saved = queue.playlist.last;
      final restored = VideoItem.fromJson(saved.toJson());
      library.seedVideoForTesting(restored);
      final freshApi = _Api();
      final ready = await tester.runAsync(() async {
        final freshService = BilibiliDownloadService(apiService: freshApi);
        try {
          return await freshService.completeWatchPart(library, restored.id);
        } finally {
          await freshService.shutdown();
        }
      });
      expect(ready, isTrue);
      expect(freshApi.extrasCalls, 1);
      expect(freshApi.infoCalls, 0);
      expect(queue.playlist[1].bilibiliPendingCardData, isNotNull);
    },
  );

  testWidgets(
    'cloud entries create queue-only media and deduplicate across logins',
    (tester) async {
      await pump(tester);
      const entry = CloudDriveEntry(
        providerId: 'quark',
        accountLocalId: 'local',
        remoteAccountId: 'account',
        driveId: 'drive',
        fileId: 'file',
        parentFileId: 'root',
        name: '网盘视频.mp4',
        kind: CloudDriveEntryKind.video,
      );
      final result = await tester.runAsync(
        () => addCloudSelectionToQueue(actionContext, [entry]),
      );
      expect(result!.added.length, 1);
      expect(queue.playlist.last.sourceRef?.cloudDrive?.fileId, 'file');
      expect(queue.playlist.last.isTransient, isTrue);
      expect(queue.currentItem?.id, 'a');
      final repeated = await tester.runAsync(
        () => addCloudSelectionToQueue(actionContext, [entry]),
      );
      expect(repeated!.duplicates, 1);
      expect(queue.playlist.length, 2);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'multi-select keeps failed selections and never wraps at narrow widths',
    (tester) async {
      Set<String>? processed;
      await pump(
        tester,
        child: MediaLibrarySelectionBottomBar(
          actions: MediaLibraryVirtualSelectionActions.forFolders(
            selectedIds: {'b', 'missing'},
          ),
          queueSelectedIds: const ['b', 'missing'],
          onQueueProcessed: (ids) => processed = ids,
          onAction: (_) {},
        ),
      );
      for (final width in [320.0, 820.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('selection-add-to-playlist')))
              .height,
          48,
        );
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.tap(find.byKey(const ValueKey('selection-add-to-playlist')));
      await tester.pumpAndSettle();
      expect(processed, {'b'});
      expect(queue.playlist.map((e) => e.id), ['a', 'b']);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('new button confirms in place and repeated addition is silent', (
    tester,
  ) async {
    await pump(
      tester,
      child: Builder(
        builder: (context) => SizedBox(
          width: 150,
          child: AddToPlaylistButton(
            onAdd: (progress) =>
                addLibrarySelectionToQueue(context, ['b'], progress: progress),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(AddToPlaylistButton));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.byType(AddToPlaylistButton));
    await tester.pumpAndSettle();
    expect(queue.playlist.length, 2);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });
}
