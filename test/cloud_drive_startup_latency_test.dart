import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/baidu_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_playback_budget.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

class _CountingHttp implements CloudDriveHttp {
  _CountingHttp(this._handler);
  final Future<CloudDriveHttpResponse> Function(CloudDriveHttpRequest request)
  _handler;
  final List<Uri> uris = [];

  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) {
    uris.add(request.uri);
    return _handler(request);
  }
}

CloudDriveHttpResponse _playlist(String type) {
  return CloudDriveHttpResponse(
    statusCode: 200,
    headers: {'content-type': 'application/vnd.apple.mpegurl'},
    body: utf8.encode('#EXTM3U\n#EXTINF:3600,\nseg.ts\n'),
    finalUri: Uri.parse('https://pan.baidu.com/api/streaming?type=$type'),
  );
}

CloudDriveCredential _jar({String value = 'secret'}) => CloudDriveCredential(
  cookies: [
    CloudDriveCookie(name: 'BDUSS', value: value, domain: '.baidu.com'),
  ],
);

CloudDrivePlaybackRequest _request({
  String? qualityId,
  String revision = 'rev-1',
  String account = '42',
  int? durationMs = 3600 * 1000,
  String cookie = 'secret',
}) {
  return CloudDrivePlaybackRequest(
    credential: _jar(value: cookie),
    accountLocalId: 'local',
    remoteAccountId: account,
    driveId: '0',
    fileId: '1',
    pathHint: '/course/a.mp4',
    name: 'a.mp4',
    durationMs: durationMs,
    preferredQualityId: qualityId,
    revision: revision,
  );
}

void main() {
  test(
    'explicit transcode with a known duration does not ask for a dlink',
    () async {
      final http = _CountingHttp((request) async {
        expect(request.uri.path.contains('filemetas'), isFalse);
        expect(request.uri.query.contains('dlink=1'), isFalse);
        return _playlist(request.uri.queryParameters['type'] ?? '');
      });
      final provider = BaiduCloudDriveProvider(http: http);
      final first = await provider.resolvePlayback(
        _request(qualityId: 'M3U8_AUTO_720'),
      );
      expect(first.quality.id, 'M3U8_AUTO_720');
      expect(first.manifest?.text, contains('#EXTM3U'));
      expect(http.uris, hasLength(1));

      final second = await provider.resolvePlayback(
        _request(qualityId: 'M3U8_AUTO_720'),
      );
      expect(second.quality.id, 'M3U8_AUTO_720');
      expect(second.manifest?.text, contains('#EXTM3U'));
      expect(http.uris, hasLength(1));
    },
  );

  test(
    'a verified rung is not reused for another account or revision',
    () async {
      final http = _CountingHttp(
        (request) async => _playlist(request.uri.queryParameters['type'] ?? ''),
      );
      final provider = BaiduCloudDriveProvider(http: http);
      await provider.resolvePlayback(_request(qualityId: 'M3U8_AUTO_720'));
      await provider.resolvePlayback(
        _request(qualityId: 'M3U8_AUTO_720', cookie: 'other-secret'),
      );
      await provider.resolvePlayback(
        _request(qualityId: 'M3U8_AUTO_720', revision: 'rev-2'),
      );
      expect(http.uris, hasLength(3));
    },
  );

  test(
    'the first verified rung is available before the ladder finishes',
    () async {
      final releaseRest = Completer<void>();
      var streaming = 0;
      final http = _CountingHttp((request) async {
        if (request.uri.path.contains('filemetas')) {
          return CloudDriveHttpResponse(
            statusCode: 200,
            headers: {'content-type': 'application/json'},
            body: utf8.encode(
              jsonEncode({
                'errno': 0,
                'info': [
                  {'path': '/course/a.mp4', 'duration': 3600, 'category': 1},
                ],
              }),
            ),
            finalUri: request.uri,
          );
        }
        streaming += 1;
        if (streaming > 1) await releaseRest.future;
        return _playlist(request.uri.queryParameters['type'] ?? '');
      });
      final provider = BaiduCloudDriveProvider(http: http);
      final discovery = provider.beginQualityDiscovery(
        _request(durationMs: null),
      );
      final first = await discovery.firstVerified.timeout(
        const Duration(seconds: 2),
      );
      expect(first?.quality.id, 'M3U8_AUTO_1080');
      expect(first?.manifest, isNotNull);
      var ladderDone = false;
      unawaited(discovery.choices.then((_) => ladderDone = true));
      await Future<void>.delayed(Duration.zero);
      expect(ladderDone, isFalse);
      releaseRest.complete();
      final all = await discovery.choices;
      expect(all.map((item) => item.id), [
        'original',
        'M3U8_AUTO_1080',
        'M3U8_AUTO_720',
        'M3U8_AUTO_480',
      ]);
      expect(all.first.availability, CloudDriveQualityAvailability.unavailable);
      expect(all.first.selectable, isFalse);
    },
  );

  test('one operation deadline caps every stage', () {
    var now = DateTime.utc(2026, 10, 17, 12);
    final budget = CloudDrivePlaybackBudget(
      total: const Duration(seconds: 30),
      clock: () => now,
      started: now,
    );
    expect(budget.remaining(cloudDriveResolveCap), cloudDriveResolveCap);
    now = now.add(const Duration(seconds: 26));
    expect(
      budget.remaining(cloudDriveInitializeCap),
      const Duration(seconds: 4),
    );
    now = now.add(const Duration(seconds: 5));
    expect(budget.remaining(cloudDriveHandoffCap), Duration.zero);
    expect(() => budget.ensure('handoff'), throwsA(isA<TimeoutException>()));
  });

  test('a timed-out stage still releases a late result', () async {
    final created = Completer<String>();
    final released = Completer<String>();
    final pending = bindCloudDriveStage<String>(
      future: created.future,
      budget: const Duration(milliseconds: 10),
      onLate: (value) async {
        released.complete(value);
      },
    );
    await expectLater(pending, throwsA(isA<TimeoutException>()));
    created.complete('lease');
    expect(await released.future, 'lease');
  });

  test(
    'cancelling one single-flight caller leaves the other running',
    () async {
      final flight = CloudDriveSingleFlight<int>();
      final started = Completer<CloudDriveCancelToken>();
      final finish = Completer<int>();
      final firstCancel = CloudDriveCancelToken();
      final secondCancel = CloudDriveCancelToken();
      final first = flight.run('meta', (token) {
        started.complete(token);
        return finish.future;
      }, caller: firstCancel);
      final second = flight.run(
        'meta',
        (token) async => 0,
        caller: secondCancel,
      );
      final token = await started.future;
      firstCancel.cancel();
      expect(token.isCancelled, isFalse);
      secondCancel.cancel();
      expect(token.isCancelled, isTrue);
      finish.complete(7);
      expect(await first, 7);
      expect(await second, 7);
    },
  );

  test('cloud profile does not copy the bilibili force-seekable probe', () {
    final hls = NativeVideoPlayerMediaKit.cloudDriveNativeOptions(
      hls: true,
      fastStart: true,
      existingLavfOptions: 'seg_max_retry=5,strict=experimental',
    );
    final progressive = NativeVideoPlayerMediaKit.cloudDriveNativeOptions(
      hls: false,
      fastStart: true,
    );
    expect(hls['network-timeout'], '12');
    expect(hls['cache-pause-initial'], 'no');
    expect(hls.containsKey('force-seekable'), isFalse);
    expect(
      hls.containsKey('demuxer-lavf-o'),
      isFalse,
      reason: 'mpv readback cannot be safely re-parsed as an option dictionary',
    );
    expect(progressive.containsKey('demuxer-lavf-probesize'), isFalse);
    expect(progressive.containsKey('force-seekable'), isFalse);
    final headers = NativeVideoPlayerMediaKit.cloudDrivePlayerHeaders(
      hls: false,
      start: const Duration(minutes: 20),
    );
    expect(
      headers[NativeVideoPlayerMediaKit.cloudDriveProfileHeader],
      'progressive',
    );
    expect(headers[NativeVideoPlayerMediaKit.fastStreamStartHeader], '1');
    expect(
      headers[NativeVideoPlayerMediaKit.startPositionMsHeader],
      '${20 * 60 * 1000}',
    );
  });

  test(
    'a shared client reuses the connection and a cancel does not stop the other',
    () async {
      final ports = <int>[];
      var clients = 0;
      final holdSlow = Completer<void>();
      final seen = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final port = request.connectionInfo?.remotePort ?? -1;
        ports.add(port);
        seen.add(
          'port=$port connection=${request.headers.value(HttpHeaders.connectionHeader)} '
          'persistent=${request.persistentConnection}',
        );
        if (request.uri.path == '/slow') {
          await holdSlow.future.timeout(const Duration(seconds: 2));
        }
        final body = utf8.encode(request.uri.path);
        request.response.persistentConnection = true;
        request.response.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
      });
      addTearDown(() async {
        if (!holdSlow.isCompleted) holdSlow.complete();
        CloudDriveClientPools.discardAll();
        await server.close(force: true);
      });

      HttpClient makeClient() {
        clients++;
        return HttpClient();
      }

      final client = CloudDriveClientPools.checkout(
        scope: 'acct',
        generation: 7,
        createClient: makeClient,
      );
      try {
        for (final path in ['/a', '/b']) {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}$path'),
          );
          request.persistentConnection = true;
          final response = await request.close();
          expect(
            response.persistentConnection,
            isTrue,
            reason: response.headers.toString(),
          );
          expect(await utf8.decodeStream(response), path);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      } finally {
        CloudDriveClientPools.release(scope: 'acct', generation: 7);
      }
      expect(clients, 1);
      expect(ports, hasLength(2));
      expect(ports[0], ports[1], reason: seen.join(' | '));

      final again = CloudDriveClientPools.checkout(
        scope: 'acct',
        generation: 7,
        createClient: makeClient,
      );
      final slow = await again.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/slow'),
      );
      final fast = await again.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/fast'),
      );
      final fastBody = fast.close().then(utf8.decodeStream);
      slow.abort();
      expect(await fastBody.timeout(const Duration(seconds: 2)), '/fast');
      holdSlow.complete();
      CloudDriveClientPools.release(scope: 'acct', generation: 7);
      expect(clients, 1);

      CloudDriveClientPools.discard(scope: 'acct', generation: 7);
      final fresh = CloudDriveClientPools.checkout(
        scope: 'acct',
        generation: 7,
        createClient: makeClient,
      );
      CloudDriveClientPools.release(scope: 'acct', generation: 7);
      fresh.close(force: true);
      expect(clients, 2);
    },
  );
}
