import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_startup.dart';
import 'package:video_player_app/services/network/network_http.dart';

import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

class _PlaybackApi extends BilibiliApiService {
  _PlaybackApi(this.origin);

  final Uri origin;
  int calls = 0;
  List<String> backupPaths = ['/backup'];
  Future<void> Function()? beforeFetch;

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    calls++;
    await beforeFetch?.call();
    return BilibiliStreamInfo(
      durationMs: 60000,
      qualityMap: const {80: '1080P'},
      videoStreams: [
        StreamItem(
          id: 80,
          baseUrl: origin.resolve('/primary').toString(),
          backupUrls: [
            for (final path in backupPaths) origin.resolve(path).toString(),
          ],
          bandwidth: 800000,
          codecs: 'avc1.640028',
          codecid: 7,
          mimeType: 'video/mp4',
          width: 1920,
          height: 1080,
          initializationRange: '0-1',
          indexRange: '2-3',
        ),
      ],
      audioStreams: [
        StreamItem(
          id: 30280,
          baseUrl: origin.resolve('/audio').toString(),
          bandwidth: 128000,
          codecs: 'mp4a.40.2',
          codecid: 0,
          mimeType: 'audio/mp4',
          initializationRange: '0-1',
          indexRange: '2-3',
        ),
      ],
    );
  }
}

class _GatewayFixture {
  _GatewayFixture(this.server, this.directory, this.api, this.service);

  final HttpServer server;
  final Directory directory;
  final _PlaybackApi api;
  final BilibiliStreamingService service;
  final client = HttpClient();
  final sockets = <Socket>[];
  final requests = <String>[];
  final ranges = <String?>[];
  final firstPrimaryRequest = Completer<void>();
  StreamSubscription<HttpRequest>? subscription;
  bool _closed = false;

  static Future<_GatewayFixture> create(
    Future<void> Function(HttpRequest, _GatewayFixture) handle, {
    Duration openTimeout = const Duration(milliseconds: 200),
    Duration hedgeDelay = const Duration(milliseconds: 750),
    DateTime Function()? clock,
    bool allowAlternatePorts = false,
    NetworkSettingsService? networkSettings,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directory = await Directory.systemTemp.createTemp(
      'stream-reliability-',
    );
    final origin = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
    );
    final api = _PlaybackApi(origin);
    final service = BilibiliStreamingService(
      api,
      mediaUriValidator: (uri) =>
          uri.host == origin.host &&
          (allowAlternatePorts || uri.port == origin.port),
      cacheDirectory: directory,
      upstreamOpenTimeout: openTimeout,
      cdnHedgeDelay: hedgeDelay,
      clock: clock,
      networkSettings: networkSettings,
      upstreamIdleTimeout: const Duration(milliseconds: 200),
    );
    final fixture = _GatewayFixture(server, directory, api, service);
    fixture.subscription = server.listen((request) {
      fixture.requests.add(request.uri.path);
      fixture.ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      if (request.uri.path == '/primary' &&
          !fixture.firstPrimaryRequest.isCompleted) {
        fixture.firstPrimaryRequest.complete();
      }
      unawaited(handle(request, fixture).catchError((Object _) {}));
    });
    addTearDown(fixture.close);
    return fixture;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    client.close(force: true);
    await service.shutdown();
    for (final socket in sockets) {
      socket.destroy();
    }
    await subscription?.cancel();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }

  Future<List<int>> read(Uri uri, {String? range}) async {
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    expect(
      response.statusCode,
      range == null ? HttpStatus.ok : HttpStatus.partialContent,
    );
    return response.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
  }
}

VideoItem _item({String id = 'reliable-stream'}) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1xx411c7mD?cid=456',
  title: 'stream',
  durationMs: 60000,
  lastUpdated: 0,
  sourceRef: const MediaSourceRef(
    value: 'BV1xx411c7mD',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV1xx411c7mD',
    cid: 456,
  ),
);

Future<void> _send(HttpRequest request, List<int> bytes) async {
  request.response.contentLength = bytes.length;
  if (request.method != 'HEAD') request.response.add(bytes);
  await request.response.close();
}

void main() {
  test(
    'rapid audio-only off/on cannot revive an aborted old video request',
    () async {
      var respond = false;
      final fixture = await _GatewayFixture.create((request, _) async {
        if (respond) await _send(request, [1, 2, 3, 4]);
      }, openTimeout: const Duration(seconds: 1));
      final playback = await fixture.service.prepare(_item());
      final old = (await fixture.client.getUrl(playback.videoUri)).close();
      await fixture.firstPrimaryRequest.future;
      fixture.service.setPlaybackVideoEnabled(playback, false);
      fixture.service.setPlaybackVideoEnabled(playback, true);
      final cancelled = await old.timeout(const Duration(seconds: 1));
      await cancelled.drain<void>();
      expect(cancelled.statusCode, HttpStatus.gone);
      expect(fixture.requests, ['/primary']);
      expect(fixture.api.calls, 1);
      respond = true;
      expect(await fixture.read(playback.videoUri), [1, 2, 3, 4]);
    },
  );
  test(
    'audio-only stops this video socket while audio and another playback continue',
    () async {
      final fixture = await _GatewayFixture.create((request, fixture) async {
        request.response.contentLength = 1000000;
        final socket = await request.response.detachSocket(writeHeaders: true);
        fixture.sockets.add(socket);
        for (var i = 0; i < 200; i++) {
          socket.add(List.filled(16384, 7));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }, openTimeout: const Duration(seconds: 1));
      final playback = await fixture.service.prepare(_item());
      final video = await (await fixture.client.getUrl(
        playback.videoUri,
      )).close();
      final audio = await (await fixture.client.getUrl(
        playback.audioUri,
      )).close();
      final independent = await fixture.service.prepare(
        _item(id: 'independent-playback'),
      );
      final otherVideo = await (await fixture.client.getUrl(
        independent.videoUri,
      )).close();
      var audioBytes = 0;
      var otherVideoBytes = 0;
      var videoDone = false;
      final videoSubscription = video.listen(
        (_) {},
        onError: (Object _) {},
        onDone: () => videoDone = true,
      );
      final audioSubscription = audio.listen(
        (bytes) => audioBytes += bytes.length,
        onError: (Object _) {},
      );
      final otherSubscription = otherVideo.listen(
        (bytes) => otherVideoBytes += bytes.length,
        onError: (Object _) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      fixture.service.setPlaybackVideoEnabled(playback, false);
      final before = audioBytes;
      final otherBefore = otherVideoBytes;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(videoDone, isTrue);
      expect(audioBytes, greaterThan(before));
      expect(otherVideoBytes, greaterThan(otherBefore));
      final blocked = await (await fixture.client.getUrl(
        playback.videoUri,
      )).close();
      expect(blocked.statusCode, HttpStatus.gone);
      await blocked.drain<void>();
      // Re-enabling the same lease retains its source selection and audio.
      fixture.service.setPlaybackVideoEnabled(playback, true);
      final resumed = await (await fixture.client.getUrl(
        playback.videoUri,
      )).close();
      expect(resumed.statusCode, HttpStatus.ok);
      await resumed.listen((_) {}, onError: (Object _) {}).cancel();
      expect(fixture.api.calls, 1);
      await videoSubscription.cancel();
      await audioSubscription.cancel();
      await otherSubscription.cancel();
    },
  );
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'system notifications preserve pending address resolution and reusable playback URLs',
    () async {
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      await settings.setMode(NetworkScope.bilibili, NetworkMode.system);
      final fixture = await _GatewayFixture.create(
        (request, _) => _send(request, [1, 2, 3, 4]),
        networkSettings: settings,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.api.beforeFetch = () async {
        entered.complete();
        await release.future;
      };
      final pending = fixture.service.prepare(_item());
      // Attach an error handler before injecting callbacks: the old implementation
      // invalidated this in-flight prepare even though no request had failed.
      final resolved = expectLater(pending, completes);
      await entered.future;
      for (var i = 0; i < 100; i++) {
        settings.deviceNetworkChanged();
      }
      release.complete();
      await resolved;
      final playback = await pending;
      fixture.api.beforeFetch = null;
      for (var i = 0; i < 100; i++) {
        settings.deviceNetworkChanged();
      }
      expect(await fixture.read(playback.videoUri), [1, 2, 3, 4]);
      expect(await fixture.read(playback.audioUri), [1, 2, 3, 4]);
      expect(fixture.api.calls, 1);
      await fixture.service.releasePlayback(playback);
      settings.dispose();
    },
  );

  test(
    'new startups prefer a successful CDN only in the current network generation',
    () async {
      final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      backup.listen((request) => _send(request, [1, 2, 3, 4]));
      addTearDown(() => backup.close(force: true));
      final fixture = await _GatewayFixture.create(
        (request, fixture) async {
          request.response.contentLength = 4;
          final socket = await request.response.detachSocket(
            writeHeaders: true,
          );
          fixture.sockets.add(socket);
          socket.listen((_) {}, onError: (Object _) {});
        },
        allowAlternatePorts: true,
        hedgeDelay: const Duration(milliseconds: 20),
      );
      fixture.api.backupPaths = ['http://127.0.0.1:${backup.port}/backup'];
      for (var index = 0; index < 3; index++) {
        if (index == 2) fixture.service.invalidateNetwork();
        final startup = BilibiliStartupContext();
        final playback = await fixture.service.prepareForStartup(
          _item(id: 'cdn-generation-$index'),
          startup: startup,
        );
        expect(await fixture.read(playback.videoUri), [1, 2, 3, 4]);
        startup.ready();
        await fixture.service.releasePlayback(playback);
        expect(fixture.requests.length, index == 2 ? 2 : 1);
      }
    },
  );

  test(
    'foreground playback cancels speculative CDN reads and pauses neighbor prefetch',
    () async {
      final released = Completer<void>();
      final fixture = await _GatewayFixture.create((request, fixture) async {
        request.response.contentLength = 4;
        final socket = await request.response.detachSocket(writeHeaders: true);
        fixture.sockets.add(socket);
        socket.listen(
          (_) {},
          onError: (Object _) {},
          onDone: () {
            if (!released.isCompleted) released.complete();
          },
        );
      });
      await fixture.service.prefetch(_item(id: 'neighbor'));
      await fixture.firstPrimaryRequest.future;
      final startup = BilibiliStartupContext();
      final playback = await fixture.service.prepareForStartup(
        _item(id: 'foreground'),
        startup: startup,
      );
      await released.future.timeout(const Duration(seconds: 1));
      final requestsBefore = fixture.requests.length;
      await fixture.service.prefetch(_item(id: 'another-neighbor'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(fixture.requests.length, requestsBefore);
      expect(fixture.service.activePlaybackSessionCount, 1);
      startup.ready();
      await fixture.service.releasePlayback(playback);
    },
  );

  test(
    'startup transport benchmark with identical media and network conditions',
    () async {
      final report = <String, Object?>{};
      for (final stalled in [false, true]) {
        for (final hedged in [false, true]) {
          final samples = <int>[];
          for (var sample = 0; sample < 10; sample++) {
            final fixture = await _GatewayFixture.create((
              request,
              fixture,
            ) async {
              if (stalled && request.uri.path == '/primary') {
                request.response.contentLength = 4;
                final socket = await request.response.detachSocket(
                  writeHeaders: true,
                );
                fixture.sockets.add(socket);
                socket.listen((_) {}, onError: (Object _) {});
                return;
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
              await _send(request, [1, 2, 3, 4]);
            }, openTimeout: const Duration(seconds: 4));
            try {
              final watch = Stopwatch()..start();
              final context = hedged ? BilibiliStartupContext() : null;
              final playback = await fixture.service.prepareForStartup(
                _item(),
                startup: context,
              );
              expect(await fixture.read(playback.videoUri), [1, 2, 3, 4]);
              samples.add(watch.elapsedMilliseconds);
              context?.ready();
            } finally {
              await fixture.close();
            }
          }
          final sorted = [...samples]..sort();
          report['${stalled ? 'silent-primary' : 'healthy'}-${hedged ? 'hedged' : 'sequential'}'] =
              {
                'samplesMs': samples,
                'medianMs': sorted[sorted.length ~/ 2],
                'p95Ms': sorted[(sorted.length * .95).ceil() - 1],
                'successful': samples.length,
              };
        }
      }
      final destination =
          Platform.environment['BILIBILI_STARTUP_BENCHMARK_REPORT'];
      if (destination != null) {
        final output = File(destination);
        await output.parent.create(recursive: true);
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
        );
      }
      // ignore: avoid_print
      print('BILIBILI_STARTUP_BENCHMARK ${jsonEncode(report)}');
    },
    skip: Platform.environment['BILIBILI_STARTUP_BENCHMARK'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'preparing another item never expires a four-hour active playback',
    () async {
      var now = DateTime.now();
      final fixture = await _GatewayFixture.create(
        (request, _) => _send(request, [1, 2, 3, 4]),
        clock: () => now,
      );
      final active = await fixture.service.prepare(_item());
      now = now.add(const Duration(hours: 4));
      final other = _item(id: 'other-active-item');
      await fixture.service.prepare(other);
      expect(await fixture.read(active.videoUri), [1, 2, 3, 4]);
      expect(fixture.service.activePlaybackSessionCount, 2);
    },
  );

  test(
    'an expired speculative session is removed before it can be reused',
    () async {
      var now = DateTime.now();
      final fixture = await _GatewayFixture.create(
        (request, _) => _send(request, [1, 2, 3, 4]),
        clock: () => now,
      );
      await fixture.service.prefetch(_item());
      now = now.add(const Duration(hours: 4));
      await fixture.service.prepare(_item(id: 'new-active-item'));
      expect(fixture.service.activePlaybackSessionCount, 1);
      final revived = await fixture.service.prepare(_item());
      expect(await fixture.read(revived.videoUri), [1, 2, 3, 4]);
      expect(fixture.service.activePlaybackSessionCount, 2);
    },
  );

  test(
    'a faster CDN with the wrong byte range cannot win or poison the cache',
    () async {
      final fixture = await _GatewayFixture.create((request, _) async {
        request.response.statusCode = HttpStatus.partialContent;
        final primary = request.uri.path == '/primary';
        request.response.headers.set(
          'content-range',
          primary ? 'bytes 0-1/4' : 'bytes 2-3/4',
        );
        await _send(request, primary ? [1, 2] : [3, 4]);
      }, hedgeDelay: const Duration(milliseconds: 20));
      final playback = await fixture.service.prepareForStartup(
        _item(),
        startup: BilibiliStartupContext(),
      );
      expect(await fixture.read(playback.videoUri, range: 'bytes=2-3'), [3, 4]);
      expect(await fixture.read(playback.videoUri, range: 'bytes=2-3'), [3, 4]);
      expect(fixture.api.calls, 1);
    },
  );

  test(
    'startup races a silent CDN and cancels its socket after the backup wins',
    () async {
      final disconnected = Completer<void>();
      final fixture = await _GatewayFixture.create(
        (request, fixture) async {
          if (request.uri.path == '/primary') {
            request.response.contentLength = 4;
            final socket = await request.response.detachSocket(
              writeHeaders: true,
            );
            fixture.sockets.add(socket);
            socket.listen(
              (_) {},
              onError: (Object _) {
                if (!disconnected.isCompleted) disconnected.complete();
              },
              onDone: () {
                if (!disconnected.isCompleted) disconnected.complete();
              },
            );
            return;
          }
          await _send(request, [1, 2, 3, 4]);
        },
        openTimeout: const Duration(seconds: 2),
        hedgeDelay: const Duration(milliseconds: 30),
      );
      final startup = BilibiliStartupContext();
      final playback = await fixture.service.prepareForStartup(
        _item(),
        startup: startup,
      );
      final watch = Stopwatch()..start();
      expect(
        await fixture
            .read(playback.videoUri)
            .timeout(const Duration(seconds: 1)),
        [1, 2, 3, 4],
      );
      expect(watch.elapsedMilliseconds, lessThan(1000));
      await disconnected.future.timeout(const Duration(seconds: 1));
      expect(fixture.requests, ['/primary', '/backup']);
      expect(fixture.api.calls, 1);
    },
  );

  test(
    'startup budget stops silent candidates without a late address refresh',
    () async {
      final fixture = await _GatewayFixture.create(
        (request, _) async {},
        openTimeout: const Duration(seconds: 2),
        hedgeDelay: const Duration(milliseconds: 20),
      );
      final startup = BilibiliStartupContext(
        limit: const Duration(milliseconds: 120),
      );
      final playback = await fixture.service.prepareForStartup(
        _item(),
        startup: startup,
      );
      final request = await fixture.client.getUrl(playback.videoUri);
      final response = await request.close().timeout(
        const Duration(milliseconds: 700),
      );
      expect(response.statusCode, HttpStatus.badGateway);
      await response.drain<void>();
      expect(
        fixture.api.calls,
        1,
        reason: 'Expired attempts cannot start more API calls',
      );
      expect(fixture.requests, ['/primary', '/backup']);
      await fixture.service.releasePlayback(playback);
      expect(fixture.service.activePlaybackSessionCount, 0);
    },
  );

  test(
    'cancelled startup releases its open CDN requests and never reuses that warm session',
    () async {
      final fixture = await _GatewayFixture.create(
        (request, _) async {},
        openTimeout: const Duration(seconds: 2),
        hedgeDelay: const Duration(milliseconds: 20),
      );
      final startup = BilibiliStartupContext();
      final playback = await fixture.service.prepareForStartup(
        _item(),
        startup: startup,
      );
      final request = await fixture.client.getUrl(playback.videoUri);
      final opening = request.close();
      await fixture.firstPrimaryRequest.future;
      startup.cancel();
      final response = await opening.timeout(const Duration(milliseconds: 700));
      expect(response.statusCode, HttpStatus.gone);
      await response.drain<void>();
      await fixture.service.releasePlayback(playback);
      expect(fixture.service.activePlaybackSessionCount, 0);
      expect(fixture.api.calls, 1);
    },
  );

  test(
    'a silent primary connection falls back before the player times out',
    () async {
      final fixture = await _GatewayFixture.create((request, _) async {
        if (request.uri.path == '/primary') return;
        await _send(request, [1, 2, 3, 4]);
      });
      final prepared = await fixture.service.prepare(_item());
      expect(
        await fixture
            .read(prepared.videoUri)
            .timeout(const Duration(seconds: 2)),
        [1, 2, 3, 4],
      );
      expect(fixture.requests, ['/primary', '/backup']);
      expect(fixture.api.calls, 1);
    },
  );

  test(
    'headers without first media bytes do not prevent backup selection',
    () async {
      final fixture = await _GatewayFixture.create((request, fixture) async {
        if (request.uri.path == '/primary') {
          request.response.contentLength = 4;
          fixture.sockets.add(
            await request.response.detachSocket(writeHeaders: true),
          );
          return;
        }
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 10-13/100',
        );
        await _send(request, [5, 6, 7, 8]);
      });
      final prepared = await fixture.service.prepare(_item());
      expect(
        await fixture
            .read(prepared.videoUri, range: 'bytes=10-13')
            .timeout(const Duration(seconds: 2)),
        [5, 6, 7, 8],
      );
      expect(fixture.ranges, ['bytes=10-13', 'bytes=10-13']);
      expect(fixture.api.calls, 1);
    },
  );

  for (final status in [401, 403, 404, 429, 503]) {
    test(
      'HTTP $status with a stalled error body uses the backup immediately',
      () async {
        final fixture = await _GatewayFixture.create((request, fixture) async {
          if (request.uri.path == '/primary') {
            request.response.statusCode = status;
            request.response.contentLength = 500;
            fixture.sockets.add(
              await request.response.detachSocket(writeHeaders: true),
            );
            return;
          }
          await _send(request, [9, 10]);
        });
        final prepared = await fixture.service.prepare(_item());
        expect(await fixture.read(prepared.videoUri), [9, 10]);
        expect(fixture.requests, ['/primary', '/backup']);
        expect(fixture.api.calls, 1);
      },
    );
  }

  test(
    'an empty primary response uses the backup and remembers it for subsequent ranges',
    () async {
      final fixture = await _GatewayFixture.create((request, _) async {
        await _send(request, request.uri.path == '/primary' ? [] : [11, 12]);
      });
      final item = _item();
      fixture.service.updateCachePolicy(
        itemId: item.id,
        isOnlineItem: true,
        isPlaying: false,
        playbackPageVisible: false,
        miniPlaybackCardVisible: false,
        mediaNotificationVisible: false,
      );
      final prepared = await fixture.service.prepare(item);
      expect(await fixture.read(prepared.videoUri), [11, 12]);
      expect(await fixture.read(prepared.videoUri), [11, 12]);
      expect(await fixture.read(prepared.audioUri), [11, 12]);
      expect(fixture.requests, ['/primary', '/backup', '/backup', '/audio']);
      expect(fixture.api.calls, 1);
    },
  );

  test(
    'initial network handover recovers without replacing the playback session',
    () async {
      final fixture = await _GatewayFixture.create((request, fixture) async {
        if (fixture.requests.length <= 2) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
          return;
        }
        request.response.contentLength = 8;
        request.response.add([1, 2, 3, 4, 5, 6, 7, 8]);
        await request.response.close();
      });
      final prepared = await fixture.service.prepare(_item());
      final response = await (await fixture.client.getUrl(
        prepared.videoUri,
      )).close();
      expect(await response.expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);
      expect(fixture.api.calls, 1);
      expect(fixture.service.activePlaybackSessionCount, 1);
      expect(fixture.requests, hasLength(3));
    },
  );

  test(
    'all failed routes perform one refresh and then return a finite error',
    () async {
      final fixture = await _GatewayFixture.create((request, _) async {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });
      final prepared = await fixture.service.prepare(_item());
      final response = await (await fixture.client.getUrl(
        prepared.videoUri,
      )).close().timeout(const Duration(seconds: 2));
      expect(response.statusCode, HttpStatus.badGateway);
      await response.drain<void>();
      expect(fixture.api.calls, 2);
      expect(fixture.requests, ['/primary', '/backup', '/primary', '/backup']);
    },
  );

  test(
    'session release cancels a pending connection without trying more routes',
    () async {
      final fixture = await _GatewayFixture.create((request, _) async {});
      final prepared = await fixture.service.prepare(_item());
      final responseFuture = (await fixture.client.getUrl(
        prepared.videoUri,
      )).close();
      await fixture.firstPrimaryRequest.future;
      await fixture.service
          .releasePlayback(prepared)
          .timeout(const Duration(seconds: 1));
      final response = await responseFuture.timeout(const Duration(seconds: 1));
      await response.drain<void>();
      expect(fixture.requests, ['/primary']);
      expect(fixture.api.calls, 1);
      expect(fixture.service.activePlaybackSessionCount, 0);
    },
  );

  test(
    'a stalled body continues from the next byte without reopening the player',
    () async {
      final fixture = await _GatewayFixture.create((request, fixture) async {
        if (request.uri.path == '/primary') {
          request.response.contentLength = 10;
          final socket = await request.response.detachSocket(
            writeHeaders: true,
          );
          fixture.sockets.add(socket);
          socket.add([1, 2]);
          await socket.flush();
          return;
        }
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-9/10',
        );
        await _send(request, List<int>.generate(8, (index) => index + 3));
      });
      final prepared = await fixture.service.prepare(_item());
      final response = await (await fixture.client.getUrl(
        prepared.videoUri,
      )).close();
      expect(
        await response
            .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk))
            .timeout(const Duration(seconds: 2)),
        List<int>.generate(10, (index) => index + 1),
      );
      expect(fixture.requests, ['/primary', '/backup']);
      expect(fixture.ranges, [null, 'bytes=2-9']);
      expect(fixture.api.calls, 1);
    },
  );

  test(
    'concurrent prepares share the same in-flight play address request',
    () async {
      final fixture = await _GatewayFixture.create((request, _) async {
        await _send(request, [1]);
      });
      final started = Completer<void>();
      final finish = Completer<void>();
      fixture.api.beforeFetch = () {
        if (!started.isCompleted) started.complete();
        return finish.future;
      };
      final first = fixture.service.prepare(_item());
      final second = fixture.service.prepare(_item());
      await started.future;
      expect(fixture.api.calls, 1);
      finish.complete();
      final prepared = await Future.wait([first, second]);
      expect(fixture.api.calls, 1);
      expect(prepared[0].videoUri, isNot(prepared[1].videoUri));
    },
  );

  test(
    'a connection closing mid-body continues on an exact backup range',
    () async {
      final fixture = await _GatewayFixture.create((request, fixture) async {
        if (request.uri.path == '/primary') {
          request.response.contentLength = 6;
          final socket = await request.response.detachSocket(
            writeHeaders: true,
          );
          fixture.sockets.add(socket);
          socket.add([1, 2]);
          await socket.flush();
          socket.destroy();
          return;
        }
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-5/6',
        );
        await _send(request, [3, 4, 5, 6]);
      });
      final prepared = await fixture.service.prepare(_item());
      expect(await fixture.read(prepared.videoUri), [1, 2, 3, 4, 5, 6]);
      expect(fixture.requests, ['/primary', '/backup']);
      expect(fixture.ranges, [null, 'bytes=2-5']);
      expect(fixture.api.calls, 1);
      await fixture.service.releasePlayback(prepared);
      expect(
        (await fixture.service.inspectCache()).bytes,
        greaterThanOrEqualTo(6),
      );
    },
  );

  test(
    'a backup that ignores the resume range cannot corrupt the response or cache',
    () async {
      final fixture = await _GatewayFixture.create((request, fixture) async {
        if (request.uri.path == '/primary') {
          request.response.contentLength = 6;
          final socket = await request.response.detachSocket(
            writeHeaders: true,
          );
          fixture.sockets.add(socket);
          socket.add([1, 2]);
          await socket.flush();
          socket.destroy();
          return;
        }
        await _send(request, [1, 2, 3, 4, 5, 6]);
      });
      final prepared = await fixture.service.prepare(_item());
      final response = await (await fixture.client.getUrl(
        prepared.videoUri,
      )).close();
      await expectLater(response.drain<void>(), throwsA(isA<HttpException>()));
      await fixture.service.releasePlayback(prepared);
      expect((await fixture.service.inspectCache()).bytes, 0);
      expect(fixture.requests, ['/primary', '/backup']);
    },
  );

  for (final video in [true, false]) {
    for (final range in ['bytes=512-', 'bytes=512-1535']) {
      test(
        '${video ? 'video' : 'audio'} partial cache cannot shorten $range',
        () async {
          final payload = List<int>.generate(4096, (i) => i % 251);
          final fixture = await _GatewayFixture.create((request, _) async {
            final match = RegExp(
              r'^bytes=(\d+)-(\d*)$',
            ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '')!;
            final start = int.parse(match[1]!);
            final end = match[2]!.isEmpty
                ? payload.length - 1
                : int.parse(match[2]!);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${payload.length}',
            );
            await _send(request, payload.sublist(start, end + 1));
          });
          final prepared = await fixture.service.prepare(_item());
          final uri = video ? prepared.videoUri : prepared.audioUri;
          expect(
            await fixture.read(uri, range: 'bytes=0-1023'),
            payload.sublist(0, 1024),
          );
          // A complete cached window remains usable without another CDN read.
          expect(
            await fixture.read(uri, range: 'bytes=100-199'),
            payload.sublist(100, 200),
          );
          expect(fixture.ranges, ['bytes=0-1023']);
          final end = range.endsWith('-') ? payload.length : 1536;
          expect(
            await fixture.read(uri, range: range),
            payload.sublist(512, end),
            reason: 'A cache boundary is not the end of the media response',
          );
          expect(fixture.ranges, ['bytes=0-1023', range]);
          if (range.endsWith('-')) {
            // The merged complete cache must still work without upstream,
            // including a bounded Range extending past the true file end.
            expect(await fixture.read(uri, range: 'bytes=0-'), payload);
            expect(
              await fixture.read(uri, range: 'bytes=100-9999'),
              payload.sublist(100),
            );
            expect(fixture.ranges, ['bytes=0-1023', range]);
          }
        },
      );
    }
  }

  for (final status in [HttpStatus.ok, HttpStatus.partialContent]) {
    test(
      'HTTP $status from byte zero cannot answer a later player range',
      () async {
        final fixture = await _GatewayFixture.create((request, _) async {
          final primary = request.uri.path == '/primary';
          request.response.statusCode = primary
              ? status
              : HttpStatus.partialContent;
          if (!primary || status == HttpStatus.partialContent) {
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              primary ? 'bytes 0-3/6' : 'bytes 2-5/6',
            );
          }
          await _send(request, primary ? [1, 2, 3, 4] : [3, 4, 5, 6]);
        });
        final prepared = await fixture.service.prepare(_item());
        expect(await fixture.read(prepared.videoUri, range: 'bytes=2-5'), [
          3,
          4,
          5,
          6,
        ]);
        expect(fixture.requests, ['/primary', '/backup']);
        expect(fixture.ranges, ['bytes=2-5', 'bytes=2-5']);
        // The accepted suffix alone must be reusable from cache.
        expect(await fixture.read(prepared.videoUri, range: 'bytes=2-5'), [
          3,
          4,
          5,
          6,
        ]);
        expect(fixture.requests, ['/primary', '/backup']);
      },
    );
  }

  test(
    'a CDN 200 with an aligned Content-Range stays playable and cacheable',
    () async {
      final fixture = await _GatewayFixture.create((request, _) async {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-5/6',
        );
        await _send(request, [3, 4, 5, 6]);
      });
      final prepared = await fixture.service.prepare(_item());
      final request = await fixture.client.getUrl(prepared.videoUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-5');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(
        await response.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
        [3, 4, 5, 6],
      );
      expect(await fixture.read(prepared.videoUri, range: 'bytes=2-5'), [
        3,
        4,
        5,
        6,
      ]);
      expect(fixture.ranges, ['bytes=2-5']);
    },
  );

  test(
    'stalling on every body route stops after each route is tried once',
    () async {
      final fixture = await _GatewayFixture.create((request, fixture) async {
        final primary = request.uri.path == '/primary';
        request.response.contentLength = primary ? 6 : 4;
        if (!primary) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 2-5/6',
          );
        }
        final socket = await request.response.detachSocket(writeHeaders: true);
        fixture.sockets.add(socket);
        socket.add(primary ? [1, 2] : [3]);
        await socket.flush();
      });
      final prepared = await fixture.service.prepare(_item());
      final response = await (await fixture.client.getUrl(
        prepared.videoUri,
      )).close();
      await expectLater(
        response.drain<void>().timeout(const Duration(seconds: 2)),
        throwsA(isA<HttpException>()),
      );
      expect(fixture.requests, ['/primary', '/backup']);
      await fixture.service.releasePlayback(prepared);
      expect((await fixture.service.inspectCache()).bytes, 0);
    },
  );

  test(
    'resume skips an incompatible backup and tries the remaining route',
    () async {
      final fixture = await _GatewayFixture.create((request, fixture) async {
        if (request.uri.path == '/primary') {
          request.response.contentLength = 6;
          final socket = await request.response.detachSocket(
            writeHeaders: true,
          );
          fixture.sockets.add(socket);
          socket.add([1, 2]);
          await socket.flush();
          socket.destroy();
          return;
        }
        if (request.uri.path == '/backup') {
          await _send(request, [1, 2, 3, 4, 5, 6]);
          return;
        }
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-5/6',
        );
        await _send(request, [3, 4, 5, 6]);
      });
      fixture.api.backupPaths = ['/backup', '/backup-2'];
      final prepared = await fixture.service.prepare(_item());
      expect(await fixture.read(prepared.videoUri), [1, 2, 3, 4, 5, 6]);
      expect(fixture.requests, ['/primary', '/backup', '/backup-2']);
      expect(fixture.api.calls, 1);
    },
  );
}
