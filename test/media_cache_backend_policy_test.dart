import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/media_cache/app_media_cache_backend.dart';
import 'package:video_player_app/features/media_cache/media_cache_backend.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';

class _UnusedBilibili extends Fake implements BilibiliDownloadService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'prepared cache publication does not launch a media probe or decoder',
    () async {
      final root = await Directory.systemTemp.createTemp('cache-no-probe-');
      addTearDown(() => root.delete(recursive: true));
      // The transport has already accepted this file; publication must not launch
      // FFprobe or a player to read its contents a second time.
      final file = File('${root.path}/ready.mp4')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final task = CacheTask(
        id: 'prepared',
        createdAt: 1,
        source: const CacheSource(
          ref: MediaSourceRef(
            kind: MediaSourceKind.bilibiliStream,
            value: 'BV1',
            bvid: 'BV1',
            cid: 1,
          ),
          itemId: 'one',
          title: 'Already downloaded',
          kind: MediaType.video,
          durationMs: 600000,
        ),
      );
      final backend = AppMediaCacheBackend(_UnusedBilibili());
      final plan = CacheDownloadPlan(
        quality: const CacheQuality(id: '80', label: '1080P'),
        payload: file,
      );
      final progress = <CacheTransferProgress>[];
      final result = await backend.download(
        task,
        plan,
        MediaCachePreferences(),
        CancelToken(),
        progress.add,
      );
      expect(result.path, file.path);
      expect(
        progress.where((p) => p.state == CacheTaskState.verifying),
        isEmpty,
      );
      final cancelled = CancelToken()..cancel('user pause');
      await expectLater(
        backend.download(
          task,
          plan,
          MediaCachePreferences(),
          cancelled,
          progress.add,
        ),
        throwsA(isA<DioException>()),
      );
    },
  );
}
