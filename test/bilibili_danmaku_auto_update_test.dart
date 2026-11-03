import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_danmaku_auto_update.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';

const _xml = '<i><d p="1,1,25,16777215">new danmaku</d></i>';

class _Api extends BilibiliApiService {
  _Api({this.pages = const [], this.xml = _xml, this.fail});

  List<BilibiliPage> pages;
  String xml;
  Object? fail;
  final fetchedCids = <int>[];

  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    return BilibiliVideoInfo(
      title: 'video',
      desc: '',
      pic: '',
      bvid: bvid,
      aid: aid ?? '1',
      ownerName: '',
      ownerMid: '',
      pubDate: 0,
      pages: pages,
    );
  }

  @override
  Future<String> fetchDanmakuXml(int cid) async {
    fetchedCids.add(cid);
    final error = fail;
    if (error != null) throw error;
    return xml;
  }
}

class _ScriptedDownloads extends BilibiliDownloadService {
  _ScriptedDownloads(this.result) : super(apiService: BilibiliApiService());

  BilibiliDanmakuAutoUpdateResult result;
  int calls = 0;

  @override
  Future<BilibiliDanmakuAutoUpdateResult> autoUpdateDanmakuForVideo(
    VideoItem item,
    LibraryService library,
  ) async {
    calls++;
    return result;
  }
}

VideoItem _item({
  required String danmakuPath,
  int durationMs = 10000,
  int cid = 123,
  int? page = 1,
  String path = 'video.mp4',
}) {
  return VideoItem(
    id: 'video-id',
    path: path,
    title: 'video',
    durationMs: durationMs,
    lastUpdated: 1,
    isBilibiliExported: true,
    danmakuPath: danmakuPath,
    sourceRef: MediaSourceRef(
      value: 'BV1xx411c7mD',
      kind: path.startsWith('bilibili://')
          ? MediaSourceKind.bilibiliStream
          : MediaSourceKind.bilibiliBv,
      bvid: 'BV1xx411c7mD',
      cid: cid,
      page: page,
    ),
  );
}

BilibiliPage _page({required int cid, int page = 1, int duration = 10}) {
  return BilibiliPage(cid: cid, page: page, part: 'video', duration: duration);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local refresh keeps the saved cid when the timeline still matches',
    () async {
      final directory = await Directory.systemTemp.createTemp('danmaku-auto-');
      addTearDown(() => directory.delete(recursive: true));
      final target = File(
        '${directory.path}${Platform.pathSeparator}video.ass',
      );
      await target.writeAsString('old danmaku');
      final api = _Api(pages: [_page(cid: 123), _page(cid: 999, page: 2)]);

      final result = await BilibiliDownloadService(apiService: api)
          .autoUpdateDanmakuForVideo(
            _item(danmakuPath: target.path),
            LibraryService(),
          );

      expect(result.status, BilibiliDanmakuAutoUpdateStatus.updated);
      expect(api.fetchedCids, [123]);
      expect(await target.readAsString(), contains('new danmaku'));
    },
  );

  test(
    'local refresh skips a replaced timeline and leaves the sidecar',
    () async {
      final directory = await Directory.systemTemp.createTemp('danmaku-auto-');
      addTearDown(() => directory.delete(recursive: true));
      final target = File(
        '${directory.path}${Platform.pathSeparator}video.ass',
      );
      await target.writeAsString('old danmaku');
      final api = _Api(pages: [_page(cid: 123, duration: 80)]);

      final result = await BilibiliDownloadService(apiService: api)
          .autoUpdateDanmakuForVideo(
            _item(danmakuPath: target.path, durationMs: 10000),
            LibraryService(),
          );

      expect(result.status, BilibiliDanmakuAutoUpdateStatus.durationMismatch);
      expect(result.hardFailure, isTrue);
      expect(api.fetchedCids, isEmpty);
      expect(await target.readAsString(), 'old danmaku');
    },
  );

  test('a deleted local source does not clear the sidecar', () async {
    final directory = await Directory.systemTemp.createTemp('danmaku-auto-');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}${Platform.pathSeparator}video.ass');
    await target.writeAsString('old danmaku');
    final api = _Api(pages: [_page(cid: 999)]);

    final result = await BilibiliDownloadService(apiService: api)
        .autoUpdateDanmakuForVideo(
          _item(danmakuPath: target.path),
          LibraryService(),
        );

    expect(result.status, BilibiliDanmakuAutoUpdateStatus.failedHard);
    expect(api.fetchedCids, isEmpty);
    expect(await target.readAsString(), 'old danmaku');
  });

  test('online playback follows a replaced part cid', () async {
    final directory = await Directory.systemTemp.createTemp('danmaku-auto-');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}${Platform.pathSeparator}video.ass');
    await target.writeAsString('old danmaku');
    final api = _Api(pages: [_page(cid: 999)]);
    final item = _item(
      danmakuPath: target.path,
      path: 'bilibili://stream/BV1xx411c7mD?cid=123',
    );

    final result = await BilibiliDownloadService(
      apiService: api,
    ).autoUpdateDanmakuForVideo(item, LibraryService());

    expect(result.status, BilibiliDanmakuAutoUpdateStatus.updated);
    expect(api.fetchedCids, [999]);
    expect(item.sourceRef?.cid, 999);
    expect(await target.readAsString(), contains('new danmaku'));
  });

  test('an unchanged sidecar is not rewritten', () async {
    final directory = await Directory.systemTemp.createTemp('danmaku-auto-');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}${Platform.pathSeparator}video.ass');
    await target.writeAsString('old danmaku');
    final api = _Api(pages: [_page(cid: 123)]);
    final service = BilibiliDownloadService(apiService: api);
    final item = _item(danmakuPath: target.path);

    await service.autoUpdateDanmakuForVideo(item, LibraryService());
    final written = await target.readAsString();
    await target.writeAsString(written);
    final result = await service.autoUpdateDanmakuForVideo(
      item,
      LibraryService(),
    );

    expect(result.status, BilibiliDanmakuAutoUpdateStatus.unchanged);
    expect(await target.readAsString(), written);
    expect(api.fetchedCids, [123, 123]);
  });

  test('empty and network failures keep the previous sidecar', () async {
    final directory = await Directory.systemTemp.createTemp('danmaku-auto-');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}${Platform.pathSeparator}video.ass');
    await target.writeAsString('old danmaku');
    final item = _item(danmakuPath: target.path);
    final empty = _Api(pages: [_page(cid: 123)], xml: '<i></i>');

    final emptyResult = await BilibiliDownloadService(
      apiService: empty,
    ).autoUpdateDanmakuForVideo(item, LibraryService());
    expect(emptyResult.status, BilibiliDanmakuAutoUpdateStatus.failedHard);
    expect(await target.readAsString(), 'old danmaku');

    final offline = _Api(
      pages: [_page(cid: 123)],
      fail: DioException(
        requestOptions: RequestOptions(path: '/danmaku'),
        type: DioExceptionType.connectionTimeout,
      ),
    );
    final offlineResult = await BilibiliDownloadService(
      apiService: offline,
    ).autoUpdateDanmakuForVideo(item, LibraryService());
    expect(offlineResult.status, BilibiliDanmakuAutoUpdateStatus.failedNetwork);
    expect(offlineResult.hardFailure, isFalse);
    expect(await target.readAsString(), 'old danmaku');
  });

  test(
    'automatic refresh waits out a success cooldown and retries network failures on the next open',
    () async {
      final downloads = _ScriptedDownloads(
        const BilibiliDanmakuAutoUpdateResult(
          BilibiliDanmakuAutoUpdateStatus.updated,
        ),
      );
      final ledger = MemoryDanmakuAutoUpdateLedger();
      final auto = BilibiliDanmakuAutoUpdate(
        delay: Duration.zero,
        clock: () => DateTime.utc(2026, 10, 18),
        isOnline: () async => true,
        ledger: ledger,
      );
      final item = _item(danmakuPath: 'video.ass');
      var reloads = 0;

      Future<void> open(Object surface, int token) {
        return auto.scheduleForPlayback(
          item: item,
          surface: surface,
          playbackToken: token,
          enabled: true,
          downloads: downloads,
          library: LibraryService(),
          stillCurrent: () => true,
          position: () => const Duration(seconds: 2),
          playing: () => true,
          reloadVisual: () => reloads++,
        );
      }

      await open(Object(), 1);
      await open(Object(), 2);
      expect(downloads.calls, 1);
      expect(reloads, 1);

      downloads.result = const BilibiliDanmakuAutoUpdateResult(
        BilibiliDanmakuAutoUpdateStatus.failedNetwork,
      );
      ledger.records.clear();
      final sameOpen = Object();
      await open(sameOpen, 3);
      await open(sameOpen, 3);
      await open(Object(), 4);
      expect(downloads.calls, 3);
    },
  );

  test('a refresh deep into playback waits for pause or seek', () async {
    final downloads = _ScriptedDownloads(
      const BilibiliDanmakuAutoUpdateResult(
        BilibiliDanmakuAutoUpdateStatus.updated,
      ),
    );
    final auto = BilibiliDanmakuAutoUpdate(
      delay: Duration.zero,
      clock: () => DateTime.utc(2026, 10, 18),
      isOnline: () async => true,
      ledger: MemoryDanmakuAutoUpdateLedger(),
    );
    final item = _item(danmakuPath: 'video.ass');
    var reloads = 0;
    await auto.scheduleForPlayback(
      item: item,
      surface: Object(),
      playbackToken: 1,
      enabled: true,
      downloads: downloads,
      library: LibraryService(),
      stillCurrent: () => true,
      position: () => const Duration(minutes: 2),
      playing: () => true,
      reloadVisual: () => reloads++,
    );

    expect(reloads, 0);
    expect(
      auto.consumePendingVisual(
        videoId: item.id,
        position: const Duration(minutes: 2, milliseconds: 200),
        playing: true,
      ),
      isFalse,
    );
    expect(
      auto.consumePendingVisual(
        videoId: item.id,
        position: const Duration(minutes: 2, seconds: 3),
        playing: true,
      ),
      isTrue,
    );
    expect(reloads, 0);
    expect(auto.hasPendingVisual(item.id), isFalse);
  });

  test('switching away before the delay skips the request', () async {
    final downloads = _ScriptedDownloads(
      const BilibiliDanmakuAutoUpdateResult(
        BilibiliDanmakuAutoUpdateStatus.updated,
      ),
    );
    final auto = BilibiliDanmakuAutoUpdate(
      delay: Duration.zero,
      isOnline: () async => true,
      ledger: MemoryDanmakuAutoUpdateLedger(),
    );
    var current = true;
    final pending = auto.scheduleForPlayback(
      item: _item(danmakuPath: 'video.ass'),
      surface: Object(),
      playbackToken: 1,
      enabled: true,
      downloads: downloads,
      library: LibraryService(),
      stillCurrent: () => current,
      position: () => Duration.zero,
      playing: () => true,
      reloadVisual: () {},
    );
    current = false;
    await pending;
    expect(downloads.calls, 0);
  });

  test('the switch and being offline both skip the request', () async {
    final downloads = _ScriptedDownloads(
      const BilibiliDanmakuAutoUpdateResult(
        BilibiliDanmakuAutoUpdateStatus.updated,
      ),
    );
    var online = false;
    final auto = BilibiliDanmakuAutoUpdate(
      delay: Duration.zero,
      isOnline: () async => online,
      ledger: MemoryDanmakuAutoUpdateLedger(),
    );
    final item = _item(danmakuPath: 'video.ass');

    await auto.scheduleForPlayback(
      item: item,
      surface: Object(),
      playbackToken: 1,
      enabled: false,
      downloads: downloads,
      library: LibraryService(),
      stillCurrent: () => true,
      position: () => Duration.zero,
      playing: () => false,
      reloadVisual: () {},
    );
    await auto.scheduleForPlayback(
      item: item,
      surface: Object(),
      playbackToken: 2,
      enabled: true,
      downloads: downloads,
      library: LibraryService(),
      stillCurrent: () => true,
      position: () => Duration.zero,
      playing: () => false,
      reloadVisual: () {},
    );
    expect(downloads.calls, 0);

    online = true;
    await auto.scheduleForPlayback(
      item: item,
      surface: Object(),
      playbackToken: 3,
      enabled: true,
      downloads: downloads,
      library: LibraryService(),
      stillCurrent: () => true,
      position: () => Duration.zero,
      playing: () => false,
      reloadVisual: () {},
    );
    expect(downloads.calls, 1);
  });
}
