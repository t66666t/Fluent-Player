import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_playback.dart';
import 'package:video_player_app/features/media_cache/media_cache_reads.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/bilibili/media_connection_pool.dart';
import 'package:video_player_app/services/network/network_recovery.dart';
import 'media_cache_service_test.dart' show FakeBackend, source, until;

class _Api extends BilibiliApiService {
  _Api(this.uri);
  final Uri uri;
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async =>
      BilibiliStreamInfo(
        durationMs: 10000,
        videoStreams: [stream],
        audioStreams: [
          StreamItem(
            id: 30280,
            baseUrl: uri.resolve('/audio').toString(),
            bandwidth: 128000,
            codecs: 'mp4a.40.2',
            codecid: 0,
            initializationRange: '0-1',
            indexRange: '2-3',
          ),
        ],
        qualityMap: const {80: '1080P'},
      );
  StreamItem get stream => StreamItem(
    id: 80,
    baseUrl: uri.resolve('/video').toString(),
    bandwidth: 1000000,
    codecs: 'avc1',
    codecid: 7,
    initializationRange: '0-1',
    indexRange: '2-3',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MediaCacheService service;
  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('media_cache_playback_');
    service = MediaCacheService(
      backend: FakeBackend(root),
      journal: File(p.join(root.path, 'media_cache.json')),
      observeNetwork: false,
    );
    await service.initialize();
  });
  tearDown(() async {
    MediaCacheReadHooks.bilibili = null;
    MediaCacheReadHooks.cloud = null;
    await service.shutdown();
    service.dispose();
    await root.delete(recursive: true);
  });
  test(
    'a bounded cached prefix is combined with the exact network suffix on Bilibili',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final uri = Uri.parse('http://127.0.0.1:${server.port}');
      final api = _Api(uri);
      final seen = <String?>[];
      final payload = List.generate(4096, (i) => i % 251);
      server.listen((request) async {
        final range = request.headers.value('range');
        seen.add(range);
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range ?? '');
        final start = match == null ? 0 : int.parse(match[1]!);
        final end = match == null || match[2]!.isEmpty
            ? payload.length - 1
            : int.parse(match[2]!);
        request.response.statusCode = range == null ? 200 : 206;
        request.response.headers.contentType = ContentType('video', 'mp4');
        if (range != null) {
          request.response.headers.set(
            'content-range',
            'bytes $start-$end/${payload.length}',
          );
        }
        request.response.contentLength = end - start + 1;
        request.response.add(payload.sublist(start, end + 1));
        await request.response.close();
      });
      final backend = service.backend as FakeBackend;
      backend.slow = true;
      final task = (await service.enqueue(source()))!;
      await until(() => task.workDirectory != null);
      await service.pause(task.id);
      final part = File(p.join(task.workDirectory!, 'video.m4s'))
        ..writeAsBytesSync(payload.sublist(0, 1024));
      task.resume = {
        'video': DownloadPartResumeState(
          tempPath: part.path,
          downloadedBytes: 1024,
          totalBytes: payload.length,
          streamId: 80,
          codecid: 7,
          codecs: 'avc1',
          mimeType: 'video/mp4',
        ).toJson(),
      };
      MediaCacheReadHooks.bilibili = service.readBilibili;
      final streaming = BilibiliStreamingService(
        api,
        mediaUriValidator: (u) => u.host == '127.0.0.1',
        cacheDirectory: Directory(p.join(root.path, 'stream')),
      );
      final prepared = await streaming.prepare(
        source().toItem(),
        qualityId: 80,
      );
      final client = HttpClient();
      try {
        for (final range in ['bytes=0-', 'bytes=512-2047']) {
          final request = await client.getUrl(prepared.videoUri);
          request.headers.set('range', range);
          final response = await request.close();
          final received = await response.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          );
          expect(response.statusCode, 206);
          expect(
            received,
            range == 'bytes=0-' ? payload : payload.sublist(512, 2048),
          );
        }
        expect(seen.first, 'bytes=1024-4095');
        expect(seen.every((r) => r != 'bytes=0-'), isTrue);
        expect(File(part.path).existsSync(), isTrue);
        await part.writeAsBytes(payload);
        task.resume['video'] = DownloadPartResumeState(
          tempPath: part.path,
          downloadedBytes: payload.length,
          totalBytes: payload.length,
          streamId: 80,
          codecid: 7,
          codecs: 'avc1',
          mimeType: 'video/mp4',
        ).toJson();
        task.state = CacheTaskState.completed;
        final before = seen.length;
        final request = await client.getUrl(prepared.videoUri);
        request.headers.set('range', 'bytes=0-');
        final response = await request.close();
        expect(
          await response.fold<List<int>>([], (all, data) => all..addAll(data)),
          payload,
        );
        expect(
          seen.length,
          before,
          reason: 'an active gateway keeps using the completed local tracks',
        );
      } finally {
        client.close(force: true);
        await streaming.shutdown();
        await server.close(force: true);
      }
    },
  );

  test(
    'cloud gateway stitches the prefix without shortening an open range',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final uri = Uri.parse('http://127.0.0.1:${server.port}/file');
      final bytes = List.generate(100, (i) => i);
      final seen = <String?>[];
      server.listen((request) async {
        final range = request.headers.value('range');
        seen.add(range);
        final start = int.parse(RegExp(r'bytes=(\d+)').firstMatch(range!)![1]!);
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes $start-99/100');
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = 100 - start;
        request.response.add(bytes.sublist(start));
        await request.response.close();
      });
      final part = File(p.join(root.path, 'prefix'))
        ..writeAsBytesSync(bytes.sublist(0, 40));
      MediaCacheReadHooks.cloud = (_, target, range) => CacheFileAccess.read(
        part,
        resourceStart: 0,
        availableBytes: 40,
        total: 100,
        range: range,
        allowPrefix: true,
      );
      final gateway = CloudDriveStreamGateway();
      final descriptor = CloudDrivePlaybackDescriptor(
        upstreamUri: uri,
        transport: CloudDriveTransport.progressive,
        quality: const CloudDriveQualityChoice(
          id: 'original',
          label: '原画',
          transcoded: false,
          complete: true,
        ),
        fileId: 'file',
        revision: '1',
        complete: true,
        seekable: true,
        userAgent: '',
        referer: '',
        cookies: const [],
        providerId: 'baidu',
        remoteAccountId: 'u',
        sizeBytes: 100,
      );
      final lease = await gateway.open(
        descriptor: descriptor,
        accountLocalId: 'a',
      );
      final client = HttpClient();
      try {
        final request = await client.getUrl(lease.loopbackUri);
        request.headers.set('range', 'bytes=0-');
        final response = await request.close();
        expect(
          await response.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
          ),
          bytes,
        );
        expect(response.headers.value('content-range'), 'bytes 0-99/100');
        expect(seen, ['bytes=40-99']);
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'cloud full caches play offline with seek and deferred deletion',
    () async {
      const cloud = CacheSource(
        ref: MediaSourceRef(
          kind: MediaSourceKind.cloudDrive,
          value: 'cloud-drive://baidu/f',
          cloudDrive: CloudDriveSourceRef(
            providerId: 'baidu',
            remoteAccountId: 'u',
            driveId: '0',
            fileId: 'f',
          ),
        ),
        itemId: 'f',
        title: '离线音频.m4a',
        kind: MediaType.audio,
      );
      final bytes = List.generate(512, (i) => i % 251);
      final file = File(p.join(root.path, 'audio.m4a'))
        ..writeAsBytesSync(bytes);
      final variant = CacheVariant(
        source: cloud,
        quality: const CacheQuality(id: 'original', label: '原音质'),
        path: file.path,
        bytes: bytes.length,
        createdAt: 1,
      );
      await service.registerLegacy(variant);
      final playback = MediaCachePlayback(service);
      final prepared = (await playback.openCloud(cloud.toItem()))!;
      final client = HttpClient();
      try {
        final request = await client.getUrl(prepared.lease.loopbackUri);
        request.headers.set('range', 'bytes=128-255');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(
          await response.fold<List<int>>([], (all, data) => all..addAll(data)),
          bytes.sublist(128, 256),
        );
        await service.deleteVariant(variant.id);
        expect(file.existsSync(), isTrue);
        await prepared.lease.release();
        expect(file.existsSync(), isFalse);
      } finally {
        client.close(force: true);
        await playback.shutdown();
      }
    },
  );

  test(
    'playback waiters precede downloads within the same connection budget',
    () async {
      final pool = BilibiliMediaConnectionPool(limit: 1);
      final first = await pool.acquire();
      final order = <String>[];
      final download = pool.acquire().then((p) {
        order.add('download');
        p.release();
      });
      final play = pool.acquire(playback: true).then((p) {
        order.add('playback');
        p.release();
      });
      first.release();
      await Future.wait([download, play]);
      expect(order, ['playback', 'download']);
      expect(pool.activeConnections, 0);
    },
  );
  test(
    'server retry hints extend backoff without shortening the existing delay',
    () {
      expect(
        NetworkRecovery.retryDelay(
          RecoverableMediaHttpException(429, retryAfter: '20'),
          const Duration(seconds: 2),
        ),
        const Duration(seconds: 20),
      );
      expect(
        NetworkRecovery.retryDelay(
          RecoverableMediaHttpException(429, retryAfter: 'invalid'),
          const Duration(seconds: 2),
        ),
        const Duration(seconds: 2),
      );
    },
  );
  test('large local range streams hold a read lease until released', () async {
    final file = File(p.join(root.path, 'large'))
      ..writeAsBytesSync(List.filled(9 * 1024 * 1024, 42));
    final slice = (await CacheFileAccess.read(
      file,
      resourceStart: 0,
      availableBytes: file.lengthSync(),
      total: file.lengthSync(),
      range: 'bytes=0-',
      completeResource: true,
    ))!;
    expect(slice.completeRequest, isTrue);
    expect(slice.bytes, isEmpty);
    final deleting = CacheFileAccess.mutate(file.path, () => file.delete());
    expect(
      await slice.stream!.fold<int>(0, (sum, bytes) => sum + bytes.length),
      slice.length,
    );
    expect(file.existsSync(), isTrue);
    await slice.release!();
    await deleting;
    expect(file.existsSync(), isFalse);
    expect(CacheFileAccess.readingPaths, isEmpty);
  });
}
