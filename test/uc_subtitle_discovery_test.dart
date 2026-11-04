import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/uc_cloud_drive_provider.dart';

class _UcHttp implements CloudDriveHttp {
  _UcHttp({this.total = 3});

  final int total;
  final calls = <CloudDriveHttpRequest>[];

  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    calls.add(request);
    expect(request.uri.host, 'pc-api.uc.cn');
    expect(request.uri.queryParameters['pr'], 'UCBrowser');
    expect(request.headers['Cookie'], contains('__uid=uc-account'));
    final Object data;
    if (request.uri.path.endsWith('/file/info')) {
      expect(request.uri.queryParameters['fid'], 'video');
      data = {
        'fid': 'video',
        'pdir_fid': 'actual-parent',
        'file_name': 'Episode 01.mp4',
        'file': true,
        'category': 1,
      };
    } else {
      expect(request.uri.path, endsWith('/file/sort/extension'));
      expect(request.uri.queryParameters['pdir_fid'], 'actual-parent');
      expect(request.uri.queryParameters['file_ext'], 'srt,vtt,ass,ssa');
      data = {
        'list': [
          {'fid': 'matching', 'file_name': 'Episode 01.zh.srt'},
          {'fid': 'wrong-episode', 'file_name': 'Episode 02.zh.srt'},
          {'fid': 'unrelated', 'file_name': 'Other Movie.srt'},
        ],
      };
    }
    return CloudDriveHttpResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: utf8.encode(
        jsonEncode({
          'code': 0,
          'data': data,
          'metadata': {'_total': total},
        }),
      ),
      finalUri: request.uri,
    );
  }
}

const _request = CloudDrivePlaybackRequest(
  credential: CloudDriveCredential(
    cookies: [
      CloudDriveCookie(name: '__uid', value: 'uc-account', domain: '.uc.cn'),
    ],
  ),
  accountLocalId: 'local-account',
  remoteAccountId: 'uc-account',
  driveId: '0',
  fileId: 'video',
  // Both the hint and the editable title may be stale. UC file metadata wins.
  pathHint: '/old-folder/old-name.mp4',
  name: 'Edited title',
);

void main() {
  test(
    'UC matches siblings of the actual file without probing official AI',
    () async {
      final http = _UcHttp();
      final provider = UcCloudDriveProvider(http: http);
      final official = await provider.discoverOfficialSubtitles(_request);
      expect(official.status, CloudDriveOfficialSubtitleStatus.unsupported);
      expect(http.calls, isEmpty);

      final catalog = await provider.discoverSidecarCatalog(_request);
      expect(catalog.warning, isNull);
      expect(catalog.tracks.single.fileId, 'matching');
      expect(catalog.tracks.single.origin, CloudDriveSubtitleOrigin.sidecar);
      expect(catalog.tracks.single.autoSelect, isTrue);
      expect(http.calls, hasLength(2));
    },
  );

  test(
    'UC stops after five pages and reports that the scan is incomplete',
    () async {
      final http = _UcHttp(total: 1200);
      final catalog = await UcCloudDriveProvider(
        http: http,
      ).discoverSidecarCatalog(_request);
      final pages = http.calls
          .where((call) => call.uri.path.endsWith('/extension'))
          .map((call) => call.uri.queryParameters['_page']);
      expect(pages, ['1', '2', '3', '4', '5']);
      expect(catalog.warning, contains('前 5 页'));
    },
  );
}
