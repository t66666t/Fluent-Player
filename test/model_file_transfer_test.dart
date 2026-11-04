import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/model_file_transfer.dart';
import 'package:video_player_app/services/network/network_http.dart';

class _Ranges implements HttpClientAdapter {
  final bytes = Uint8List.fromList(List.generate(1024, (i) => i % 251));
  final requests = <RequestOptions>[];
  bool ignoreRanges = false, ignoreLaterRanges = false, omitEtag = false;
  bool truncate = false, changedEtag = false;
  bool emptyRanges = false;
  bool changeEtagOnRetry = false;
  bool dropRangesOnRetry = false;
  bool trickle = false;
  bool resetRange = false;
  int active = 0, maximumActive = 0;
  Completer<void>? slowRange;
  int slowStart = 256;
  final refilled = Completer<void>();

  Future<void> get idle async {
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (active > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(active, 0, reason: 'cancelled response streams must close promptly');
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final range = RegExp(
      r'^bytes=(\d+)-(\d*)$',
    ).firstMatch('${options.headers['Range']}');
    final retry =
        options.extra[NetworkHttp.modelDownloadFreshConnectionKey] == true;
    final ignored =
        ignoreRanges ||
        ignoreLaterRanges && requests.length > 1 ||
        dropRangesOnRetry && retry;
    final ranged = range != null && !ignored;
    final start = ranged ? int.parse(range[1]!) : 0;
    if (start == 320 && !refilled.isCompleted) refilled.complete();
    final end = ranged && range[2]!.isNotEmpty
        ? int.parse(range[2]!)
        : bytes.length - 1;
    Stream<Uint8List> stream() async* {
      active++;
      maximumActive = math.max(maximumActive, active);
      try {
        if (emptyRanges) return;
        if (start == slowStart && slowRange != null) {
          await Future.any([slowRange!.future, ?cancel]);
        }
        await Future<void>.delayed(const Duration(milliseconds: 3));
        final stop = truncate && start == 64 && range![2]!.isNotEmpty
            ? end - 20
            : end;
        for (var at = start; at <= stop; at += 16) {
          await Future<void>.delayed(Duration(milliseconds: trickle ? 10 : 1));
          yield Uint8List.sublistView(bytes, at, math.min(at + 16, stop + 1));
          if (resetRange && start == 64) {
            throw DioException(
              requestOptions: options,
              error: const SocketException('connection reset while streaming'),
            );
          }
        }
      } finally {
        active--;
      }
    }

    return ResponseBody(
      stream(),
      ranged ? 206 : 200,
      headers: {
        'content-length': ['${end - start + 1}'],
        if (ranged) 'content-range': ['bytes $start-$end/${bytes.length}'],
        if (!omitEtag)
          'etag': [
            changedEtag && start > 0 || changeEtagOnRetry && retry
                ? '"v2"'
                : '"v1"',
          ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory root;
  late File partial;
  late _Ranges adapter;
  late Dio dio;
  String? validator;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('model-transfer-');
    partial = File('${root.path}/model.part');
    adapter = _Ranges();
    dio = Dio()..httpClientAdapter = adapter;
    validator = null;
  });
  tearDown(() async {
    dio.close(force: true);
    await root.delete(recursive: true);
  });
  Future<void> download({
    CancelToken? cancel,
    void Function(int)? onBytes,
    String? ifRange,
    int parallelism = 4,
    Duration recoveryWindow = const Duration(seconds: 5),
  }) async {
    await ModelFileTransfer(
      dio: dio,
      parallelism: parallelism,
      chunkBytes: 64,
      minimumParallelBytes: 256,
      recoveryWindow: recoveryWindow,
    ).download(
      url: 'https://model.test/weights',
      total: adapter.bytes.length,
      partial: partial,
      offset: await partial.exists() ? await partial.length() : 0,
      cancel: cancel ?? CancelToken(),
      ifRange: ifRange,
      onValidator: (etag) async {
        validator = etag;
      },
      onBytes: onBytes ?? (_) {},
    );
  }

  test(
    'refills other connections while the very first range is stalled',
    () async {
      adapter.slowStart = 0;
      adapter.slowRange = Completer<void>();
      final transfer = download();
      try {
        await adapter.refilled.future.timeout(const Duration(seconds: 2));
        expect(adapter.slowRange!.isCompleted, isFalse);
        expect(await partial.length(), 0);
        expect(adapter.requests.length, lessThanOrEqualTo(8));
      } finally {
        adapter.slowRange!.complete();
        await transfer;
      }
      expect(await partial.readAsBytes(), adapter.bytes);
      expect(adapter.maximumActive, 4);
    },
  );

  test(
    'four concurrent ranges assemble exact bytes with a bounded checkpoint',
    () async {
      final progress = <int>[];
      await download(onBytes: progress.add);
      expect(await partial.readAsBytes(), adapter.bytes);
      expect(adapter.maximumActive, 4);
      expect(adapter.active, 0);
      expect(progress.last, adapter.bytes.length);
      expect(progress.every((n) => n <= adapter.bytes.length), isTrue);
      expect(validator, '"v1"');
      expect(
        adapter.requests.skip(1).every((r) => r.headers['If-Range'] == '"v1"'),
        isTrue,
      );
    },
  );

  test(
    'refills a completed slot while a later range is still transferring',
    () async {
      adapter.slowRange = Completer<void>();
      final transfer = download();
      try {
        await adapter.refilled.future.timeout(const Duration(seconds: 2));
        expect(adapter.slowRange!.isCompleted, isFalse);
      } finally {
        adapter.slowRange!.complete();
        await transfer;
      }
      expect(await partial.readAsBytes(), adapter.bytes);
      expect(adapter.maximumActive, lessThanOrEqualTo(4));
    },
  );

  test(
    'existing contiguous partial resumes without fetching its prefix',
    () async {
      await partial.writeAsBytes(adapter.bytes.sublist(0, 37));
      await download(ifRange: '"v1"');
      expect(adapter.requests.first.headers['Range'], 'bytes=37-100');
      expect(await partial.readAsBytes(), adapter.bytes);
    },
  );

  test('range rejection falls back to one ordinary stream', () async {
    adapter.ignoreRanges = true;
    await download();
    expect(adapter.maximumActive, 1);
    expect(adapter.requests, hasLength(1));
    expect(await partial.readAsBytes(), adapter.bytes);
  });

  test(
    'a server that stops honoring ranges restarts safely as one stream',
    () async {
      adapter.ignoreLaterRanges = true;
      await download();
      expect(
        adapter.requests.last.headers['Range'],
        anyOf(isNull, 'bytes=64-'),
      );
      expect(await partial.readAsBytes(), adapter.bytes);
      expect(adapter.active, 0);
    },
  );

  test('missing strong validator never mixes parallel chunks', () async {
    adapter.omitEtag = true;
    await download();
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.last.headers['Range'], isNull);
    expect(await partial.readAsBytes(), adapter.bytes);
  });

  test(
    'truncated chunk reconnects at its remaining offset without duplicate bytes',
    () async {
      adapter.truncate = true;
      final progress = <int>[];
      await download(onBytes: progress.add);
      expect(await partial.readAsBytes(), adapter.bytes);
      expect(progress.last, adapter.bytes.length);
      final retry = adapter.requests.where(
        (request) =>
            request.extra[NetworkHttp.modelDownloadFreshConnectionKey] == true,
      );
      expect(retry.single.headers['Range'], 'bytes=108-127');
      expect(retry.single.headers['If-Range'], '"v1"');
      expect(adapter.active, 0);
    },
  );

  test(
    'Dio-wrapped socket resets reconnect only the unfinished range',
    () async {
      adapter.resetRange = true;
      final progress = <int>[];
      await download(onBytes: progress.add);
      final retry = adapter.requests
          .where(
            (request) =>
                request.extra[NetworkHttp.modelDownloadFreshConnectionKey] ==
                true,
          )
          .single;
      expect(retry.headers['Range'], 'bytes=80-127');
      expect(await partial.readAsBytes(), adapter.bytes);
      expect(progress.last, adapter.bytes.length);
      await adapter.idle;
    },
  );

  test(
    'permanently broken ranges have bounded retries and keep the old prefix',
    () async {
      adapter.emptyRanges = true;
      await partial.writeAsBytes(adapter.bytes.sublist(0, 37));
      await expectLater(
        download(ifRange: '"v1"'),
        throwsA(isA<HttpException>()),
      );
      expect(await partial.readAsBytes(), adapter.bytes.sublist(0, 37));
      expect(adapter.requests.length, lessThanOrEqualTo(4 * 3));
      expect(
        adapter.requests.where((r) => r.headers['Range'] == 'bytes=37-100'),
        hasLength(3),
      );
      await adapter.idle;
    },
  );

  test(
    'a permanently slow connection continues after bounded automatic reconnects',
    () async {
      adapter.trickle = true;
      await partial.writeAsBytes(adapter.bytes.sublist(0, 37));
      final progress = <int>[];
      await download(
        ifRange: '"v1"',
        onBytes: progress.add,
        recoveryWindow: const Duration(milliseconds: 5),
      );
      expect(await partial.readAsBytes(), adapter.bytes);
      expect(progress.last, adapter.bytes.length);
      expect(progress, orderedEquals(progress.toList()..sort()));
      expect(adapter.requests.length, lessThanOrEqualTo(3 * 16));
      expect(
        adapter.requests.where(
          (request) =>
              request.extra[NetworkHttp.modelDownloadFreshConnectionKey] ==
              true,
        ),
        isNotEmpty,
      );
      await adapter.idle;
    },
  );

  test(
    'pausing during reconnect retains the original checkpoint and stops retries',
    () async {
      await partial.writeAsBytes(adapter.bytes.sublist(0, 37));
      final cancel = CancelToken();
      adapter.trickle = true;
      await expectLater(
        download(
          cancel: cancel,
          ifRange: '"v1"',
          recoveryWindow: const Duration(milliseconds: 5),
          onBytes: (_) {
            if (adapter.requests.any(
              (request) =>
                  request.extra[NetworkHttp.modelDownloadFreshConnectionKey] ==
                  true,
            )) {
              cancel.cancel('pause during recovery');
            }
          },
        ),
        throwsA(isA<DioException>()),
      );
      final retained = await partial.readAsBytes();
      expect(retained.length, greaterThanOrEqualTo(37));
      expect(retained, adapter.bytes.sublist(0, retained.length));
      await adapter.idle;
      final requestCount = adapter.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(adapter.requests, hasLength(requestCount));
      adapter.trickle = false;
      await download(ifRange: '"v1"');
      expect(await partial.readAsBytes(), adapter.bytes);
    },
  );

  test(
    'validator changes during a range reconnect are never mixed into the model',
    () async {
      adapter.truncate = true;
      adapter.changeEtagOnRetry = true;
      await expectLater(download(), throwsFormatException);
      final retained = await partial.readAsBytes();
      expect(retained, adapter.bytes.sublist(0, retained.length));
      expect(retained.length, lessThanOrEqualTo(64));
      await adapter.idle;
    },
  );

  test(
    'a reconnect that ignores ranges falls back without duplicate data',
    () async {
      adapter.truncate = true;
      adapter.dropRangesOnRetry = true;
      await download();
      expect(await partial.readAsBytes(), adapter.bytes);
      expect(
        adapter.requests.last.extra[NetworkHttp
            .modelDownloadFreshConnectionKey],
        isNull,
      );
      await adapter.idle;
    },
  );

  test(
    'changed representation is rejected before appending other chunks',
    () async {
      adapter.changedEtag = true;
      await expectLater(download(), throwsFormatException);
      final retained = await partial.readAsBytes();
      expect(retained, adapter.bytes.sublist(0, retained.length));
      expect(retained.length, lessThanOrEqualTo(64));
      await adapter.idle;
      expect(adapter.active, 0);
    },
  );

  test('pause drains workers and keeps only a safe resumable prefix', () async {
    final cancel = CancelToken();
    await expectLater(
      download(
        cancel: cancel,
        onBytes: (n) {
          if (n > 100) cancel.cancel('pause');
        },
      ),
      throwsA(isA<DioException>()),
    );
    final retained = await partial.readAsBytes();
    expect(retained, adapter.bytes.sublist(0, retained.length));
    await adapter.idle;
    expect(adapter.active, 0);
    await download(ifRange: validator);
    expect(await partial.readAsBytes(), adapter.bytes);
  });

  for (final throttleAll in [false, true]) {
    test(
      throttleAll
          ? 'production watchdog recovers when all reused HTTP connections become slow'
          : 'production watchdog recovers a throttled HTTP connection and retains its bytes',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final contents = Uint8List((throttleAll ? 24 : 10) * 1024 * 1024);
        for (var i = 0; i < contents.length; i++) {
          contents[i] = i % 251;
        }
        const prefix = 37 * 1024;
        await partial.writeAsBytes(contents.sublist(0, prefix));
        int? throttledPort;
        final originalPorts = <int>{};
        final connectionBytes = <int, int>{};
        final requests =
            <({int start, int end, int port, String? validator})>[];
        var stopping = false;
        var active = 0;
        final handlers = <Future<void>>[];
        Future<void> serve(HttpRequest request) async {
          active++;
          try {
            final match = RegExp(
              r'^bytes=(\d+)-(\d+)$',
            ).firstMatch(request.headers.value('range') ?? '')!;
            final start = int.parse(match[1]!);
            final end = int.parse(match[2]!);
            final port = request.connectionInfo!.remotePort;
            throttledPort ??= port;
            if (requests.length < 8) originalPorts.add(port);
            requests.add((
              start: start,
              end: end,
              port: port,
              validator: request.headers.value('if-range'),
            ));
            request.response.statusCode = 206;
            request.response.contentLength = end - start + 1;
            request.response.headers.set('etag', '"stable"');
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/${contents.length}',
            );
            var at = start;
            while (at <= end && !stopping) {
              final slow = throttleAll
                  ? originalPorts.contains(port) &&
                        (connectionBytes[port] ?? 0) >= 2 * 1024 * 1024
                  : port == throttledPort && at - start >= 128 * 1024;
              final next = math.min(at + (slow ? 1024 : 64 * 1024), end + 1);
              request.response.add(Uint8List.sublistView(contents, at, next));
              await request.response.flush();
              connectionBytes[port] = (connectionBytes[port] ?? 0) + next - at;
              at = next;
              await Future<void>.delayed(
                Duration(
                  milliseconds: slow
                      ? 32
                      : throttleAll
                      ? 1
                      : 12,
                ),
              );
            }
            await request.response.close();
          } on IOException {
            // The production watchdog closes only the throttled response socket.
          } finally {
            active--;
          }
        }

        final serving = server.listen((request) {
          handlers.add(serve(request));
        });
        final network = NetworkHttp();
        final client = network.createDio(scope: NetworkScope.modelDownloads);
        final progress = <int>[];
        final clock = Stopwatch()..start();
        try {
          await ModelFileTransfer(dio: client)
              .download(
                url: 'http://${server.address.address}:${server.port}/model',
                total: contents.length,
                partial: partial,
                offset: prefix,
                ifRange: '"stable"',
                cancel: CancelToken(),
                onValidator: (etag) async {
                  expect(etag, '"stable"');
                },
                onBytes: progress.add,
              )
              .timeout(const Duration(seconds: 25));
          final initial = requests.first;
          final rangeBytes = initial.end - initial.start + 1;
          final retries = requests
              .where((request) => (request.start - prefix) % rangeBytes != 0)
              .toList();
          expect(retries, hasLength(throttleAll ? 4 : 1));
          for (final retry in retries) {
            final original = requests.firstWhere(
              (request) => request.end == retry.end,
            );
            expect(
              retry.port,
              isNot(original.port),
              reason: 'a fresh TCP connection is required',
            );
            expect(retry.start, greaterThan(original.start));
            expect(retry.validator, '"stable"');
          }
          expect(
            requests.where((request) => request.start == prefix),
            hasLength(1),
            reason:
                'the existing prefix and in-memory range bytes are retained',
          );
          expect(progress.last, contents.length);
          for (var i = 1; i < progress.length; i++) {
            expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
          }
          expect(await partial.length(), contents.length);
          expect(
            sha256.convert(await partial.readAsBytes()),
            sha256.convert(contents),
          );
          expect(
            clock.elapsed,
            lessThan(const Duration(seconds: 25)),
            reason: 'without recovery a throttled range needs over 30 seconds',
          );
        } finally {
          stopping = true;
          client.close(force: true);
          await server.close(force: true);
          await serving.cancel();
          await Future.wait(handlers);
          await network.dispose();
        }
        expect(active, 0);
      },
    );
  }

  test(
    'production defaults transfer a large file over eight real HTTP connections',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final contents = Uint8List.fromList(
        List.generate(10 * 1024 * 1024, (i) => i % 251),
      );
      var active = 0, maximum = 0;
      final connections = <int>{};
      final serving = server.listen((request) async {
        connections.add(request.connectionInfo!.remotePort);
        active++;
        maximum = math.max(maximum, active);
        try {
          final match = RegExp(
            r'^bytes=(\d+)-(\d*)$',
          ).firstMatch(request.headers.value('range') ?? '');
          final start = match == null ? 0 : int.parse(match[1]!);
          final end = match == null || match[2]!.isEmpty
              ? contents.length - 1
              : int.parse(match[2]!);
          request.response.statusCode = match == null ? 200 : 206;
          request.response.contentLength = end - start + 1;
          request.response.headers.set('etag', '"immutable"');
          if (match != null) {
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/${contents.length}',
            );
          }
          for (var at = start; at <= end; at += 64 * 1024) {
            request.response.add(
              Uint8List.sublistView(
                contents,
                at,
                math.min(at + 64 * 1024, end + 1),
              ),
            );
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          await request.response.close();
        } finally {
          active--;
        }
      });
      final network = NetworkHttp();
      final client = network.createDio(scope: NetworkScope.modelDownloads);
      try {
        await ModelFileTransfer(dio: client).download(
          url: 'http://${server.address.address}:${server.port}/model',
          total: contents.length,
          partial: partial,
          offset: 0,
          cancel: CancelToken(),
          onValidator: (_) async {},
          onBytes: (_) {},
        );
        expect(await partial.readAsBytes(), contents);
        expect(maximum, 8);
        expect(
          connections.length,
          8,
          reason: 'later ranges reuse the initial connection',
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
        await serving.cancel();
        await network.dispose();
      }
    },
  );
}
