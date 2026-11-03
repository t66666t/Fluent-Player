import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../services/network/network_dio_stream.dart';
import 'model_catalog.dart';

String modelSourceLabel(String key) => switch (key) {
  'mainland' => '魔搭 ModelScope',
  'mirror' => 'HF Mirror（第三方）',
  'mirror_proxy' => 'HF Mirror.net（第三方）',
  'official' => 'Hugging Face',
  'upstream' => 'GitHub 上游发布',
  _ => key,
};

class ModelSourceProbeResult {
  const ModelSourceProbeResult(this.key, this.bytesPerSecond, this.checkedAt);
  final String key;
  final double bytesPerSecond;
  final DateTime checkedAt;
  bool get available => bytesPerSecond > 0;
}

/// Samples the actual file body, including redirects, through the download's
/// configured network route. No model contents are installed from a probe.
class ModelDownloadSources {
  ModelDownloadSources({
    required this.createDio,
    this.probeTimeout = const Duration(seconds: 8),
    this.sampleBytes = 4 * 1024 * 1024,
    this.cacheDuration = const Duration(minutes: 5),
    String Function()? cacheContext,
    DateTime Function()? now,
  }) : _cacheContext = cacheContext ?? (() => ''),
       _now = now ?? DateTime.now;

  final Dio Function() createDio;
  final Duration probeTimeout;
  final int sampleBytes;
  final Duration cacheDuration;
  final String Function() _cacheContext;
  final DateTime Function() _now;
  final _rankings = <String, _ModelSourceRanking>{};

  // Files in a model combination share hosts, but have different paths. Reuse
  // the measured route across weights, dictionaries and configuration files.
  String _cacheKey(ModelFile file) {
    final hosts = file.sources.entries.map((source) {
      final uri = Uri.parse(source.value);
      final resolve = uri.pathSegments.indexOf('resolve');
      final repository = resolve < 0
          ? ''
          : uri.pathSegments.take(resolve).join('/');
      return '${source.key}:${uri.origin}/$repository';
    }).toList()..sort();
    return '${_cacheContext()}|${hosts.join('|')}';
  }

  void succeeded(ModelFile file, String source) {
    final ranking = _rankings[_cacheKey(file)];
    if (ranking == null) return;
    ranking.order.remove(source);
    ranking.order.insert(0, source);
  }

  void failed(ModelFile file, String source) {
    final ranking = _rankings[_cacheKey(file)];
    if (ranking == null) return;
    ranking.order.remove(source);
    ranking.order.add(source);
  }

  void forget(ModelFile file) => _rankings.remove(_cacheKey(file));

  Future<List<MapEntry<String, String>>> rank(
    ModelFile file, {
    required String preference,
    required CancelToken cancel,
    bool forceProbe = false,
    void Function()? onProbing,
    void Function(List<ModelSourceProbeResult>)? onProbed,
  }) async {
    if (cancel.isCancelled) throw cancel.cancelError!;
    final sources = file.sources.entries.toList();
    if (sources.length < 2) return sources;
    if (preference != 'auto') {
      // An explicit choice is a preference; failures still fall back to every
      // other catalogued source, including the domestic mirror.
      return [
        ...sources.where((source) => source.key == preference),
        ...sources.where((source) => source.key != preference),
      ];
    }
    final key = _cacheKey(file);
    final cached = _rankings[key];
    if (!forceProbe && cached != null) {
      final age = _now().difference(cached.updatedAt);
      if (!age.isNegative && age < cacheDuration) {
        onProbed?.call(cached.results);
        return [
          for (final name in cached.order)
            sources.firstWhere((source) => source.key == name),
        ];
      }
    }
    onProbing?.call();
    final results = await Future.wait([
      for (final source in sources) _probe(file, source.value, cancel),
    ]);
    if (cancel.isCancelled) throw cancel.cancelError!;
    final checks = [
      for (var index = 0; index < sources.length; index++)
        ModelSourceProbeResult(sources[index].key, results[index], _now()),
    ];
    final indices = List.generate(sources.length, (index) => index);
    indices.sort((a, b) {
      final speed = results[b].compareTo(results[a]);
      if (speed != 0) return speed;
      // Equal measurements prefer domestic hosting, without guessing location.
      int priority(int i) => switch (sources[i].key) {
        'mainland' => 0,
        'mirror_proxy' => 1,
        'mirror' => 2,
        _ => 3,
      };
      return priority(a).compareTo(priority(b));
    });
    _rankings[key] = _ModelSourceRanking(checks, [
      for (final index in indices) sources[index].key,
    ], _now());
    onProbed?.call(checks);
    // Failed probes remain fallbacks: a short outage must not permanently
    // exclude a source.
    return [for (final index in indices) sources[index]];
  }

  Future<double> _probe(ModelFile file, String url, CancelToken parent) async {
    final dio = createDio();
    final cancel = CancelToken();
    var finished = false;
    unawaited(
      parent.whenCancel.then((_) {
        if (!finished) cancel.cancel('已停止测速');
      }),
    );
    final clock = Stopwatch()..start();
    final bodyClock = Stopwatch();
    var received = 0;
    var firstChunkBytes = 0;
    var valid = false;
    try {
      await (() async {
        final length = math.min(sampleBytes, file.bytes);
        final response = await openCancellableDioStream(
          (child) => dio.get<ResponseBody>(
            url,
            cancelToken: child,
            options: Options(
              responseType: ResponseType.stream,
              headers: {
                'Range': 'bytes=0-${length - 1}',
                'Accept-Encoding': 'identity',
              },
              receiveTimeout: probeTimeout,
              sendTimeout: probeTimeout,
              validateStatus: (status) => status == 200 || status == 206,
            ),
          ),
          cancelToken: cancel,
        );
        if (response.headers.value('content-type')?.contains('text/html') ==
            true) {
          throw const FormatException('下载源返回了网页');
        }
        if (response.statusCode == 206) {
          final match = RegExp(
            r'^bytes 0-(\d+)/(\d+)$',
          ).firstMatch(response.headers.value('content-range') ?? '');
          if (match == null || int.parse(match[2]!) != file.bytes) {
            throw const FormatException('测速文件与模型清单不一致');
          }
        } else {
          final total = int.tryParse(
            response.headers.value('content-length') ?? '',
          );
          if (total != null && total != file.bytes) {
            throw const FormatException('测速文件大小不一致');
          }
        }
        valid = true;
        await for (final chunk in response.data!.stream) {
          received += math.min(chunk.length, length - received);
          if (!bodyClock.isRunning) {
            firstChunkBytes = received;
            bodyClock.start();
          }
          if (received >= length) break;
        }
      })().timeout(probeTimeout);
    } catch (_) {
      // A slow but reachable source can still be ranked using its sample.
    } finally {
      finished = true;
      cancel.cancel('测速结束');
      dio.close(force: true);
      clock.stop();
      bodyClock.stop();
    }
    // Large weight files should be ranked by sustained body throughput, not
    // DNS/TLS/redirect latency. Tiny metadata files still use end-to-end time.
    if (valid &&
        received - firstChunkBytes >= 64 * 1024 &&
        bodyClock.elapsedMilliseconds >= 5) {
      return (received - firstChunkBytes) *
          1000000 /
          bodyClock.elapsedMicroseconds;
    }
    return valid && received > 0
        ? received * 1000000 / math.max(clock.elapsedMicroseconds, 1000)
        : 0;
  }
}

class _ModelSourceRanking {
  _ModelSourceRanking(this.results, this.order, this.updatedAt);
  final List<ModelSourceProbeResult> results;
  final List<String> order;
  final DateTime updatedAt;
}

/// A rolling window avoids treating a large-file warm-up as a slow source.
/// Used by both Dart transfers and foreground observation of iOS background IO.
class ModelDownloadHealth {
  ModelDownloadHealth({
    this.window = const Duration(seconds: 20),
    this.minimumBytesPerSecond = 16 * 1024,
    this.referenceBytesPerSecond = 0,
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? (Stopwatch()..start()).elapsedTime {
    _windowStart = _elapsed();
    _lastProgress = _windowStart;
  }
  final Duration window;
  final int minimumBytesPerSecond;
  final double referenceBytesPerSecond;
  final Duration Function() _elapsed;
  double _bestWindowSpeed = 0;
  int _slowWindows = 0;
  int? _previousTotal;
  int _bytes = 0;
  Duration _windowStart = Duration.zero;
  Duration _lastProgress = Duration.zero;

  /// Native resume callbacks include bytes saved before this observation.
  /// Treat the first value (and native restarts) as a baseline, not new IO.
  void observeTotal(int received, {bool allowSlow = false}) {
    final previous = _previousTotal;
    _previousTotal = received;
    if (previous == null || received < previous) {
      _windowStart = _lastProgress = _elapsed();
      _bytes = 0;
      _bestWindowSpeed = 0;
      _slowWindows = 0;
      return;
    }
    add(received - previous, allowSlow: allowSlow);
  }

  void add(int bytes, {bool allowSlow = false}) {
    final now = _elapsed();
    if (bytes > 0) _lastProgress = now;
    _bytes += bytes;
    final duration = now - _windowStart;
    if (duration < window) return;
    final speed = _bytes * 1000000 / duration.inMicroseconds;
    final reference = math.max(referenceBytesPerSecond, _bestWindowSpeed);
    final threshold = reference >= 128 * 1024
        ? math.max(minimumBytesPerSecond, math.min(256 * 1024, reference * .2))
        : minimumBytesPerSecond;
    _slowWindows = !allowSlow && speed < threshold ? _slowWindows + 1 : 0;
    if (_slowWindows >= 2) {
      throw const ModelSourceTooSlow();
    }
    _bestWindowSpeed = math.max(_bestWindowSpeed, speed);
    _bytes = 0;
    _windowStart = now;
  }

  void check() {
    if (_elapsed() - _lastProgress >= window) {
      throw const ModelSourceTooSlow();
    }
  }
}

extension on Stopwatch {
  Duration elapsedTime() => elapsed;
}

class ModelSourceTooSlow implements Exception {
  const ModelSourceTooSlow();
  @override
  String toString() => '下载源持续过慢或无响应，正在切换来源';
}
