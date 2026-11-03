import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';

class _AudioApi extends BilibiliApiService {
  final Uri origin;

  _AudioApi(this.origin);

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    return BilibiliStreamInfo(
      videoStreams: const <StreamItem>[],
      audioStreams: [
        StreamItem(
          id: 30280,
          baseUrl: origin.resolve('/audio.m4s').toString(),
          bandwidth: 128000,
          codecs: 'mp4a.40.2',
          codecid: 0,
          mimeType: 'audio/mp4',
        ),
      ],
      qualityMap: const <int, String>{},
    );
  }
}

VideoItem _item(String id) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1xx411c7mD?cid=456',
  title: 'online',
  durationMs: 1000,
  lastUpdated: 0,
  sourceRef: const MediaSourceRef(
    value: 'BV1xx411c7mD',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV1xx411c7mD',
    cid: 456,
  ),
);

void main() {
  test(
    'transcription audio is downloaded once, reused, counted and deleted',
    () async {
      final payload = List<int>.generate(96 * 1024, (index) => index % 251);
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = () async {
        await for (final request in server) {
          requests++;
          request.response.contentLength = payload.length;
          for (var offset = 0; offset < payload.length; offset += 4096) {
            request.response.add(
              payload.sublist(offset, (offset + 4096).clamp(0, payload.length)),
            );
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 15));
          }
          await request.response.close();
        }
      }();
      addTearDown(() async {
        await server.close(force: true);
        await serving;
      });

      final cache = await Directory.systemTemp.createTemp('bili-asr-cache-');
      addTearDown(() async {
        if (await cache.exists()) await cache.delete(recursive: true);
      });
      final origin = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      final service = BilibiliStreamingService(
        _AudioApi(origin),
        mediaUriValidator: (uri) => uri.host == origin.host,
        cacheDirectory: cache,
      );
      addTearDown(service.shutdown);
      final item = _item('audio-card');
      final progress = <BilibiliAudioDownloadProgress>[];

      final first = service.downloadAudioForTranscription(
        item,
        onProgress: progress.add,
      );
      final duplicate = service.downloadAudioForTranscription(item);
      expect(identical(first, duplicate), isTrue);
      final firstPath = await first;
      final secondPath = await service.downloadAudioForTranscription(item);

      expect(firstPath, secondPath);
      expect(requests, 1);
      expect(await File(firstPath).readAsBytes(), payload);
      expect(progress, isNotEmpty);
      expect(progress.last.fraction, 1);
      expect((await service.inspectItemCache(item.id)).bytes, payload.length);

      await service.clearCacheForItem(item.id);
      expect(await File(firstPath).exists(), isFalse);
      expect((await service.inspectItemCache(item.id)).bytes, 0);
    },
  );

  test('failed audio download removes its partial file', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = () async {
      await for (final request in server) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    }();
    addTearDown(() async {
      await server.close(force: true);
      await serving;
    });
    final cache = await Directory.systemTemp.createTemp('bili-asr-fail-');
    addTearDown(() async {
      if (await cache.exists()) await cache.delete(recursive: true);
    });
    final origin = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
    );
    final service = BilibiliStreamingService(
      _AudioApi(origin),
      networkRetryDelays: const [],
      mediaUriValidator: (uri) => uri.host == origin.host,
      cacheDirectory: cache,
    );
    addTearDown(service.shutdown);

    await expectLater(
      service.downloadAudioForTranscription(_item('failed-card')),
      throwsA(isA<StateError>()),
    );

    final files = await cache
        .list(recursive: true)
        .where((entity) => entity is File)
        .toList();
    expect(files, isEmpty);
  });
}
