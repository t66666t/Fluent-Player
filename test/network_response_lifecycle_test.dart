import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as pixels;
import 'package:video_player_app/features/progress_sync/progress_sync_webdav.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/resumable_media_download.dart';
import 'package:video_player_app/services/network/scoped_network_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer origin;
  late Directory directory;
  final sockets = <Socket>[];
  late Completer<void> disconnected;
  late Future<void> Function(HttpRequest) respond;

  setUp(() async {
    HttpOverrides.global = null;
    disconnected = Completer<void>();
    directory = await Directory.systemTemp.createTemp('network-response-');
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      try {
        await respond(request);
      } catch (_) {}
    });
  });
  tearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    await origin.close(force: true);
    await directory.delete(recursive: true);
  });
  Uri uri(String path) => Uri.parse('http://127.0.0.1:${origin.port}$path');
  Future<void> stall(HttpRequest request, int status) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    sockets.add(socket);
    socket.write(
      'HTTP/1.1 $status Response\r\nContent-Length: 1000\r\nConnection: close\r\n\r\nx',
    );
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
  }

  test(
    'a rejected download cancels its error body without retrying 403',
    () async {
      var calls = 0;
      respond = (request) async {
        calls++;
        await stall(request, 403);
      };
      await expectLater(
        ResumableMediaDownload(createClient: HttpClient.new)
            .download(
              urls: [uri('/media')],
              partial: File('${directory.path}/media.part'),
              headers: const {},
              checkCancelled: () {},
            )
            .timeout(const Duration(milliseconds: 700)),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('403'),
          ),
        ),
      );
      expect(calls, 1);
      await disconnected.future.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'WebDAV body timeout closes its response without replaying writes',
    () async {
      var propfinds = 0;
      respond = (request) async {
        if (request.method == 'MKCOL') {
          request.response.statusCode = 201;
          await request.response.close();
        } else {
          propfinds++;
          await stall(request, 207);
        }
      };
      final sync = ProgressSyncWebDav(
        config: ProgressSyncWebDavConfig(url: uri('/dav/').toString()),
        httpClient: HttpClient()..findProxy = (_) => 'DIRECT',
        timeout: const Duration(milliseconds: 100),
      );
      try {
        await expectLater(
          sync.readChanges(),
          throwsA(isA<ProgressSyncWebDavException>()),
        );
        await disconnected.future.timeout(const Duration(milliseconds: 700));
        expect(propfinds, 1);
      } finally {
        sync.close();
      }
    },
  );

  ArtworkFetchRequest artworkRequest({
    Duration budget = const Duration(seconds: 5),
  }) => ArtworkFetchRequest(
    uri: uri('/cover'),
    headers: const {},
    maxBytes: 1024,
    connectTimeout: const Duration(seconds: 1),
    headerTimeout: const Duration(seconds: 1),
    totalBudget: budget,
    cancelled: () => false,
    scope: NetworkScope.other,
  );

  test('artwork errors discard a stalled error body immediately', () async {
    respond = (request) => stall(request, 503);
    final response = await defaultArtworkFetcher(
      artworkRequest(),
    ).timeout(const Duration(milliseconds: 700));
    expect(response.status, 503);
    expect(response.bytes, isEmpty);
    await disconnected.future.timeout(const Duration(milliseconds: 700));
  });

  test('artwork headers and body share the total time budget', () async {
    respond = (request) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await stall(request, 200);
    };
    await expectLater(
      defaultArtworkFetcher(
        artworkRequest(budget: const Duration(milliseconds: 300)),
      ),
      throwsA(
        isA<TimeoutException>().having(
          (error) => error.duration,
          'remaining time',
          lessThan(const Duration(milliseconds: 250)),
        ),
      ),
    );
    await disconnected.future.timeout(const Duration(milliseconds: 700));
  });

  test(
    'a completed image remains valid across a device network change',
    () async {
      final prefix = Completer<void>(), release = Completer<void>();
      final bytes = pixels.encodePng(pixels.Image(width: 2, height: 2));
      respond = (request) async {
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, bytes.length ~/ 2));
        await request.response.flush();
        prefix.complete();
        await release.future;
        request.response.add(bytes.sublist(bytes.length ~/ 2));
        await request.response.close();
      };
      final settings = NetworkSettingsService.instance;
      final image = ScopedNetworkImage(
        uri('/cover.png').toString(),
        scope: NetworkScope.other,
        context: RequestNetworkContext(
          scope: NetworkScope.other,
          configuration: NetworkConfiguration(),
          deviceGeneration: settings.deviceGeneration,
        ),
      );
      final completed = Completer<ImageInfo>();
      final stream = image.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (info, _) => completed.complete(info),
        onError: (Object e, StackTrace? st) => completed.completeError(e, st),
      );
      stream.addListener(listener);
      try {
        await prefix.future;
        settings.deviceNetworkChanged();
        release.complete();
        final info = await completed.future.timeout(const Duration(seconds: 2));
        expect(info.image.width, 2);
        info.dispose();
      } finally {
        if (!release.isCompleted) release.complete();
        stream.removeListener(listener);
        await image.evict();
      }
    },
  );
}
