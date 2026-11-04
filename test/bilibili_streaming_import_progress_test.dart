import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

const _bvid = 'BV1xx411c7mD';
const _coverUrl = 'https://i0.hdslb.com/bfs/archive/cover.jpg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPathProvider;
  late LibraryService library;
  late _ControlledApi api;
  late BilibiliDownloadService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    root = await Directory.systemTemp.createTemp('bilibili_fast_card_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    api = _ControlledApi();
    service = BilibiliDownloadService(apiService: api);
    library.attachBilibiliStreamingService(service.streamingService);
  });

  tearDown(() async {
    api.releaseAll();
    await service.waitForPendingStreamCardData();
    await service.shutdown();
    library.attachBilibiliStreamingService(null);
    library.resetLibraryForTesting();
    PathProviderPlatform.instance = originalPathProvider;
    SettingsService().resetForTest();
    if (await root.exists()) await root.delete(recursive: true);
  });

  for (final clipboard in [false, true]) {
    test('${clipboard ? 'clipboard' : 'parse page'} saves a playable card '
        'while every optional network request is blocked', () async {
      final task = _streamingTask();
      final episode = task.videos.single.episodes.single;
      final stages = <String>[];
      service.addListener(() {
        final status = episode.downloadSpeed;
        if (status != null && !stages.contains(status)) stages.add(status);
      });
      if (!clipboard) service.tasks.add(task);
      final timer = Stopwatch()..start();
      final count =
          await (clipboard
                  ? service.importParsedStreamingTaskToLibrary(library, task)
                  : service.importStreamingToLibrary(library, episode: episode))
              .timeout(const Duration(seconds: 2));
      timer.stop();

      expect(count, 1);
      expect(api.metadataReady.isCompleted, isFalse);
      expect(api.filesReady.isCompleted, isFalse);
      expect(api.danmakuReady.isCompleted, isFalse);
      expect(api.shotsReady.isCompleted, isFalse);
      final card = library.bilibiliStreamItems.single;
      expect(card.path, 'bilibili://stream/$_bvid?cid=101');
      expect(card.title, 'Video');
      expect(card.durationMs, 60000);
      expect(card.sourceRef?.cid, 101);
      expect(card.bilibiliPendingCardData, isNotNull);
      expect(card.hasProbedChapters, isFalse);
      expect(episode.importedVideoIds, [card.id]);
      expect(episode.status, DownloadStatus.completed);
      expect(episode.isExported, isTrue);
      expect(service.isStreamingImporting(episode), isFalse);
      expect(stages, containsAllInOrder(['正在写入媒体库...', '已添加在线卡片']));
      expect(library.isImporting.value, isFalse);
      expect(library.importProgress.value, 0);
      expect(library.importStatus.value, isEmpty);
      expect(service.tasks, [task]);
      final saved = await File(
        p.join(root.path, 'library.json'),
      ).readAsString();
      expect(saved, contains(card.id));
      expect(saved, contains('bilibiliPendingCardData'));
      // No external response is needed to complete the import. The generous
      // wall-clock budget only catches stalls in the remaining local work.
      expect(timer.elapsed, lessThan(const Duration(seconds: 2)));

      // A cover can appear while metadata is still stalled. Playback joining
      // the same pending card shares its metadata request with the import.
      final coverArrived = Completer<void>();
      void onCover() {
        if (card.thumbnailPath != null && !coverArrived.isCompleted) {
          coverArrived.complete();
        }
      }

      library.addListener(onCover);
      addTearDown(() => library.removeListener(onCover));
      api.filesReady.complete();
      await coverArrived.future.timeout(const Duration(seconds: 2));
      expect(api.metadataReady.isCompleted, isFalse);
      final joined = service.completeWatchPart(library, card.id);

      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(await joined, isTrue);
      expect(card.bilibiliPendingCardData, isNull);
      expect(card.hasProbedChapters, isTrue);
      expect(card.chapters.single.title, 'Chapter');
      expect(await File(card.thumbnailPath!).exists(), isTrue);
      expect(await File(card.subtitlePath!).exists(), isTrue);
      expect(await File(card.danmakuPath!).exists(), isTrue);
      expect(card.additionalSubtitles, hasLength(2));
      expect(card.managedSubtitleAssets, hasLength(2));
      expect(card.bilibiliVideoShot?.hasLocalSprites, isTrue);
      expect(api.metadataRequests, 1);
      expect(api.shotRequests, 1);
      expect(api.playUrlRequests, 0);
      expect(library.bilibiliStreamItems.single, same(card));
    });
  }

  test('online cleanup waits for durable publication and retry reuses its reserved card', () async {
    service.autoDeleteOnlineTaskAfterImport = true;
    final task = _streamingTask();
    final episode = task.videos.single.episodes.single;
    library.saveRetryDelaysForTesting = [];
    library.writeLibrarySnapshotOverrideForTesting = () async {
      throw const FileSystemException('disk unavailable');
    };
    expect(await service.importParsedStreamingTaskToLibrary(library, task), 0);
    final reservedId = episode.importContext!.mediaId;
    expect(service.tasks, [task]);
    expect(episode.isExported, isFalse);
    expect(episode.importState, BilibiliImportState.failed);
    library.writeLibrarySnapshotOverrideForTesting = null;
    expect(await service.importStreamingToLibrary(library, episode: episode), 1);
    expect(episode.latestImportedVideoId, reservedId);
    expect(library.bilibiliStreamItems, hasLength(1));
    expect(service.tasks, isEmpty);
    expect(service.autoDeleteTaskAfterImport, isFalse);
  });

  test('folder covers arrive while earlier card metadata is blocked', () async {
    await service.importParsedStreamingTaskToLibrary(library, _streamingTask());
    await api.requestStarted.future;
    await service.importParsedStreamingTaskToLibrary(
      library,
      _streamingTask(parts: 3),
    );
    final folder = library.collections.single;
    final coverReady = Completer<void>();
    void onCover() {
      if (folder.thumbnailPath != null && !coverReady.isCompleted) {
        coverReady.complete();
      }
    }

    library.addListener(onCover);
    addTearDown(() => library.removeListener(onCover));
    api.filesReady.complete();
    onCover();
    await coverReady.future.timeout(const Duration(seconds: 2));
    expect(api.metadataReady.isCompleted, isFalse);
    expect(await File(folder.thumbnailPath!).length(), greaterThan(0));
    final folderId = folder.id;
    final coverPath = folder.thumbnailPath;
    api.releaseAll();
    await service.waitForPendingStreamCardData();
    library.resetLibraryForTesting();
    await library.init();
    expect(library.getCollection(folderId)?.thumbnailPath, coverPath);
  });

  test(
    'missing folder covers survive task deletion and retry after restart',
    () async {
      api.images.emptyResponse = true;
      service.autoDeleteOnlineTaskAfterImport = true;
      await service.importParsedStreamingTaskToLibrary(
        library,
        _streamingTask(parts: 3, collection: true),
      );
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(service.tasks, isEmpty);
      final folders = library.storageCollections;
      expect(folders, hasLength(2));
      expect(folders.every((folder) => folder.thumbnailPath == null), isTrue);
      expect(
        folders.every((folder) => folder.bilibiliPendingCoverUrl != null),
        isTrue,
      );
      // A previous interrupted write must not count as a cached cover.
      final emptyCover = File(
        p.join(root.path, 'thumbnails', 'collection_${folders.first.id}.jpg'),
      );
      await emptyCover.writeAsBytes([]);
      await service.shutdown();
      library.resetLibraryForTesting();
      await library.init();
      expect(
        library.storageCollections.every(
          (folder) => folder.bilibiliPendingCoverUrl != null,
        ),
        isTrue,
      );
      api = _ControlledApi()..releaseAll();
      service = BilibiliDownloadService(apiService: api);
      library.attachBilibiliStreamingService(service.streamingService);
      service.resumePendingStreamCardData(library);
      await service.waitForPendingStreamCardData();
      for (final folder in library.storageCollections) {
        expect(folder.bilibiliPendingCoverUrl, isNull);
        expect(await File(folder.thumbnailPath!).length(), greaterThan(0));
      }
      expect(
        api.images.urls,
        contains('https://i0.hdslb.com/bfs/archive/collection.jpg'),
      );
      expect(api.images.urls, contains(_coverUrl));
    },
  );

  test(
    'a late folder cover preserves a custom cover selected during download',
    () async {
      await service.importParsedStreamingTaskToLibrary(
        library,
        _streamingTask(parts: 3),
      );
      await api.images.started.future;
      final folder = library.collections.single;
      final custom = File(p.join(root.path, 'custom.png'));
      await custom.writeAsBytes([1, 2, 3]);
      await library.updateCollectionThumbnail(folder.id, custom.path);
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(folder.thumbnailPath, custom.path);
      expect(folder.bilibiliPendingCoverUrl, isNull);
      expect(await custom.readAsBytes(), [1, 2, 3]);
      expect(
        await File(
          p.join(root.path, 'thumbnails', 'collection_${folder.id}.jpg'),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'clearing a folder cover during its download keeps it cleared',
    () async {
      await service.importParsedStreamingTaskToLibrary(
        library,
        _streamingTask(parts: 3),
      );
      await api.images.started.future;
      final folder = library.collections.single;
      await library.updateCollectionThumbnail(folder.id, null);
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(folder.thumbnailPath, isNull);
      expect(folder.bilibiliPendingCoverUrl, isNull);
      expect(
        await File(
          p.join(root.path, 'thumbnails', 'collection_${folder.id}.jpg'),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'a late metadata failure keeps the saved card and can be retried',
    () async {
      api.metadataError = StateError('metadata unavailable');
      expect(
        await service.importParsedStreamingTaskToLibrary(
          library,
          _streamingTask(),
        ),
        1,
      );
      final card = library.bilibiliStreamItems.single;
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(card.bilibiliPendingCardData, isNotNull);
      expect(
        service.tasks.single.videos.single.episodes.single.status,
        DownloadStatus.completed,
      );

      api.metadataError = null;
      service.resumePendingStreamCardData(library);
      await service.waitForPendingStreamCardData();
      expect(card.bilibiliPendingCardData, isNull);
      expect(api.metadataRequests, 2);
      expect(library.bilibiliStreamItems, [card]);
    },
  );

  test(
    'pending data survives restart and task auto-deletion, including subtitle preference',
    () async {
      service
        ..autoDeleteOnlineTaskAfterImport = true
        ..preferredSubtitleLang = 'en';
      api.metadataError = StateError('interrupted');
      expect(
        await service.importParsedStreamingTaskToLibrary(
          library,
          _streamingTask(),
        ),
        1,
      );
      final id = library.bilibiliStreamItems.single.id;
      expect(service.tasks, isEmpty);
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      await service.shutdown();
      library.resetLibraryForTesting();
      await library.init();
      final restored = library.getVideo(id)!;
      expect(restored.bilibiliPendingCardData?.subtitleLanguage, 'en');

      api = _ControlledApi()..releaseAll();
      service = BilibiliDownloadService(apiService: api)
        ..preferredSubtitleLang = 'none';
      library.attachBilibiliStreamingService(service.streamingService);
      expect(await service.completeWatchPart(library, id), isTrue);
      await service.waitForPendingStreamCardData();
      expect(restored.bilibiliPendingCardData, isNull);
      expect(restored.subtitlePath, restored.additionalSubtitles!['English']);
      expect(restored.chapters.single.title, 'Chapter');
      expect(library.bilibiliStreamItems, [restored]);
    },
  );

  test(
    'partial failures retry missing files without duplicating saved subtitles',
    () async {
      api
        ..failedSubtitleLanguage = 'en'
        ..danmakuError = StateError('danmaku unavailable');
      expect(
        await service.importParsedStreamingTaskToLibrary(
          library,
          _streamingTask(),
        ),
        1,
      );
      final card = library.bilibiliStreamItems.single;
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(card.bilibiliPendingCardData, isNotNull);
      expect(card.managedSubtitleAssets, hasLength(1));
      final savedSubtitle = card.subtitlePath;
      expect(await File(savedSubtitle!).exists(), isTrue);
      expect(card.danmakuPath, isNull);

      api
        ..failedSubtitleLanguage = null
        ..danmakuError = null;
      service.resumePendingStreamCardData(library);
      await service.waitForPendingStreamCardData();
      expect(card.bilibiliPendingCardData, isNull);
      expect(card.subtitlePath, savedSubtitle);
      expect(card.additionalSubtitles, hasLength(2));
      expect(card.managedSubtitleAssets, hasLength(2));
      expect(api.subtitleRequests['zh'], 1);
      expect(api.subtitleRequests['en'], 2);
      expect(await File(card.danmakuPath!).exists(), isTrue);
    },
  );

  test(
    'empty metadata is marked successful only after a valid player response',
    () async {
      final adapter = _PlayerAdapter();
      final realApi = BilibiliApiService(httpClientAdapter: adapter);
      addTearDown(() => realApi.dio.close(force: true));
      adapter.playerAnswer = {'code': -403, 'message': 'request rejected'};
      expect(
        (await realApi.fetchPlayerMetadata(_bvid, 101)).requestSucceeded,
        isFalse,
      );
      adapter.playerAnswer = {'code': 0, 'data': <String, Object?>{}};
      final empty = await realApi.fetchPlayerMetadata(_bvid, 101);
      expect(empty.requestSucceeded, isTrue);
      expect(empty.subtitles, isEmpty);
      adapter.failNetwork = true;
      expect(
        (await realApi.fetchPlayerMetadata(_bvid, 101)).requestSucceeded,
        isFalse,
      );
    },
  );

  test(
    'retry retains distinct subtitles that share the same display name',
    () async {
      api
        ..sameSubtitleLabels = true
        ..failedSubtitleLanguage = 'zh';
      expect(
        await service.importParsedStreamingTaskToLibrary(
          library,
          _streamingTask(),
        ),
        1,
      );
      final card = library.bilibiliStreamItems.single;
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      final firstPath = card.additionalSubtitles!.values.single;
      api.failedSubtitleLanguage = null;
      service.resumePendingStreamCardData(library);
      await service.waitForPendingStreamCardData();
      expect(card.bilibiliPendingCardData, isNull);
      expect(card.additionalSubtitles, hasLength(2));
      expect(card.additionalSubtitles!.values.toSet(), hasLength(2));
      expect(card.additionalSubtitles!.values, contains(firstPath));
      expect(card.managedSubtitleAssets, hasLength(2));
      expect(api.subtitleRequests['en'], 1);
      expect(api.subtitleRequests['zh'], 2);
    },
  );

  test('an unavailable metadata response keeps its retry marker', () async {
    api.metadataRequestSucceeded = false;
    expect(
      await service.importParsedStreamingTaskToLibrary(
        library,
        _streamingTask(),
      ),
      1,
    );
    final card = library.bilibiliStreamItems.single;
    api.releaseAll();
    await service.waitForPendingStreamCardData();
    expect(card.bilibiliPendingCardData, isNotNull);
    expect(card.hasProbedChapters, isFalse);
    api.metadataRequestSucceeded = true;
    service.resumePendingStreamCardData(library);
    await service.waitForPendingStreamCardData();
    expect(card.bilibiliPendingCardData, isNull);
    expect(card.hasProbedChapters, isTrue);
  });

  test(
    'simultaneous clipboard clicks share the same task, new tasks still create independent cards',
    () async {
      final task = _streamingTask();
      final counts = await Future.wait([
        service.importParsedStreamingTaskToLibrary(library, task),
        service.importParsedStreamingTaskToLibrary(library, task),
      ]);
      expect(counts, [1, 0]);
      expect(service.tasks, [task]);
      expect(
        await service.importParsedStreamingTaskToLibrary(
          library,
          _streamingTask(),
        ),
        1,
      );
      expect(library.bilibiliStreamItems, hasLength(2));
      expect(
        library.bilibiliStreamItems.map((item) => item.id).toSet(),
        hasLength(2),
      );
    },
  );

  test(
    'multi-part cards are all saved before metadata, with bounded background requests',
    () async {
      final task = _streamingTask(parts: 5);
      expect(
        await service
            .importParsedStreamingTaskToLibrary(library, task)
            .timeout(const Duration(seconds: 2)),
        5,
      );
      final cards = library.bilibiliStreamItems.toList();
      expect(cards.map((item) => item.sourceRef?.page).toSet(), {
        1,
        2,
        3,
        4,
        5,
      });
      expect(cards.map((item) => item.parentId).toSet(), hasLength(1));
      final folder = library.getCollection(cards.first.parentId!)!;
      expect(folder.name, 'Video');
      expect(
        library
            .getContents(folder.id)
            .cast<VideoItem>()
            .map((item) => item.title),
        [
          'Video · P1 Part 1',
          'Video · P2 Part 2',
          'Video · P3 Part 3',
          'Video · P4 Part 4',
          'Video · P5 Part 5',
        ],
      );
      await api.requestStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(api.metadataRequests, inInclusiveRange(1, 2));
      expect(api.playUrlRequests, 0);
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(
        cards.every((item) => item.bilibiliPendingCardData == null),
        isTrue,
      );
      expect(folder.thumbnailPath, isNotNull);
    },
  );

  test(
    'shutdown waits for active writers and leaves queued cards recoverable',
    () async {
      expect(
        await service.importParsedStreamingTaskToLibrary(
          library,
          _streamingTask(parts: 5),
        ),
        5,
      );
      await api.requestStarted.future;
      final shutdown = service.shutdown();
      api.releaseAll();
      await shutdown;
      expect(api.metadataRequests, inInclusiveRange(1, 2));
      final pending = library.bilibiliStreamItems.where(
        (item) => item.bilibiliPendingCardData != null,
      );
      expect(pending.length, greaterThanOrEqualTo(3));
      final persisted = jsonDecode(
        await File(p.join(root.path, 'library.json')).readAsString(),
      );
      expect(jsonEncode(persisted), contains('bilibiliPendingCardData'));
    },
  );

  test(
    'deleting a card while extras load never recreates it or leaves card files',
    () async {
      expect(
        await service.importParsedStreamingTaskToLibrary(
          library,
          _streamingTask(),
        ),
        1,
      );
      final card = library.bilibiliStreamItems.single;
      await api.requestStarted.future;
      await library.moveToRecycleBin([card.id]);
      await library.deleteFromRecycleBin([card.id]);
      expect(library.getVideo(card.id), isNull);
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(library.getVideo(card.id), isNull);
      expect(service.isPendingWatchPart(card.id), isFalse);
      final files = await root
          .list(recursive: true)
          .where((entry) => entry is File)
          .toList();
      expect(files.where((file) => file.path.contains(card.id)), isEmpty);
    },
  );

  test(
    'late data preserves user subtitle choices, custom tracks and playback position',
    () async {
      expect(
        await service.importParsedStreamingTaskToLibrary(
          library,
          _streamingTask(),
        ),
        1,
      );
      final card = library.bilibiliStreamItems.single;
      await api.requestStarted.future;
      card
        ..subtitlePath = 'user-selected.srt'
        ..additionalSubtitles = {'Custom': 'custom.srt'}
        ..lastPositionMs = 27000
        ..title = 'Renamed';
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(card.subtitlePath, 'user-selected.srt');
      expect(card.additionalSubtitles!['Custom'], 'custom.srt');
      expect(card.additionalSubtitles, hasLength(3));
      expect(card.lastPositionMs, 27000);
      expect(card.title, 'Renamed');

      await service.shutdown();
      api = _ControlledApi();
      service = BilibiliDownloadService(apiService: api);
      library.attachBilibiliStreamingService(service.streamingService);
      expect(
        await service.importParsedStreamingTaskToLibrary(
          library,
          _streamingTask(),
        ),
        1,
      );
      final next = library.bilibiliStreamItems.firstWhere(
        (item) => item.id != card.id,
      );
      next.blockAutoAssociatedSubtitleSelection = true;
      api.releaseAll();
      await service.waitForPendingStreamCardData();
      expect(next.subtitlePath, isNull);
      expect(next.additionalSubtitles, hasLength(2));
    },
  );

  test('download info prefetch skips every online parse task', () async {
    service.tasks.add(_streamingTask());
    await service.fetchAllInfos();
    expect(api.playUrlRequests, 0);
    expect(api.metadataRequests, 0);
    expect(
      service.tasks.single.videos.single.episodes.single.status,
      DownloadStatus.pending,
    );
  });
}

BilibiliDownloadTask _streamingTask({int parts = 1, bool collection = false}) {
  final pages = <BilibiliPage>[
    for (var i = 1; i <= parts; i++)
      BilibiliPage(
        cid: 100 + i,
        page: i,
        part: 'Part $i',
        duration: 60,
        bvid: _bvid,
        aid: '123',
      ),
  ];
  final info = BilibiliVideoInfo(
    title: 'Video',
    desc: '',
    pic: _coverUrl,
    bvid: _bvid,
    aid: '123',
    ownerName: '',
    ownerMid: '',
    pubDate: 0,
    pages: pages,
  );
  return BilibiliDownloadTask(
    singleVideoInfo: collection ? null : info,
    collectionInfo: collection
        ? BilibiliCollectionInfo(
            title: 'Collection',
            cover: 'https://i0.hdslb.com/bfs/archive/collection.jpg',
            videos: [info],
          )
        : null,
    isStreamingImport: true,
    videos: [
      BilibiliVideoItem(
        videoInfo: info,
        episodes: [
          for (final page in pages)
            BilibiliDownloadEpisode(page: page, bvid: _bvid, isSelected: true),
        ],
      ),
    ],
  );
}

class _ControlledApi extends BilibiliApiService {
  _ControlledApi() {
    images = _ImageAdapter(filesReady.future);
    dio.httpClientAdapter = images;
  }

  late final _ImageAdapter images;

  final requestStarted = Completer<void>();
  final metadataReady = Completer<void>();
  final filesReady = Completer<void>();
  final danmakuReady = Completer<void>();
  final shotsReady = Completer<void>();
  Object? metadataError;
  bool metadataRequestSucceeded = true;
  bool sameSubtitleLabels = false;
  String? failedSubtitleLanguage;
  Object? danmakuError;
  final subtitleRequests = <String, int>{};
  int metadataRequests = 0;
  int shotRequests = 0;
  int playUrlRequests = 0;

  void releaseAll() {
    for (final gate in [metadataReady, filesReady, danmakuReady, shotsReady]) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async {
    metadataRequests++;
    if (!requestStarted.isCompleted) requestStarted.complete();
    await metadataReady.future;
    if (metadataError != null) throw metadataError!;
    return BilibiliPlayerMetadata(
      requestSucceeded: metadataRequestSucceeded,
      subtitles: [
        BilibiliSubtitle(
          id: 'zh',
          lan: 'zh-CN',
          lanDoc: sameSubtitleLabels ? '字幕' : '中文',
          url: 'https://example.invalid/zh',
          isAi: false,
        ),
        BilibiliSubtitle(
          id: 'en',
          lan: 'en',
          lanDoc: sameSubtitleLabels ? '字幕' : 'English',
          url: 'https://example.invalid/en',
          isAi: false,
        ),
      ],
      chapters: const [
        MediaChapter(title: 'Chapter', startMs: 0, endMs: 60000),
      ],
    );
  }

  @override
  Future<dynamic> fetchSubtitleContent(String url) async {
    final language = Uri.parse(url).pathSegments.last;
    subtitleRequests.update(language, (count) => count + 1, ifAbsent: () => 1);
    await filesReady.future;
    if (failedSubtitleLanguage == language) return null;
    return {
      'body': [
        {'from': 0, 'to': 1, 'content': url.endsWith('en') ? 'Hello' : '你好'},
      ],
    };
  }

  @override
  Future<String> fetchDanmakuXml(int cid) async {
    await danmakuReady.future;
    if (danmakuError != null) throw danmakuError!;
    return '<i></i>';
  }

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async {
    shotRequests++;
    await shotsReady.future;
    return {
      'img_x_len': 1,
      'img_y_len': 1,
      'img_x_size': 1,
      'img_y_size': 1,
      'image': ['https://i0.hdslb.com/bfs/videoshot/sprite.jpg'],
      'index': [0, 0],
    };
  }

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    playUrlRequests++;
    throw StateError('Online import must not request download URLs');
  }
}

class _ImageAdapter implements HttpClientAdapter {
  _ImageAdapter(this.ready);
  final Future<void> ready;
  final started = Completer<void>();
  final urls = <String>[];
  bool emptyResponse = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri.toString());
    if (!started.isCompleted) started.complete();
    await ready;
    return ResponseBody.fromBytes(
      emptyResponse
          ? []
          : base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=',
            ),
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _PlayerAdapter implements HttpClientAdapter {
  Map<String, Object?> playerAnswer = {};
  bool failNetwork = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (failNetwork) throw const SocketException('offline');
    final answer = options.uri.path.endsWith('/nav')
        ? {
            'code': 0,
            'data': {
              'wbi_img': {
                'img_url':
                    'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                'sub_url':
                    'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
              },
            },
          }
        : playerAnswer;
    return ResponseBody.fromString(
      jsonEncode(answer),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootPath);
  final String rootPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
