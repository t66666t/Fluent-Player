import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer origin;
  late HttpClient client;
  late Future<void> Function(HttpRequest) respond;
  final sockets = <Socket>[];

  setUp(() async {
    HttpOverrides.global = null;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient()..findProxy = (_) => 'DIRECT';
    origin.listen((request) async {
      try {
        await respond(request);
      } catch (_) {
        // A bounded reader may close the response before its server finishes.
      }
    });
  });
  tearDown(() async {
    client.close(force: true);
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    await origin.close(force: true);
  });
  Future<HttpClientResponse> open() async => (await client.getUrl(
    Uri.parse('http://127.0.0.1:${origin.port}/'),
  )).close();

  test('compressed content is limited by its decoded size', () async {
    final encoded = gzip.encode(List<int>.filled(8192, 42));
    expect(encoded.length, lessThan(1024));
    respond = (request) async {
      request.response.headers.set('content-encoding', 'gzip');
      request.response.contentLength = encoded.length;
      request.response.add(encoded);
      await request.response.close();
    };
    await expectLater(
      readNetworkResponseBytes(await open(), maxBytes: 1024),
      throwsA(isA<FormatException>()),
    );
  });

  test('compressed length is not reported as decoded progress total', () async {
    final expected = List<int>.filled(8192, 42);
    final encoded = gzip.encode(expected);
    respond = (request) async {
      request.response.headers.set('content-encoding', 'gzip');
      request.response.contentLength = encoded.length;
      request.response.add(encoded);
      await request.response.close();
    };
    int? received;
    final result = await readNetworkResponseBytes(
      await open(),
      maxBytes: 8192,
      onBytes: (count, total) {
        received = count;
        expect(total, isNull);
      },
    );
    expect(result, expected);
    expect(received, expected.length);
  });

  test('continuous small chunks do not extend the total deadline', () async {
    final stopped = Completer<void>();
    respond = (request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      sockets.add(socket);
      void done() {
        if (!stopped.isCompleted) stopped.complete();
      }

      socket.listen((_) {}, onDone: done, onError: (Object _) => done());
      socket.write(
        'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n'
        'Connection: close\r\n\r\n',
      );
      for (var i = 0; i < 100 && !stopped.isCompleted; i++) {
        socket.add([42]);
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await socket.close();
    };
    await expectLater(
      readNetworkResponseBytes(
        await open(),
        idleTimeout: const Duration(milliseconds: 100),
        totalTimeout: const Duration(milliseconds: 150),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await stopped.future.timeout(const Duration(seconds: 1));
  });
}
