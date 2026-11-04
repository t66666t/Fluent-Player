import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/baidu_hls_hosts.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';

class _Upstream extends CloudDriveUpstreamClient {
  _Upstream(this.handler);
  final Future<CloudDriveUpstreamResponse> Function(CloudDriveUpstreamRequest)
  handler;
  final calls = <CloudDriveUpstreamRequest>[];
  @override
  Future<CloudDriveUpstreamResponse> open(CloudDriveUpstreamRequest request) {
    calls.add(request);
    return handler(request);
  }
}

Uri _segment({
  List<Object> hosts = const ['a.baidupcs.com', 'b.baidupcs.com'],
}) {
  return Uri.parse(
    'https://v2-ant.baidu.com/video/segment?sign=keep%2Bvalue%2funchanged'
    '&backhost=${Uri.encodeQueryComponent(jsonEncode(hosts))}',
  );
}

CloudDrivePlaybackDescriptor _descriptor({String provider = 'baidu'}) {
  final uri = Uri.parse('https://pan.baidu.com/api/streaming?type=1080');
  return CloudDrivePlaybackDescriptor(
    upstreamUri: uri,
    transport: CloudDriveTransport.hls,
    quality: const CloudDriveQualityChoice(
      id: '1080',
      label: '1080',
      transcoded: true,
      complete: true,
    ),
    fileId: 'file',
    revision: 'v1',
    complete: true,
    seekable: true,
    userAgent: 'pan.baidu.com',
    referer: 'https://pan.baidu.com/',
    providerId: provider,
    cookies: const [
      CloudDriveCookie(
        name: 'BDUSS',
        value: 'private-cookie',
        domain: '.baidu.com',
      ),
    ],
    manifest: CloudDriveManifestSnapshot(
      text:
          '#EXTM3U\n#EXTINF:4,\n${_segment()}\n#EXTINF:4,\n'
          '${_segment().replace(path: '/video/second', query: 'sign=second%2Bvalue')}\n#EXT-X-ENDLIST\n',
      baseUri: uri,
      fetchedAt: DateTime.now(),
    ),
  );
}

CloudDriveUpstreamResponse _media({
  int status = 200,
  int start = 0,
  Stream<List<int>>? body,
  Future<void> Function()? close,
}) => CloudDriveUpstreamResponse(
  statusCode: status,
  headers: {
    'content-type': 'video/mp2t',
    'content-length': '${4 - start}',
    'etag': 'same-segment',
    if (status == 206) 'content-range': 'bytes $start-3/4',
  },
  body: body ?? Stream.value([11, 12, 13, 14].sublist(start)),
  close: close ?? () async {},
);

Future<List<Uri>> _playlist(HttpClient client, Uri root) async {
  final response = await (await client.getUrl(root)).close();
  final text = await response.transform(utf8.decoder).join();
  return text
      .split('\n')
      .where((s) => s.startsWith('http'))
      .map(Uri.parse)
      .toList();
}

void main() {
  test('declared CDN authorities preserve the exact signed path and query', () {
    final source = _segment(
      hosts: [
        'a.baidupcs.com',
        'b.baidupcs.com:8443',
        'a.baidupcs.com',
        '127.0.0.1',
        'evil.test',
        'a.baidupcs.com.evil.test',
        'a.baidupcs.com@evil.test',
        'a.baidupcs.com/other',
      ],
    );
    final routes = baiduHlsHostCandidates(
      source,
      preferredAuthority: 'b.baidupcs.com:8443',
    );
    expect(routes.map((u) => u.authority), [
      'b.baidupcs.com:8443',
      'v2-ant.baidu.com',
      'a.baidupcs.com',
    ]);
    for (final route in routes) {
      expect(route.scheme, source.scheme);
      expect(route.path, source.path);
      expect(route.query, source.query);
    }
    for (final raw in ['not-json', '{}', 'null']) {
      final uri = source.replace(queryParameters: {'backhost': raw});
      expect(baiduHlsHostCandidates(uri), [uri]);
    }
    final foreign = source.replace(host: 'foreign.test');
    expect(baiduHlsHostCandidates(foreign), [foreign]);
  });

  test(
    'failed PCDN rotates immediately and following segments reuse the healthy host',
    () async {
      final upstream = _Upstream((request) async {
        if (request.uri.host == 'v2-ant.baidu.com') {
          throw const HttpException('connection closed');
        }
        if (request.uri.host == 'a.baidupcs.com') return _media(status: 403);
        final headers = request.headersFor!(request.uri);
        expect(headers['Cookie'], isNull);
        expect(headers['User-Agent'], 'pan.baidu.com');
        expect(headers['Range'], 'bytes=0-3');
        return _media(status: 206);
      });
      final logs = <String>[];
      final gateway = CloudDriveStreamGateway(
        upstream: upstream,
        retryDelays: const [],
        onDiagnostic: logs.add,
      );
      final lease = await gateway.open(
        descriptor: _descriptor(),
        accountLocalId: 'local',
      );
      final client = HttpClient();
      try {
        final segments = await _playlist(client, lease.loopbackUri);
        // A seek/quality switch may open a later segment before segment zero.
        // Only segment zero carries Baidu's backup list.
        for (final segment in [segments.last, segments.first]) {
          final request = await client.getUrl(segment);
          request.headers.set('Range', 'bytes=0-3');
          final response = await request.close();
          expect(response.statusCode, 206);
          expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
            11,
            12,
            13,
            14,
          ]);
        }
        expect(upstream.calls.map((r) => r.uri.host), [
          'v2-ant.baidu.com',
          'a.baidupcs.com',
          'b.baidupcs.com',
          'b.baidupcs.com',
        ]);
        expect(logs.where((s) => s.contains('host fallback')).length, 2);
        expect(logs.join('\n'), isNot(contains('private-cookie')));
        expect(logs.join('\n'), isNot(contains('keep%2B')));
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
      }
    },
  );

  test(
    'a stalled first host reserves deadline for backups and closes a late response',
    () async {
      final stalled = Completer<CloudDriveUpstreamResponse>();
      var lateClosed = false;
      final upstream = _Upstream(
        (request) async =>
            request.uri.host == 'v2-ant.baidu.com' ? stalled.future : _media(),
      );
      final gateway = CloudDriveStreamGateway(
        upstream: upstream,
        retryDelays: const [],
        headerTimeout: const Duration(milliseconds: 180),
      );
      final lease = await gateway.open(
        descriptor: _descriptor(),
        accountLocalId: 'local',
      );
      final client = HttpClient();
      try {
        final segment = (await _playlist(client, lease.loopbackUri)).first;
        final response = await (await client.getUrl(
          segment,
        )).close().timeout(const Duration(seconds: 1));
        expect(response.statusCode, 200);
        await response.drain<void>();
        expect(upstream.calls.first.cancelToken!.isCancelled, isTrue);
        expect(
          upstream.calls.first.headerTimeout,
          lessThan(gateway.headerTimeout),
        );
        stalled.complete(
          _media(
            close: () async {
              lateClosed = true;
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(lateClosed, isTrue);
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
      }
    },
  );

  test('other providers do not apply Baidu host routing', () async {
    final upstream = _Upstream((_) async => _media(status: 403));
    final gateway = CloudDriveStreamGateway(
      upstream: upstream,
      retryDelays: const [],
    );
    final lease = await gateway.open(
      descriptor: _descriptor(provider: 'quark'),
      accountLocalId: 'local',
    );
    final client = HttpClient();
    try {
      final segment = (await _playlist(client, lease.loopbackUri)).first;
      final response = await (await client.getUrl(segment)).close();
      expect(response.statusCode, 403);
      await response.drain<void>();
      expect(upstream.calls, hasLength(1));
    } finally {
      client.close(force: true);
      await lease.release();
      await gateway.close();
    }
  });

  test(
    'interrupted bodies resume the same signed segment on an alternate host',
    () async {
      var aCalls = 0;
      final upstream = _Upstream((request) async {
        final headers = request.headersFor!(request.uri);
        if (request.uri.host == 'v2-ant.baidu.com') {
          throw const HttpException('closed');
        }
        if (request.uri.host == 'a.baidupcs.com') {
          aCalls++;
          if (aCalls == 1) {
            return _media(
              body: () async* {
                yield [11, 12];
                throw const HttpException('body interrupted');
              }(),
            );
          }
          return _media(status: 503);
        }
        expect(headers['Range'], 'bytes=2-3');
        expect(headers['If-Range'], 'same-segment');
        return _media(status: 206, start: 2);
      });
      final gateway = CloudDriveStreamGateway(
        upstream: upstream,
        retryDelays: const [Duration.zero],
      );
      final lease = await gateway.open(
        descriptor: _descriptor(),
        accountLocalId: 'local',
      );
      final client = HttpClient();
      try {
        final segment = (await _playlist(client, lease.loopbackUri)).first;
        final response = await (await client.getUrl(segment)).close();
        expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
          11,
          12,
          13,
          14,
        ]);
        expect(upstream.calls.last.uri.host, 'b.baidupcs.com');
        expect(upstream.calls.last.uri.query, _segment().query);
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
      }
    },
  );
}
