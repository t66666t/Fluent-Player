import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_preview_loader.dart';

const _rss = '''<rss version="2.0"><channel><title>Podnews test</title>
<item><title>Episode</title><guid>one</guid>
<enclosure url="https://media.test/one.mp3" type="audio/mpeg"/>
</item></channel></rss>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late String address;
  late PodcastClient client;
  late PodcastPreviewLoader loader;
  late void Function(HttpRequest request) respond;
  var calls = 0;

  void send(HttpRequest request, {int status = 200, String body = _rss}) {
    request.response.statusCode = status;
    request.response.write(body);
    unawaited(request.response.close().catchError((Object _) {}));
  }

  PodcastResolveRequest operation({Duration? budget}) {
    final value = PodcastResolveRequest(
      budget: budget ?? const Duration(seconds: 5),
    );
    addTearDown(value.dispose);
    return value;
  }

  setUp(() async {
    HttpOverrides.global = null;
    calls = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    address = 'http://127.0.0.1:${server.port}/feed.xml';
    respond = (request) => send(request);
    server.listen((request) {
      calls++;
      respond(request);
    });
    client = PodcastClient(http: PodcastHttp(clientFactory: HttpClient.new));
    loader = PodcastPreviewLoader(client: client, retryDelay: Duration.zero);
  });

  tearDown(() async => server.close(force: true));

  test(
    'a temporary source failure recovers within the same preview load',
    () async {
      respond = (request) => send(request, status: calls == 1 ? 503 : 200);
      var retries = 0;
      final result = await loader.load(
        address,
        request: operation(),
        onRetry: () => retries++,
      );
      expect(result.feed.channel.title, 'Podnews test');
      expect(calls, 2);
      expect(retries, 1);
    },
  );

  test('ordinary RSS reads do not acquire preview retries', () async {
    respond = (request) => send(request, status: 503);
    await expectLater(client.resolve(address), throwsA(isA<HttpException>()));
    expect(calls, 1);
  });

  test('repeated temporary failures stop after three attempts', () async {
    respond = (request) => send(request, status: 502);
    await expectLater(
      loader.load(address, request: operation()),
      throwsA(isA<PodcastHttpStatusException>()),
    );
    expect(calls, 3);
    expect(loader.cached(address), isNull);
  });

  for (final status in [401, 403, 404, 410]) {
    test('HTTP $status is reported without retrying', () async {
      respond = (request) => send(request, status: status);
      await expectLater(
        loader.load(address, request: operation()),
        throwsA(
          isA<PodcastHttpStatusException>().having(
            (error) => error.status,
            'status',
            status,
          ),
        ),
      );
      expect(calls, 1);
    });
  }

  test('invalid content is not retried or cached', () async {
    respond = (request) => send(request, body: '<html>No feed here</html>');
    await expectLater(
      loader.load(address, request: operation()),
      throwsFormatException,
    );
    expect(calls, 1);
    expect(loader.cached(address), isNull);
  });

  for (final useDate in [false, true]) {
    test(
      'a long Retry-After ${useDate ? 'date' : 'delay'} is respected',
      () async {
        respond = (request) {
          request.response.headers.set(
            HttpHeaders.retryAfterHeader,
            useDate
                ? HttpDate.format(
                    DateTime.now().add(const Duration(minutes: 2)),
                  )
                : '120',
          );
          send(request, status: 429);
        };
        await expectLater(
          loader.load(address, request: operation()),
          throwsA(isA<PodcastHttpStatusException>()),
        );
        expect(calls, 1);
      },
    );
  }

  test('a source permitting an immediate retry recovers', () async {
    respond = (request) {
      request.response.headers.set(HttpHeaders.retryAfterHeader, '0');
      send(request, status: calls == 1 ? 429 : 200);
    };
    await loader.load(address, request: operation());
    expect(calls, 2);
  });

  test('an explicitly offline device sends no source requests', () async {
    loader = PodcastPreviewLoader(
      client: client,
      readConnectivity: () async => [ConnectivityResult.none],
    );
    await expectLater(
      loader.load(address, request: operation()),
      throwsA(isA<PodcastPreviewOffline>()),
    );
    expect(calls, 0);
  });

  test('losing the network stops automatic retries', () async {
    loader = PodcastPreviewLoader(
      client: client,
      readConnectivity: () async => [
        calls == 0 ? ConnectivityResult.wifi : ConnectivityResult.none,
      ],
    );
    respond = (request) => send(request, status: 503);
    await expectLater(
      loader.load(address, request: operation()),
      throwsA(isA<PodcastPreviewOffline>()),
    );
    expect(calls, 1);
  });

  test(
    'a failed connectivity detector still permits an actual request',
    () async {
      loader = PodcastPreviewLoader(
        client: client,
        readConnectivity: () async => throw StateError('detector unavailable'),
      );
      await loader.load(address, request: operation());
      expect(calls, 1);
    },
  );

  test('a stalled detector is bounded by the total request budget', () async {
    loader = PodcastPreviewLoader(
      client: client,
      readConnectivity: () => Completer<List<ConnectivityResult>>().future,
    );
    await expectLater(
      loader.load(
        address,
        request: operation(budget: const Duration(milliseconds: 60)),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(calls, 0);
  });

  test('a connected device with an unresponsive source times out', () async {
    final started = Completer<void>();
    respond = (_) => started.complete();
    final request = operation(budget: const Duration(milliseconds: 150));
    final loading = loader.load(address, request: request);
    final assertion = expectLater(loading, throwsA(isA<TimeoutException>()));
    await started.future;
    await assertion;
    expect(calls, 1);
  });

  test(
    'leaving the preview cancels a waiting source and does not cache it',
    () async {
      final started = Completer<void>();
      respond = (_) => started.complete();
      final request = operation();
      final assertion = expectLater(
        loader.load(address, request: request),
        throwsA(isA<PodcastResolveCancelled>()),
      );
      await started.future;
      request.cancel();
      await assertion;
      expect(calls, 1);
      expect(loader.cached(address), isNull);
    },
  );

  test('cancelling during backoff prevents another attempt', () async {
    loader = PodcastPreviewLoader(client: client);
    respond = (request) => send(request, status: 503);
    final request = operation();
    await expectLater(
      loader.load(address, request: request, onRetry: request.cancel),
      throwsA(isA<PodcastResolveCancelled>()),
    );
    expect(calls, 1);
  });

  test(
    'cache survives failed refreshes and isolates mutable preview data',
    () async {
      final result = await loader.load(address, request: operation());
      result.feed.channel.nextPage = 'https://other.test/page';
      result.feed.episodes.clear();
      final cached = loader.cached(address)!;
      expect(cached.feed.episodes, hasLength(1));
      expect(cached.feed.channel.nextPage, isNull);
      cached.feed.channel.title = 'Mutated by a page';
      cached.feed.episodes.clear();
      respond = (request) => send(request, status: 503);
      await expectLater(
        loader.load(address, request: operation()),
        throwsA(isA<HttpException>()),
      );
      expect(loader.cached(address)!.feed.channel.title, 'Podnews test');
      expect(loader.cached(address)!.feed.episodes, hasLength(1));
      expect(loader.cached('$address?different'), isNull);
    },
  );

  test(
    'cache is bounded and expires instead of accumulating whole catalogs',
    () async {
      var now = DateTime(2026, 10, 21);
      loader = PodcastPreviewLoader(client: client, now: () => now);
      for (var index = 0; index < 7; index++) {
        await loader.load('$address?$index', request: operation());
      }
      expect(loader.cached('$address?0'), isNull);
      expect(loader.cached('$address?6'), isNotNull);
      now = now.add(const Duration(hours: 7));
      expect(loader.cached('$address?6'), isNull);
    },
  );

  test(
    'live Podnews Daily preview loads and caches its published media',
    () async {
      const address = 'https://podnews.net/rss';
      final live = PodcastPreviewLoader(client: client);
      final result = await live.load(
        address,
        request: operation(budget: const Duration(seconds: 20)),
      );
      expect(result.feed.channel.title, contains('Podnews Daily'));
      expect(result.feed.episodes, isNotEmpty);
      expect(result.feed.episodes.first.media.any((m) => m.isVideo), isTrue);
      expect(result.feed.episodes.first.transcripts, isNotEmpty);
      final cached = live.cached(address)!;
      expect(cached.feed.episodes.length, result.feed.episodes.length);
      expect(identical(cached.feed.channel, result.feed.channel), isFalse);
    },
    skip: !const bool.fromEnvironment('PODCAST_PREVIEW_LIVE_TEST'),
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
