import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/baidu_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/quark_cloud_drive_provider.dart';

class ScriptedHttp implements CloudDriveHttp {
  ScriptedHttp(this._pages);
  final List<CloudDriveHttpResponse> _pages;
  final List<Uri> uris = [];

  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    uris.add(request.uri);
    if (_pages.isEmpty) {
      throw StateError('no scripted response for ${request.uri}');
    }
    return _pages.removeAt(0);
  }
}

/// Answers by path so an original probe and a transcode candidate can overlap.
class _RoutedBaiduHttp implements CloudDriveHttp {
  final List<Uri> uris = [];

  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    uris.add(request.uri);
    final path = request.uri.path;
    if (path.contains('filemetas')) {
      final withLink = request.uri.query.contains('dlink=1');
      return jsonResponse({
        'errno': 0,
        'info': [
          {
            'fs_id': 1,
            'server_filename': 'a.mp4',
            'path': '/course/a.mp4',
            if (withLink) 'dlink': 'https://d.pcs.baidu.com/file.mp4?sign=secret',
            'size': 100,
            'duration': 3600,
            'category': 1,
            'md5': 'abc',
          },
        ],
      });
    }
    if (path.contains('streaming')) {
      final type = request.uri.queryParameters['type'] ?? 'unknown';
      return CloudDriveHttpResponse(
        statusCode: 200,
        headers: {'content-type': 'application/vnd.apple.mpegurl'},
        body: utf8.encode('#EXTM3U\n#EXTINF:3600,\nseg.ts\n'),
        finalUri: Uri.parse('https://pan.baidu.com/api/streaming?type=$type'),
      );
    }
    return CloudDriveHttpResponse(
      statusCode: 206,
      headers: {
        'content-type': 'video/mp4',
        'content-range': 'bytes 0-1/100',
        'accept-ranges': 'bytes',
      },
      body: const [0, 1],
      finalUri: request.uri,
    );
  }
}

CloudDriveHttpResponse jsonResponse(Object body, {int status = 200, Map<String, String>? headers}) {
  return CloudDriveHttpResponse(
    statusCode: status,
    headers: {'content-type': 'application/json', ...?headers},
    body: utf8.encode(jsonEncode(body)),
    finalUri: Uri.parse('https://example.test/response'),
  );
}

CloudDriveCredential baiduJar() => CloudDriveCredential(
  cookies: [
    CloudDriveCookie(name: 'BDUSS', value: 'secret', domain: '.baidu.com'),
  ],
);

void main() {
  test('baidu pages, empty folder and auth errors', () async {
    final http = ScriptedHttp([
      jsonResponse({
        'errno': 0,
        'login_info': {'uk': 42, 'username': '甲'},
      }),
      jsonResponse({'errno': 0, 'list': []}),
      jsonResponse({
        'errno': 0,
        'list': List.generate(
          100,
          (index) => {
            'fs_id': index + 1,
            'server_filename': index == 0 ? '测试 文件.mp4' : 'item$index',
            'path': '/测试 文件.mp4',
            'isdir': index == 1 ? 1 : 0,
            'category': index == 0 ? 1 : 6,
            'size': 10,
          },
        ),
      }),
      jsonResponse({'errno': -6}),
      jsonResponse({'errno': 31066}),
      jsonResponse({'errno': 0, 'info': []}),
      jsonResponse({'errno': 31326}),
      jsonResponse({'errno': 31326}),
      jsonResponse({'errno': 31326}),
      jsonResponse({'errno': 31034}),
    ]);
    final provider = BaiduCloudDriveProvider(http: http);
    final session = await provider.verifySession(baiduJar());
    expect(session.remoteAccountId, '42');
    final page = await provider.listChildren(
      CloudDriveListRequest(
        credential: baiduJar(),
        accountLocalId: 'local',
        remoteAccountId: '42',
        driveId: '0',
        parentFileId: '/',
      ),
    );
    expect(page.entries.first.name, '测试 文件.mp4');
    expect(page.hasMore, isTrue);
    expect(
      provider.listChildren(
        CloudDriveListRequest(
          credential: baiduJar(),
          accountLocalId: 'local',
          remoteAccountId: '42',
          driveId: '0',
          parentFileId: '/',
        ),
      ),
      throwsA(
        isA<CloudDriveFailure>().having(
          (error) => error.kind,
          'kind',
          CloudDriveFailureKind.notLoggedIn,
        ),
      ),
    );
    await expectLater(
      provider.getFile(
        CloudDriveFileRequest(
          credential: baiduJar(),
          accountLocalId: 'local',
          remoteAccountId: '42',
          driveId: '0',
          fileId: '1',
        ),
      ),
      throwsA(
        isA<CloudDriveFailure>().having(
          (error) => error.kind,
          'kind',
          CloudDriveFailureKind.fileMissing,
        ),
      ),
    );
    expect(
      () => provider.resolvePlayback(
        CloudDrivePlaybackRequest(
          credential: baiduJar(),
          accountLocalId: 'local',
          remoteAccountId: '42',
          driveId: '0',
          fileId: '1',
          pathHint: '/a.mp4',
        ),
      ),
      throwsA(
        isA<CloudDriveFailure>().having(
          (error) => error.kind,
          'kind',
          CloudDriveFailureKind.transcoding,
        ),
      ),
    );
  });

  test('preview playlist is not a full baidu stream', () {
    final playlist = '#EXTM3U\n#EXTINF:10,\nseg.ts\n';
    expect(baiduPlaylistLooksLikePreview(playlist, 10 * 60 * 1000), isTrue);
  });

  test('quark maps rate limit and keeps two pages', () async {
    final http = ScriptedHttp([
      jsonResponse({
        'code': 0,
        'status': 200,
        'data': {'uid': 'q1', 'nick_name': '夸克'},
      }),
      jsonResponse({
        'code': 0,
        'status': 200,
        'data': {'list': []},
        'metadata': {'_total': 0},
      }),
      jsonResponse({
        'code': 0,
        'status': 200,
        'data': {
          'list': [
            {'fid': 'f1', 'file_name': 'a.mp4', 'file_type': 1, 'category': 1, 'size': 3},
          ],
        },
        'metadata': {'_total': 150, '_page': 1},
      }),
      jsonResponse({'code': 429, 'status': 429, 'message': 'too many'}),
    ]);
    final provider = QuarkCloudDriveProvider(http: http);
    final session = await provider.verifySession(
      CloudDriveCredential(
        cookies: [
          CloudDriveCookie(name: '__puus', value: 's', domain: '.quark.cn'),
        ],
      ),
    );
    expect(session.remoteAccountId, 'q1');
    final page = await provider.listChildren(
      CloudDriveListRequest(
        credential: CloudDriveCredential(cookies: const []),
        accountLocalId: 'local',
        remoteAccountId: 'q1',
        driveId: '0',
        parentFileId: '0',
      ),
    );
    expect(page.hasMore, isTrue);
    expect(page.entries.single.kind, CloudDriveEntryKind.video);
    expect(
      provider.listChildren(
        CloudDriveListRequest(
          credential: CloudDriveCredential(cookies: const []),
          accountLocalId: 'local',
          remoteAccountId: 'q1',
          driveId: '0',
          parentFileId: '0',
        ),
      ),
      throwsA(
        isA<CloudDriveFailure>().having(
          (error) => error.kind,
          'kind',
          CloudDriveFailureKind.rateLimited,
        ),
      ),
    );
  });

  test('baidu errno depends on which api returned it', () {
    expect(
      baiduApiFailure('streaming', {'errno': 31023})!.kind,
      CloudDriveFailureKind.unavailable,
    );
    expect(
      baiduApiFailure('streaming', {'errno': 31341})!.kind,
      CloudDriveFailureKind.entitlement,
    );
    expect(
      baiduApiFailure('filemetas', {'errno': 31341})!.kind,
      CloudDriveFailureKind.unavailable,
    );
    expect(
      baiduApiFailure('login', {'errno': -6})!.kind,
      CloudDriveFailureKind.notLoggedIn,
    );
    expect(
      baiduPlaylistLooksLikePreview(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvariant.m3u8\n',
        60 * 60 * 1000,
      ),
      isFalse,
    );
    expect(
      baiduPlaylistLooksLikePreview('#EXTM3U\n#EXTINF:10,\nseg.ts\n', null),
      isFalse,
    );
  });

  test('original baidu media still discovers other rungs', () async {
    final http = _RoutedBaiduHttp();
    final provider = BaiduCloudDriveProvider(http: http);
    final request = CloudDrivePlaybackRequest(
      credential: baiduJar(),
      accountLocalId: 'local',
      remoteAccountId: '42',
      driveId: '0',
      fileId: '1',
      pathHint: '/course/a.mp4',
      name: 'a.mp4',
    );
    final playback = await provider.resolvePlayback(request);
    expect(playback.quality.id, 'original');
    expect(playback.durationMs, 3600 * 1000);
    expect(playback.mediaKind, CloudDriveMediaKind.video);
    expect(
      http.uris.where((uri) => uri.path.contains('filemetas')).first.query,
      contains('dlink=1'),
    );
    final discovered = await provider.discoverQualities(request);
    expect(discovered.map((item) => item.id), [
      'original',
      'M3U8_AUTO_1080',
      'M3U8_AUTO_720',
      'M3U8_AUTO_480',
    ]);
    expect(discovered.every((item) => item.selectable), isTrue);
  });

  test('an explicit baidu quality is the only one resolved', () async {
    final http = ScriptedHttp([
      jsonResponse({
        'errno': 0,
        'info': [
          {
            'path': '/course/a.mp4',
            'duration': 3600,
            'category': 1,
            'server_filename': 'a.mp4',
          },
        ],
      }),
      CloudDriveHttpResponse(
        statusCode: 200,
        headers: {'content-type': 'application/vnd.apple.mpegurl'},
        body: utf8.encode('#EXTM3U\n#EXTINF:3600,\nseg.ts\n'),
        finalUri: Uri.parse('https://pan.baidu.com/api/streaming?type=M3U8_AUTO_720'),
      ),
    ]);
    final provider = BaiduCloudDriveProvider(http: http);
    final playback = await provider.resolvePlayback(
      CloudDrivePlaybackRequest(
        credential: baiduJar(),
        accountLocalId: 'local',
        remoteAccountId: '42',
        driveId: '0',
        fileId: '1',
        pathHint: '/course/a.mp4',
        name: 'a.mp4',
        preferredQualityId: 'M3U8_AUTO_720',
      ),
    );
    expect(playback.quality.id, 'M3U8_AUTO_720');
    expect(playback.verifiedComplete, isTrue);
    expect(http.uris.any((uri) => uri.query.contains('dlink=1')), isFalse);
    expect(http.uris.any((uri) => uri.query.contains('dlink=0')), isTrue);
    expect(http.uris.any((uri) => uri.query.contains('M3U8_AUTO_1080')), isFalse);
    expect(http.uris.any((uri) => uri.query.contains('M3U8_AUTO_720')), isTrue);
  });

  test('baidu audio uses the original file and sidecars stay matchable', () async {
    final http = ScriptedHttp([
      jsonResponse({
        'errno': 0,
        'info': [
          {
            'fs_id': 9,
            'server_filename': 'song.mp3',
            'path': '/music/song.mp3',
            'dlink': 'https://d.pcs.baidu.com/song.mp3?sign=secret',
            'size': 40,
            'duration': 180,
            'category': 2,
          },
        ],
      }),
      CloudDriveHttpResponse(
        statusCode: 206,
        headers: {'content-type': 'audio/mpeg', 'accept-ranges': 'bytes'},
        body: const [0, 1],
        finalUri: Uri.parse('https://d.pcs.baidu.com/song.mp3?sign=secret'),
      ),
      jsonResponse({
        'errno': 0,
        'info': [
          {'path': '/music/song.mp3', 'category': 2, 'server_filename': 'song.mp3'},
        ],
      }),
      CloudDriveHttpResponse(
        statusCode: 200,
        headers: {'content-type': 'text/html'},
        body: utf8.encode('<html>{"bdstoken":"token-a"}</html>'),
        finalUri: Uri.parse('https://pan.baidu.com/disk/main'),
      ),
      CloudDriveHttpResponse(
        statusCode: 200,
        headers: {'content-type': 'application/x-mpegURL'},
        body: utf8.encode('#EXTM3U\n'),
        finalUri: Uri.parse(
          'https://pan.baidu.com/api/streaming?type=M3U8_SUBTITLE_SRT',
        ),
      ),
      jsonResponse({
        'errno': 0,
        'list': [
          {
            'fs_id': 9,
            'server_filename': 'song.mp3',
            'path': '/music/song.mp3',
            'isdir': 0,
            'category': 2,
          },
          {
            'fs_id': 10,
            'server_filename': 'song.srt',
            'path': '/music/song.srt',
            'isdir': 0,
            'category': 6,
          },
          {
            'fs_id': 11,
            'server_filename': 'notes.srt',
            'path': '/music/notes.srt',
            'isdir': 0,
            'category': 6,
          },
        ],
      }),
    ]);
    final provider = BaiduCloudDriveProvider(http: http);
    final request = CloudDrivePlaybackRequest(
      credential: baiduJar(),
      accountLocalId: 'local',
      remoteAccountId: '42',
      driveId: '0',
      fileId: '9',
      pathHint: '/music/song.mp3',
      name: 'song.mp3',
    );
    final playback = await provider.resolvePlayback(request);
    expect(playback.mediaKind, CloudDriveMediaKind.audio);
    expect(playback.quality.label, '原始音频');
    expect(http.uris.any((uri) => uri.path.contains('streaming')), isFalse);
    final tracks = await provider.discoverSubtitles(request);
    expect(tracks.map((track) => track.label), contains('song.srt'));
    expect(
      tracks.where((track) => track.label == 'song.srt').single.autoSelect,
      isTrue,
    );
    expect(
      tracks.where((track) => track.label == 'notes.srt').every((track) => !track.autoSelect),
      isTrue,
    );
  });

  test('baidu sidecar scan stays on five pages and json cues parse', () async {
    final pages = <CloudDriveHttpResponse>[
      jsonResponse({'errno': 0, 'info': <Object>[]}),
      CloudDriveHttpResponse(
        statusCode: 200,
        headers: {'content-type': 'text/html'},
        body: utf8.encode('<html>{"bdstoken":"token-a"}</html>'),
        finalUri: Uri.parse('https://pan.baidu.com/disk/main'),
      ),
      CloudDriveHttpResponse(
        statusCode: 200,
        headers: {'content-type': 'application/x-mpegURL'},
        body: utf8.encode('#EXTM3U\n'),
        finalUri: Uri.parse(
          'https://pan.baidu.com/api/streaming?type=M3U8_SUBTITLE_SRT',
        ),
      ),
      for (var page = 1; page <= 5; page++)
        jsonResponse({'errno': 0, 'list': <Object>[], 'has_more': 1}),
      jsonResponse({
        'body': [
          {'from': 1, 'to': 2, 'content': '台词'},
        ],
      }),
    ];
    final http = ScriptedHttp(pages);
    final provider = BaiduCloudDriveProvider(http: http);
    final request = CloudDrivePlaybackRequest(
      credential: baiduJar(),
      accountLocalId: 'local',
      remoteAccountId: '42',
      driveId: '0',
      fileId: '9',
      pathHint: '/show/episode.mp4',
      name: 'episode.mp4',
    );
    final catalog = await provider.discoverSubtitleCatalog(request);
    expect(catalog.tracks, isEmpty);
    expect(catalog.warning, contains('前 5 页'));
    expect(http.uris.where((uri) => uri.path == '/api/list'), hasLength(5));
    final text = await provider.readSubtitleText(
      CloudDriveSubtitleReadRequest(
        credential: baiduJar(),
        accountLocalId: 'local',
        remoteAccountId: '42',
        driveId: '0',
        track: CloudDriveSubtitleTrack(
          id: 'json',
          label: '平台字幕',
          format: 'json',
          origin: CloudDriveSubtitleOrigin.provider,
          remoteUri: Uri.parse('https://pan.baidu.com/sub.json'),
        ),
      ),
    );
    expect(text, contains('台词'));
  });
}
