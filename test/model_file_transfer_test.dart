import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/model_file_transfer.dart';
import 'package:video_player_app/services/network/network_http.dart';

class _Ranges implements HttpClientAdapter {
  final bytes = Uint8List.fromList(List.generate(1024, (i) => i % 251));
  final requests = <RequestOptions>[];
  bool ignoreRanges = false, ignoreLaterRanges = false, omitEtag = false;
  bool truncate = false, changedEtag = false;
  int active = 0, maximumActive = 0;
  Completer<void>? slowRange;
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
    final ignored = ignoreRanges || ignoreLaterRanges && requests.length > 1;
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
        if (start == 256 && slowRange != null) {
          await slowRange!.future;
        }
        await Future<void>.delayed(const Duration(milliseconds: 3));
        final stop = truncate && start == 64 ? end - 20 : end;
        for (var at = start; at <= stop; at += 16) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          yield Uint8List.sublistView(bytes, at, math.min(at + 16, stop + 1));
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
        if (!omitEtag) 'etag': [changedEtag && start > 0 ? '"v2"' : '"v1"'],
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
  }) async {
    await ModelFileTransfer(
      dio: dio,
      chunkBytes: 64,
      minimumParallelBytes: 256,
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
      expect(adapter.requests.last.headers['Range'], 'bytes=64-');
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
    'truncated chunk leaves a contiguous prefix and retry resumes it',
    () async {
      adapter.truncate = true;
      await expectLater(download(), throwsA(isA<HttpException>()));
      final retained = await partial.readAsBytes();
      expect(retained, adapter.bytes.sublist(0, retained.length));
      expect(retained.length, 64);
      expect(adapter.active, 0);
      adapter.truncate = false;
      await download(ifRange: validator);
      expect(await partial.readAsBytes(), adapter.bytes);
    },
  );

  test(
    'changed representation is rejected before appending other chunks',
    () async {
      adapter.changedEtag = true;
      await expectLater(download(), throwsFormatException);
      expect(await partial.readAsBytes(), adapter.bytes.sublist(0, 64));
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

  test(
    'production defaults transfer a large file over four real HTTP connections',
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
        expect(maximum, 4);
        expect(
          connections.length,
          4,
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
