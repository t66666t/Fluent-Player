import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_stream_card.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

const String _bvid = 'BV1xx411c7mD';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryService library;
  late _FakeApi api;
  late BilibiliDownloadService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    final root = await Directory.systemTemp.createTemp('bilibili_stream_card_');
    final originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    api = _FakeApi();
    service = BilibiliDownloadService(apiService: api);
    addTearDown(() async {
      await service.shutdown();
      library.resetLibraryForTesting();
      PathProviderPlatform.instance = originalPathProvider;
      SettingsService().resetForTest();
      if (await root.exists()) await root.delete(recursive: true);
    });
  });

  List<VideoItem> cardsOf(String bvid) => findBilibiliStreamCardsOfVideo(
    library.bilibiliStreamItems,
    bvid: bvid,
    collectionOf: library.getCollection,
  );

  test('playing the same BV + part again reuses its card', () async {
    api.videos[_bvid] = _videoInfo(_bvid, parts: 1);

    final first = await service.obtainStreamCardsForVideo(
      library,
      bvid: _bvid,
      pages: <int>[1],
    );
    final second = await service.obtainStreamCardsForVideo(
      library,
      bvid: _bvid,
      pages: <int>[1],
    );

    expect(first.createdCount, 1);
    expect(second.createdCount, 0);
    expect(second.reusedCount, 1);
    expect(second.cards.single.item.id, first.cards.single.item.id);
    expect(cardsOf(_bvid), hasLength(1));
    final card = first.cards.single.item;
    expect(card.sourceRef?.kind, MediaSourceKind.bilibiliStream);
    expect(card.sourceRef?.page, 1);
    expect(card.path, 'bilibili://stream/$_bvid?cid=1001');
    expect(card.parentId, isNull, reason: 'default location is the root');
    // The second call never fetched metadata again.
    expect(api.metadataRequests, 1);
  });

  test('concurrent requests for one part create a single card', () async {
    final info = _videoInfo(_bvid, parts: 1);
    final results = await Future.wait([
      for (var i = 0; i < 3; i++)
        service.obtainStreamCard(
          library,
          videoInfo: info,
          page: info.pages.single,
          reuseExisting: true,
        ),
    ]);

    expect(results.map((r) => r.item.id).toSet(), hasLength(1));
    expect(results.where((r) => r.created), hasLength(1));
    expect(cardsOf(_bvid), hasLength(1));
  });

  for (final deferred in [false, true]) {
    test(
      'one imported part retains its video title (deferred=$deferred)',
      () async {
        final info = _videoInfo(_bvid, parts: 3);
        final task = _streamingTask(info);
        for (final episode in task.videos.single.episodes) {
          episode.isSelected = episode.page.page == 1;
        }
        if (deferred) {
          expect(
            await service.importParsedStreamingTaskToLibrary(library, task),
            1,
          );
        } else {
          await service.obtainStreamCard(
            library,
            videoInfo: info,
            page: info.pages.first,
            reuseExisting: false,
          );
        }

        final card = cardsOf(_bvid).single;
        expect(card.title, 'Video $_bvid · P1 Part 1');
        expect(card.sourceRef?.page, 1);
        expect(card.sourceRef?.cid, 1001);
        expect(card.sourceRef?.bilibiliVideoTitle, info.title);
        expect(card.sourceRef?.bilibiliPartTitle, 'Part 1');
        expect(card.sourceRef?.bilibiliPartCount, 3);
        final restored = VideoItem.fromJson(card.toJson());
        expect(restored.sourceRef?.bilibiliVideoTitle, info.title);
        expect(restored.sourceRef?.bilibiliPartTitle, 'Part 1');
        expect(restored.sourceRef?.bilibiliPartCount, 3);
        await service.waitForPendingStreamCardData();
        expect(card.title, 'Video $_bvid · P1 Part 1');
        expect(cardsOf(_bvid), [card]);
      },
    );
  }

  test('lightweight playback parts retain their video title', () async {
    final info = _videoInfo(_bvid, parts: 3);
    final cards = await service.addWatchParts(
      library,
      videoInfo: info,
      pages: info.pages,
    );
    expect(cards.map((card) => card.title), [
      'Video $_bvid · P1 Part 1',
      'Video $_bvid · P2 Part 2',
      'Video $_bvid · P3 Part 3',
    ]);
    expect(cards.every((card) => card.isTransient), isTrue);
    expect(cardsOf(_bvid), isEmpty);
  });

  test(
    'every part of a multi-part video gets its own card, in one folder',
    () async {
      api.videos[_bvid] = _videoInfo(_bvid, parts: 3);

      final played = await service.obtainStreamCardsForVideo(
        library,
        bvid: _bvid,
        pages: <int>[2],
      );
      final all = await service.obtainStreamCardsForVideo(
        library,
        bvid: _bvid,
        pages: <int>[1, 2, 3],
      );

      expect(played.createdCount, 1);
      expect(all.createdCount, 2);
      expect(all.reusedCount, 1);
      final cards = cardsOf(_bvid);
      expect(cards, hasLength(3));
      expect(cards.map((c) => c.sourceRef?.page).toSet(), {1, 2, 3});
      expect(cards.map((c) => c.sourceRef?.cid).toSet(), {1001, 1002, 1003});
      final folderId = cards.first.parentId;
      expect(folderId, isNotNull);
      expect(cards.every((c) => c.parentId == folderId), isTrue);
      expect(library.getCollection(folderId!)?.name, 'Video $_bvid');
      final order = library
          .getContents(folderId)
          .cast<VideoItem>()
          .map((c) => c.sourceRef?.page)
          .toList();
      expect(order, <int?>[1, 2, 3]);

      final again = await service.obtainStreamCardsForVideo(
        library,
        bvid: _bvid,
        pages: <int>[1, 2, 3],
      );
      expect(again.createdCount, 0);
      expect(cardsOf(_bvid), hasLength(3));
      expect(
        library.getContents(null).whereType<VideoCollection>(),
        hasLength(1),
      );
    },
  );

  test('import goes to the chosen folder and is not duplicated', () async {
    api.videos[_bvid] = _videoInfo(_bvid, parts: 1);
    final folder = await library.createCollection('Target', null);
    final other = await library.createCollection('Other', null);

    final imported = await service.obtainStreamCardsForVideo(
      library,
      bvid: _bvid,
      pages: <int>[1],
      useDefaultLocation: false,
      targetFolderId: folder.id,
    );
    final again = await service.obtainStreamCardsForVideo(
      library,
      bvid: _bvid,
      pages: <int>[1],
      useDefaultLocation: false,
      targetFolderId: other.id,
    );

    expect(imported.cards.single.item.parentId, folder.id);
    expect(again.createdCount, 0);
    expect(again.cards.single.item.parentId, folder.id);
    expect(cardsOf(_bvid), hasLength(1));
  });

  test('a recycled card is not reused', () async {
    api.videos[_bvid] = _videoInfo(_bvid, parts: 1);
    final first = await service.obtainStreamCardsForVideo(
      library,
      bvid: _bvid,
      pages: <int>[1],
    );
    await library.moveToRecycleBin(<String>[first.cards.single.item.id]);

    final second = await service.obtainStreamCardsForVideo(
      library,
      bvid: _bvid,
      pages: <int>[1],
    );
    expect(second.createdCount, 1);
    expect(second.cards.single.item.id, isNot(first.cards.single.item.id));
  });

  test('finder matches older cards without a part number by cid', () {
    VideoItem card(String id, int cid, {int? page, int updated = 0}) =>
        VideoItem(
          id: id,
          path: 'bilibili://stream/$_bvid?cid=$cid',
          title: id,
          durationMs: 0,
          lastUpdated: updated,
          sourceRef: MediaSourceRef(
            value: _bvid,
            kind: MediaSourceKind.bilibiliStream,
            bvid: _bvid,
            cid: cid,
            page: page,
          ),
        );
    final items = <VideoItem>[
      card('legacy-p2', 2002),
      card('p1-old', 2001, page: 1, updated: 1),
      card('p1-new', 2001, page: 1, updated: 5),
    ];
    VideoCollection? noFolder(String _) => null;

    expect(
      findBilibiliStreamCard(
        items,
        bvid: _bvid,
        page: 2,
        cid: 2002,
        collectionOf: noFolder,
      )?.id,
      'legacy-p2',
    );
    expect(
      findBilibiliStreamCard(
        items,
        bvid: _bvid,
        page: 1,
        cid: 2001,
        collectionOf: noFolder,
      )?.id,
      'p1-new',
    );
    expect(
      findBilibiliStreamCard(
        items,
        bvid: 'BV1yy411c7mE',
        page: 1,
        collectionOf: noFolder,
      ),
      isNull,
    );
  });

  test('clipboard / parse-list export keeps creating its own card', () async {
    api.videos[_bvid] = _videoInfo(_bvid, parts: 1);
    final inApp = await service.obtainStreamCardsForVideo(
      library,
      bvid: _bvid,
      pages: <int>[1],
    );

    final exported = await service.importParsedStreamingTaskToLibrary(
      library,
      _streamingTask(_videoInfo(_bvid, parts: 1)),
    );
    final exportedAgain = await service.importParsedStreamingTaskToLibrary(
      library,
      _streamingTask(_videoInfo(_bvid, parts: 1)),
    );

    expect(exported, 1);
    expect(exportedAgain, 1);
    final cards = cardsOf(_bvid);
    expect(cards, hasLength(3));
    expect(cards.map((c) => c.id), contains(inApp.cards.single.item.id));
    expect(
      cards.every((c) => c.path == 'bilibili://stream/$_bvid?cid=1001'),
      isTrue,
    );
  });
}

BilibiliVideoInfo _videoInfo(String bvid, {required int parts}) {
  return BilibiliVideoInfo(
    title: 'Video $bvid',
    desc: '',
    pic: '',
    bvid: bvid,
    aid: '123',
    ownerName: 'owner',
    ownerMid: '1',
    pubDate: 0,
    pages: <BilibiliPage>[
      for (var i = 1; i <= parts; i++)
        BilibiliPage(
          cid: 1000 + i,
          page: i,
          part: 'Part $i',
          duration: 60,
          bvid: bvid,
          aid: '123',
        ),
    ],
  );
}

BilibiliDownloadTask _streamingTask(BilibiliVideoInfo info) {
  return BilibiliDownloadTask(
    singleVideoInfo: info,
    isStreamingImport: true,
    videos: <BilibiliVideoItem>[
      BilibiliVideoItem(
        videoInfo: info,
        episodes: <BilibiliDownloadEpisode>[
          for (final page in info.pages)
            BilibiliDownloadEpisode(
              page: page,
              bvid: info.bvid,
              isSelected: true,
            ),
        ],
      ),
    ],
  );
}

class _FakeApi extends BilibiliApiService {
  final Map<String, BilibiliVideoInfo> videos = <String, BilibiliVideoInfo>{};
  int metadataRequests = 0;

  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    final info = videos[bvid];
    if (info == null) throw StateError('unknown video $bvid');
    return info;
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
    return const BilibiliPlayerMetadata();
  }

  @override
  Future<String> fetchDanmakuXml(int cid) async => '<i></i>';

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
