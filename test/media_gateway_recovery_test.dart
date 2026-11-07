import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';
import 'package:video_player_app/features/web_media/web_media_download_service.dart';
import 'package:video_player_app/features/web_media/web_media_resource.dart';
import 'package:video_player_app/services/network/recoverable_media_stream.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

import 'cloud_drive_gateway_test.dart' show sample;

class _InterruptedUpstream implements CloudDriveUpstreamClient {
  final calls = <Map<String, String>>[];
  final bytes = List.generate(16384, (i) => i % 251);
  @override
  Future<CloudDriveUpstreamResponse> open(
    CloudDriveUpstreamRequest request,
  ) async {
    final headers = request.headersFor?.call(request.uri) ?? request.headers;
    calls.add(headers);
    final first = calls.length == 1;
    final start = first ? 0 : 8192;
    Stream<List<int>> body() async* {
      if (first) {
        yield bytes.sublist(0, 8192);
        throw const SocketException('simulated network handover');
      }
      yield bytes.sublist(start);
    }

    return CloudDriveUpstreamResponse(
      statusCode: first ? 200 : 206,
      headers: {
        'etag': '"stable"',
        'content-type': 'video/mp4',
        'content-length': '${bytes.length - start}',
        if (!first)
          'content-range': 'bytes $start-${bytes.length - 1}/${bytes.length}',
      },
      body: body(),
      close: () async {},
    );
  }
}

void main() {
  setUp(() => HttpOverrides.global = null);
  test(
    'cancelled normal streaming recovery ends its pending read without a late error',
    () async {
      final waiting = Completer<void>();
      final disconnect = Completer<void>();
      var cancelled = false;
      var closes = 0;
      var reopens = 0;
      Stream<List<int>> upstream() async* {
        yield [1, 2];
        waiting.complete();
        await disconnect.future;
        throw const SocketException('connection closed during cancellation');
      }

      final result = recoverableMediaStream(
        initial: NetworkMediaResponse(
          status: 200,
          headers: const {'content-length': '4', 'etag': '"stable"'},
          body: upstream(),
          close: () async {
            closes++;
          },
        ),
        reopen: (_, _, _) async {
          reopens++;
          throw StateError('cancelled playback must not reconnect');
        },
        checkCancelled: () {
          if (cancelled) throw StateError('playback cancelled');
        },
        isCancelled: () => cancelled,
        retryDelays: const [Duration.zero],
      ).toList();
      await waiting.future;
      cancelled = true;
      disconnect.complete();
      expect(await result, [
        [1, 2],
      ]);
      expect(reopens, 0);
      expect(closes, 1);
    },
  );
  test(
    'podcast playback cache continues an interrupted chunk and reuses the completed bytes',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payload = List.generate(16384, (i) => i % 251);
      final ranges = <String?>[];
      origin.listen((request) async {
        ranges.add(request.headers.value('range'));
        if (ranges.length == 1) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 206 Partial Content\r\nContent-Type: audio/mpeg\r\n'
            'Content-Length: 16384\r\nContent-Range: bytes 0-16383/16384\r\n'
            'ETag: "stable"\r\nConnection: close\r\n\r\n',
          );
          socket.add(payload.sublist(0, 8192));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          socket.destroy();
          return;
        }
        request.response.statusCode = 206;
        request.response.headers
          ..set('content-range', 'bytes 8192-16383/16384')
          ..set('etag', '"stable"')
          ..set('content-type', 'audio/mpeg');
        request.response.contentLength = 8192;
        request.response.add(payload.sublist(8192));
        await request.response.close();
      });
      final root = await Directory.systemTemp.createTemp('podcast-handover-');
      final store = PodcastStore(sqlite3.openInMemory());
      final mediaStore = PodcastMediaStore(
        root: root,
        store: store,
        http: PodcastHttp(clientFactory: HttpClient.new),
      );
      addTearDown(() async {
        await mediaStore.close();
        store.close();
        await origin.close(force: true);
        await root.delete(recursive: true);
      });
      final media = PodcastMedia(
        url: 'http://127.0.0.1:${origin.port}/media',
        mimeType: 'audio/mpeg',
        length: payload.length,
      );
      final episode = PodcastEpisode(
        sourceFeedUrl: 'https://publisher.test/rss',
        id: 'episode',
        channelId: 'channel',
        title: 'episode',
        media: [media],
      );
      expect(await mediaStore.chunk(episode, media, 0), payload);
      expect(ranges, ['bytes=0-1048575', 'bytes=8192-16383']);
      expect(await mediaStore.chunk(episode, media, 0), payload);
      expect(ranges, hasLength(2));
    },
  );
  test(
    'retired cloud gateway refuses a restored descriptor before upstream access',
    () async {
      final upstream = _InterruptedUpstream();
      final gateway = CloudDriveStreamGateway(
        upstream: upstream,
        retryDelays: const [Duration.zero],
      );
      addTearDown(gateway.close);
      await expectLater(
        gateway.open(descriptor: sample(), accountLocalId: 'account'),
        throwsUnsupportedError,
      );
      expect(upstream.calls, isEmpty);
    },
  );

  test(
    'retired webpage relay refuses a saved media resource without a request',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      origin.listen((request) async {
        requests++;
        request.response.statusCode = 500;
        await request.response.close();
      });
      final service = WebMediaDownloadService(dio: Dio());
      addTearDown(() async {
        await service.cancel();
        service.close();
        await origin.close(force: true);
      });
      final media = WebMediaResource(
        url: 'http://127.0.0.1:${origin.port}/media',
        sourcePage: Uri.parse('http://127.0.0.1:${origin.port}/page'),
        title: 'media',
        kind: WebMediaKind.video,
        headers: {},
      );
      await expectLater(
        service.openPlaybackRelay(media),
        throwsUnsupportedError,
      );
      expect(requests, 0);
    },
  );

  for (final invalid in ['validator', 'range', 'unvalidated']) {
    test(
      'a gateway never splices unsafe bytes after reconnect: $invalid',
      () async {
        var reopened = 0;
        final output = <int>[];
        Stream<List<int>> broken() async* {
          yield [1, 2];
          throw const SocketException('handover');
        }

        final stream = recoverableMediaStream(
          initial: NetworkMediaResponse(
            status: 200,
            headers: {
              'content-length': '4',
              if (invalid != 'unvalidated') 'etag': '"old"',
            },
            body: broken(),
            close: () async {},
          ),
          retryDelays: const [Duration.zero],
          checkCancelled: () {},
          reopen: (start, end, validator) async {
            reopened++;
            return NetworkMediaResponse(
              status: 206,
              headers: {
                'content-range': invalid == 'range'
                    ? 'bytes 0-1/4'
                    : 'bytes 2-3/4',
                'etag': invalid == 'validator' ? '"new"' : '"old"',
              },
              body: Stream.value([9, 9]),
              close: () async {},
            );
          },
        );
        await expectLater(
          stream.forEach(output.addAll),
          throwsA(
            invalid == 'unvalidated'
                ? isA<SocketException>()
                : isA<FormatException>(),
          ),
        );
        expect(output, [1, 2]);
        expect(reopened, invalid == 'unvalidated' ? 0 : 1);
      },
    );
  }
}
