import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

enum AsrAcceleration { auto, cpu, gpu }

String asrAccelerationPackId(String modelId) => '$modelId-gpu';

/// Timings include transport and decoding. Startup is cold warm-up less steady
/// inference, including session loading, compilation and provider verification.
class AsrPerformanceProfile {
  const AsrPerformanceProfile({
    required this.signature,
    required this.testedAt,
    required this.backend,
    required this.device,
    required this.weights,
    required this.sampleSeconds,
    required this.cpuMs,
    required this.gpuMs,
    this.cpuStartupMs = 0,
    this.gpuStartupMs = 0,
    this.failed = false,
    this.failureReason = '',
  });
  final String signature, backend, device, weights, failureReason;
  final DateTime testedAt;
  final double sampleSeconds;
  final int cpuMs, gpuMs, cpuStartupMs, gpuStartupMs;
  final bool failed;

  bool matches(String key, DateTime now) =>
      signature == key &&
      !now.isBefore(testedAt) &&
      now.difference(testedAt) < const Duration(days: 14);

  bool supportsProbe(double seconds) =>
      failed ||
      (sampleSeconds - seconds.clamp(3, 12)).abs() <=
          (sampleSeconds * .2).clamp(.5, 2);

  double estimate(bool gpu, double seconds, int loads, {double? calls}) {
    var scale = (seconds / sampleSeconds).clamp(1, 1e9).toDouble();
    // File transport and GPU dispatch have a per-segment cost. Scaling only by
    // seconds would incorrectly predict a long-stream gain for many short VAD
    // spans. Keep the estimate conservative when the real call count is known.
    if (gpu && calls != null && calls > scale) scale = calls;
    return (gpu ? gpuStartupMs : cpuStartupMs) * loads +
        (gpu ? gpuMs : cpuMs) * scale;
  }

  bool useGpu(double seconds, {int loads = 1, double? calls}) =>
      !failed &&
      cpuMs > 0 &&
      gpuMs > 0 &&
      estimate(true, seconds, loads, calls: calls) <
          estimate(false, seconds, loads) * .9;

  String get summary => failed
      ? 'GPU 检查失败，使用 CPU${failureReason.isEmpty ? '' : '：$failureReason'}；可重新测速'
      : '同段语音 CPU ${(cpuMs / 1000).toStringAsFixed(2)} 秒 / '
            '$backend ${(gpuMs / 1000).toStringAsFixed(2)} 秒（不含启动）';

  Map<String, Object> toJson() => {
    'signature': signature,
    'testedAt': testedAt.toUtc().toIso8601String(),
    'backend': backend,
    'device': device,
    'weights': weights,
    'sampleSeconds': sampleSeconds,
    'cpuMs': cpuMs,
    'gpuMs': gpuMs,
    'cpuStartupMs': cpuStartupMs,
    'gpuStartupMs': gpuStartupMs,
    'failed': failed,
    if (failureReason.isNotEmpty) 'failureReason': failureReason,
  };

  static AsrPerformanceProfile? fromJson(Object? value) {
    if (value is! Map || value['signature'] is! String) return null;
    final date = DateTime.tryParse('${value['testedAt']}');
    final seconds = value['sampleSeconds'];
    int number(String key) {
      final n = value[key];
      return n is num && n.isFinite && n >= 0 ? n.toInt() : 0;
    }

    if (date == null || seconds is! num || !seconds.isFinite || seconds <= 0) {
      return null;
    }
    return AsrPerformanceProfile(
      signature: value['signature'] as String,
      testedAt: date,
      backend: value['backend'] is String ? value['backend'] as String : '',
      device: value['device'] is String ? value['device'] as String : '',
      weights: value['weights'] is String ? value['weights'] as String : '',
      sampleSeconds: seconds.toDouble(),
      cpuMs: number('cpuMs'),
      gpuMs: number('gpuMs'),
      cpuStartupMs: number('cpuStartupMs'),
      gpuStartupMs: number('gpuStartupMs'),
      failed: value['failed'] == true,
      failureReason: value['failureReason'] is String
          ? value['failureReason'] as String
          : '',
    );
  }
}

/// Known failures must be checked before opening a GPU process. Unlike device
/// timing keys, this key can be computed even if startup/capability probing dies.
/// App/runtime or installed-weight changes invalidate it without hashing models.
///
/// v2 omits the CPU thread count. Playback and thermal limits change that count
/// often; a known-bad GPU must stay skipped until the user retests or the
/// record expires. v1 records are still honored by [asrAvailabilityMatches].
String asrAvailabilitySignature(Map<String, dynamic> configuration) =>
    jsonEncode({
      'scope': 'asr-availability-v2',
      'os': Platform.operatingSystemVersion,
      'abi': Abi.current().toString(),
      'dart': Platform.version,
      'environment': configuration['accelerationEnvironment'],
      'model': configuration['identity'],
      'weights': configuration['gpuIdentity'],
      'language': configuration['language'],
      'decoding': configuration['decoding'],
      'audioConfiguration': configuration['audioConfiguration'],
    });

/// Records written before thread count was removed from the availability key.
String asrAvailabilitySignatureV1(Map<String, dynamic> configuration) =>
    jsonEncode({
      'scope': 'asr-availability-v1',
      'os': Platform.operatingSystemVersion,
      'abi': Abi.current().toString(),
      'dart': Platform.version,
      'environment': configuration['accelerationEnvironment'],
      'model': configuration['identity'],
      'weights': configuration['gpuIdentity'],
      'threads': configuration['threads'],
      'language': configuration['language'],
      'decoding': configuration['decoding'],
      'audioConfiguration': configuration['audioConfiguration'],
    });

bool asrAvailabilityMatches(
  AsrPerformanceProfile profile,
  Map<String, dynamic> configuration,
  DateTime now,
) =>
    profile.matches(asrAvailabilitySignature(configuration), now) ||
    profile.matches(asrAvailabilitySignatureV1(configuration), now);

/// Qwen GPU faults are independent of the CPU thread pool. [component]
/// separates the recognizer from the shared aligner so one failure does not
/// blacklist the other.
String qwenAvailabilitySignature(
  Map<String, dynamic> configuration, {
  required String component,
}) => jsonEncode({
  'scope': 'qwen-availability-v1',
  'os': Platform.operatingSystemVersion,
  'abi': Abi.current().toString(),
  'environment': configuration['accelerationEnvironment'],
  'model': configuration['identity'],
  'language': configuration['language'],
  'hotwords': configuration['hotwords'] ?? configuration['decoding'],
  'component': component,
  if (configuration['runtimeStamp'] != null)
    'runtime': configuration['runtimeStamp'],
});

/// A stored timing can approve GPU before any driver is opened. The thread
/// count is read from the signature: a playback budget change is not evidence
/// that the same device is still faster.
bool freshGpuWin(
  AsrPerformanceProfile profile, {
  required Set<String> weights,
  required int threads,
  required double seconds,
  required DateTime now,
}) {
  if (profile.failed ||
      profile.gpuMs <= 0 ||
      !weights.contains(profile.weights)) {
    return false;
  }
  if (!profile.matches(profile.signature, now) || !profile.useGpu(seconds)) {
    return false;
  }
  try {
    final decoded = jsonDecode(profile.signature);
    if (decoded is! Map || decoded['threads'] != threads) return false;
  } catch (_) {
    return false;
  }
  return true;
}

String asrPerformanceSignature({
  required Map<String, dynamic> configuration,
  required Map<String, dynamic> device,
  required String weights,
}) => jsonEncode({
  'v': 3,
  'os': Platform.operatingSystemVersion,
  'abi': Abi.current().toString(),
  'runtime': device['runtime'],
  'device': device['fingerprint'],
  'backend': device['backend'],
  'model': configuration['identity'],
  'weights': weights,
  'threads': configuration['threads'],
  'language': configuration['language'],
  'decoding': configuration['decoding'],
  'pipeline': configuration['pipeline'],
  'chunkSeconds': configuration['chunkSeconds'] ?? 120,
  'audioConfiguration': configuration['audioConfiguration'],
});

int asrMedian(List<int> values) {
  final sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2].clamp(1, 1 << 40);
}

/// Used only to reject grossly different probe output, never as an accuracy score.
bool asrProbeAgrees(String cpu, String gpu) {
  String canonical(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[\s\p{P}\p{S}]', unicode: true),
    '',
  );
  final a = canonical(cpu).runes.toList(), b = canonical(gpu).runes.toList();
  if (a.isEmpty || b.isEmpty) return a.isEmpty && b.isEmpty;
  if (a.length > 4000 || b.length > 4000) return false;
  var row = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 0; i < a.length; i++) {
    final next = List<int>.filled(b.length + 1, i + 1);
    for (var j = 0; j < b.length; j++) {
      final replace = row[j] + (a[i] == b[j] ? 0 : 1);
      final insert = next[j] + 1, delete = row[j + 1] + 1;
      next[j + 1] = replace < insert ? replace : insert;
      if (delete < next[j + 1]) next[j + 1] = delete;
    }
    row = next;
  }
  return 1 - row.last / (a.length > b.length ? a.length : b.length) >= .8;
}
