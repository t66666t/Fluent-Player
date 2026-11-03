import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_response.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final cancel in [false, true]) {
    test(
      'a ${cancel ? 'cancelled' : 'timed-out'} opening disposes its late socket',
      () async {
        HttpOverrides.global = null;
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final release = Completer<void>(),
            gone = Completer<void>(),
            stop = Completer<void>();
        final sockets = <Socket>[];
        server.listen((socket) {
          final first = sockets.isEmpty;
          sockets.add(socket);
          socket.listen(
            (bytes) {
              socket.write(
                'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}',
              );
              socket.close();
            },
            onDone: () {
              if (first && !gone.isCompleted) gone.complete();
            },
            onError: (Object _) {
              if (first && !gone.isCompleted) gone.complete();
            },
          );
        });
        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        client.connectionFactory = (uri, _, _) async {
          await release.future;
          return Socket.startConnect('127.0.0.1', server.port);
        };
        addTearDown(() async {
          client.close(force: true);
          for (final socket in sockets) {
            socket.destroy();
          }
          await server.close();
        });
        final uri = Uri.parse('http://127.0.0.1:${server.port}/request');
        final pending = openNetworkRequest(
          client,
          'GET',
          uri,
          timeout: cancel
              ? const Duration(seconds: 5)
              : const Duration(milliseconds: 20),
          cancelSignal: cancel ? stop.future : null,
          cancellationError: StateError('cancelled'),
        );
        final rejected = expectLater(
          pending,
          throwsA(cancel ? isA<StateError>() : isA<TimeoutException>()),
        );
        if (cancel) stop.complete();
        await rejected;
        release.complete();
        await gone.future.timeout(const Duration(seconds: 1));
        final request = await openNetworkRequest(
          client,
          'GET',
          uri,
          timeout: const Duration(seconds: 1),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        expect((await readNetworkResponseBytes(response)).length, 2);
      },
    );
  }
}
