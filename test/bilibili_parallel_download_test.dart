import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/download_manager.dart';
import 'package:video_player_app/services/bilibili/download_route_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealHttpOverrides();

  late Directory tempDirectory;
  final servers = <_RangeTestServer>[];

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'bilibili_parallel_download_test_',
    );
  });

  tearDown(() async {
    for (final server in servers) {
      await server.close();
    }
    servers.clear();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  Future<_RangeTestServer> startServer({
    bool ignoreRanges = false,
    bool rejectPrimary = false,
    Duration chunkDelay = const Duration(milliseconds: 2),
    bool slowPrimary = false,
    bool slowBackup = false,
    bool rejectBackup = false,
    bool ignoreBackupRanges = false,
    bool wrongBackupTotal = false,
    bool briefPrimaryDip = false,
    int dataSize = 512 * 1024,
    bool interruptBackup = false,
    bool ignorePrimaryRanges = false,
  }) async {
    final server = await _RangeTestServer.start(
      ignoreRanges: ignoreRanges,
      rejectPrimary: rejectPrimary,
      chunkDelay: chunkDelay,
      slowPrimary: slowPrimary,
      slowBackup: slowBackup,
      rejectBackup: rejectBackup,
      ignoreBackupRanges: ignoreBackupRanges,
      wrongBackupTotal: wrongBackupTotal,
      briefPrimaryDip: briefPrimaryDip,
      dataSize: dataSize,
      interruptBackup: interruptBackup,
      ignorePrimaryRanges: ignorePrimaryRanges,
    );
    servers.add(server);
    return server;
  }

  BilibiliDownloadManager createManager() {
    return BilibiliDownloadManager(
      BilibiliApiService(),
      rangeMinBytesPerConnection: 64 * 1024,
    );
  }

  BilibiliDownloadManager createSlowAwareManager(
    List<Map<String, Object?>> events, {
    void Function(Map<String, Object?> event)? onEvent,
  }) => BilibiliDownloadManager(
    BilibiliApiService(),
    rangeMinBytesPerConnection: 64 * 1024,
    routePolicy: const BilibiliDownloadRoutePolicy(
      warmUp: Duration(milliseconds: 20),
      sampleWindow: Duration(milliseconds: 80),
      minimumBytesPerSecond: 512 * 1024,
      minimumRemainingBytes: 0,
      diagnosticInterval: Duration(milliseconds: 40),
    ),
    onDiagnostic: (event) {
      events.add(event);
      onEvent?.call(event);
    },
  );

  for (final connections in [1, 4]) {
    test('持续低速按断点切换备用地址（$connections 连接）', () async {
      final server = await startServer(slowPrimary: true);
      final events = <Map<String, Object?>>[];
      final parent = CancelToken();
      final output = '${tempDirectory.path}/slow_$connections.m4s';
      final result = await createSlowAwareManager(events)
          .downloadVideoStreamForTesting(
            stream: server.streamItem('/primary', backupPath: '/backup'),
            filePath: output,
            maxConnections: connections,
            cancelToken: parent,
          );
      expect(result.isComplete, isTrue);
      expect(await File(output).readAsBytes(), server.data);
      expect(
        events.where((event) => event['event'] == 'slow_switch'),
        isNotEmpty,
      );
      expect(server.backupRanges, isNotEmpty);
      expect(server.backupRanges.every((range) => range.$1 > 0), isTrue);
      expect(
        events
            .where(
              (event) =>
                  event['sourceIndex'] == 1 && event['event'] == 'started',
            )
            .every((event) => (event['resumedBytes'] as int) > 0),
        isTrue,
      );
      expect(parent.isCancelled, isFalse);
    });
  }

  test('没有备用地址时只重连一次并保留已有断点', () async {
    final server = await startServer(slowPrimary: true);
    final events = <Map<String, Object?>>[];
    final output = '${tempDirectory.path}/single_source.m4s';
    await createSlowAwareManager(events).downloadVideoStreamForTesting(
      stream: server.streamItem('/primary'), filePath: output, maxConnections: 1,
    );
    expect(await File(output).readAsBytes(), server.data);
    expect(events.where((event) => event['event'] == 'slow_reconnect'), hasLength(1));
    expect(server.fullGetRequests, 1);
    expect(server.requestedRanges.single.$1, greaterThan(0));
  });

  test('默认参数下真实持续低速会在预热和观察后续传到备用地址', () async {
    final server = await startServer(slowPrimary: true, dataSize: 12 * 1024 * 1024,
      chunkDelay: Duration.zero);
    final events = <Map<String, Object?>>[];
    final output = '${tempDirectory.path}/default_slow_policy.m4s';
    await BilibiliDownloadManager(BilibiliApiService(), onDiagnostic: events.add)
      .downloadVideoStreamForTesting(
        stream: server.streamItem('/primary', backupPath: '/backup'),
        filePath: output, maxConnections: 1,
      );
    expect(await File(output).readAsBytes(), server.data);
    final switched = events.singleWhere((event) => event['event'] == 'slow_switch');
    expect(switched['elapsedMs'], greaterThanOrEqualTo(17000));
    expect(switched['bytesPerSecond'], lessThan(512 * 1024));
    expect(server.backupRanges, hasLength(1));
    expect(server.backupRanges.single.$1, switched['transferredBytes']);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('所有地址都慢时继续完成，不反复切换或报失败', () async {
    final server = await startServer(slowPrimary: true, slowBackup: true);
    final events = <Map<String, Object?>>[];
    final output = '${tempDirectory.path}/all_slow.m4s';
    await createSlowAwareManager(events).downloadVideoStreamForTesting(
      stream: server.streamItem('/primary', backupPath: '/backup'),
      filePath: output,
      maxConnections: 1,
    );
    expect(await File(output).readAsBytes(), server.data);
    expect(
      events.where((event) => event['event'] == 'slow_switch'),
      hasLength(1),
    );
    expect(
      events.where((event) => event['event'] == 'slow_continue'),
      isNotEmpty,
    );
    expect(server.backupRanges, hasLength(1));
  });

  for (final behavior in ['rejected', 'ignoredRange', 'changedTotal']) {
    test('备用地址 $behavior 时保留原断点并回到可用来源', () async {
      final server = await startServer(
        slowPrimary: true,
        rejectBackup: behavior == 'rejected',
        ignoreBackupRanges: behavior == 'ignoredRange',
        wrongBackupTotal: behavior == 'changedTotal',
      );
      final events = <Map<String, Object?>>[];
      final output = '${tempDirectory.path}/backup_$behavior.m4s';
      await createSlowAwareManager(events).downloadVideoStreamForTesting(
        stream: server.streamItem('/primary', backupPath: '/backup'),
        filePath: output,
        maxConnections: 1,
      );
      expect(await File(output).readAsBytes(), server.data);
      expect(
        events.where((event) => event['event'] == 'slow_switch'),
        hasLength(1),
      );
      final originalResume = events.where(
        (event) =>
            event['sourceIndex'] == 0 &&
            event['event'] == 'started' &&
            (event['resumedBytes'] as int) > 0,
      );
      expect(originalResume, hasLength(1));
      expect(server.fullGetRequests, 1);
    });
  }

  test('备用传输中断且原地址不能续传时安全回退完整下载', () async {
    final server = await startServer(slowPrimary: true,
      interruptBackup: true, ignorePrimaryRanges: true);
    final events = <Map<String, Object?>>[];
    final output = '${tempDirectory.path}/last_full_fallback.m4s';
    await createSlowAwareManager(events).downloadVideoStreamForTesting(
      stream: server.streamItem('/primary', backupPath: '/backup'),
      filePath: output, maxConnections: 1,
    );
    expect(await File(output).readAsBytes(), server.data);
    expect(server.backupRanges, hasLength(1));
    expect(server.fullGetRequests, 2);
    expect(events.where((event) => event['event'] == 'slow_switch'), hasLength(1));
  });

  test('短暂波动恢复后不会切换地址', () async {
    final server = await startServer(
      briefPrimaryDip: true,
      chunkDelay: Duration.zero,
    );
    final events = <Map<String, Object?>>[];
    final output = '${tempDirectory.path}/brief_dip.m4s';
    await createSlowAwareManager(events).downloadVideoStreamForTesting(
      stream: server.streamItem('/primary', backupPath: '/backup'),
      filePath: output,
      maxConnections: 1,
    );
    expect(await File(output).readAsBytes(), server.data);
    expect(events.where((event) => event['event'] == 'slow_switch'), isEmpty);
    expect(server.backupRanges, isEmpty);
  });

  test('低速换源同时取消不会启动备用请求或丢失断点', () async {
    final server = await startServer(slowPrimary: true);
    final events = <Map<String, Object?>>[];
    final parent = CancelToken();
    final manager = createSlowAwareManager(
      events,
      onEvent: (event) {
        if (event['event'] == 'slow_switch') {
          parent.cancel('pause during slow recovery');
        }
      },
    );
    final output = '${tempDirectory.path}/cancel_switch.m4s';
    DownloadPartResumeState? latest;
    await expectLater(
      manager.downloadVideoStreamForTesting(
        stream: server.streamItem('/primary', backupPath: '/backup'),
        filePath: output,
        maxConnections: 1,
        cancelToken: parent,
        onProgress: (state, _) {
          latest = state;
        },
      ),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(server.backupRanges, isEmpty);
    expect(await File(output).length(), latest!.downloadedBytes);
    expect(BilibiliDownloadManager.mediaConnectionPool.activeConnections, 0);
  });

  test('单个视频使用多个严格 Range 请求并正确拼接', () async {
    final server = await startServer();
    final outputPath = '${tempDirectory.path}/parallel_video.m4s';

    final result = await createManager().downloadVideoStreamForTesting(
      stream: server.streamItem('/media'),
      filePath: outputPath,
      maxConnections: 4,
    );

    expect(await File(outputPath).readAsBytes(), server.data);
    expect(result.isComplete, isTrue);
    expect(result.rangeParts, isEmpty);
    expect(result.supportsRange, isTrue);
    expect(server.nonProbeRangeRequests, greaterThanOrEqualTo(4));
    expect(server.maximumActiveRangeRequests, greaterThanOrEqualTo(2));
    expect(
      await tempDirectory
          .list()
          .where((entity) => entity.path.endsWith('.part'))
          .isEmpty,
      isTrue,
    );
  });

  test('CDN 忽略 Range 时自动回退单连接且不损坏文件', () async {
    final server = await startServer(ignoreRanges: true);
    final outputPath = '${tempDirectory.path}/fallback_video.m4s';

    final result = await createManager().downloadVideoStreamForTesting(
      stream: server.streamItem('/media'),
      filePath: outputPath,
      maxConnections: 4,
    );

    expect(await File(outputPath).readAsBytes(), server.data);
    expect(result.isComplete, isTrue);
    expect(result.rangeParts, isEmpty);
    expect(server.ignoredRangeRequests, greaterThan(0));
    expect(server.fullGetRequests, 1);
  });

  test('主 CDN 拒绝访问时按 Range 切换备用 CDN', () async {
    final server = await startServer(rejectPrimary: true);
    final outputPath = '${tempDirectory.path}/backup_video.m4s';

    final result = await createManager().downloadVideoStreamForTesting(
      stream: server.streamItem('/primary', backupPath: '/backup'),
      filePath: outputPath,
      maxConnections: 4,
    );

    expect(await File(outputPath).readAsBytes(), server.data);
    expect(result.isComplete, isTrue);
    expect(server.primaryRejectedRequests, greaterThan(0));
    expect(server.backupRangeRequests, greaterThanOrEqualTo(4));
  });

  test('单连接模式也会切换备用 CDN', () async {
    final server = await startServer(rejectPrimary: true);
    final outputPath = '${tempDirectory.path}/single_backup_video.m4s';

    final result = await createManager().downloadVideoStreamForTesting(
      stream: server.streamItem('/primary', backupPath: '/backup'),
      filePath: outputPath,
      maxConnections: 1,
    );

    expect(result.isComplete, isTrue);
    expect(await File(outputPath).readAsBytes(), server.data);
    expect(server.primaryRejectedRequests, greaterThan(0));
    expect(server.fullGetRequests, 1);
  });

  test('并行下载暂停后按各分片真实长度恢复', () async {
    final server = await startServer(
      chunkDelay: const Duration(milliseconds: 8),
    );
    final outputPath = '${tempDirectory.path}/resume_video.m4s';
    final manager = createManager();
    final cancelToken = CancelToken();
    DownloadPartResumeState? pausedState;

    final interrupted = manager.downloadVideoStreamForTesting(
      stream: server.streamItem('/media'),
      filePath: outputPath,
      maxConnections: 4,
      cancelToken: cancelToken,
      onProgress: (state, _) {
        pausedState = state;
        if (state.downloadedBytes >= 96 * 1024 && !cancelToken.isCancelled) {
          cancelToken.cancel('test pause');
        }
      },
    );

    await expectLater(
      interrupted,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(pausedState, isNotNull);
    expect(pausedState!.rangeParts, hasLength(4));
    expect(pausedState!.downloadedBytes, greaterThan(0));
    final recoveredStarts = <int, int>{};
    for (final part in pausedState!.rangeParts) {
      final path = part.tempPath!;
      final actualLength = await File(path).length();
      expect(actualLength, part.downloadedBytes);
      if (actualLength < part.length) {
        recoveredStarts[part.start] = part.start + actualLength;
      }
    }

    // Simulate an app process stopping after bytes reached disk but before the
    // throttled JSON state flush. Resume must trust the validated part-file
    // lengths and must not redownload from the stale counters.
    final staleParts = pausedState!.rangeParts
        .map(
          (part) => part.copyWith(
            downloadedBytes: (part.downloadedBytes - 4096).clamp(
              0,
              part.length,
            ),
          ),
        )
        .toList(growable: false);
    final staleState = DownloadPartResumeState(
      tempPath: pausedState!.tempPath,
      url: pausedState!.url,
      downloadedBytes: staleParts.fold<int>(
        0,
        (sum, part) => sum + part.downloadedBytes,
      ),
      totalBytes: pausedState!.totalBytes,
      streamId: pausedState!.streamId,
      codecid: pausedState!.codecid,
      codecs: pausedState!.codecs,
      mimeType: pausedState!.mimeType,
      supportsRange: true,
      rangeParts: staleParts,
    );

    server.requestedRanges.clear();
    final resumed = await manager.downloadVideoStreamForTesting(
      stream: server.streamItem('/media'),
      filePath: outputPath,
      maxConnections: 4,
      initialState: staleState,
    );

    expect(resumed.isComplete, isTrue);
    expect(await File(outputPath).readAsBytes(), server.data);
    expect(
      recoveredStarts.values.every(
        (expectedStart) =>
            server.requestedRanges.any((range) => range.$1 == expectedStart),
      ),
      isTrue,
    );
  });
}

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionTimeout = const Duration(seconds: 5);
    return client;
  }
}

class _RangeTestServer {
  _RangeTestServer._(
    this.server,
    this.data, {
    required this.ignoreRanges,
    required this.rejectPrimary,
    required this.chunkDelay,
    required this.slowPrimary,
    required this.slowBackup,
    required this.rejectBackup,
    required this.ignoreBackupRanges,
    required this.wrongBackupTotal,
    required this.briefPrimaryDip,
    required this.interruptBackup,
    required this.ignorePrimaryRanges,
  });

  final HttpServer server;
  final Uint8List data;
  final bool ignoreRanges;
  final bool rejectPrimary;
  final Duration chunkDelay;
  final bool slowPrimary;
  final bool slowBackup;
  final bool rejectBackup;
  final bool ignoreBackupRanges;
  final bool wrongBackupTotal;
  final bool briefPrimaryDip;
  final bool interruptBackup;
  final bool ignorePrimaryRanges;
  final List<(int, int)> backupRanges = [];
  final List<(int, int)> requestedRanges = <(int, int)>[];
  int _activeRangeRequests = 0;
  int maximumActiveRangeRequests = 0;
  int nonProbeRangeRequests = 0;
  int ignoredRangeRequests = 0;
  int fullGetRequests = 0;
  int primaryRejectedRequests = 0;
  int backupRangeRequests = 0;

  static Future<_RangeTestServer> start({
    required bool ignoreRanges,
    required bool rejectPrimary,
    required Duration chunkDelay,
    required bool slowPrimary,
    required bool slowBackup,
    required bool rejectBackup,
    required bool ignoreBackupRanges,
    required bool wrongBackupTotal,
    required bool briefPrimaryDip,
    required int dataSize,
    required bool interruptBackup,
    required bool ignorePrimaryRanges,
  }) async {
    final data = Uint8List(dataSize);
    for (var index = 0; index < data.length; index++) {
      data[index] = (index * 31 + 7) & 0xff;
    }
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _RangeTestServer._(
      httpServer,
      data,
      ignoreRanges: ignoreRanges,
      rejectPrimary: rejectPrimary,
      chunkDelay: chunkDelay,
      slowPrimary: slowPrimary,
      slowBackup: slowBackup,
      rejectBackup: rejectBackup,
      ignoreBackupRanges: ignoreBackupRanges,
      wrongBackupTotal: wrongBackupTotal,
      briefPrimaryDip: briefPrimaryDip,
      interruptBackup: interruptBackup,
      ignorePrimaryRanges: ignorePrimaryRanges,
    );
    httpServer.listen((request) {
      unawaited(result._handle(request));
    });
    return result;
  }

  StreamItem streamItem(String path, {String? backupPath}) {
    return StreamItem(
      id: 80,
      baseUrl: _url(path),
      backupUrls: backupPath == null ? const [] : <String>[_url(backupPath)],
      bandwidth: 1,
      codecs: 'avc1',
      codecid: 7,
      mimeType: 'video/mp4',
    );
  }

  String _url(String path) =>
      'http://${server.address.address}:${server.port}$path';

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final isPrimary = request.uri.path == '/primary';
    final isBackup = request.uri.path == '/backup';
    if (rejectBackup && isBackup) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (rejectPrimary && isPrimary) {
      primaryRejectedRequests++;
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    if (request.method == 'HEAD') {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = data.length
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      await request.response.close();
      return;
    }

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader == null ||
        ignoreRanges ||
        (isBackup && ignoreBackupRanges) ||
        (isPrimary && ignorePrimaryRanges)) {
      if (rangeHeader == null) {
        fullGetRequests++;
      } else {
        ignoredRangeRequests++;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = data.length
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      try {
        await _writeBody(
          request.response,
          0,
          data.length - 1,
          slow: isPrimary && slowPrimary || isBackup && slowBackup,
          briefDip: isPrimary && briefPrimaryDip,
        );
        await request.response.close();
      } catch (_) {}
      return;
    }

    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(rangeHeader);
    if (match == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await request.response.close();
      return;
    }
    final start = int.parse(match.group(1)!);
    final parsedEnd = int.tryParse(match.group(2) ?? '');
    final end = parsedEnd ?? data.length - 1;
    if (start < 0 ||
        start >= data.length ||
        end < start ||
        end >= data.length) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await request.response.close();
      return;
    }

    requestedRanges.add((start, end));
    if (!(start == 0 && end == 0)) nonProbeRangeRequests++;
    if (request.uri.path == '/backup' && !(start == 0 && end == 0)) {
      backupRangeRequests++;
      backupRanges.add((start, end));
    }
    _activeRangeRequests++;
    maximumActiveRangeRequests =
        maximumActiveRangeRequests < _activeRangeRequests
        ? _activeRangeRequests
        : maximumActiveRangeRequests;
    request.response
      ..statusCode = HttpStatus.partialContent
      ..contentLength = end - start + 1
      ..headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${isBackup && wrongBackupTotal ? data.length + 1 : data.length}',
      )
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    try {
      if (isBackup && interruptBackup) {
        request.response.add(data.sublist(start, (start + 16 * 1024).clamp(start, end + 1)));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final socket = await request.response.detachSocket();
        socket.destroy();
        return;
      }
      await _writeBody(
        request.response,
        start,
        end,
        slow: isPrimary && slowPrimary || isBackup && slowBackup,
        briefDip: isPrimary && briefPrimaryDip,
      );
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    } finally {
      _activeRangeRequests--;
    }
  }

  Future<void> _writeBody(
    HttpResponse response,
    int start,
    int end, {
    required bool slow,
    required bool briefDip,
  }) async {
    const chunkSize = 16 * 1024;
    var offset = start;
    while (offset <= end) {
      final chunkEnd = (offset + chunkSize - 1).clamp(offset, end);
      response.add(data.sublist(offset, chunkEnd + 1));
      await response.flush();
      offset = chunkEnd + 1;
      final delay = briefDip && offset == start + chunkSize
          ? const Duration(milliseconds: 80)
          : slow
          ? const Duration(milliseconds: 40)
          : chunkDelay;
      if (delay > Duration.zero) await Future<void>.delayed(delay);
    }
  }
}
