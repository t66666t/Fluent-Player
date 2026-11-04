import 'package:llamadart/llamadart.dart';

/// Only routes shipped by the pinned llama.cpp bundle. GGUF is not a QNN or
/// LiteRT-LM model; an enum in another runtime does not make it NPU-compatible.
List<GpuBackend> translationGpuRoutes(
  String platform, {
  String backend = 'auto',
}) {
  final available = switch (platform) {
    'android' => const [GpuBackend.opencl, GpuBackend.vulkan],
    'windows' || 'linux' => const [GpuBackend.cuda, GpuBackend.vulkan],
    'macos' || 'ios' => const [GpuBackend.metal],
    _ => const <GpuBackend>[],
  };
  return backend == 'auto'
      ? available
      : available.where((route) => route.name == backend).toList();
}

ModelParams isolatedTranslationModelParams({
  required String platform,
  required GpuBackend backend,
  required int threads,
  required int promptThreads,
  required int gpuLayers,
}) {
  if (!translationGpuRoutes(platform).contains(backend)) {
    throw ArgumentError('当前系统没有对应的翻译加速路线');
  }
  return ModelParams(
    contextSize: 4096,
    device: ComputeDevice.gpu,
    preferredBackend: backend,
    gpuLayers: gpuLayers.clamp(1, 999),
    numberOfThreads: threads.clamp(1, 12),
    numberOfThreadsBatch: promptThreads.clamp(1, 12),
    batchSize: 256,
    // Keep upstream's subgroup-size and unknown-driver guard on Android.
    // Overriding it can corrupt text/grammar processing on Mali hardware.
    microBatchSize: platform == 'android' ? 0 : 128,
  );
}
