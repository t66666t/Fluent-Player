import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_materialization.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_materialization_service.dart';

Future<void> _expectContentSeal(File file, List<int> expected) async {
  final manifest =
      jsonDecode(await File('${file.parent.path}/manifest.json').readAsString())
          as Map;
  expect(manifest['size'], expected.length);
  expect(manifest['sha256'], sha256.convert(expected).toString());
}

void main() {
  for (final verifyContent in [false, true]) {
    test(
      'content hashing is optional for active caches, defaults remain intact: $verifyContent',
      () async {
        final server = await _Server.bind();
        addTearDown(server.close);
        final root = await Directory.systemTemp.createTemp(
          'cloud-hash-policy-',
        );
        addTearDown(() => root.delete(recursive: true));
        final payload = [1, 2, 3, 4];
        server.handle = (request) => _sendFull(request, payload, status: 200);
        final service = CloudDriveMaterialization(
          cacheRoot: root,
          verifyContent: verifyContent,
          resolveOverride: (_) async =>
              _source(server.uri, revision: 'policy', size: payload.length),
        );
        addTearDown(service.prepareStorageMigration);
        final stages = <MediaMaterializationStage>[];
        final lease = await service.acquire(
          _item(revision: 'policy'),
          MediaMaterializationRequirement.completeMedia,
          onProgress: (p) => stages.add(p.stage),
        );
        final file = File(lease.requiredVideoPath);
        final manifest =
            jsonDecode(
                  await File(
                    '${file.parent.path}/manifest.json',
                  ).readAsString(),
                )
                as Map;
        expect(
          manifest['sha256'],
          verifyContent ? sha256.convert(payload).toString() : '',
        );
        expect(stages.contains(MediaMaterializationStage.verifying), isFalse);
        expect(await file.readAsBytes(), payload);
        await lease.release();
      },
    );
  }

  test('native results still receive a content seal before leasing', () async {
    final root = await Directory.systemTemp.createTemp('cloud-native-seal-');
    addTearDown(() => root.delete(recursive: true));
    final payload = [4, 3, 2, 1];
    final service = CloudDriveMaterialization(
      cacheRoot: root,
      resolveOverride: (_) async => _source(
        Uri.parse('https://cdn.example/media'),
        revision: 'native',
        size: payload.length,
      ),
      nativeDownload:
          (source, uri, target, {byteStart, byteLength, onBytes}) async {
            await target.writeAsBytes(payload, flush: true);
            return true;
          },
    );
    addTearDown(service.prepareStorageMigration);
    final stages = <MediaMaterializationStage>[];
    final lease = await service.acquire(
      _item(revision: 'native'),
      MediaMaterializationRequirement.completeMedia,
      onProgress: (p) => stages.add(p.stage),
    );
    await _expectContentSeal(File(lease.requiredVideoPath), payload);
    expect(stages, contains(MediaMaterializationStage.verifying));
    await lease.release();
  });

  test('same-size corruption still invalidates a temporary material', () async {
    final server = await _Server.bind();
    addTearDown(server.close);
    final root = await Directory.systemTemp.createTemp('cloud-corrupt-seal-');
    addTearDown(() => root.delete(recursive: true));
    final payload = [1, 2, 3, 4];
    var downloads = 0;
    server.handle = (request) async {
      downloads++;
      await _sendFull(request, payload, status: 200);
    };
    final service = _service(
      root,
      () => _source(server.uri, revision: 'corrupt', size: payload.length),
    );
    addTearDown(service.prepareStorageMigration);
    final item = _item(revision: 'corrupt');
    final first = await service.acquire(
      item,
      MediaMaterializationRequirement.completeMedia,
    );
    final file = File(first.requiredVideoPath);
    await _expectContentSeal(file, payload);
    await first.release();
    await file.writeAsBytes([4, 3, 2, 1], flush: true);
    final repaired = await service.acquire(
      item,
      MediaMaterializationRequirement.completeMedia,
    );
    expect(downloads, 2);
    expect(await File(repaired.requiredVideoPath).readAsBytes(), payload);
    await _expectContentSeal(File(repaired.requiredVideoPath), payload);
    await repaired.release();
  });

  for (final status in [302, 503, 403]) {
    test(
      'stalled HTTP $status body does not block material recovery',
      () async {
        final server = await _Server.bind();
        addTearDown(server.close);
        final sockets = <Socket>[];
        addTearDown(() {
          for (final socket in sockets) {
            socket.destroy();
          }
        });
        final root = await Directory.systemTemp.createTemp('cloud-status-');
        addTearDown(() => root.delete(recursive: true));
        var calls = 0, resolves = 0;
        server.handle = (request) async {
          if (++calls == 1) {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            sockets.add(socket);
            socket.write(
              'HTTP/1.1 $status Response\r\n'
              'Location: /new\r\nContent-Length: 1000\r\n'
              'Connection: close\r\n\r\nx',
            );
            await socket.flush();
            socket.listen((_) {}, onError: (Object _) {});
            return;
          }
          await _sendFull(request, [1, 2, 3, 4], status: 200);
        };
        final service = CloudDriveMaterialization(
          cacheRoot: root,
          retryDelays: [Duration.zero],
          resolveOverride: (_) async {
            resolves++;
            return _source(server.uri, revision: 'status-$status', size: 4);
          },
        );
        final item = _item(revision: 'status-$status');
        final pending = service.acquire(
          item,
          MediaMaterializationRequirement.completeMedia,
        );
        try {
          final lease = await pending.timeout(
            const Duration(milliseconds: 700),
          );
          expect(await File(lease.requiredVideoPath).readAsBytes(), [
            1,
            2,
            3,
            4,
          ]);
          expect(calls, 2);
          expect(resolves, status == 403 ? 2 : 1);
          await lease.release();
        } finally {
          service.pause(item.id);
          await pending.then<void>((_) {}, onError: (Object _) {});
        }
      },
    );
  }

  test(
    'progressive resume, ignored range, etag change and cache reuse',
    () async {
      final payload = List<int>.generate(32, (index) => index + 1);
      final server = await _Server.bind();
      addTearDown(server.close);
      var etag = 'v1';
      server.handle = (request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final start = _rangeStart(range);
        if (etag == 'v1' && start == 0) {
          etag = 'v1';
          await _sendPartial(request, payload, 0, 8, etag);
          return;
        }
        if (etag == 'v1' && start == 8) {
          await _sendFull(request, payload, status: 200);
          return;
        }
        await _sendFull(request, payload, status: 200, etag: 'v2');
      };
      final root = await Directory.systemTemp.createTemp('cloud-material');
      addTearDown(() => root.delete(recursive: true));
      final item = _item();
      final service = _service(
        root,
        () => _source(server.uri, revision: 'rev-1', size: payload.length),
      );
      final first = service.acquire(
        item,
        MediaMaterializationRequirement.completeMedia,
      );
      // The first response is only 8 bytes of a 32 byte file, then a 200 of
      // the whole file. That 200 must replace, not append.
      final lease = await first;
      final bytes = await File(lease.requiredVideoPath).readAsBytes();
      expect(bytes, payload);
      await _expectContentSeal(File(lease.requiredVideoPath), payload);
      await lease.release();
      server.requests.clear();
      final again = await service.acquire(
        item,
        MediaMaterializationRequirement.audioOnly,
      );
      expect(server.requests, isEmpty);
      expect(await File(again.requiredAudioPath).readAsBytes(), payload);
      await again.release();
    },
  );

  for (final mode in ['append', 'changed-etag', 'wrong-range']) {
    test('progressive seal follows the actual resource after $mode', () async {
      final server = await _Server.bind();
      addTearDown(server.close);
      final root = await Directory.systemTemp.createTemp('cloud-digest-$mode-');
      addTearDown(() => root.delete(recursive: true));
      final original = List<int>.filled(32, 1);
      final expected = mode == 'changed-etag'
          ? List<int>.filled(32, 2)
          : original;
      var calls = 0;
      final seen = <String?>[];
      server.handle = (request) async {
        seen.add(request.headers.value(HttpHeaders.rangeHeader));
        calls++;
        if (calls == 1) {
          await _sendPartial(request, original, 0, 8, 'old');
        } else if (calls == 2) {
          await _sendPartial(
            request,
            expected,
            mode == 'wrong-range' ? 7 : 8,
            expected.length,
            mode == 'changed-etag' ? 'new' : 'old',
          );
        } else {
          await _sendFull(request, expected, status: 200, etag: 'new');
        }
      };
      final service = _service(
        root,
        () => _source(server.uri, revision: mode, size: expected.length),
      );
      addTearDown(service.prepareStorageMigration);
      final lease = await service.acquire(
        _item(revision: mode),
        MediaMaterializationRequirement.completeMedia,
      );
      expect(await File(lease.requiredVideoPath).readAsBytes(), expected);
      await _expectContentSeal(File(lease.requiredVideoPath), expected);
      expect(calls, mode == 'append' ? 2 : 3);
      expect(seen[1], 'bytes=8-');
      if (mode != 'append') expect(seen[2], isNull);
      await lease.release();
    });
  }

  test('a source size mismatch cannot publish a temporary material', () async {
    final server = await _Server.bind();
    addTearDown(server.close);
    final root = await Directory.systemTemp.createTemp('cloud-wrong-size-');
    addTearDown(() => root.delete(recursive: true));
    server.handle = (request) => _sendFull(request, [1, 2, 3, 4], status: 200);
    final service = _service(
      root,
      () => _source(server.uri, revision: 'wrong-size', size: 8),
    );
    addTearDown(service.prepareStorageMigration);
    await expectLater(
      service.acquire(
        _item(revision: 'wrong-size'),
        MediaMaterializationRequirement.completeMedia,
      ),
      throwsA(isA<CloudDriveFailure>()),
    );
    expect(
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('manifest.json')),
      isEmpty,
    );
  });

  test(
    '416 completes only when the local length is the resource length',
    () async {
      final server = await _Server.bind();
      addTearDown(server.close);
      final full = List<int>.filled(8, 9);
      var calls = 0;
      server.handle = (request) async {
        calls++;
        if (calls == 1) {
          request.response.statusCode = 206;
          request.response.headers.set(HttpHeaders.etagHeader, '"e"');
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-7/16',
          );
          request.response.contentLength = full.length;
          request.response.add(full);
          await request.response.close();
          return;
        }
        request.response.statusCode = 416;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */8',
        );
        await request.response.close();
      };
      final root = await Directory.systemTemp.createTemp('cloud-material-416');
      addTearDown(() => root.delete(recursive: true));
      final service = _service(
        root,
        () => _source(server.uri, revision: 'rev-416', size: null),
      );
      final lease = await service.acquire(
        _item(revision: 'rev-416'),
        MediaMaterializationRequirement.videoFrames,
      );
      expect(await File(lease.requiredVideoPath).readAsBytes(), full);
      await _expectContentSeal(File(lease.requiredVideoPath), full);
      await lease.release();
    },
  );

  test(
    'signature refresh continues and a new revision does not append',
    () async {
      final server = await _Server.bind();
      addTearDown(server.close);
      final firstBody = List<int>.filled(6, 1);
      final secondBody = List<int>.filled(6, 2);
      server.handle = (request) async {
        if (request.uri.path == '/old') {
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        if (request.uri.path == '/mixed') {
          await _sendPartial(request, firstBody, 0, 3, 'old');
          return;
        }
        await _sendFull(request, secondBody, status: 200);
      };
      final root = await Directory.systemTemp.createTemp(
        'cloud-material-refresh',
      );
      addTearDown(() => root.delete(recursive: true));
      var resolveCount = 0;
      final service = CloudDriveMaterialization(
        cacheRoot: root,
        resolveOverride: (_) async {
          resolveCount++;
          if (resolveCount == 1) {
            return _source(
              server.uri.replace(path: '/old'),
              revision: 'rev-a',
              size: firstBody.length,
            );
          }
          return _source(
            server.uri.replace(path: '/new'),
            revision: 'rev-b',
            size: secondBody.length,
          );
        },
      );
      final lease = await service.acquire(
        _item(revision: 'rev-a'),
        MediaMaterializationRequirement.completeMedia,
      );
      expect(await File(lease.requiredVideoPath).readAsBytes(), secondBody);
      await _expectContentSeal(File(lease.requiredVideoPath), secondBody);
      await lease.release();
    },
  );

  test(
    'hls automatically retries missing segments and rejects a different playlist',
    () async {
      final server = await _Server.bind();
      addTearDown(server.close);
      var failSeg1 = true;
      var changed = false;
      server.handle = (request) async {
        final path = request.uri.path;
        if (path == '/index.m3u8') {
          final duration = changed ? '3.0' : '2.0';
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:5
#EXTINF:$duration,
seg0.ts
#EXTINF:$duration,
seg1.ts
#EXT-X-ENDLIST
''');
          await request.response.close();
          return;
        }
        if (path.endsWith('seg1.ts') && failSeg1) {
          failSeg1 = false;
          request.response.statusCode = 500;
          await request.response.close();
          return;
        }
        request.response.add(<int>[0x47, 1, 2, 3]);
        await request.response.close();
      };
      final root = await Directory.systemTemp.createTemp('cloud-material-hls');
      addTearDown(() => root.delete(recursive: true));
      final service = _service(
        root,
        () => _source(
          server.uri.replace(path: '/index.m3u8'),
          revision: 'hls-1',
          transport: CloudDriveTransport.hls,
        ),
      );
      final item = _item(revision: 'hls-1', quality: 'hls');
      const seg0 = 1;
      final lease = await service.acquire(
        item,
        MediaMaterializationRequirement.videoFrames,
      );
      expect(await File(lease.requiredVideoPath).readAsBytes(), <int>[
        0x47, 1, 2, 3, // seg0 kept
        0x47, 1, 2, 3,
      ]);
      expect(
        server.requests.where((path) => path.endsWith('seg0.ts')).length,
        seg0,
      );
      await lease.release();
      changed = true;
      final other = CloudDriveMaterialization(
        cacheRoot: root,
        resolveOverride: (_) async => _source(
          server.uri.replace(path: '/index.m3u8'),
          revision: 'hls-2',
          transport: CloudDriveTransport.hls,
        ),
      );
      final again = await other.acquire(
        _item(revision: 'hls-2', quality: 'hls'),
        MediaMaterializationRequirement.videoFrames,
      );
      expect(await File(again.requiredVideoPath).length(), 8);
      await again.release();
    },
  );

  test('encrypted hls stops and does not create a lease', () async {
    final server = await _Server.bind();
    addTearDown(server.close);
    server.handle = (request) async {
      request.response.write('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:2.0,
seg0.ts
#EXT-X-ENDLIST
''');
      await request.response.close();
    };
    final root = await Directory.systemTemp.createTemp('cloud-material-drm');
    addTearDown(() => root.delete(recursive: true));
    final service = _service(
      root,
      () => _source(
        server.uri.replace(path: '/locked.m3u8'),
        revision: 'drm',
        transport: CloudDriveTransport.hls,
      ),
    );
    await expectLater(
      service.acquire(
        _item(revision: 'drm', quality: 'hls'),
        MediaMaterializationRequirement.completeMedia,
      ),
      throwsA(
        isA<CloudDriveFailure>().having(
          (error) => error.message,
          'message',
          contains('加密'),
        ),
      ),
    );
  });

  test('low disk does not seal a manifest', () async {
    final server = await _Server.bind();
    addTearDown(server.close);
    server.handle = (request) async {
      await _sendFull(request, List<int>.filled(4, 3), status: 200);
    };
    final root = await Directory.systemTemp.createTemp('cloud-material-disk');
    addTearDown(() => root.delete(recursive: true));
    final service = CloudDriveMaterialization(
      cacheRoot: root,
      reserveSpace: (_) async {
        throw StateError('磁盘空间不足');
      },
      resolveOverride: (_) async =>
          _source(server.uri, revision: 'disk', size: 4),
    );
    await expectLater(
      service.acquire(
        _item(revision: 'disk'),
        MediaMaterializationRequirement.completeMedia,
      ),
      throwsA(isA<StateError>()),
    );
    final files = await root.list(recursive: true).toList();
    expect(
      files.where((entity) => entity.path.endsWith('manifest.json')),
      isEmpty,
    );
  });
}

CloudDriveMaterialization _service(
  Directory root,
  CloudDriveDownloadSource Function() source,
) {
  return CloudDriveMaterialization(
    cacheRoot: root,
    resolveOverride: (_) async => source(),
  );
}

CloudDriveDownloadSource _source(
  Uri uri, {
  required String revision,
  int? size,
  CloudDriveTransport transport = CloudDriveTransport.progressive,
}) {
  return CloudDriveDownloadSource(
    uri: uri,
    transport: transport,
    providerId: 'baidu',
    remoteAccountId: '42',
    driveId: '0',
    fileId: 'file-1',
    revision: revision,
    representation: transport == CloudDriveTransport.hls ? 'hls' : 'original',
    sizeBytes: size,
    qualityLabel: '原画',
  );
}

VideoItem _item({String revision = 'rev-1', String quality = 'original'}) {
  final cloud = CloudDriveSourceRef(
    providerId: 'baidu',
    remoteAccountId: '42',
    driveId: '0',
    fileId: 'file-1',
    revision: revision,
    preferredQuality: quality,
  );
  return VideoItem(
    id: 'card-$revision',
    path: cloudDriveLogicalUri(
      providerId: 'baidu',
      remoteAccountId: '42',
      driveId: '0',
      fileId: 'file-1',
    ),
    title: 'clip',
    durationMs: 1000,
    lastUpdated: 1,
    sourceRef: MediaSourceRef(
      value: cloud.sourceKey,
      kind: MediaSourceKind.cloudDrive,
      cloudDrive: cloud,
    ),
  );
}

int _rangeStart(String? header) {
  if (header == null) return 0;
  final match = RegExp(r'bytes=(\d+)-').firstMatch(header);
  return int.parse(match?.group(1) ?? '0');
}

Future<void> _sendPartial(
  HttpRequest request,
  List<int> payload,
  int start,
  int end,
  String etag,
) async {
  final body = payload.sublist(start, end);
  request.response.statusCode = 206;
  request.response.headers.set(HttpHeaders.etagHeader, '"$etag"');
  request.response.headers.set(
    HttpHeaders.contentRangeHeader,
    'bytes $start-${end - 1}/${payload.length}',
  );
  request.response.contentLength = body.length;
  request.response.add(body);
  await request.response.close();
}

Future<void> _sendFull(
  HttpRequest request,
  List<int> payload, {
  required int status,
  String etag = 'v1',
}) async {
  request.response.statusCode = status;
  request.response.headers.set(HttpHeaders.etagHeader, '"$etag"');
  request.response.contentLength = payload.length;
  request.response.add(payload);
  await request.response.close();
}

class _Server {
  _Server(this._server);
  final HttpServer _server;
  Future<void> Function(HttpRequest request)? handle;
  final List<String> requests = [];

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/file');

  static Future<_Server> bind() async {
    final raw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _Server(raw);
    raw.listen((request) async {
      server.requests.add(request.uri.path);
      final handler = server.handle;
      if (handler == null) {
        request.response.statusCode = 500;
        await request.response.close();
        return;
      }
      await handler(request);
    });
    return server;
  }

  Future<void> close() => _server.close(force: true);
}
