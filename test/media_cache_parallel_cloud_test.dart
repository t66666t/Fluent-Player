import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_materialization.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/bilibili/media_connection_pool.dart';

void main() {
  test(
    'cloud original uses bounded parallel ranges with real byte progress and exact output',
    () async {
      final root = await Directory.systemTemp.createTemp('media_cache_ranges_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var active = 0, maxActive = 0;
      final seen = <String?>[];
      final bytes = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);
      server.listen((request) async {
        final range = request.headers.value('range');
        seen.add(range);
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range ?? '');
        final start = match == null ? 0 : int.parse(match[1]!);
        final end = match == null || match[2]!.isEmpty
            ? bytes.length - 1
            : int.parse(match[2]!);
        request.response.statusCode = match == null ? 200 : 206;
        request.response.headers.set('etag', '"v1"');
        if (match != null) {
          request.response.headers.set(
            'content-range',
            'bytes $start-$end/${bytes.length}',
          );
        }
        request.response.contentLength = end - start + 1;
        if (end > 0) {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        request.response.add(bytes.sublist(start, end + 1));
        await request.response.close();
        if (end > 0) active--;
      });
      final pool = BilibiliMediaConnectionPool(limit: 3);
      final service = CloudDriveMaterialization(
        cacheRoot: root,
        maxParallelSegments: 4,
        connectionPool: pool,
        retryDelays: [Duration.zero],
        resolveOverride: (_) async => CloudDriveDownloadSource(
          uri: Uri.parse('http://127.0.0.1:${server.port}/media'),
          transport: CloudDriveTransport.progressive,
          providerId: 'quark',
          remoteAccountId: 'u',
          driveId: '0',
          fileId: 'f',
          revision: 'v1',
          representation: 'original',
          sizeBytes: bytes.length,
        ),
      );
      final item = VideoItem(
        id: 'item',
        path: 'cloud-drive://quark/f',
        title: 'large.mp4',
        lastUpdated: 0,
        durationMs: 0,
        sourceRef: const MediaSourceRef(
          kind: MediaSourceKind.cloudDrive,
          value: 'cloud-drive://quark/f',
          cloudDrive: CloudDriveSourceRef(
            providerId: 'quark',
            remoteAccountId: 'u',
            driveId: '0',
            fileId: 'f',
            revision: 'v1',
            preferredQuality: 'original',
          ),
        ),
      );
      final progress = <MediaMaterializationProgress>[];
      try {
        final lease = await service.acquire(
          item,
          MediaMaterializationRequirement.completeMedia,
          onProgress: progress.add,
        );
        expect(await File(lease.requiredVideoPath).readAsBytes(), bytes);
        final manifest =
            jsonDecode(
                  await File(
                    '${File(lease.requiredVideoPath).parent.path}/manifest.json',
                  ).readAsString(),
                )
                as Map;
        expect(manifest['sha256'], sha256.convert(bytes).toString());
        expect(
          progress.any((p) => p.stage == MediaMaterializationStage.verifying),
          isFalse,
        );
        expect(maxActive, inInclusiveRange(2, 3));
        expect(seen, hasLength(5));
        expect(progress.last.receivedBytes, bytes.length);
        expect(
          progress.any(
            (p) => p.totalBytes == bytes.length && p.receivedBytes > 0,
          ),
          isTrue,
        );
        expect(pool.activeConnections, 0);
        await lease.release();
      } finally {
        await service.prepareStorageMigration();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'ignored range probe falls back to one full request without mixing bytes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'media_cache_range_fallback_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = List.filled(2 * 1024 * 1024, 13);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = 200;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final item = VideoItem(
        id: 'fallback',
        path: 'remote',
        title: 'x',
        lastUpdated: 0,
        durationMs: 0,
      );
      final service = CloudDriveMaterialization(
        cacheRoot: root,
        maxParallelSegments: 4,
        resolveOverride: (_) async => CloudDriveDownloadSource(
          uri: Uri.parse('http://127.0.0.1:${server.port}/media'),
          transport: CloudDriveTransport.progressive,
          providerId: 'baidu',
          remoteAccountId: 'u',
          driveId: '0',
          fileId: 'f',
          revision: 'v1',
          representation: 'original',
          sizeBytes: bytes.length,
        ),
      );
      try {
        final lease = await service.acquire(
          item,
          MediaMaterializationRequirement.completeMedia,
        );
        expect(await File(lease.requiredVideoPath).readAsBytes(), bytes);
        expect(requests, 2);
        await lease.release();
      } finally {
        await service.prepareStorageMigration();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
}
