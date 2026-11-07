import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_thumbnails.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/video_picker_tree_node.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/services/internal_media_picker_source.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/services/transcription_media_selection.dart';
import 'package:video_player_app/widgets/internal_video_picker_dialog.dart';
import 'package:video_player_app/widgets/media_library_activity_menu.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';

import 'support/cloud_drive_fixture.dart' show CloudFixtureSecrets;

class _MetadataProvider extends CloudDriveProvider {
  int calls = 0;
  int? durationMs = 90000;
  Completer<void>? gate;
  @override
  String get id => 'baidu';
  @override
  Future<CloudDriveEntry> getFile(
    CloudDriveFileRequest request, {
    Object? cancelToken,
  }) async {
    calls++;
    await gate?.future;
    return CloudDriveEntry(
      providerId: id,
      accountLocalId: request.accountLocalId,
      remoteAccountId: request.remoteAccountId,
      driveId: request.driveId,
      fileId: request.fileId,
      parentFileId: '0',
      name: '网盘课程.mp4',
      kind: CloudDriveEntryKind.video,
      durationMs: durationMs,
      revision: 'r1',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HistoryController extends PodcastController {
  _HistoryController({
    required super.store,
    required super.client,
    required super.mediaStore,
  });
  Future<void> Function()? history;
  @override
  Future<void> refreshChannel(
    String id, {
    bool manual = true,
    bool history = false,
  }) async {
    if (history) await this.history?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preview = Platform.environment['INTERNAL_MEDIA_PICKER_PREVIEW'] == '1';
  setUpAll(() async {
    if (!preview) return;
    await (FontLoader('Noto Sans SC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  final library = LibraryService();
  final settings = SettingsService();
  late Directory root;
  late PodcastStore store;
  late PodcastRuntime runtime;
  late _HistoryController controller;
  late TranscriptionManager manager;
  late InternalMediaPickerSource source;
  late VideoCollection folder;
  var writes = 0;

  PodcastEpisode episode(int index, {bool video = false, int duration = 0}) {
    final value = PodcastEpisode(
      id: 'episode-$index',
      channelId: 'channel',
      title: '第 $index 集',
      publishedMs: index,
      durationMs: duration,
      media: [
        PodcastMedia(
          url: 'https://example.invalid/$index.${video ? 'mp4' : 'mp3'}',
          mimeType: video ? 'video/mp4' : 'audio/mpeg',
        ),
      ],
    );
    store.write('episode', value.id, value.toJson(), channel: 'channel');
    return value;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    await settings.init();
    library.resetLibraryForTesting();
    library.cloudDriveThumbnails = null;
    writes = 0;
    library.writeLibrarySnapshotOverrideForTesting = () async => writes++;
    root = await Directory.systemTemp.createTemp('internal-media-picker-');
    store = PodcastStore(sqlite3.openInMemory());
    final channel = PodcastChannel(
      id: 'channel',
      feedUrl: 'https://example.invalid/feed',
      title: '播客频道',
    );
    store.write('channel', channel.id, channel.toJson());
    final client = PodcastClient();
    controller = _HistoryController(
      store: store,
      client: client,
      mediaStore: PodcastMediaStore(
        root: root,
        store: store,
        http: client.http,
      ),
    );
    runtime = PodcastRuntime.forTesting(controller, library: library);
    PodcastRuntime.debugOverride = runtime;
    folder = await library.createCollection(
      '播客频道',
      null,
      podcastRef: const PodcastChannelRef(
        channelId: 'channel',
        feedUrl: 'https://example.invalid/feed',
      ),
    );
    manager = TranscriptionManager(settings: settings);
    source = InternalMediaPickerSource(library: library, manager: manager);
  });

  tearDown(() async {
    manager.dispose();
    library.cloudDriveThumbnails?.close();
    library.cloudDriveThumbnails = null;
    await runtime.shutdown();
    PodcastRuntime.debugOverride = null;
    library.resetLibraryForTesting();
    settings.resetForTest();
    await root.delete(recursive: true);
  });

  Future<void> openPicker(
    WidgetTester tester, {
    FutureOr<void> Function(List<VideoPickerTreeNode>)? confirm,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: preview ? 'Noto Sans SC' : null),
        builder: (context, child) => RepaintBoundary(
          key: const ValueKey('internal-media-preview'),
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => InternalVideoPickerDialog(
                  libraryService: library,
                  transcriptionManager: manager,
                  onConfirm: confirm ?? (_) {},
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<(_MetadataProvider, VideoItem)> cloudMedia() async {
    final provider = _MetadataProvider();
    final accounts = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: CloudFixtureSecrets()),
      metadata: MemoryCloudDriveAccountMetadataStore(),
    );
    await accounts.commitVerified(
      providerId: 'baidu',
      remoteAccountId: '42',
      displayName: '测试账号',
      credential: const CloudDriveCredential(cookies: []),
    );
    library.cloudDriveThumbnails = CloudDriveThumbnails(
      providers: CloudDriveProviderRegistry([provider]),
      accounts: accounts,
      root: root,
    );
    const reference = CloudDriveSourceRef(
      providerId: 'baidu',
      remoteAccountId: '42',
      driveId: '0',
      fileId: '9',
      revision: 'r1',
    );
    final item = VideoItem(
      id: reference.itemId,
      path: reference.logicalUri,
      title: '网盘课程',
      durationMs: 0,
      lastUpdated: 1,
      sourceRef: MediaSourceRef(
        value: reference.logicalUri,
        kind: MediaSourceKind.cloudDrive,
        cloudDrive: reference,
      ),
    );
    library.seedVideoForTesting(item);
    return (provider, item);
  }

  test(
    'catalog includes untouched audio/video, preserving adapters and aliases',
    () async {
      final first = episode(1, duration: 3723000);
      episode(2);
      episode(3, video: true);
      episode(4);
      store.setPresentation('episode-2', localTitle: '自定义单集名称');
      store.setPresentation('episode-4', hidden: true);
      final projection = await runtime.itemFor(first, persist: false);
      final existing = VideoItem.fromJson({
        ...projection.toJson(),
        'id': 'legacy-id',
      });
      existing.durationMs = 0;
      await library.upsertPodcastEpisode(existing, persist: false);
      final beforeWrites = writes;
      final tree = source.buildTree();
      expect(store.catalogQueries, 0);
      final channel = tree.roots.single;
      expect(channel.childrenLoaded, isFalse);
      await source.loadChildren(channel);
      expect(channel.children, hasLength(3));
      expect(
        channel.children.map((node) => node.videoId),
        contains('legacy-id'),
      );
      expect(channel.children.map((node) => node.name), contains('自定义单集名称'));
      expect(
        channel.children.map((node) => node.videoId),
        isNot(contains('episode-4')),
      );
      expect(
        channel.children.where(
          (node) => node.mediaItem?.type == MediaType.audio,
        ),
        hasLength(2),
      );
      expect(
        channel.children.where(
          (node) => node.mediaItem?.type == MediaType.video,
        ),
        hasLength(1),
      );
      expect(
        channel.children
            .singleWhere((node) => node.videoId == 'legacy-id')
            .videoDuration,
        '01:02:03',
      );
      expect(library.storageVideos, hasLength(1));
      expect(writes, beforeWrites);
      final selected = channel.children.singleWhere(
        (node) => node.videoId == 'episode-2',
      );
      await source.prepareSelection([selected]);
      expect(library.storageVideos, hasLength(2));
      expect(writes, beforeWrites + 1);
      await manager.startTranscription(
        selected.videoPath!,
        videoId: selected.videoId,
        videoTitle: selected.name,
        libraryService: library,
      );
      expect(manager.getQueueSnapshot().single.videoPath, 'podcast:episode-2');
      expect(manager.getQueueSnapshot().single.videoName, '自定义单集名称');
    },
  );

  test(
    'older pages retain selection and newly discovered episodes stay unselected',
    () async {
      episode(2);
      final value = store.channel('channel')!
        ..nextPage = 'https://example.invalid/page2';
      store.write('channel', value.id, value.toJson());
      final tree = source.buildTree();
      final channel = tree.roots.single;
      await source.loadChildren(channel);
      tree.updateSelection(channel, true);
      expect(source.hasEarlierEpisodes(channel), isTrue);
      controller.history = () async {
        episode(1);
        value.nextPage = null;
        store.write('channel', value.id, value.toJson());
      };
      await source.loadEarlierEpisodes(channel);
      tree.recalculateCounts();
      expect(channel.children, hasLength(2));
      expect(tree.selectedCount, 1);
      expect(channel.isIndeterminate, isTrue);
      expect(tree.getSelectedLeaves().single.videoId, 'episode-2');
      expect(source.hasEarlierEpisodes(channel), isFalse);
      expect(library.storageVideos, isEmpty);
    },
  );

  test('failed historical page does not clear the current selection', () async {
    episode(1);
    final value = store.channel('channel')!
      ..nextPage = 'https://example.invalid/page2';
    store.write('channel', value.id, value.toJson());
    final tree = source.buildTree();
    final channel = tree.roots.single;
    await source.loadChildren(channel);
    tree.updateSelection(channel, true);
    await expectLater(source.loadEarlierEpisodes(channel), throwsStateError);
    expect(tree.getSelectedLeaves(), hasLength(1));
    expect(source.hasEarlierEpisodes(channel), isTrue);
  });

  test(
    'cloud duration uses metadata only and updates an already queued task',
    () async {
      final (provider, item) = await cloudMedia();
      final node = source.nodeFor(item);
      await manager.startTranscription(
        item.path,
        videoId: item.id,
        libraryService: library,
      );
      expect(manager.getQueueSnapshot().single.videoDuration, isEmpty);
      expect(await source.refreshDuration(node), isTrue);
      expect(node.videoDuration, '01:30');
      expect(item.durationMs, 90000);
      expect(manager.getQueueSnapshot().single.videoDuration, '01:30');
      expect(provider.calls, 1);
      expect(await source.refreshDuration(node), isTrue);
      expect(provider.calls, 1);
    },
  );

  test(
    'missing cloud duration remains selectable and an explicit retry refetches',
    () async {
      final (provider, item) = await cloudMedia();
      provider.durationMs = null;
      final node = source.nodeFor(item);
      expect(await source.refreshDuration(node), isFalse);
      final tree = VideoPickerTree(roots: [node]);
      tree.updateSelection(node, true);
      expect(tree.getSelectedLeaves(), [node]);
      await manager.startTranscription(
        item.path,
        videoId: item.id,
        libraryService: library,
      );
      expect(manager.getQueueSnapshot(), hasLength(1));
      provider.durationMs = 90000;
      expect(await source.refreshDuration(node, force: true), isTrue);
      expect(provider.calls, 2);
      expect(item.durationMs, 90000);
    },
  );

  test('late cloud metadata cannot update a different file revision', () async {
    final (provider, item) = await cloudMedia();
    provider.gate = Completer<void>();
    final pending = source.refreshDuration(source.nodeFor(item));
    await Future<void>.delayed(Duration.zero);
    item.sourceRef = MediaSourceRef(
      value: item.path,
      kind: MediaSourceKind.cloudDrive,
      cloudDrive: const CloudDriveSourceRef(
        providerId: 'baidu',
        remoteAccountId: '42',
        driveId: '0',
        fileId: '9',
        revision: 'r2',
      ),
    );
    provider.gate!.complete();
    expect(await pending, isFalse);
    expect(item.durationMs, 0);
  });

  testWidgets(
    'select all loads collapsed catalogs beyond the viewport without persisting',
    (tester) async {
      for (var i = 0; i < 305; i++) {
        episode(i);
      }
      await manager.startTranscription(
        'podcast:episode-2',
        videoId: 'episode-2',
      );
      await openPicker(tester);
      expect(store.catalogQueries, 0);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('确认 (304)'), findsOneWidget);
      expect(library.storageVideos, isEmpty);
      expect(store.catalogQueries, 1);
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(find.text('确认 (0)'), findsOneWidget);
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isFalse,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(library.storageVideos, isEmpty);
    },
  );

  testWidgets(
    'failed catalog load is retryable and cannot select a partial folder',
    (tester) async {
      store.remove('channel', 'channel');
      await openPicker(tester);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('确认 (0)'), findsOneWidget);
      expect(find.text('文件夹未能读取完整，请重试后选择'), findsOneWidget);
      store.write(
        'channel',
        'channel',
        PodcastChannel(
          id: 'channel',
          feedUrl: 'https://example.invalid/feed',
          title: '频道',
        ).toJson(),
      );
      episode(1);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('确认 (1)'), findsOneWidget);
    },
  );

  test(
    'direct channel imports share picker titles, durations and deduplication',
    () async {
      episode(1, duration: 62000);
      episode(2, video: true);
      store.setPresentation('episode-1', localTitle: '本地别名');
      final resolver = TranscriptionMediaResolver(
        library: library,
        manager: manager,
      );
      await resolver.resolve(
        TranscriptionMediaSelection(
          libraryIds: [folder.id],
          podcastChannelIds: ['channel'],
          podcastEpisodeIds: ['episode-1'],
        ),
      );
      expect(resolver.failures, isEmpty);
      expect(resolver.nodes, hasLength(2));
      final audio = resolver.nodes.singleWhere((n) => n.videoId == 'episode-1');
      expect(audio.name, '本地别名');
      expect(audio.videoDuration, '01:02');
      expect(resolver.nodes.map((n) => n.mediaItem!.type).toSet(), {
        MediaType.audio,
        MediaType.video,
      });
      expect(library.storageVideos, isEmpty);
      expect(manager.getQueueSnapshot(), isEmpty);
    },
  );

  for (final entry in [
    'selection',
    'folder-menu',
    'media-menu',
    'episode-menu',
  ]) {
    testWidgets(
      '$entry opens queue and imports the selected media exactly once',
      (tester) async {
        final first = episode(1, duration: 62000);
        episode(2, video: true);
        if (entry == 'media-menu') {
          await tester.runAsync(() async {
            await library.upsertPodcastEpisode(
              await runtime.itemFor(first, persist: false),
            );
          });
        }
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: library),
              ChangeNotifierProvider.value(value: manager),
              ChangeNotifierProvider.value(value: settings),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: entry == 'episode-menu'
                    ? PodcastEpisodeTile(episode: first)
                    : Center(
                        child: MediaLibraryActivityMenuButton(
                          targetId: entry == 'media-menu'
                              ? 'episode-1'
                              : folder.id,
                          isCollection: entry != 'media-menu',
                        ),
                      ),
                bottomNavigationBar: entry == 'selection'
                    ? MediaLibrarySelectionBottomBar.folders(
                        queueSelectedIds: [folder.id],
                        onMoveToRecycleBin: () {},
                        onExportFluentPack: () {},
                      )
                    : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (entry == 'selection') {
          await tester.tap(find.byKey(const ValueKey('selection-transcribe')));
        } else {
          await tester.tap(
            entry == 'episode-menu'
                ? find.byTooltip('节目操作')
                : find.byKey(const ValueKey('media-library-activity-menu')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('批量字幕转录'));
        }
        await tester.runAsync(() async {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(BatchSubtitleScreen), findsOneWidget);
        expect(find.text('语音转录队列'), findsWidgets);
        final count = entry == 'selection' || entry == 'folder-menu' ? 2 : 1;
        expect(manager.getQueueSnapshot(), hasLength(count));
        expect(manager.isQueueRunning, isFalse);
        expect(
          manager.getQueueSnapshot().every((task) => !task.isStarted),
          isTrue,
        );
        await tester.pump();
        expect(manager.getQueueSnapshot(), hasLength(count));
        expect(
          manager
              .getQueueSnapshot()
              .singleWhere((t) => t.videoId == 'episode-1')
              .videoDuration,
          '01:02',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'the batch screen registers only confirmed podcasts before queueing',
    (tester) async {
      episode(1, duration: 62000);
      episode(2, video: true);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: manager),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            home: BatchSubtitleScreen(collectionId: folder.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择内部媒体').first);
      await tester.pumpAndSettle();
      expect(find.text('播客音频 · 01:02'), findsOneWidget);
      expect(find.text('播客视频 · 时长待获取'), findsOneWidget);
      await tester.tap(find.text('第 1 集'));
      await tester.pumpAndSettle();
      expect(library.storageVideos, isEmpty);
      // Library persistence shares a serial queue with setup outside the fake
      // widget clock. Confirm in that real async zone as well.
      await tester.runAsync(() async {
        await tester.tap(find.text('确认 (1)'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(library.storageVideos.map((item) => item.id), ['episode-1']);
      final task = manager.getQueueSnapshot().single;
      expect(task.videoId, 'episode-1');
      expect(task.videoPath, 'podcast:episode-1');
      expect(task.videoDuration, '01:02');
      expect(task.videoName, '第 1 集');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final (size, scale) in [
    (const Size(320, 640), 1.0),
    (const Size(390, 844), 1.0),
    (const Size(568, 320), 1.0),
    (const Size(1280, 800), 1.0),
    (const Size(320, 568), 1.6),
  ]) {
    testWidgets(
      'media dialog supports $size text $scale with unknown durations',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        episode(1);
        episode(2, video: true, duration: 3723000);
        store.setPresentation(
          'episode-2',
          localTitle: '第 2 集 · 一段较长的媒体标题，检查手机上的阅读空间',
        );
        final channel = store.channel('channel')!
          ..nextPage = 'https://example.invalid/older';
        store.write('channel', channel.id, channel.toJson());
        final (provider, cloud) = await cloudMedia();
        provider.durationMs = null;
        cloud.parentId = folder.id;
        folder.childrenIds.add(cloud.id);
        await openPicker(tester, scale: scale);
        await tester.tap(find.text('播客频道'));
        await tester.pumpAndSettle();
        if (find.text('第 1 集').hitTestable().evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.text('第 1 集'),
            70,
            scrollable: find.descendant(
              of: find.byType(InternalVideoPickerDialog),
              matching: find.byType(Scrollable),
            ),
          );
          await tester.pumpAndSettle();
        }
        expect(find.text('播客音频 · 时长待获取'), findsOneWidget);
        await tester.tap(find.text('第 1 集'));
        await tester.pumpAndSettle();
        expect(find.text('确认 (1)'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (preview) {
          await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey('internal-media-preview')),
                )
                .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final output = File(
              '.artifacts/internal-media-picker/dialog-${size.width.toInt()}-text-$scale.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
  }
}
