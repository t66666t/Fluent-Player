import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_materialization.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/network/network_recovery.dart';

VideoItem _item() => VideoItem(
  id: 'baidu',
  path: 'cloud-drive://baidu/file',
  title: 'video.mp4',
  lastUpdated: 0,
  durationMs: 8000,
  sourceRef: const MediaSourceRef(
    kind: MediaSourceKind.cloudDrive,
    value: 'cloud-drive://baidu/file',
    cloudDrive: CloudDriveSourceRef(
      providerId: 'baidu',
      remoteAccountId: 'u',
      driveId: '0',
      fileId: 'file',
      revision: 'r',
      preferredQuality: 'M3U8_AUTO_720',
    ),
  ),
);

void main() {
  test(
    'Baidu downloads rotate declared CDNs, inherit backups and preserve playback resource identity',
    () async {
      final root = await Directory.systemTemp.createTemp('baidu_cdn_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final first = Uri.https('v2-ant.baidu.com', '/first', {
        'sign': 'private',
        'backhost': jsonEncode(['failed.baidupcs.com', 'healthy.baidupcs.com']),
      });
      final second = Uri.https('v2-ant.baidu.com', '/second', {
        'sign': 'private',
      });
      server.listen((request) async {
        request.response.write(
          '#EXTM3U\n#EXTINF:4,\n$first\n#EXTINF:4,\n$second\n#EXT-X-ENDLIST\n',
        );
        await request.response.close();
      });
      final calls = <Uri>[];
      final readable = <Uri>[];
      final bytes = List<int>.filled(188, 0x47);
      final service = CloudDriveMaterialization(
        cacheRoot: root,
        requireCompletePlaylist: true,
        retryDelays: const [],
        resolveOverride: (_) async => CloudDriveDownloadSource(
          uri: Uri.parse('http://127.0.0.1:${server.port}/playlist'),
          transport: CloudDriveTransport.hls,
          providerId: 'baidu',
          remoteAccountId: 'u',
          driveId: '0',
          fileId: 'file',
          revision: 'r',
          representation: 'M3U8_AUTO_720',
        ),
        nativeDownload:
            (source, uri, target, {byteStart, byteLength, onBytes}) async {
              calls.add(uri);
              if (uri.host == 'failed.baidupcs.com') {
                throw RecoverableMediaHttpException(403);
              }
              if (uri.host == 'v2-ant.baidu.com') {
                throw const HttpException('Connection closed before header');
              }
              await target.writeAsBytes(bytes, flush: true);
              onBytes?.call(bytes.length, bytes.length);
              return true;
            },
        onReadable: (source, uri, file, start, count, total, complete) {
          readable.add(uri);
        },
      );
      try {
        final lease = await service.acquire(
          _item(),
          MediaMaterializationRequirement.completeMedia,
        );
        expect(calls.map((u) => u.host), [
          'failed.baidupcs.com',
          'v2-ant.baidu.com',
          'healthy.baidupcs.com',
          'healthy.baidupcs.com',
        ]);
        expect(calls.first.query, first.query);
        expect(readable, [first, second]);
        expect(await File(lease.requiredVideoPath).length(), 376);
        await lease.release();
      } finally {
        await service.prepareStorageMigration();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'standalone Baidu MP4 segments join their timelines instead of byte concatenation',
    () async {
      final root = await Directory.systemTemp.createTemp('baidu_mp4_join_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.write(
          '#EXTM3U\n#EXTINF:4,\nhttps://v2-ant.baidu.com/first\n#EXT-X-DISCONTINUITY\n#EXTINF:4,\nhttps://v2-ant.baidu.com/second\n#EXT-X-ENDLIST\n',
        );
        await request.response.close();
      });
      final bytes = <int>[0, 0, 0, 16, ...ascii.encode('ftypisom'), 0, 0, 0, 0];
      var joins = 0;
      final service = CloudDriveMaterialization(
        cacheRoot: root,
        requireCompletePlaylist: true,
        resolveOverride: (_) async => CloudDriveDownloadSource(
          uri: Uri.parse('http://127.0.0.1:${server.port}/playlist'),
          transport: CloudDriveTransport.hls,
          providerId: 'baidu',
          remoteAccountId: 'u',
          driveId: '0',
          fileId: 'file',
          revision: 'r',
          representation: '720',
        ),
        nativeDownload:
            (source, uri, target, {byteStart, byteLength, onBytes}) async {
              await target.writeAsBytes(bytes);
              return true;
            },
        joinHlsSegments: (files, durations, output) async {
          joins++;
          expect(durations, [4000, 4000]);
          expect(files.map((f) => f.uri.pathSegments.last), [
            'seg-0.part',
            'seg-1.part',
          ]);
          for (final file in files) {
            expect(await file.readAsBytes(), bytes);
          }
          return output.writeAsBytes([...bytes, 99]);
        },
      );
      try {
        final lease = await service.acquire(
          _item(),
          MediaMaterializationRequirement.completeMedia,
        );
        expect(joins, 1);
        expect(await File(lease.requiredVideoPath).readAsBytes(), [
          ...bytes,
          99,
        ]);
        await lease.release();
      } finally {
        await service.prepareStorageMigration();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
}
