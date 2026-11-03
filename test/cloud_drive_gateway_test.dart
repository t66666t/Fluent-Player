import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';

class FakeUpstream implements CloudDriveUpstreamClient {
  FakeUpstream(this._script);
  final List<int> _script;
  final List<Map<String, String>> seen = [];
  var opens = 0;

  @override
  Future<CloudDriveUpstreamResponse> open(
    CloudDriveUpstreamRequest request,
  ) async {
    final headers = request.headersFor?.call(request.uri) ?? request.headers;
    seen.add(headers);
    final status = _script[opens.clamp(0, _script.length - 1)];
    opens++;
    final range = headers['Range'];
    if (status == 200 && range != null && range != 'bytes=0-') {
      return CloudDriveUpstreamResponse(
        statusCode: 200,
        headers: {'content-type': 'video/mp4', 'content-length': '4'},
        body: Stream<List<int>>.value(utf8.encode('full')),
        close: () async {},
      );
    }
    return CloudDriveUpstreamResponse(
      statusCode: status,
      headers: {
        'content-type': 'video/mp4',
        'content-length': '4',
        if (status == 206) 'content-range': 'bytes 0-1/4',
      },
      body: Stream<List<int>>.value(
        utf8.encode(status == 200 ? 'full' : '<html>'),
      ),
      close: () async {},
    );
  }
}

CloudDrivePlaybackDescriptor sample({
  Uri? uri,
  String revision = 'v1',
  CloudDriveTransport transport = CloudDriveTransport.progressive,
}) {
  return CloudDrivePlaybackDescriptor(
    upstreamUri:
        uri ?? Uri.parse('https://d.pcs.baidu.com/file.mp4?sign=secret'),
    transport: transport,
    quality: const CloudDriveQualityChoice(
      id: 'original',
      label: '原画',
      transcoded: false,
      complete: true,
    ),
    fileId: 'file-1',
    revision: revision,
    complete: true,
    seekable: true,
    userAgent: 'pan.baidu.com',
    referer: 'https://pan.baidu.com/',
    cookies: const [
      CloudDriveCookie(
        name: 'BDUSS',
        value: 'secret-cookie',
        domain: '.baidu.com',
      ),
    ],
    providerId: 'baidu',
    accountLocalId: 'local',
    remoteAccountId: 'uk',
  );
}

class _RangeUpstream implements CloudDriveUpstreamClient {
  _RangeUpstream(this.status, this.contentRange);

  final int status;
  final String? contentRange;
  var closed = false;

  @override
  Future<CloudDriveUpstreamResponse> open(
    CloudDriveUpstreamRequest request,
  ) async => CloudDriveUpstreamResponse(
    statusCode: status,
    headers: {
      'content-type': 'video/mp4',
      'content-length': '2',
      'content-range': ?contentRange,
    },
    body: Stream<List<int>>.value([11, 12]),
    close: () async => closed = true,
  );
}

void main() {
  for (final change in ['quality', 'transport', 'size']) {
    test('renewal reopens changed $change before the first byte', () async {
      final original = sample().copyWith(sizeBytes: 1024);
      final next = switch (change) {
        'quality' => original.copyWith(
          quality: const CloudDriveQualityChoice(
            id: '720p',
            label: '720P',
            transcoded: true,
            complete: true,
          ),
        ),
        'transport' => sample(transport: CloudDriveTransport.hls),
        _ => original.copyWith(sizeBytes: 2048),
      };
      final upstream = FakeUpstream([403, 200]);
      final gateway = CloudDriveStreamGateway(
        upstream: upstream,
        refresher: (_) async => next,
      );
      final lease = await gateway.open(
        descriptor: original,
        accountLocalId: 'local',
      );
      var signals = 0;
      lease.reopenRequired.addListener(() => signals++);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(lease.loopbackUri)).close();
        await response.drain<void>();
        expect(response.statusCode, 409);
        expect(lease.needsReopen, isTrue);
        expect(signals, 1);
        expect(upstream.opens, 1);
        expect(lease.descriptor, same(original));
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
      }
    });
  }

  test(
    'a synchronous renewal exception does not poison the next read',
    () async {
      var calls = 0;
      final gateway = CloudDriveStreamGateway(
        upstream: FakeUpstream([403, 403, 200]),
        refresher: (current) {
          if (++calls == 1) {
            throw StateError('credential temporarily unavailable');
          }
          return Future.value(sample().copyWith(generation: 1));
        },
      );
      final lease = await gateway.open(
        descriptor: sample(),
        accountLocalId: 'local',
      );
      final client = HttpClient();
      try {
        final failed = await (await client.getUrl(lease.loopbackUri)).close();
        await failed.drain<void>();
        expect(failed.statusCode, 403);
        final retry = await (await client.getUrl(lease.loopbackUri)).close();
        await retry.drain<void>();
        expect(retry.statusCode, 200);
        expect(calls, 2);
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
      }
    },
  );
  test(
    'a stalled renewal is cancelled and the next read starts a fresh renewal',
    () async {
      final stale = Completer<CloudDrivePlaybackDescriptor>();
      final tokens = <CloudDriveCancelToken>[];
      final upstream = FakeUpstream([403, 403, 200]);
      final gateway = CloudDriveStreamGateway(
        upstream: upstream,
        refreshTimeout: const Duration(milliseconds: 30),
        cancellableRefresher: (current, cancel) {
          tokens.add(cancel);
          return tokens.length == 1
              ? stale.future
              : Future.value(sample().copyWith(generation: 2));
        },
      );
      final lease = await gateway.open(
        descriptor: sample(),
        accountLocalId: 'local',
      );
      final client = HttpClient();
      try {
        final first = await (await client.getUrl(
          lease.loopbackUri,
        )).close().timeout(const Duration(seconds: 1));
        await first.drain<void>();
        expect(first.statusCode, 403);
        expect(tokens.single.isCancelled, isTrue);
        final second = await (await client.getUrl(
          lease.loopbackUri,
        )).close().timeout(const Duration(seconds: 1));
        await second.drain<void>();
        expect(second.statusCode, 200);
        expect(tokens, hasLength(2));
        stale.complete(sample().copyWith(generation: 99));
        await Future<void>.delayed(Duration.zero);
        expect(lease.descriptor.generation, 2);
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
      }
    },
  );

  test('releasing a lease cancels an in-flight renewal', () async {
    final entered = Completer<CloudDriveCancelToken>();
    final late = Completer<CloudDrivePlaybackDescriptor>();
    final gateway = CloudDriveStreamGateway(
      upstream: FakeUpstream([403]),
      cancellableRefresher: (current, cancel) {
        entered.complete(cancel);
        return late.future;
      },
    );
    final lease = await gateway.open(
      descriptor: sample(),
      accountLocalId: 'local',
    );
    final client = HttpClient();
    try {
      final reading = (await client.getUrl(lease.loopbackUri)).close();
      final cancel = await entered.future;
      await lease.release();
      expect(cancel.isCancelled, isTrue);
      await (await reading.timeout(const Duration(seconds: 1))).drain<void>();
      late.complete(sample().copyWith(generation: 99));
      await Future<void>.delayed(Duration.zero);
      expect(lease.descriptor.generation, 0);
    } finally {
      client.close(force: true);
      await lease.release();
      await gateway.close();
    }
  });

  test('renewal updates the descriptor exposed by the current lease', () async {
    final gateway = CloudDriveStreamGateway(
      upstream: FakeUpstream([403, 200]),
      refresher: (current) async => sample(
        uri: Uri.parse('https://d.pcs.baidu.com/file.mp4?sign=renewed'),
      ).copyWith(generation: current.generation + 1),
    );
    final lease = await gateway.open(
      descriptor: sample(),
      accountLocalId: 'local',
    );
    // Event consumers can schedule a controlled reopen without polling.
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(lease.loopbackUri)).close();
      await response.drain<void>();
      expect(response.statusCode, 200);
      expect(lease.descriptor.generation, 1);
      expect(lease.descriptor.upstreamUri.query, 'sign=renewed');
    } finally {
      client.close(force: true);
      await lease.release();
      await gateway.close();
    }
  });

  test('range, html and cross-domain cookie stay isolated', () async {
    final upstream = FakeUpstream([206, 200, 200]);
    final gateway = CloudDriveStreamGateway(upstream: upstream);
    final lease = await gateway.open(
      descriptor: sample(),
      accountLocalId: 'local',
    );
    final head = await HttpClient().headUrl(lease.loopbackUri);
    final headResponse = await head.close();
    expect(headResponse.statusCode, 206);
    await headResponse.drain<void>();

    final ranged = await HttpClient().getUrl(lease.loopbackUri);
    ranged.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
    final rangedResponse = await ranged.close();
    expect(rangedResponse.statusCode, 200);
    await rangedResponse.drain<void>();

    expect(upstream.seen.first['Cookie'], contains('secret-cookie'));
    await lease.release();
    await gateway.close();
  });

  test('parallel 403 responses refresh the url once', () async {
    final upstream = FakeUpstream([403, 403, 200, 200]);
    var refreshes = 0;
    final gateway = CloudDriveStreamGateway(
      upstream: upstream,
      refresher: (current) async {
        refreshes++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return current.copyWith(
          upstreamUri: Uri.parse('https://d.pcs.baidu.com/file.mp4?sign=next'),
        );
      },
    );
    final lease = await gateway.open(
      descriptor: sample(),
      accountLocalId: 'local',
    );
    final first = HttpClient()
        .getUrl(lease.loopbackUri)
        .then((request) => request.close());
    final second = HttpClient()
        .getUrl(lease.loopbackUri)
        .then((request) => request.close());
    final responses = await Future.wait([first, second]);
    expect(refreshes, 1);
    expect(
      responses.map((response) => response.statusCode).toSet(),
      isNot(contains(403)),
    );
    for (final response in responses) {
      await response.drain<void>();
    }
    await lease.release();
    await gateway.close();
  });

  test('Quark HTTP 412 renews its signed address and cookie once', () async {
    final base = sample();
    final descriptor = CloudDrivePlaybackDescriptor(
      upstreamUri: Uri.parse('https://media.quark.cn/a.mp4'),
      transport: base.transport,
      quality: base.quality,
      fileId: base.fileId,
      revision: base.revision,
      complete: true,
      seekable: true,
      userAgent: base.userAgent,
      referer: 'https://pan.quark.cn/',
      cookies: const [],
      providerId: 'quark',
    );
    var refreshes = 0;
    final gateway = CloudDriveStreamGateway(
      upstream: FakeUpstream([412, 200]),
      refresher: (current) async {
        refreshes++;
        return current.copyWith(
          cookies: const [
            CloudDriveCookie(
              name: '__puus',
              value: 'renewed',
              domain: '.quark.cn',
            ),
          ],
        );
      },
    );
    final lease = await gateway.open(
      descriptor: descriptor,
      accountLocalId: 'quark',
    );
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(lease.loopbackUri)).close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      expect(refreshes, 1);
    } finally {
      client.close(force: true);
      await lease.release();
      await gateway.close();
    }
  });

  test('hls rewrite keeps signed urls off the player path', () {
    final playlist = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.key?sign=secret"
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4,
seg-1.ts
''';
    final rewritten = rewriteHlsPlaylist(
      playlist,
      Uri.parse('https://cdn.example/live/master.m3u8?sign=secret'),
      (uri) => 'http://127.0.0.1:9/cd/token/h/${uri.pathSegments.last}',
    );
    expect(rewritten.contains('sign=secret'), isFalse);
    expect(rewritten.contains('http://127.0.0.1:9/cd/token/h/key.key'), isTrue);
    expect(
      rewritten.contains('http://127.0.0.1:9/cd/token/h/seg-1.ts'),
      isTrue,
    );
  });

  test('gateway HLS addresses retain container suffixes for FFmpeg', () async {
    final gateway = CloudDriveStreamGateway(upstream: FakeUpstream([200]));
    final lease = await gateway.open(
      descriptor: sample(transport: CloudDriveTransport.hls).copyWith(
        manifest: CloudDriveManifestSnapshot(
          text:
              '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="secret.key?sign=hidden"\n'
              '#EXT-X-MAP:URI="private-init.mp4"\n#EXTINF:10,\nprivate-segment.ts?sign=hidden\n#EXT-X-ENDLIST\n',
          baseUri: Uri.parse('https://media.quark.cn/master.m3u8'),
          fetchedAt: DateTime.now().toUtc(),
        ),
      ),
      accountLocalId: 'local',
    );
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(lease.loopbackUri)).close();
      final playlist = await utf8.decoder.bind(response).join();
      expect(playlist, contains('/h/1.key'));
      expect(playlist, contains('/h/2.mp4'));
      expect(playlist, contains('/h/3.ts'));
      expect(playlist, isNot(contains('private-')));
      expect(playlist, isNot(contains('sign=')));
      final segment = playlist
          .split('\n')
          .firstWhere((line) => line.startsWith('http'));
      final streamed = await (await client.getUrl(Uri.parse(segment))).close();
      expect(
        streamed.statusCode,
        200,
        reason: 'Suffixes still resolve to their registered upstream target',
      );
      await streamed.drain<void>();
    } finally {
      client.close(force: true);
      await lease.release();
      await gateway.close();
    }
  });

  test('a changed revision is not mixed into the old stream', () async {
    final upstream = FakeUpstream([403]);
    final gateway = CloudDriveStreamGateway(
      upstream: upstream,
      refresher: (current) async => sample(revision: 'v2'),
    );
    final lease = await gateway.open(
      descriptor: sample(),
      accountLocalId: 'local',
    );
    final response = await (await HttpClient().getUrl(
      lease.loopbackUri,
    )).close();
    expect(response.statusCode, 409);
    expect(lease.needsReopen, isTrue);
    await response.drain<void>();
    await lease.release();
    await gateway.close();
  });

  test('a later range is refused when the upstream ignores Range', () async {
    final upstream = FakeUpstream([200]);
    final gateway = CloudDriveStreamGateway(upstream: upstream);
    final lease = await gateway.open(
      descriptor: sample(),
      accountLocalId: 'local',
    );
    final ranged = await HttpClient().getUrl(lease.loopbackUri);
    ranged.headers.set(HttpHeaders.rangeHeader, 'bytes=2-3');
    final response = await ranged.close();
    expect(response.statusCode, 416);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes */4');
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      isNot('bytes */*'),
    );
    await response.drain<void>();
    await lease.release();
    await gateway.close();
  });

  for (final entry in [
    (206, 'bytes 0-1/4'),
    (206, null),
    (200, 'bytes 0-1/4'),
  ]) {
    test(
      'a later cloud range rejects misaligned HTTP ${entry.$1} ${entry.$2}',
      () async {
        final upstream = _RangeUpstream(entry.$1, entry.$2);
        final gateway = CloudDriveStreamGateway(upstream: upstream);
        final lease = await gateway.open(
          descriptor: sample(),
          accountLocalId: 'local',
        );
        final client = HttpClient();
        try {
          final request = await client.getUrl(lease.loopbackUri);
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-3');
          final response = await request.close();
          expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
          final body = await response.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          );
          expect(
            body,
            isEmpty,
            reason: 'The file opening must not enter a later media position',
          );
          expect(upstream.closed, isTrue);
          if (entry.$1 == HttpStatus.partialContent) {
            expect(lease.descriptor.seekable, isTrue);
          }
        } finally {
          client.close(force: true);
          await lease.release();
          await gateway.close();
        }
      },
    );
  }

  for (final range in ['bytes=2-3', 'bytes=2-', 'bytes=-2', 'bytes=2-99']) {
    test('an aligned cloud $range still forwards its exact bytes', () async {
      final upstream = _RangeUpstream(206, 'bytes 2-3/4');
      final gateway = CloudDriveStreamGateway(upstream: upstream);
      final lease = await gateway.open(
        descriptor: sample(),
        accountLocalId: 'local',
      );
      final client = HttpClient();
      try {
        final request = await client.getUrl(lease.loopbackUri);
        request.headers.set(HttpHeaders.rangeHeader, range);
        final response = await request.close();
        expect(response.statusCode, HttpStatus.partialContent);
        expect(
          await response.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          ),
          [11, 12],
        );
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
      }
    });
  }

  test(
    'a cloud 200 with an aligned Content-Range remains compatible',
    () async {
      final upstream = _RangeUpstream(200, 'bytes 2-3/4');
      final gateway = CloudDriveStreamGateway(upstream: upstream);
      final lease = await gateway.open(
        descriptor: sample(),
        accountLocalId: 'local',
      );
      final client = HttpClient();
      try {
        final request = await client.getUrl(lease.loopbackUri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-3');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        expect(
          await response.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          ),
          [11, 12],
        );
        expect(lease.descriptor.seekable, isTrue);
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
      }
    },
  );

  test('the same lease can refresh a signature twice', () async {
    final upstream = FakeUpstream([403, 200, 403, 200]);
    var refreshes = 0;
    final gateway = CloudDriveStreamGateway(
      upstream: upstream,
      refresher: (current) async {
        refreshes++;
        return current.copyWith(
          upstreamUri: Uri.parse(
            'https://d.pcs.baidu.com/file.mp4?sign=v$refreshes',
          ),
          generation: current.generation + 1,
        );
      },
    );
    final lease = await gateway.open(
      descriptor: sample(),
      accountLocalId: 'local',
    );
    final first = await (await HttpClient().getUrl(lease.loopbackUri)).close();
    expect(first.statusCode, 200);
    await first.drain<void>();
    final second = await (await HttpClient().getUrl(lease.loopbackUri)).close();
    expect(second.statusCode, 200);
    expect(refreshes, 2);
    await second.drain<void>();
    await lease.release();
    await gateway.close();
  });

  test('hls media bytes stay binary and larger than the text cap', () async {
    final payload = Uint8List(2 * 1024 * 1024 + 32);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = i % 251;
    }
    final upstream = _RoutingUpstream(payload);
    final gateway = CloudDriveStreamGateway(upstream: upstream);
    final lease = await gateway.open(
      descriptor: sample(
        uri: Uri.parse('https://cdn.example/live/master.m3u8?sign=secret'),
        transport: CloudDriveTransport.hls,
      ),
      accountLocalId: 'local',
    );
    final playlist = await (await HttpClient().getUrl(
      lease.loopbackUri,
    )).close();
    final text = await utf8.decodeStream(playlist);
    expect(text.contains('sign=secret'), isFalse);
    expect(text.contains('#EXT-X-BYTERANGE:100@0'), isTrue);
    final key = RegExp(
      r'URI="(http://127\.0\.0\.1:\d+/cd/[^"]+)"',
    ).firstMatch(text)!.group(1)!;
    final segment = text
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.startsWith('http://'));
    final segmentResponse = await (await HttpClient().getUrl(
      Uri.parse(segment),
    )).close();
    final received = await segmentResponse.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, chunk) => builder..add(chunk),
    );
    expect(segmentResponse.statusCode, 200);
    expect(received.takeBytes(), payload);
    final keyResponse = await (await HttpClient().getUrl(
      Uri.parse(key),
    )).close();
    final keyBytes = await keyResponse.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    expect(keyBytes, [9, 8, 7, 6]);
    await lease.release();
    await gateway.close();
  });

  test('a prepared manifest is served without another upstream read', () async {
    final upstream = FakeUpstream([200]);
    final gateway = CloudDriveStreamGateway(upstream: upstream);
    final playlist = '#EXTM3U\n#EXTINF:4,\nseg.ts?sign=secret\n';
    final lease = await gateway.open(
      descriptor:
          sample(
            uri: Uri.parse(
              'https://pan.baidu.com/api/streaming?type=M3U8_AUTO_720',
            ),
            transport: CloudDriveTransport.hls,
          ).copyWith(
            manifest: CloudDriveManifestSnapshot(
              text: playlist,
              baseUri: Uri.parse(
                'https://pan.baidu.com/api/streaming?type=M3U8_AUTO_720',
              ),
              fetchedAt: DateTime.now(),
            ),
          ),
      accountLocalId: 'local',
    );
    final head = await HttpClient().headUrl(lease.loopbackUri);
    final headResponse = await head.close();
    expect(headResponse.statusCode, 200);
    expect(headResponse.contentLength, greaterThan(0));
    expect(await utf8.decodeStream(headResponse), isEmpty);
    expect(upstream.opens, 0);

    final first = await (await HttpClient().getUrl(lease.loopbackUri)).close();
    final text = await utf8.decodeStream(first);
    expect(text, contains('#EXTM3U'));
    expect(text, contains('127.0.0.1'));
    expect(text.contains('sign=secret'), isFalse);
    final second = await (await HttpClient().getUrl(lease.loopbackUri)).close();
    await second.drain<void>();
    expect(upstream.opens, 0);
    await lease.release();
    await gateway.close();
  });

  test('a mutable manifest is refreshed after the first response', () async {
    final upstream = FakeUpstream([200]);
    final gateway = CloudDriveStreamGateway(upstream: upstream);
    final lease = await gateway.open(
      descriptor:
          sample(
            uri: Uri.parse('https://cdn.example/live.m3u8'),
            transport: CloudDriveTransport.hls,
          ).copyWith(
            manifest: CloudDriveManifestSnapshot(
              text: '#EXTM3U\n#EXTINF:1,\nlive.ts\n',
              baseUri: Uri.parse('https://cdn.example/live.m3u8'),
              fetchedAt: DateTime.now(),
              mutable: true,
            ),
          ),
      accountLocalId: 'local',
    );
    final first = await (await HttpClient().getUrl(lease.loopbackUri)).close();
    expect(await utf8.decodeStream(first), contains('#EXTM3U'));
    expect(upstream.opens, 0);
    final second = await (await HttpClient().getUrl(lease.loopbackUri)).close();
    await second.drain<void>();
    expect(upstream.opens, 1);
    await lease.release();
    await gateway.close();
  });
}

class _RoutingUpstream implements CloudDriveUpstreamClient {
  _RoutingUpstream(this.segment);
  final Uint8List segment;

  @override
  Future<CloudDriveUpstreamResponse> open(
    CloudDriveUpstreamRequest request,
  ) async {
    final path = request.uri.path;
    if (path.endsWith('.m3u8')) {
      const playlist = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.key?sign=secret"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="zh",URI="sub.m3u8?sign=secret"
#EXT-X-BYTERANGE:100@0
#EXTINF:4,
seg.ts?sign=secret
''';
      return CloudDriveUpstreamResponse(
        statusCode: 200,
        headers: {'content-type': 'application/vnd.apple.mpegurl'},
        body: Stream<List<int>>.value(utf8.encode(playlist)),
        effectiveUri: Uri.parse('https://cdn.example/real/master.m3u8'),
        close: () async {},
      );
    }
    if (path.endsWith('.key')) {
      return CloudDriveUpstreamResponse(
        statusCode: 200,
        headers: {
          'content-type': 'application/octet-stream',
          'content-length': '4',
        },
        body: Stream<List<int>>.value(const [9, 8, 7, 6]),
        effectiveUri: request.uri,
        close: () async {},
      );
    }
    return CloudDriveUpstreamResponse(
      statusCode: 200,
      headers: {
        'content-type': 'video/mp2t',
        'content-length': '${segment.length}',
      },
      body: Stream<List<int>>.value(segment),
      effectiveUri: request.uri,
      close: () async {},
    );
  }
}
