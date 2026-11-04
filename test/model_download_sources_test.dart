import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_download_sources.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) => respond(options);
  @override
  void close({bool force = false}) {
    closed = true;
  }
}

void main() {
  final file = ModelFile(
    name: 'model.onnx',
    bytes: 4096,
    sha256: 'a' * 64,
    sources: const {
      'official': 'https://official.test/model.onnx',
      'mainland': 'https://mainland.test/model.onnx',
      'mirror': 'https://mirror.test/model.onnx',
    },
  );
  ResponseBody sample({int total = 4096}) => ResponseBody.fromBytes(
    List.filled(128, 0),
    206,
    headers: {
      'content-range': ['bytes 0-127/$total'],
    },
  );

  test(
    'auto measures file bodies concurrently and includes third-party mirrors',
    () async {
      final requests = <RequestOptions>[];
      final adapters = <_Adapter>[];
      final selector = ModelDownloadSources(
        sampleBytes: 128,
        createDio: () {
          final adapter = _Adapter((options) async {
            requests.add(options);
            await Future<void>.delayed(
              Duration(
                milliseconds: switch (options.uri.host) {
                  'mirror.test' => 2,
                  'mainland.test' => 40,
                  _ => 100,
                },
              ),
            );
            return sample();
          });
          adapters.add(adapter);
          return Dio()..httpClientAdapter = adapter;
        },
      );
      final result = await selector.rank(
        file,
        preference: 'auto',
        cancel: CancelToken(),
      );
      expect(result.map((s) => s.key), ['mirror', 'mainland', 'official']);
      expect(requests, hasLength(3));
      expect(
        requests.every((r) => r.headers['Range'] == 'bytes=0-127'),
        isTrue,
      );
      expect(adapters.every((a) => a.closed), isTrue);
    },
  );

  test(
    'large-file ranking favors sustained throughput over fast first byte',
    () async {
      final weights = ModelFile(
        name: file.name,
        bytes: 256 * 1024,
        sha256: file.sha256,
        sources: file.sources,
      );
      final selector = ModelDownloadSources(
        createDio: () => Dio()
          ..httpClientAdapter = _Adapter((options) async {
            final official = options.uri.host == 'official.test';
            if (official) {
              await Future<void>.delayed(const Duration(milliseconds: 400));
            }
            Stream<Uint8List> stream() async* {
              yield Uint8List(64 * 1024);
              for (var i = 0; i < 3; i++) {
                await Future<void>.delayed(
                  Duration(milliseconds: official ? 40 : 120),
                );
                yield Uint8List(64 * 1024);
              }
            }

            return ResponseBody(
              stream(),
              206,
              headers: {
                'content-range': [
                  'bytes 0-${weights.bytes - 1}/${weights.bytes}',
                ],
              },
            );
          }),
      );
      final order = await selector.rank(
        weights,
        preference: 'auto',
        cancel: CancelToken(),
      );
      expect(order.first.key, 'official');
    },
  );

  test(
    'bounded probe rejects a wrong file and does not wait for a dead source',
    () async {
      final selector = ModelDownloadSources(
        sampleBytes: 128,
        probeTimeout: const Duration(milliseconds: 60),
        createDio: () => Dio()
          ..httpClientAdapter = _Adapter((request) async {
            if (request.uri.host == 'official.test') {
              return Completer<ResponseBody>().future;
            }
            return sample(
              total: request.uri.host == 'mainland.test' ? 999 : 4096,
            );
          }),
      );
      final clock = Stopwatch()..start();
      final result = await selector.rank(
        file,
        preference: 'auto',
        cancel: CancelToken(),
      );
      expect(result.first.key, 'mirror');
      expect(result, hasLength(3));
      expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );

  test(
    'manual preferences retain every fallback and require no speed test',
    () async {
      final selector = ModelDownloadSources(
        createDio: () => throw StateError('unexpected probe'),
      );
      final result = await selector.rank(
        file,
        preference: 'mainland',
        cancel: CancelToken(),
      );
      expect(result.first.key, 'mainland');
      expect(result.map((s) => s.key).toSet(), file.sources.keys.toSet());
    },
  );

  test(
    'auto reuses routes for other model files and remembers a working fallback',
    () async {
      var requests = 0;
      var probing = 0;
      final selector = ModelDownloadSources(
        createDio: () => Dio()
          ..httpClientAdapter = _Adapter((_) async {
            requests++;
            return sample();
          }),
      );
      final first = await selector.rank(
        file,
        preference: 'auto',
        cancel: CancelToken(),
        onProbing: () => probing++,
      );
      final config = ModelFile(
        name: 'inference.yml',
        bytes: 12,
        sha256: 'b' * 64,
        sources: {
          for (final source in file.sources.entries)
            source.key: source.value.replaceFirst(
              'model.onnx',
              'other/inference.yml',
            ),
        },
      );
      final cached = await selector.rank(
        config,
        preference: 'auto',
        cancel: CancelToken(),
        onProbing: () => probing++,
      );
      expect(requests, 3);
      expect(probing, 1);
      expect(
        cached.map((source) => source.key),
        first.map((source) => source.key),
      );
      expect(
        cached.every((source) => source.value.endsWith('other/inference.yml')),
        isTrue,
      );
      selector.failed(config, cached.first.key);
      final fallback = cached.last.key;
      selector.succeeded(config, fallback);
      expect(
        (await selector.rank(
          file,
          preference: 'auto',
          cancel: CancelToken(),
        )).first.key,
        fallback,
      );
      expect(requests, 3);
    },
  );

  test(
    'expired routes, changed networks and explicit probes take fresh measurements',
    () async {
      var requests = 0;
      var generation = 'network-one';
      var time = DateTime(2026);
      final selector = ModelDownloadSources(
        now: () => time,
        cacheContext: () => generation,
        cacheDuration: const Duration(minutes: 15),
        createDio: () => Dio()
          ..httpClientAdapter = _Adapter((_) async {
            requests++;
            return sample();
          }),
      );
      Future<void> rank({bool force = false}) async {
        await selector.rank(
          file,
          preference: 'auto',
          cancel: CancelToken(),
          forceProbe: force,
        );
      }

      await rank();
      await rank();
      expect(requests, 3);
      time = time.add(const Duration(minutes: 16));
      await rank();
      expect(requests, 6);
      generation = 'network-two';
      await rank();
      expect(requests, 9);
      await rank(force: true);
      expect(requests, 12);
      selector.forget(file);
      await rank();
      expect(requests, 15);
    },
  );

  test(
    'source rankings are isolated by host and successes do not extend probe age',
    () async {
      var requests = 0;
      var time = DateTime(2026);
      final selector = ModelDownloadSources(
        now: () => time,
        createDio: () => Dio()
          ..httpClientAdapter = _Adapter((_) async {
            requests++;
            return sample();
          }),
      );
      final first = await selector.rank(
        file,
        preference: 'auto',
        cancel: CancelToken(),
      );
      time = time.add(const Duration(minutes: 20));
      selector.succeeded(file, first.first.key);
      await selector.rank(file, preference: 'auto', cancel: CancelToken());
      expect(requests, 6);
      final other = ModelFile(
        name: file.name,
        bytes: file.bytes,
        sha256: file.sha256,
        sources: {
          for (final entry in file.sources.entries)
            entry.key: entry.value.replaceFirst('.test', '.example'),
        },
      );
      await selector.rank(other, preference: 'auto', cancel: CancelToken());
      expect(requests, 9);
    },
  );

  test(
    'pause cancels ranking without producing a download candidate',
    () async {
      final cancel = CancelToken();
      final selector = ModelDownloadSources(
        probeTimeout: const Duration(milliseconds: 40),
        createDio: () => Dio()
          ..httpClientAdapter = _Adapter(
            (_) => Completer<ResponseBody>().future,
          ),
      );
      final result = selector.rank(file, preference: 'auto', cancel: cancel);
      cancel.cancel('pause');
      await expectLater(result, throwsA(isA<DioException>()));
    },
  );

  test('last fallback can continue slowly but still detects stalled IO', () {
    var time = Duration.zero;
    final health = ModelDownloadHealth(elapsed: () => time);
    time = const Duration(seconds: 20);
    health.add(1, allowSlow: true);
    expect(health.check, returnsNormally);
    time += const Duration(seconds: 20);
    expect(health.check, throwsA(isA<ModelSourceTooSlow>()));
  });

  test('sustained slowdown is detected above the old 16 KiB/s floor', () {
    var time = Duration.zero;
    final health = ModelDownloadHealth(
      elapsed: () => time,
      referenceBytesPerSecond: 1024 * 1024,
    );
    time = const Duration(seconds: 20);
    health.add(100 * 1024 * 20);
    time += const Duration(seconds: 20);
    expect(
      () => health.add(100 * 1024 * 20),
      throwsA(isA<ModelSourceTooSlow>()),
    );

    time = Duration.zero;
    final observed = ModelDownloadHealth(elapsed: () => time);
    time = const Duration(seconds: 20);
    observed.add(1024 * 1024 * 20);
    time = const Duration(seconds: 40);
    observed.add(100 * 1024 * 20);
    time += const Duration(seconds: 20);
    expect(
      () => observed.add(100 * 1024 * 20),
      throwsA(isA<ModelSourceTooSlow>()),
    );
  });

  test(
    'temporary slowdown recovers and shared bandwidth is not a failed source',
    () {
      var time = Duration.zero;
      final health = ModelDownloadHealth(
        elapsed: () => time,
        referenceBytesPerSecond: 100 * 1024 * 1024,
      );
      for (final speed in [
        1024 * 1024,
        32 * 1024,
        1024 * 1024,
        32 * 1024,
        1024 * 1024,
      ]) {
        time += const Duration(seconds: 20);
        expect(() => health.add(speed * 20), returnsNormally);
      }
    },
  );

  test('native resume offsets do not inflate the measured healthy speed', () {
    var time = Duration.zero;
    final health = ModelDownloadHealth(elapsed: () => time);
    const offset = 1024 * 1024 * 1024;
    health.observeTotal(offset);
    time = const Duration(seconds: 20);
    health.observeTotal(offset + 1024 * 1024 * 20);
    time = const Duration(seconds: 40);
    expect(
      () => health.observeTotal(offset + 1024 * 1024 * 40),
      returnsNormally,
    );
  });

  test(
    'different repositories on the same host get independent probes',
    () async {
      var requests = 0;
      final selector = ModelDownloadSources(
        createDio: () => Dio()
          ..httpClientAdapter = _Adapter((_) async {
            requests++;
            return sample();
          }),
      );
      ModelFile repository(String repo, String path) => ModelFile(
        name: path,
        bytes: file.bytes,
        sha256: file.sha256,
        sources: {
          for (final entry in file.sources.entries)
            entry.key:
                'https://${Uri.parse(entry.value).host}/owner/$repo/resolve/rev/$path',
        },
      );
      await selector.rank(
        repository('one', 'model.onnx'),
        preference: 'auto',
        cancel: CancelToken(),
      );
      await selector.rank(
        repository('one', 'tokens.txt'),
        preference: 'auto',
        cancel: CancelToken(),
      );
      expect(requests, 3);
      await selector.rank(
        repository('two', 'model.onnx'),
        preference: 'auto',
        cancel: CancelToken(),
      );
      expect(requests, 6);
    },
  );

  test(
    'health switches on sustained low throughput and on missing progress',
    () {
      var time = Duration.zero;
      final health = ModelDownloadHealth(elapsed: () => time);
      health.add(100);
      time = const Duration(seconds: 19);
      expect(health.check, returnsNormally);
      time = const Duration(seconds: 20);
      health.add(100);
      time += const Duration(seconds: 20);
      expect(() => health.add(100), throwsA(isA<ModelSourceTooSlow>()));
      final stalled = ModelDownloadHealth(elapsed: () => time);
      stalled.add(1024 * 1024);
      time += const Duration(seconds: 20);
      expect(stalled.check, throwsA(isA<ModelSourceTooSlow>()));
    },
  );

  test(
    'healthy rolling windows continue and low speed is detected in later windows',
    () {
      var time = Duration.zero;
      final health = ModelDownloadHealth(elapsed: () => time);
      for (var i = 0; i < 4; i++) {
        time += const Duration(seconds: 10);
        health.add(1024 * 1024);
        health.check();
      }
      time += const Duration(seconds: 20);
      health.add(1);
      time += const Duration(seconds: 20);
      expect(() => health.add(1), throwsA(isA<ModelSourceTooSlow>()));
    },
  );
}
