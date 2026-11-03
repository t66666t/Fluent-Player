import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final shared in [false, true]) {
    for (final read in [false, true]) {
      test(
        '${shared ? 'shared' : 'native'} Dio closes a '
        '${read ? 'partly read' : 'unread'} body without cancelling siblings',
        () async {
          HttpOverrides.global = null;
          final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final sockets = <Socket>[];
          final gone = Completer<void>();
          origin.listen((request) async {
            if (request.uri.path == '/healthy') {
              request.response.write('ok');
              await request.response.close();
              return;
            }
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            sockets.add(socket);
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n'
              'Connection: close\r\n\r\nx',
            );
            await socket.flush();
            void closed() {
              if (!gone.isCompleted) gone.complete();
            }

            socket.listen(
              (_) {},
              onDone: closed,
              onError: (Object _) => closed(),
            );
          });
          final dio = shared ? NetworkHttp.instance.createDio() : Dio();
          final parent = CancelToken();
          addTearDown(() async {
            parent.cancel();
            dio.close(force: true);
            for (final socket in sockets) {
              socket.destroy();
            }
            await origin.close(force: true);
          });
          final base = 'http://127.0.0.1:${origin.port}';
          final response = await openCancellableDioStream(
            (child) => dio.get<ResponseBody>(
              '$base/stall',
              cancelToken: child,
              options: Options(responseType: ResponseType.stream),
            ),
            cancelToken: parent,
          );
          final healthy = dio.get<String>('$base/healthy', cancelToken: parent);
          if (read) {
            final iterator = StreamIterator(response.data!.stream);
            expect(await iterator.moveNext(), isTrue);
            await iterator.cancel();
          } else {
            await response.data!.stream.listen((_) {}).cancel();
          }
          await gone.future.timeout(const Duration(milliseconds: 700));
          expect(parent.isCancelled, isFalse);
          expect((await healthy).data, 'ok');
        },
      );
    }
  }

  test(
    'rejecting an HTTP status retains the status and closes its body',
    () async {
      HttpOverrides.global = null;
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final gone = Completer<void>();
      Socket? stalled;
      origin.listen((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        stalled = socket;
        socket.write(
          'HTTP/1.1 403 Forbidden\r\nContent-Length: 1000\r\n'
          'Connection: close\r\n\r\nx',
        );
        await socket.flush();
        void closed() {
          if (!gone.isCompleted) gone.complete();
        }

        socket.listen((_) {}, onDone: closed, onError: (Object _) => closed());
      });
      final dio = Dio();
      final parent = CancelToken();
      addTearDown(() async {
        parent.cancel();
        dio.close(force: true);
        stalled?.destroy();
        await origin.close(force: true);
      });
      await expectLater(
        openCancellableDioStream(
          (child) => dio.get<ResponseBody>(
            'http://127.0.0.1:${origin.port}/',
            cancelToken: child,
            options: Options(responseType: ResponseType.stream),
          ),
          cancelToken: parent,
        ),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.badResponse)
              .having((e) => e.response?.statusCode, 'status', 403),
        ),
      );
      expect(parent.isCancelled, isFalse);
      await gone.future.timeout(const Duration(milliseconds: 700));
    },
  );
}
