import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';

class _FakeBilibiliApiService extends BilibiliApiService {
  final Uri? mediaOrigin;

  _FakeBilibiliApiService({this.mediaOrigin});

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    StreamItem video(int id, int codecid, String codecs) => StreamItem(
      id: id,
      baseUrl:
          mediaOrigin?.resolve('/video-$id-$codecid.m4s').toString() ??
          'https://upos-test.bilivideo.com/video-$id-$codecid.m4s',
      bandwidth: id * 1000 + codecid,
      codecs: codecs,
      codecid: codecid,
      mimeType: 'video/mp4',
      qualityName: id == 80 ? '1080P 高清' : '720P 高清',
      width: id == 80 ? 1920 : 1280,
      height: id == 80 ? 1080 : 720,
      frameRate: '30',
      initializationRange: '0-999',
      indexRange: '1000-1999',
    );

    return BilibiliStreamInfo(
      durationMs: 120000,
      qualityMap: const {80: '1080P 高清', 64: '720P 高清'},
      videoStreams: [
        video(80, 12, 'hev1.1.6.L120.90'),
        video(80, 7, 'avc1.640028'),
        video(64, 7, 'avc1.64001f'),
      ],
      audioStreams: [
        StreamItem(
          id: 30280,
          baseUrl:
              mediaOrigin?.resolve('/audio.m4s').toString() ??
              'https://upos-test.bilivideo.com/audio.m4s',
          bandwidth: 128000,
          codecs: 'mp4a.40.2',
          codecid: 0,
          mimeType: 'audio/mp4',
          initializationRange: '0-899',
          indexRange: '900-1799',
        ),
      ],
    );
  }
}

class _CountingFakeBilibiliApiService extends _FakeBilibiliApiService {
  int fetchPlayUrlCalls = 0;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    fetchPlayUrlCalls++;
    return super.fetchPlayUrl(bvid, cid);
  }
}

class _BackupOnlyQualityApiService extends BilibiliApiService {
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    StreamItem video({
      required int id,
      required String baseUrl,
      List<String> backupUrls = const [],
    }) => StreamItem(
      id: id,
      baseUrl: baseUrl,
      backupUrls: backupUrls,
      bandwidth: id * 1000,
      codecs: 'avc1.640028',
      codecid: 7,
      mimeType: 'video/mp4',
      qualityName: id == 120 ? '超清 4K' : '高清 1080P',
      width: id == 120 ? 3840 : 1920,
      height: id == 120 ? 2160 : 1080,
      initializationRange: '0-999',
      indexRange: '1000-1999',
    );

    return BilibiliStreamInfo(
      qualityMap: const {120: '超清 4K', 80: '高清 1080P'},
      videoStreams: [
        video(id: 120, baseUrl: 'https://upos-test.bilivideo.com/4k.m4s'),
        video(
          id: 80,
          baseUrl: 'https://edge.mountaintoys.cn/1080p.m4s',
          backupUrls: const ['https://upos-test.bilivideo.com/1080p.m4s'],
        ),
      ],
      audioStreams: [
        StreamItem(
          id: 30280,
          baseUrl: 'https://upos-test.bilivideo.com/audio.m4s',
          bandwidth: 128000,
          codecs: 'mp4a.40.2',
          codecid: 0,
          mimeType: 'audio/mp4',
          initializationRange: '0-899',
          indexRange: '900-1799',
        ),
      ],
    );
  }
}

class _SwitchingPlayUrlApi extends BilibiliApiService {
  _SwitchingPlayUrlApi({
    required this.origin,
    required this.firstVideoPath,
    required this.secondVideoPath,
    this.firstDeadline,
    this.secondDeadline,
  });

  final Uri origin;
  final String firstVideoPath;
  final String secondVideoPath;
  final int? firstDeadline;
  final int? secondDeadline;
  int fetchPlayUrlCalls = 0;

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    final first = fetchPlayUrlCalls == 0;
    fetchPlayUrlCalls++;
    return _switchableStreamInfo(
      origin,
      first ? firstVideoPath : secondVideoPath,
      deadline: first ? firstDeadline : secondDeadline,
    );
  }
}

BilibiliStreamInfo _switchableStreamInfo(
  Uri origin,
  String videoPath, {
  int? deadline,
}) {
  String url(String path) {
    final signed = origin.replace(path: path);
    if (deadline == null) return signed.toString();
    return signed
        .replace(queryParameters: {'deadline': '$deadline'})
        .toString();
  }

  return BilibiliStreamInfo(
    durationMs: 120000,
    qualityMap: const {80: '1080P 高清'},
    videoStreams: [
      StreamItem(
        id: 80,
        baseUrl: url(videoPath),
        bandwidth: 800000,
        codecs: 'avc1.640028',
        codecid: 7,
        mimeType: 'video/mp4',
        qualityName: '1080P 高清',
        width: 1920,
        height: 1080,
        frameRate: '30',
        initializationRange: '0-999',
        indexRange: '1000-1999',
      ),
    ],
    audioStreams: [
      StreamItem(
        id: 30280,
        baseUrl: url('/audio.m4s'),
        bandwidth: 128000,
        codecs: 'mp4a.40.2',
        codecid: 0,
        mimeType: 'audio/mp4',
        initializationRange: '0-899',
        indexRange: '900-1799',
      ),
    ],
  );
}

VideoItem _streamItem(String id) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1xx411c7mD?cid=456',
  title: 'stream',
  durationMs: 120000,
  lastUpdated: 0,
  sourceRef: const MediaSourceRef(
    value: 'BV1xx411c7mD',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV1xx411c7mD',
    cid: 456,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stream media identity persists without a temporary CDN URL', () {
    const source = MediaSourceRef(
      value: 'BV1xx411c7mD',
      kind: MediaSourceKind.bilibiliStream,
      originalValue: 'https://www.bilibili.com/video/BV1xx411c7mD',
      bvid: 'BV1xx411c7mD',
      aid: '123',
      cid: 456,
      page: 2,
    );

    final restored = MediaSourceRef.fromJson(source.toJson());

    expect(restored.kind, MediaSourceKind.bilibiliStream);
    expect(restored.bvid, 'BV1xx411c7mD');
    expect(restored.aid, '123');
    expect(restored.cid, 456);
    expect(restored.page, 2);
    expect(restored.toJson().values, isNot(contains('https://cdn.example')));
  });

  test('DASH aliases and SegmentBase are normalized for streaming', () {
    final info = BilibiliStreamInfo.fromJson({
      'data': {
        'timelength': 123456,
        'accept_quality': [80],
        'accept_description': ['1080P 高清'],
        'dash': {
          'duration': 123.456,
          'video': [
            {
              'id': 80,
              'baseUrl': 'https://upos.example.bilivideo.com/video.m4s',
              'backupUrl': ['https://backup.bilivideo.com/video.m4s'],
              'bandwidth': 1000,
              'codecs': 'avc1.640028',
              'codecid': 7,
              'mimeType': 'video/mp4',
              'width': 1920,
              'height': 1080,
              'frameRate': '30',
              'SegmentBase': {
                'Initialization': '0-999',
                'indexRange': '1000-1999',
              },
            },
          ],
          'audio': [
            {
              'id': 30280,
              'base_url': 'https://upos.example.bilivideo.com/audio.m4s',
              'bandwidth': 128000,
              'codecs': 'mp4a.40.2',
              'codecid': 0,
              'mime_type': 'audio/mp4',
              'segment_base': {
                'initialization': '0-899',
                'index_range': '900-1799',
              },
            },
          ],
        },
      },
    });

    expect(info.durationMs, 123456);
    expect(info.videoStreams.single.qualityName, '1080P 高清');
    expect(info.videoStreams.single.initializationRange, '0-999');
    expect(info.videoStreams.single.indexRange, '1000-1999');
    expect(info.videoStreams.single.width, 1920);
    expect(info.audioStreams.single.indexRange, '900-1799');
  });

  test('streaming task mode survives task persistence', () {
    final task = BilibiliDownloadTask(
      isStreamingImport: true,
      videos: [
        BilibiliVideoItem(
          videoInfo: BilibiliVideoInfo(
            title: 'title',
            desc: '',
            pic: '',
            bvid: 'BV1xx411c7mD',
            aid: '123',
            ownerName: '',
            ownerMid: '',
            pubDate: 0,
            pages: const [],
          ),
          episodes: const [],
        ),
      ],
    );

    final restored = BilibiliDownloadTask.fromJson(task.toJson());
    expect(restored.isStreamingImport, isTrue);
  });

  test(
    'loopback manifest keeps video and audio on one DASH timeline',
    () async {
      final service = BilibiliStreamingService(_FakeBilibiliApiService());
      addTearDown(service.shutdown);
      final item = VideoItem(
        id: 'stream-item',
        path: 'bilibili://stream/BV1xx411c7mD?cid=456',
        title: 'stream',
        durationMs: 120000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'BV1xx411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1xx411c7mD',
          cid: 456,
        ),
      );

      final prepared = await service.prepare(item);
      expect(prepared.qualities.map((quality) => quality.id), [80, 64]);
      expect(prepared.selectedQuality.id, 80);
      expect(prepared.displayAspectRatio, closeTo(16 / 9, 0.0001));

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        prepared.manifestUri,
      )).close();
      final manifest = await response.transform(const Utf8Decoder()).join();

      expect(response.statusCode, HttpStatus.ok);
      expect(manifest, contains('mediaPresentationDuration="PT120.000S"'));
      expect(manifest, contains('/video</BaseURL>'));
      expect(manifest, contains('/audio</BaseURL>'));
      expect(manifest, contains('codecs="avc1.640028"'));
      expect(manifest, contains('indexRange="1000-1999"'));
    },
  );

  test('stream quality preference persists globally across cards', () async {
    final firstService = BilibiliStreamingService(_FakeBilibiliApiService());
    firstService.rememberQuality('first-card', 64);
    await Future<void>.delayed(Duration.zero);
    await firstService.shutdown();

    final secondService = BilibiliStreamingService(_FakeBilibiliApiService());
    addTearDown(secondService.shutdown);
    final prepared = await secondService.prepare(_streamItem('second-card'));

    expect(prepared.selectedQuality.id, 64);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getInt('bilibili_stream_preferred_quality'), 64);
  });

  test('prepare reuses a fresh playurl instead of fetching again', () async {
    SharedPreferences.setMockInitialValues({});
    final api = _CountingFakeBilibiliApiService();
    final service = BilibiliStreamingService(api);
    addTearDown(service.shutdown);
    final item = _streamItem('cached-playurl');

    await service.prepare(item);
    await service.prepare(item);

    expect(api.fetchPlayUrlCalls, 1);
  });

  test(
    'prefetch warms a session that prepare consumes without a second playurl',
    () async {
      SharedPreferences.setMockInitialValues({});
      final api = _CountingFakeBilibiliApiService();
      final service = BilibiliStreamingService(api);
      addTearDown(service.shutdown);
      final item = _streamItem('warm-neighbor');

      await service.prefetch(item);
      expect(api.fetchPlayUrlCalls, 1);
      expect(service.activePlaybackSessionCount, 1);

      final prepared = await service.prepare(item);
      expect(prepared.audioUri.path, contains('/audio'));
      expect(api.fetchPlayUrlCalls, 1);
      expect(service.activePlaybackSessionCount, 1);
    },
  );

  test(
    'missing preferred quality falls back to the highest lower quality',
    () async {
      SharedPreferences.setMockInitialValues({
        'bilibili_stream_preferred_quality': 116,
      });
      final service = BilibiliStreamingService(_FakeBilibiliApiService());
      addTearDown(service.shutdown);

      final prepared = await service.prepare(_streamItem('fallback-card'));

      expect(prepared.selectedQuality.id, 80);
    },
  );

  test(
    'quality remains available when only its backup CDN is allowed',
    () async {
      final service = BilibiliStreamingService(_BackupOnlyQualityApiService());
      addTearDown(service.shutdown);

      final prepared = await service.prepare(_streamItem('backup-card'));

      expect(prepared.qualities.map((quality) => quality.id), [120, 80]);
    },
  );

  test('loopback dual-track gateway proxies HEAD and byte ranges', () async {
    final videoBytes = List<int>.generate(
      2 * 1024 * 1024,
      (index) => index % 251,
    );
    final audioBytes = List<int>.generate(2048, (index) => (index * 3) % 251);
    var videoRangeGets = 0;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamTask = () async {
      await for (final request in upstream) {
        final isAudio = request.uri.path.contains('audio');
        final source = isAudio ? audioBytes : videoBytes;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (!isAudio && request.method == 'GET' && range != null) {
          videoRangeGets++;
        }
        var start = 0;
        var end = source.length - 1;
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          if (match != null) {
            start = int.parse(match.group(1)!);
            if (match.group(2)!.isNotEmpty) {
              end = int.parse(match.group(2)!);
            }
            end = end.clamp(start, source.length - 1);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${source.length}',
            );
          }
        }
        final selected = source.sublist(start, end + 1);
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.contentLength = selected.length;
        try {
          if (request.method != 'HEAD') {
            const chunkSize = 8 * 1024;
            for (
              var offset = 0;
              offset < selected.length;
              offset += chunkSize
            ) {
              final end = (offset + chunkSize).clamp(0, selected.length);
              request.response.add(selected.sublist(offset, end));
              await request.response.flush();
              if (selected.length > chunkSize) {
                await Future<void>.delayed(const Duration(milliseconds: 2));
              }
            }
          }
          await request.response.close();
        } catch (_) {
          // Expected when clearCache force-closes an in-flight media request.
        }
      }
    }();
    addTearDown(() async {
      await upstream.close(force: true);
      await upstreamTask;
    });

    final tempCache = await Directory.systemTemp.createTemp(
      'bilibili-stream-test-',
    );
    addTearDown(() => tempCache.delete(recursive: true));
    final origin = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: upstream.port,
    );
    final service = BilibiliStreamingService(
      _FakeBilibiliApiService(mediaOrigin: origin),
      mediaUriValidator: (uri) => uri.host == origin.host,
      cacheDirectory: tempCache,
    );
    addTearDown(service.shutdown);
    final prepared = await service.prepare(
      VideoItem(
        id: 'gateway-item',
        path: 'bilibili://stream/BV1xx411c7mD?cid=456',
        title: 'stream',
        durationMs: 120000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'BV1xx411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1xx411c7mD',
          cid: 456,
        ),
      ),
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final head = await (await client.headUrl(prepared.audioUri)).close();
    expect(head.statusCode, HttpStatus.ok);
    expect(head.contentLength, audioBytes.length);
    await head.drain<void>();

    final rangeRequest = await client.getUrl(prepared.videoUri);
    rangeRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=100-299');
    final rangeResponse = await rangeRequest.close();
    final payload = await rangeResponse.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(rangeResponse.statusCode, HttpStatus.partialContent);
    expect(
      rangeResponse.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-299/${videoBytes.length}',
    );
    expect(payload, videoBytes.sublist(100, 300));

    final cache = await service.inspectCache();
    expect(cache.bytes, greaterThanOrEqualTo(payload.length));
    expect(cache.fileCount, greaterThanOrEqualTo(1));
    expect(videoRangeGets, 1);

    // A later, differently aligned Range must still be served from the merged
    // track file. Exact `bytes=100-299` filenames cannot survive libmpv restart.
    final overlapRequest = await client.getUrl(prepared.videoUri);
    overlapRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=150-250');
    final overlapResponse = await overlapRequest.close();
    final overlapPayload = await overlapResponse.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(overlapResponse.statusCode, HttpStatus.partialContent);
    expect(overlapPayload, videoBytes.sublist(150, 251));
    expect(videoRangeGets, 1);

    // A second identical Range must be answered from disk, not CDN.
    final cachedRangeRequest = await client.getUrl(prepared.videoUri);
    cachedRangeRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=100-299');
    final cachedRangeResponse = await cachedRangeRequest.close();
    final cachedPayload = await cachedRangeResponse.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(cachedRangeResponse.statusCode, HttpStatus.partialContent);
    expect(cachedPayload, videoBytes.sublist(100, 300));
    expect(videoRangeGets, 1);

    final activeResponse = await (await client.getUrl(
      prepared.videoUri,
    )).close();
    final activeDrain = activeResponse.drain<void>().catchError((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect((await service.inspectCache()).bytes, greaterThan(payload.length));

    await service.clearCache();
    await activeDrain.timeout(const Duration(seconds: 3), onTimeout: () {});
    final cleared = await service.inspectCache();
    expect(cleared.bytes, 0);
    expect(cleared.fileCount, 0);

    // Clearing cache keeps the gateway session alive for the mini player and
    // Android media notification, while this existing session no longer
    // recreates disk cache files.
    final afterClearRequest = await client.getUrl(prepared.videoUri);
    afterClearRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=400-599');
    final afterClearResponse = await afterClearRequest.close();
    final afterClearPayload = await afterClearResponse.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(afterClearResponse.statusCode, HttpStatus.partialContent);
    expect(afterClearPayload, videoBytes.sublist(400, 600));
    expect((await service.inspectCache()).bytes, 0);
  });

  test('gateway track cache survives a new service instance', () async {
    final videoBytes = List<int>.generate(64 * 1024, (index) => index % 251);
    var videoRangeGets = 0;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamTask = () async {
      await for (final request in upstream) {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (request.method == 'GET' && range != null) videoRangeGets++;
        var start = 0;
        var end = videoBytes.length - 1;
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          if (match != null) {
            start = int.parse(match.group(1)!);
            if (match.group(2)!.isNotEmpty) {
              end = int.parse(match.group(2)!);
            }
            end = end.clamp(start, videoBytes.length - 1);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${videoBytes.length}',
            );
          }
        }
        final selected = videoBytes.sublist(start, end + 1);
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.contentLength = selected.length;
        if (request.method != 'HEAD') request.response.add(selected);
        await request.response.close();
      }
    }();
    addTearDown(() async {
      await upstream.close(force: true);
      await upstreamTask;
    });

    final tempCache = await Directory.systemTemp.createTemp(
      'bilibili-stream-restart-',
    );
    addTearDown(() => tempCache.delete(recursive: true));
    final origin = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: upstream.port,
    );
    final item = _streamItem('restart-cache-item');

    final first = BilibiliStreamingService(
      _FakeBilibiliApiService(mediaOrigin: origin),
      mediaUriValidator: (uri) => uri.host == origin.host,
      cacheDirectory: tempCache,
    );
    final prepared = await first.prepare(item);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final warm = await client.getUrl(prepared.videoUri);
    warm.headers.set(HttpHeaders.rangeHeader, 'bytes=32-1023');
    final warmResponse = await warm.close();
    expect(
      await warmResponse.fold<List<int>>(<int>[], (b, c) => b..addAll(c)),
      videoBytes.sublist(32, 1024),
    );
    expect(videoRangeGets, 1);
    await first.shutdown();

    // Closing the app drops in-memory sessions. Disk intervals must still
    // answer a restarted player's differently aligned Range.
    final restarted = BilibiliStreamingService(
      _FakeBilibiliApiService(mediaOrigin: origin),
      mediaUriValidator: (uri) => uri.host == origin.host,
      cacheDirectory: tempCache,
    );
    addTearDown(restarted.shutdown);
    expect(await restarted.hasReusableTrackCache(item.id), isTrue);
    final preparedAgain = await restarted.prepare(item);
    final replay = await client.getUrl(preparedAgain.videoUri);
    replay.headers.set(HttpHeaders.rangeHeader, 'bytes=100-500');
    final replayResponse = await replay.close();
    final replayPayload = await replayResponse.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(replayResponse.statusCode, HttpStatus.partialContent);
    expect(replayPayload, videoBytes.sublist(100, 501));
    expect(videoRangeGets, 1);
  });

  test('player disconnect stops the CDN body before the file ends', () async {
    final videoBytes = List<int>.generate(1024 * 1024, (index) => index % 251);
    final upstream = await _slowUpstream(videoBytes, onSent: (_) {});
    addTearDown(() => upstream.close(force: true));
    final service = await _gatewayService(upstream);
    addTearDown(service.shutdown);
    final prepared = await service.prepare(_streamItem('abort-on-disconnect'));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request = await client.getUrl(prepared.videoUri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final response = await request.close();
    final subscription = response.listen((_) {});
    final started = DateTime.now();
    while (service.relayedBodyBytes == 0 &&
        DateTime.now().difference(started) < const Duration(seconds: 2)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(service.relayedBodyBytes, greaterThan(0));
    await subscription.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final afterCancel = service.relayedBodyBytes;
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(service.relayedBodyBytes, lessThan(videoBytes.length));
    expect(service.relayedBodyBytes - afterCancel, lessThan(64 * 1024));

    final retry = await client.getUrl(prepared.videoUri);
    retry.headers.set(HttpHeaders.rangeHeader, 'bytes=100-115');
    final retryResponse = await retry.close();
    final retryPayload = await retryResponse.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(retryResponse.statusCode, HttpStatus.partialContent);
    expect(retryPayload, videoBytes.sublist(100, 116));
  });

  test(
    'releasing the session stops the CDN body while the player socket is open',
    () async {
      final videoBytes = List<int>.generate(
        1024 * 1024,
        (index) => index % 251,
      );
      final upstream = await _slowUpstream(videoBytes, onSent: (_) {});
      addTearDown(() => upstream.close(force: true));
      final service = await _gatewayService(upstream);
      addTearDown(service.shutdown);
      final prepared = await service.prepare(_streamItem('abort-on-release'));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final request = await client.getUrl(prepared.videoUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final response = await request.close();
      final subscription = response.listen((_) {});
      addTearDown(subscription.cancel);
      final started = DateTime.now();
      while (service.relayedBodyBytes == 0 &&
          DateTime.now().difference(started) < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(service.relayedBodyBytes, greaterThan(0));

      await service
          .releasePlayback(prepared)
          .timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final afterRelease = service.relayedBodyBytes;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(service.relayedBodyBytes, lessThan(videoBytes.length));
      expect(service.relayedBodyBytes - afterRelease, lessThan(64 * 1024));
    },
  );

  test('gateway refreshes a playurl before its CDN deadline', () async {
    final requested = <String>[];
    final payload = List<int>.generate(32, (index) => index + 1);
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstreamTask = () async {
      await for (final request in upstream) {
        requested.add(request.uri.path);
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.contentLength = payload.length;
        if (request.method != 'HEAD') request.response.add(payload);
        await request.response.close();
      }
    }();
    addTearDown(() async {
      await upstream.close(force: true);
      await upstreamTask;
    });
    final origin = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: upstream.port,
    );
    final expired = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    final fresh = DateTime.now().toUtc().add(const Duration(hours: 2));
    final api = _SwitchingPlayUrlApi(
      origin: origin,
      firstVideoPath: '/stale-video.m4s',
      secondVideoPath: '/fresh-video.m4s',
      firstDeadline: expired.millisecondsSinceEpoch ~/ 1000,
      secondDeadline: fresh.millisecondsSinceEpoch ~/ 1000,
    );
    final tempCache = await Directory.systemTemp.createTemp(
      'bilibili-stream-deadline-',
    );
    addTearDown(() => tempCache.delete(recursive: true));
    final service = BilibiliStreamingService(
      api,
      mediaUriValidator: (uri) => uri.host == origin.host,
      cacheDirectory: tempCache,
    );
    addTearDown(service.shutdown);
    final prepared = await service.prepare(_streamItem('deadline-refresh'));
    expect(api.fetchPlayUrlCalls, 1);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(prepared.videoUri)).close();
    final body = await response.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(response.statusCode, HttpStatus.ok);
    expect(body, payload);
    expect(api.fetchPlayUrlCalls, 2);
    expect(requested, contains('/fresh-video.m4s'));
    expect(requested, isNot(contains('/stale-video.m4s')));
  });

  for (final retryRoute in [true, false]) {
    test(
      retryRoute
          ? 'a recovered CDN reset reuses the valid playurl'
          : 'an exhausted CDN retry refreshes the playurl once',
      () async {
        final payload = List<int>.generate(32, (index) => index + 3);
        var videoGets = 0;
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final upstreamTask = () async {
          await for (final request in upstream) {
            try {
              final isVideoGet =
                  request.method == 'GET' && request.uri.path.contains('video');
              if (isVideoGet) videoGets++;
              if (isVideoGet && videoGets == 1) {
                request.response.statusCode = HttpStatus.ok;
                request.response.contentLength = payload.length;
                final socket = await request.response.detachSocket(
                  writeHeaders: true,
                );
                socket.destroy();
                continue;
              }
              request.response.headers.set(
                HttpHeaders.acceptRangesHeader,
                'bytes',
              );
              request.response.contentLength = payload.length;
              if (request.method != 'HEAD') request.response.add(payload);
              await request.response.close();
            } catch (_) {}
          }
        }();
        addTearDown(() async {
          await upstream.close(force: true);
          await upstreamTask;
        });
        final origin = Uri(
          scheme: 'http',
          host: InternetAddress.loopbackIPv4.address,
          port: upstream.port,
        );
        final api = _SwitchingPlayUrlApi(
          origin: origin,
          firstVideoPath: '/video.m4s',
          secondVideoPath: '/video.m4s',
        );
        final tempCache = await Directory.systemTemp.createTemp(
          'bilibili-stream-reset-',
        );
        addTearDown(() => tempCache.delete(recursive: true));
        final service = BilibiliStreamingService(
          api,
          mediaUriValidator: (uri) => uri.host == origin.host,
          cacheDirectory: tempCache,
          networkRetryDelays: retryRoute ? [Duration.zero] : [],
        );
        addTearDown(service.shutdown);
        final prepared = await service.prepare(_streamItem('cdn-reset'));
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final response = await (await client.getUrl(prepared.videoUri)).close();
        final body = await response.fold<List<int>>(
          <int>[],
          (buffer, chunk) => buffer..addAll(chunk),
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(body, payload);
        expect(api.fetchPlayUrlCalls, retryRoute ? 1 : 2);
        expect(videoGets, 2);
      },
    );
  }

  test(
    'a playurl fetched for subtitles replaces the live gateway address',
    () async {
      final requested = <String>[];
      final payload = List<int>.generate(16, (index) => index + 7);
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamTask = () async {
        await for (final request in upstream) {
          requested.add(request.uri.path);
          request.response.contentLength = payload.length;
          if (request.method != 'HEAD') request.response.add(payload);
          await request.response.close();
        }
      }();
      addTearDown(() async {
        await upstream.close(force: true);
        await upstreamTask;
      });
      final origin = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: upstream.port,
      );
      final api = _SwitchingPlayUrlApi(
        origin: origin,
        firstVideoPath: '/original-video.m4s',
        secondVideoPath: '/original-video.m4s',
      );
      final tempCache = await Directory.systemTemp.createTemp(
        'bilibili-stream-adopt-',
      );
      addTearDown(() => tempCache.delete(recursive: true));
      final service = BilibiliStreamingService(
        api,
        mediaUriValidator: (uri) => uri.host == origin.host,
        cacheDirectory: tempCache,
      );
      addTearDown(service.shutdown);
      final item = _streamItem('subtitle-playurl');
      final prepared = await service.prepare(item);
      service.noteFreshPlayUrl(
        item.id,
        _switchableStreamInfo(origin, '/adopted-video.m4s'),
      );

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(prepared.videoUri)).close();
      final body = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(body, payload);
      expect(api.fetchPlayUrlCalls, 1);
      expect(requested, contains('/adopted-video.m4s'));
      expect(requested, isNot(contains('/original-video.m4s')));
    },
  );
}

Future<HttpServer> _slowUpstream(
  List<int> videoBytes, {
  required void Function(int sent) onSent,
}) async {
  final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in upstream) {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = videoBytes.length - 1;
      if (range != null) {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match != null) {
          start = int.parse(match.group(1)!);
          if (match.group(2)!.isNotEmpty) {
            end = int.parse(match.group(2)!);
          }
          end = end.clamp(start, videoBytes.length - 1);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${videoBytes.length}',
          );
        }
      }
      final selected = videoBytes.sublist(start, end + 1);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.contentLength = selected.length;
      try {
        const chunkSize = 8 * 1024;
        for (var offset = 0; offset < selected.length; offset += chunkSize) {
          final chunkEnd = (offset + chunkSize).clamp(0, selected.length);
          request.response.add(selected.sublist(offset, chunkEnd));
          await request.response.flush();
          onSent(start + chunkEnd);
          if (selected.length > chunkSize) {
            await Future<void>.delayed(const Duration(milliseconds: 8));
          }
        }
        await request.response.close();
      } catch (_) {}
    }
  }());
  return upstream;
}

Future<BilibiliStreamingService> _gatewayService(HttpServer upstream) async {
  final tempCache = await Directory.systemTemp.createTemp(
    'bilibili-stream-abort-',
  );
  addTearDown(() => tempCache.delete(recursive: true));
  final origin = Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: upstream.port,
  );
  return BilibiliStreamingService(
    _FakeBilibiliApiService(mediaOrigin: origin),
    mediaUriValidator: (uri) => uri.host == origin.host,
    cacheDirectory: tempCache,
  );
}
