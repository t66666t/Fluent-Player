import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_favorites_models.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_favorites_import.dart';
import 'package:video_player_app/services/bilibili/bilibili_favorites_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'support/bilibili_favorites_support.dart';
import 'test_dir_cleanup.dart';

const _second = 'BV1xx411c7mD';
const _third = 'BV1bb411c7mB';
const _folder = BilibiliFavoriteFolder(id: 41, title: '远端学习收藏', mediaCount: 4);

BilibiliFavoriteVideo _entry(
  int id,
  String bvid, {
  bool unavailable = false,
  int type = 2,
}) => BilibiliFavoriteVideo(
  id: id,
  type: type,
  bvid: bvid,
  title: '视频$id',
  unavailable: unavailable,
);

BilibiliVideoInfo _info(String bvid, {int parts = 1}) => BilibiliVideoInfo(
  title: bvid,
  desc: '',
  pic: '',
  bvid: bvid,
  aid: '1',
  ownerName: 'UP',
  ownerMid: '7',
  pubDate: 0,
  pages: [
    for (var n = 1; n <= parts; n++)
      BilibiliPage(cid: 100 + n, page: n, part: 'P$n', duration: 60),
  ],
);

class _Api extends BilibiliApiService {
  final infos = {
    favoriteTestBvid: _info(favoriteTestBvid, parts: 2),
    _second: _info(_second),
    _third: _info(_third),
  };
  final rejected = <String>{};
  final requested = <String>[];
  void Function(String)? afterInfo;
  @override
  Future<void> init() async {}
  @override
  Future<bool> hasCookie() async => false;
  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    requested.add(bvid);
    if (rejected.contains(bvid)) throw StateError('unavailable');
    afterInfo?.call(bvid);
    return infos[bvid]!;
  }

  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async => const BilibiliPlayerMetadata();
  @override
  Future<String> fetchDanmakuXml(int cid) async => '<i></i>';
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

class _PublicApi extends BilibiliPublicApiService {
  @override
  Future<Never> fetchVideoDetail({String? bvid, int? aid}) async =>
      throw StateError('unavailable');
}

class _Favorites extends BilibiliFavoritesService {
  Object? error;
  @override
  Future<BilibiliFavoriteContents> fetchAllVideos(
    int mid,
    int folderId, {
    bool Function()? isCancelled,
    void Function(int loaded, int total)? onProgress,
  }) async {
    if (error case final failure?) throw failure;
    return BilibiliFavoriteContents(
      folder: _folder,
      entries: [
        _entry(91, favoriteTestBvid),
        _entry(92, _second),
        _entry(93, _third, unavailable: true),
        _entry(94, _third, type: 12),
      ],
    );
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late LibraryService library;
  late BilibiliDownloadService service;
  late _Api api;
  late _Favorites favorites;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().importCardPlacement =
        ImportCardPlacement.libraryRoot.storageValue;
    BilibiliHistoryService.instance.resetForTest();
    root = await Directory.systemTemp.createTemp('favorites_import_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    api = _Api();
    favorites = _Favorites();
    service = BilibiliDownloadService(apiService: api, publicApi: _PublicApi());
  });

  tearDown(() async {
    await service.waitForPendingStreamCardData();
    await service.shutdown();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = null;
    BilibiliHistoryService.instance.resetForTest();
    PathProviderPlatform.instance = originalPaths;
    await deleteTestTempDir(root);
  });

  BilibiliFavoritesImportRequest request({
    List<BilibiliFavoriteVideo>? selected,
    ImportPlacementRequest? placement,
  }) => BilibiliFavoritesImportRequest(
    mid: 7,
    folder: _folder,
    selectedVideos: selected,
    placement:
        placement ??
        ImportPlacementRequest.explicit(ImportCardFeature.bilibiliPage, null),
  );

  Future<BilibiliFavoritesImportResult> run(
    BilibiliFavoritesImportRequest input, {
    bool Function()? isCancelled,
  }) => importBilibiliFavorites(
    request: input,
    service: service,
    library: library,
    favorites: favorites,
    isCancelled: isCancelled,
  );

  test(
    'whole folder creates an outer folder and retains every video part',
    () async {
      final result = await run(request());
      expect(result.imported, {'2:91', '2:92'});
      expect(result.parts, 3);
      expect(result.skipped, 2);
      final outer = library.collections.single;
      expect(outer.name, _folder.title);
      final multipart = library.bilibiliStreamItems
          .where((v) => v.sourceRef?.bvid == favoriteTestBvid)
          .toList();
      expect(multipart.map((v) => v.sourceRef?.page), [1, 2]);
      final videoFolder = library.getCollection(multipart.first.parentId!)!;
      expect(videoFolder.parentId, outer.id);
      expect(
        library.bilibiliStreamItems
            .singleWhere((v) => v.sourceRef?.bvid == _second)
            .parentId,
        outer.id,
      );
      expect(service.tasks.every((task) => task.isStreamingImport), isTrue);
    },
  );

  test(
    'selected videos import directly to the target without a favorites wrapper',
    () async {
      final target = await library.createCollection('目标目录', null);
      final result = await run(
        request(
          selected: [_entry(91, favoriteTestBvid), _entry(92, _second)],
          placement: ImportPlacementRequest.explicit(
            ImportCardFeature.bilibiliPage,
            target.id,
          ),
        ),
      );
      expect(result.parts, 3);
      expect(
        library
            .getCollection(target.id)!
            .childrenIds
            .where((id) => library.getCollection(id) != null)
            .map((id) => library.getCollection(id)!.name),
        [favoriteTestBvid],
      );
      expect(
        library.collections.map((folder) => folder.name),
        isNot(contains(_folder.title)),
      );
      final single = library.bilibiliStreamItems.singleWhere(
        (v) => v.sourceRef?.bvid == _second,
      );
      expect(single.parentId, target.id);
      final parts = library.bilibiliStreamItems
          .where((v) => v.sourceRef?.bvid == favoriteTestBvid)
          .toList();
      expect(library.getCollection(parts.first.parentId!)!.parentId, target.id);
      expect(service.tasks, isEmpty);
    },
  );

  for (final whole in [false, true]) {
    test(
      'resolves an ask-every-time destination once for whole=$whole',
      () async {
        final target = await library.createCollection('指定目录', null);
        var prompts = 0;
        library.importPlacementPicker = (feature, current) async {
          prompts++;
          return ImportPlacementRequest.explicit(feature, target.id);
        };
        await run(
          request(
            selected: whole
                ? null
                : [_entry(91, favoriteTestBvid), _entry(92, _second)],
            placement: ImportPlacementRequest(
              feature: ImportCardFeature.bilibiliPage,
              placement: ImportCardPlacement.askEveryTime,
            ),
          ),
        );
        expect(prompts, 1);
        expect(library.bilibiliStreamItems, hasLength(3));
      },
    );
  }

  test(
    'reimporting selected videos reuses cards and preserves saved progress',
    () async {
      final entries = [_entry(91, favoriteTestBvid), _entry(92, _second)];
      await run(request(selected: entries));
      final original = library.bilibiliStreamItems.first;
      await library.updateVideoProgress(original.id, 42000);
      final ids = library.bilibiliStreamItems.map((v) => v.id).toSet();
      await run(request(selected: entries));
      expect(library.bilibiliStreamItems.map((v) => v.id).toSet(), ids);
      expect(library.getVideo(original.id)!.lastPositionMs, 42000);
    },
  );

  test(
    'selected multipart videos bypass the fifty-part automatic limit',
    () async {
      api.infos[favoriteTestBvid] = _info(favoriteTestBvid, parts: 52);
      final result = await run(
        request(selected: [_entry(91, favoriteTestBvid)]),
      );
      expect(result.parts, 52);
      expect(result.failed, isEmpty);
      expect(
        library.bilibiliStreamItems.map((v) => v.sourceRef?.page),
        List.generate(52, (i) => i + 1),
      );
      expect(library.collections.single.name, favoriteTestBvid);
    },
  );

  test(
    'a failed selected video is reported while other videos continue',
    () async {
      api.rejected.add(_second);
      final result = await run(
        request(
          selected: [
            _entry(91, favoriteTestBvid),
            _entry(92, _second),
            _entry(93, _third),
          ],
        ),
      );
      expect(result.imported, {'2:91', '2:93'});
      expect(result.failed.keys, ['2:92']);
      expect(result.parts, 3);
      expect(library.bilibiliStreamItems, hasLength(3));
      api.rejected.clear();
      await run(request(selected: [_entry(92, _second)]));
      expect(library.bilibiliStreamItems, hasLength(4));
    },
  );

  test('pagination failure publishes no task, folder or card', () async {
    favorites.error = const BilibiliFavoritesException('第二页读取失败');
    await expectLater(
      run(request()),
      throwsA(isA<BilibiliFavoritesException>()),
    );
    expect(library.bilibiliStreamItems, isEmpty);
    expect(library.collections, isEmpty);
    expect(service.tasks, isEmpty);
    expect(api.requested, isEmpty);
  });

  test(
    'cancellation stops unstarted selected videos and retains completed cards',
    () async {
      var cancelled = false;
      api.afterInfo = (bvid) {
        if (bvid == _second) cancelled = true;
      };
      final result = await run(
        request(
          selected: [
            _entry(91, favoriteTestBvid),
            _entry(92, _second),
            _entry(93, _third),
          ],
        ),
        isCancelled: () => cancelled,
      );
      expect(result.cancelled, isTrue);
      expect(result.imported, {'2:91'});
      expect(api.requested, [favoriteTestBvid, _second]);
      expect(library.bilibiliStreamItems, hasLength(2));
    },
  );

  test(
    'whole-folder cancellation releases pending part import state',
    () async {
      await service.init();
      final task = await prepareBilibiliFavoritesFolderImport(
        service: service,
        contents: await favorites.fetchAllVideos(7, 41),
        placement: request().placement,
        mid: 7,
      );
      final episodes = task.videos.expand((v) => v.episodes).toList();
      var checks = 0;
      final count = await service.importParsedStreamingTaskToLibrary(
        library,
        task,
        shouldContinue: () => ++checks <= 1,
      );
      expect(count, 1);
      expect(
        episodes
            .skip(1)
            .every((ep) => ep.importState == BilibiliImportState.pending),
        isTrue,
      );
      expect(episodes.any(service.isStreamingImporting), isFalse);
      expect(library.bilibiliStreamItems, hasLength(1));
    },
  );
}
