import 'dart:math' as math;

import 'model_device_info.dart';
import 'model_catalog.dart';
import 'device_resource_snapshot.dart';
import 'inference_resource_governor.dart';
import 'translation_memory.dart';

/// A task owns this budget inside the shared heavy-inference reservation.
/// Each native model has one owner; only different stages overlap.
class AsrExecutionPlan {
  const AsrExecutionPlan({
    required this.pipeline,
    required this.asrThreads,
    required this.enhancementThreads,
    required this.reason,
    this.reuseModels = false,
    this.preprocessAhead = false,
    this.retainTranslation = false,
    this.manualMemorySaver = false,
  });
  final bool pipeline;
  final bool reuseModels;
  final bool preprocessAhead;
  final bool retainTranslation, manualMemorySaver;
  final int asrThreads, enhancementThreads;
  final String reason;
  Duration get chunkDuration =>
      Duration(seconds: pipeline || reuseModels ? 60 : 120);

  /// Only ASR/GGUF residency is estimated here. Occasional CTC loads can evict
  /// idle GGUF via runtime admission, without disabling the workflow pipeline.
  AsrExecutionPlan withLocalTranslation({
    required ModelDeviceInfo device,
    required String platform,
    required int modelBytes,
    required int translationBytes,
    int? translationWorkingSetBytes,
    required int alignmentBytes,
    required int lightweightBytes,
    required AsrExecutionMode mode,
  }) {
    const gib = 1073741824;
    final mobile = platform == 'android' || platform == 'ios';
    final physical = device.memoryBytes ?? 0;
    final common =
        (translationWorkingSetBytes ??
            translationAllocationBytes(translationBytes)) +
        lightweightBytes * 3;
    final serial = common + modelBytes * 2;
    bool fits(int workingSet) =>
        physical >= workingSet + gib &&
        (device.availableMemoryBytes != null
            ? device.availableMemoryBytes! > workingSet + gib ~/ 2
            : !mobile && physical >= math.max(16 * gib, workingSet * 2));
    final retain =
        mode != AsrExecutionMode.lowMemory &&
        translationBytes > 0 &&
        fits(serial);
    // Keep workflow topology separate from optional cross-stage residency.
    // Actual loads are admitted against fresh, additional memory at runtime.
    final overlap = pipeline && mode != AsrExecutionMode.lowMemory;
    return AsrExecutionPlan(
      pipeline: overlap,
      reuseModels: reuseModels && mode != AsrExecutionMode.lowMemory,
      preprocessAhead: overlap && preprocessAhead,
      asrThreads: asrThreads,
      enhancementThreads: enhancementThreads,
      retainTranslation: retain,
      manualMemorySaver:
          manualMemorySaver || mode == AsrExecutionMode.lowMemory,
      reason: overlap
          ? '识别与增强并行 · 翻译按批处理，避免争用处理器'
          : retain
          ? '分阶段处理 · 复用翻译模型，识别与时间精校交替加载'
          : '分阶段处理 · 内存余量有限，按需加载模型',
    );
  }

  static AsrExecutionPlan choose({
    required ModelDeviceInfo device,
    required String platform,
    required int requestedThreads,
    required int modelBytes,
    required int enhancementBytes,
    int? alignmentBytes,
    int lightweightEnhancementBytes = 0,
    bool hasPostProcessing = true,
    bool hasDenoising = false,
    AsrExecutionMode mode = AsrExecutionMode.auto,
  }) {
    final resource =
        InferenceResourceSession.current?.governor ??
        InferenceResourceGovernor(
          DeviceResourceSnapshot(
            platform: platform,
            processors: device.processors,
            memoryBytes: device.memoryBytes,
            availableMemoryBytes: device.availableMemoryBytes,
            capturedAt: DateTime.now(),
          ),
        );
    final overlap =
        mode != AsrExecutionMode.lowMemory &&
        (hasPostProcessing || hasDenoising);
    final decision = resource.decide(
      asrMaximum: requestedThreads,
      pipelineRequested: overlap,
    );
    final budget = decision.totalThreads;
    final reuse = mode != AsrExecutionMode.lowMemory;
    final asr = overlap
        ? math.min(
            requestedThreads > 0 ? requestedThreads.clamp(1, 12) : budget,
            math.max(1, budget - (decision.pipeline ? 1 : 0)),
          )
        : math.min(
            requestedThreads > 0 ? requestedThreads.clamp(1, 12) : budget,
            math.max(1, budget),
          );
    return AsrExecutionPlan(
      pipeline: overlap,
      reuseModels: reuse,
      preprocessAhead: overlap && hasDenoising,
      asrThreads: asr,
      enhancementThreads: 1,
      manualMemorySaver: mode == AsrExecutionMode.lowMemory,
      reason: overlap
          ? hasDenoising
                ? '降噪与识别流水线 · 识别当前块时预降噪下一块；降噪与字幕增强共用一个工作线程'
                : '双阶段流水线 · 识别与上一片段增强重叠'
          : mode == AsrExecutionMode.lowMemory
          ? '节省内存 · 分阶段释放模型'
          : reuse
          ? '顺序处理 · 复用主模型与轻量增强，按需释放精校模型'
          : '当前内存或 CPU 余量不足，使用顺序处理',
    );
  }
}
