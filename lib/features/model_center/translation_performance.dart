import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// A workload comparison for this model and device, never a claim that GPUs
/// are universally faster. Keep CPU on near ties to avoid GPU transfer cost.
class TranslationPerformanceProfile {
  const TranslationPerformanceProfile({
    required this.signature,
    required this.testedAt,
    this.cpuMs,
    this.gpuMs,
    this.gpuFailed = false,
    this.cpuStartupMs = 0,
    this.gpuStartupMs = 0,
  });
  final String signature;
  final DateTime testedAt;
  final int? cpuMs, gpuMs;
  final bool gpuFailed;
  final int cpuStartupMs, gpuStartupMs;

  bool get useGpu =>
      !gpuFailed && cpuMs != null && gpuMs != null && gpuMs! < cpuMs! * 0.9;

  bool useGpuFor(int batches) =>
      !gpuFailed &&
      cpuMs != null &&
      gpuMs != null &&
      gpuStartupMs + gpuMs! * batches.clamp(1, 1 << 31) <
          (cpuStartupMs + cpuMs! * batches.clamp(1, 1 << 31)) * 0.9;

  bool matches(String key, DateTime now) =>
      signature == key &&
      !now.isBefore(testedAt) &&
      now.difference(testedAt) < const Duration(days: 14);

  String get summary => gpuFailed
      ? '自动模式使用 CPU · GPU 未通过本机检测，可重新测速'
      : cpuMs == null || gpuMs == null
      ? '自动模式使用 CPU · 当前设备未提供可安全测速的 GPU 后端'
      : '同批字幕 CPU ${_seconds(cpuMs!)} / GPU ${_seconds(gpuMs!)} · 自动结合启动耗时和字幕量选择';

  static String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(2)} 秒';

  Map<String, Object?> toJson() => {
    'signature': signature,
    'testedAt': testedAt.toUtc().toIso8601String(),
    'cpuMs': cpuMs,
    'gpuMs': gpuMs,
    'gpuFailed': gpuFailed,
    'cpuStartupMs': cpuStartupMs,
    'gpuStartupMs': gpuStartupMs,
  };

  static TranslationPerformanceProfile? fromJson(Object? value) {
    if (value is! Map || value['signature'] is! String) return null;
    final date = DateTime.tryParse('${value['testedAt']}');
    if (date == null) return null;
    int? positive(Object? number) =>
        number is num && number.isFinite && number > 0 ? number.toInt() : null;
    return TranslationPerformanceProfile(
      signature: value['signature'] as String,
      testedAt: date,
      cpuMs: positive(value['cpuMs']),
      gpuMs: positive(value['gpuMs']),
      gpuFailed: value['gpuFailed'] == true,
      cpuStartupMs: positive(value['cpuStartupMs']) ?? 0,
      gpuStartupMs: positive(value['gpuStartupMs']) ?? 0,
    );
  }
}

String translationPerformanceSignature({
  required String modelIdentity,
  required int threads,
  required int batchSize,
  required int gpuLayers,
  String sourceLanguage = '',
  String targetLanguage = '',
  String backend = 'auto',
}) => jsonEncode({
  'version': 3,
  'runtime': 'llamadart-0.15.1',
  'os': Platform.operatingSystemVersion,
  'abi': Abi.current().toString(),
  'processors': Platform.numberOfProcessors,
  'model': modelIdentity,
  'threads': threads,
  'batchSize': batchSize,
  'gpuLayers': gpuLayers,
  'backend': backend,
  'source': sourceLanguage,
  'target': targetLanguage,
});
