import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/resumable_media_download.dart';

void main() {
  setUp(() => HttpOverrides.global = null);
  for (final behavior in [
    'resume',
    'newValidator',
    'rangeIgnored',
    'noValidator',
  ]) {
    test('interrupted media download recovers safely: $behavior', () async {
      final root = await Directory.systemTemp.createTemp('media-handover-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payload = List.generate(16384, (i) => i % 251);
      final replacement = List.generate(16384, (i) => 250 - i % 251);
      final ranges = <String?>[];
      var requests = 0;
      server.listen((request) async {
        requests++;
        ranges.add(request.headers.value('range'));
        if (requests == 1) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: 16384\r\n'
            '${behavior == 'noValidator' ? '' : 'ETag: "v1"\r\n'}Connection: close\r\n\r\n',
          );
          socket.add(payload.sublist(0, 8192));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
          socket.destroy();
          return;
        }
        final changed =
            behavior == 'newValidator' || behavior == 'rangeIgnored';
        final data = changed ? replacement : payload;
        final match = RegExp(
          r'bytes=(\d+)-',
        ).firstMatch(request.headers.value('range') ?? '');
        var start = int.tryParse(match?[1] ?? '') ?? 0;
        if (behavior == 'rangeIgnored') start = 0;
        request.response.statusCode = start > 0 ? 206 : 200;
        request.response.headers.set('etag', changed ? '"v2"' : '"v1"');
        if (start > 0) {
          request.response.headers.set(
            'content-range',
            'bytes $start-${data.length - 1}/${data.length}',
          );
        }
        request.response.contentLength = data.length - start;
        request.response.add(data.sublist(start));
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final part = File('${root.path}/media.part');
      final retries = <int>[];
      await ResumableMediaDownload(
        createClient: HttpClient.new,
        retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      ).download(
        urls: [Uri.parse('http://127.0.0.1:${server.port}/media')],
        partial: part,
        headers: {},
        checkCancelled: () {},
        onRetry: (_, _) =>
            retries.add(part.existsSync() ? part.lengthSync() : 0),
      );
      expect(retries.first, 8192);
      expect(ranges[1], behavior == 'noValidator' ? isNull : 'bytes=8192-');
      expect(
        await part.readAsBytes(),
        behavior == 'newValidator' || behavior == 'rangeIgnored'
            ? replacement
            : payload,
      );
      if (behavior == 'newValidator') {
        expect(requests, 3);
        expect(ranges.last, isNull);
      } else {
        expect(requests, 2);
      }
    });
  }

  test(
    'cancelling a reconnect stops immediately; permanent 403 is not retried',
    () async {
      final root = await Directory.systemTemp.createTemp('media-cancel-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0, status = 503;
      server.listen((request) async {
        calls++;
        request.response.statusCode = status;
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      var cancelled = false;
      final downloader = ResumableMediaDownload(createClient: HttpClient.new);
      await expectLater(
        downloader.download(
          urls: [Uri.parse('http://127.0.0.1:${server.port}/media')],
          partial: File('${root.path}/media.part'),
          headers: {},
          checkCancelled: () {
            if (cancelled) throw StateError('paused');
          },
          onRetry: (_, _) => cancelled = true,
        ),
        throwsStateError,
      );
      expect(calls, 1);
      cancelled = false;
      status = 403;
      await expectLater(
        downloader.download(
          urls: [Uri.parse('http://127.0.0.1:${server.port}/media')],
          partial: File('${root.path}/media.part'),
          headers: {},
          checkCancelled: () {},
          onRetry: (_, _) =>
              fail('Permanent permission failures must not retry'),
        ),
        throwsA(isA<HttpException>()),
      );
      expect(calls, 2);
    },
  );
}
