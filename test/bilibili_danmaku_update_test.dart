import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';

class _DanmakuApi extends BilibiliApiService {
  final bool fail;

  _DanmakuApi({this.fail = false});

  @override
  Future<String> fetchDanmakuXml(int cid) async {
    if (fail) throw StateError('empty');
    return '<i><d p="1,1,25,16777215">new danmaku</d></i>';
  }
}

VideoItem _item(String danmakuPath) => VideoItem(
  id: 'video-id',
  path: 'video.mp4',
  title: 'video',
  durationMs: 1000,
  lastUpdated: 1,
  isBilibiliExported: true,
  danmakuPath: danmakuPath,
  sourceRef: const MediaSourceRef(
    value: 'BV1xx411c7mD',
    kind: MediaSourceKind.bilibiliBv,
    bvid: 'BV1xx411c7mD',
    cid: 123,
  ),
);

void main() {
  test(
    'updates the stable danmaku sidecar without creating extra files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'danmaku-update-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final target = File(
        '${directory.path}${Platform.pathSeparator}video.ass',
      );
      await target.writeAsString('old danmaku');

      final service = BilibiliDownloadService(apiService: _DanmakuApi());
      await service.updateDanmakuForVideo(_item(target.path), LibraryService());

      final content = await target.readAsString();
      expect(content, isNot(contains('old danmaku')));
      expect(content, contains('new danmaku'));
      expect(await directory.list().length, 1);
    },
  );

  test('a failed fetch creates no file and remains retryable', () async {
    final directory = await Directory.systemTemp.createTemp('danmaku-update-');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}${Platform.pathSeparator}video.ass');
    await target.writeAsString('old danmaku');
    final item = _item(target.path);

    await expectLater(
      BilibiliDownloadService(
        apiService: _DanmakuApi(fail: true),
      ).updateDanmakuForVideo(item, LibraryService()),
      throwsA(
        isA<BilibiliDanmakuUpdateException>().having(
          (error) => error.message,
          'message',
          '最新弹幕为空',
        ),
      ),
    );
    expect(await directory.list().length, 1);

    await BilibiliDownloadService(
      apiService: _DanmakuApi(),
    ).updateDanmakuForVideo(item, LibraryService());
    expect(await target.readAsString(), contains('new danmaku'));
    expect(await directory.list().length, 1);
  });
}
