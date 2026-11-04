import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer origin;
  final sockets = <Socket>[];
  late Future<void> Function(HttpRequest) respond;
  late Completer<void> prefixSent, disconnected;

  setUp(() async {
    HttpOverrides.global = null;
    prefixSent = Completer<void>();
    disconnected = Completer<void>();
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      try {
        await respond(request);
      } catch (_) {
        // Deliberate client cancellation closes the fixture socket.
      }
    });
  });
  tearDown(() async {
    CloudDriveClientPools.discardAll();
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    await origin.close(force: true);
  });

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${origin.port}$path');
  Future<void> stall(
    HttpRequest request, {
    bool redirect = false,
    int prefixSize = 1,
  }) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    sockets.add(socket);
    socket.write(
      'HTTP/1.1 ${redirect ? '302 Found' : '200 OK'}\r\n'
      '${redirect ? 'Location: /media\r\n' : ''}'
      'Content-Length: ${prefixSize > 1000 ? 1000000 : 1000}\r\nConnection: close\r\n\r\n',
    );
    socket.add(List<int>.filled(prefixSize, 120));
    await socket.flush();
    socket.listen(
      (_) {},
      onDone: () {
        if (!disconnected.isCompleted) disconnected.complete();
      },
      onError: (Object _) {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    if (!prefixSent.isCompleted) prefixSent.complete();
  }

  test('cancelling a stalled API body releases only its response', () async {
    respond = (request) => stall(request);
    final token = CloudDriveCancelToken();
    final result = NetworkCloudDriveHttp().send(
      CloudDriveHttpRequest(method: 'GET', uri: uri('/api')),
      cancelToken: token,
    );
    final cancelled = expectLater(
      result.timeout(const Duration(milliseconds: 700)),
      throwsA(
        isA<CloudDriveFailure>().having(
          (e) => e.message,
          'message',
          contains('取消'),
        ),
      ),
    );
    await prefixSent.future;
    token.cancel();
    await cancelled;
    await disconnected.future.timeout(const Duration(seconds: 1));
    respond = (request) async {
      request.response.write('{}');
      await request.response.close();
    };
    expect(
      (await NetworkCloudDriveHttp().send(
        CloudDriveHttpRequest(method: 'GET', uri: uri('/healthy')),
      )).text,
      '{}',
    );
  });

  test(
    'cancelling before API headers returns the cancellation failure',
    () async {
      final received = Completer<void>();
      final finish = Completer<void>();
      respond = (request) async {
        received.complete();
        await finish.future;
        await request.response.close();
      };
      final token = CloudDriveCancelToken();
      final result = NetworkCloudDriveHttp().send(
        CloudDriveHttpRequest(method: 'GET', uri: uri('/headers')),
        cancelToken: token,
      );
      final cancelled = expectLater(
        result.timeout(const Duration(seconds: 2)),
        throwsA(
          isA<CloudDriveFailure>().having(
            (e) => e.message,
            'message',
            contains('取消'),
          ),
        ),
      );
      try {
        await received.future;
        token.cancel();
        await cancelled;
      } finally {
        finish.complete();
      }
    },
  );

  test('body timeout closes a stalled API response', () async {
    respond = (request) => stall(request);
    await expectLater(
      NetworkCloudDriveHttp().send(
        CloudDriveHttpRequest(
          method: 'GET',
          uri: uri('/api'),
          timeout: const Duration(milliseconds: 100),
        ),
      ),
      throwsA(isA<CloudDriveFailure>()),
    );
    await disconnected.future.timeout(const Duration(milliseconds: 700));
  });

  test('redirect ignores a stalled body and retains the probe Range', () async {
    final ranges = <String?>[];
    respond = (request) async {
      ranges.add(request.headers.value('range'));
      if (request.uri.path == '/redirect') {
        await stall(request, redirect: true);
        return;
      }
      expect(request.headers.value('authorization'), isNull);
      expect(request.headers.value('cookie'), isNull);
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 2-3/4');
      request.response.add([3, 4]);
      await request.response.close();
    };
    final response = await NetworkCloudDriveHttp()
        .send(
          CloudDriveHttpRequest(
            method: 'GET',
            uri: uri('/redirect'),
            range: (2, 3),
            readMode: CloudDriveReadMode.probe,
            maxBytes: 2,
            headers: const {'Authorization': 'private', 'Cookie': 'private'},
          ),
        )
        .timeout(const Duration(milliseconds: 700));
    expect(response.body, [3, 4]);
    expect(ranges, ['bytes=2-3', 'bytes=2-3']);
  });

  test('API body respects the remaining request deadline', () async {
    respond = (request) async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      request.response.contentLength = 2;
      request.response.write('{');
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      request.response.write('}');
      await request.response.close();
    };
    await expectLater(
      NetworkCloudDriveHttp().send(
        CloudDriveHttpRequest(
          method: 'GET',
          uri: uri('/slow'),
          timeout: const Duration(milliseconds: 240),
        ),
      ),
      throwsA(
        isA<CloudDriveFailure>().having(
          (e) => e.message,
          'message',
          contains('超时'),
        ),
      ),
    );
  });

  test('media redirects retain Range but strip unscoped credentials', () async {
    final seen = <String?>[];
    respond = (request) async {
      seen.add(request.headers.value('range'));
      if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/media');
      } else {
        expect(request.headers.value('authorization'), isNull);
        expect(request.headers.value('cookie'), isNull);
        expect(request.headers.value('x-provider-token'), isNull);
        expect(request.headers.value('if-range'), '"v1"');
        request.response.add([3, 4]);
      }
      await request.response.close();
    };
    final response = await NetworkCloudDriveUpstreamClient().open(
      CloudDriveUpstreamRequest(
        method: 'GET',
        uri: uri('/redirect'),
        headers: const {
          'Range': 'bytes=2-3',
          'If-Range': '"v1"',
          'Authorization': 'private',
          'Cookie': 'private',
          'X-Provider-Token': 'private',
        },
      ),
    );
    try {
      await response.body!.drain<void>();
      expect(seen, ['bytes=2-3', 'bytes=2-3']);
    } finally {
      await response.close();
    }
  });

  test('media cancellation closes a body waiting for its next byte', () async {
    respond = (request) => stall(request);
    final token = CloudDriveCancelToken();
    final response = await NetworkCloudDriveUpstreamClient().open(
      CloudDriveUpstreamRequest(
        method: 'GET',
        uri: uri('/media'),
        cancelToken: token,
      ),
    );
    try {
      final result = response.body!.drain<void>();
      final stopped = expectLater(
        result.timeout(const Duration(milliseconds: 700)),
        completes,
      );
      await prefixSent.future;
      token.cancel();
      await stopped;
      await disconnected.future.timeout(const Duration(seconds: 1));
    } finally {
      await response.close();
    }
  });

  test('an interrupted media body still fails without cancellation', () async {
    respond = (request) => stall(request);
    final response = await NetworkCloudDriveUpstreamClient().open(
      CloudDriveUpstreamRequest(method: 'GET', uri: uri('/media')),
    );
    try {
      final failed = expectLater(
        response.body!.drain<void>(),
        throwsA(isA<HttpException>()),
      );
      await prefixSent.future;
      sockets.single.destroy();
      await failed;
    } finally {
      await response.close();
    }
  });

  for (final prefixSize in [1, 8192, 128 * 1024]) {
    for (final disconnectFirst in [false, true]) {
      test(
        'releasing a gateway lease cleanly cancels an active media response: prefix=$prefixSize disconnected=$disconnectFirst',
        () async {
          respond = (request) => stall(request, prefixSize: prefixSize);
          final gateway = CloudDriveStreamGateway();
          addTearDown(gateway.close);
          final lease = await gateway.open(
            accountLocalId: 'uc-test',
            descriptor: CloudDrivePlaybackDescriptor(
              upstreamUri: uri('/media'),
              transport: CloudDriveTransport.progressive,
              quality: const CloudDriveQualityChoice(
                id: 'original',
                label: '原画',
                transcoded: false,
                complete: true,
              ),
              fileId: 'video',
              revision: 'r1',
              complete: true,
              seekable: true,
              userAgent: 'test',
              referer: 'http://127.0.0.1/',
              cookies: const [],
              providerId: 'uc',
              accountLocalId: 'uc-test',
              remoteAccountId: 'uc-account',
            ),
          );
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final request = await client.getUrl(lease.loopbackUri);
          final received = Completer<void>();
          final read = () async {
            try {
              final response = await request.close();
              await for (final _ in response) {
                if (!received.isCompleted) received.complete();
              }
            } on HttpException {
              // A cancelled response may end before its advertised content length.
            } on SocketException {
              // The player can disconnect while the gateway is still writing.
            }
          }();
          await prefixSent.future;
          if (prefixSize > 8192) {
            await received.future.timeout(const Duration(seconds: 2));
          }
          if (disconnectFirst) client.close(force: true);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await lease.release();
          await read.timeout(const Duration(seconds: 2));
          await disconnected.future.timeout(const Duration(seconds: 1));
        },
      );
    }
  }
}
