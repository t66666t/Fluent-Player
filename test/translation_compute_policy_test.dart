import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/translation_compute_policy.dart';
import 'package:video_player_app/features/model_center/translation_performance.dart';

void main() {
  test(
    'platform routes cover shipped modules without treating GGUF as an NPU model',
    () {
      expect(translationGpuRoutes('android'), [
        GpuBackend.opencl,
        GpuBackend.vulkan,
      ]);
      for (final platform in ['windows', 'linux']) {
        expect(translationGpuRoutes(platform), [
          GpuBackend.cuda,
          GpuBackend.vulkan,
        ]);
      }
      expect(translationGpuRoutes('macos'), [GpuBackend.metal]);
      expect(translationGpuRoutes('ios'), [GpuBackend.metal]);
      expect(translationGpuRoutes('android', backend: 'cuda'), isEmpty);
      expect(translationGpuRoutes('android', backend: 'opencl'), [
        GpuBackend.opencl,
      ]);
      expect(translationGpuRoutes('android', backend: 'qnn'), isEmpty);
    },
  );
  test(
    'private GPU parameters enforce actual offload and Android subgroup protection',
    () {
      final android = isolatedTranslationModelParams(
        platform: 'android',
        backend: GpuBackend.vulkan,
        threads: 4,
        promptThreads: 6,
        gpuLayers: 24,
      );
      expect(android.device, ComputeDevice.gpu);
      expect(android.preferredBackend, GpuBackend.vulkan);
      expect(android.gpuLayers, 24);
      expect(android.microBatchSize, 0);
      final cuda = isolatedTranslationModelParams(
        platform: 'windows',
        backend: GpuBackend.cuda,
        threads: 99,
        promptThreads: 99,
        gpuLayers: 999,
      );
      expect(cuda.numberOfThreads, 12);
      expect(cuda.numberOfThreadsBatch, 12);
      expect(cuda.device, ComputeDevice.gpu);
      expect(cuda.microBatchSize, 128);
    },
  );
  test(
    'old task JSON stays identical and new route selection round trips independently',
    () {
      const old = LocalTranslationOptions();
      expect(old.toJson(), {
        'acceleration': 'auto',
        'threads': 0,
        'batchSize': 8,
      });
      for (final backend in ['opencl', 'vulkan', 'cuda', 'metal']) {
        final value = old.copyWith(backend: backend);
        expect(
          LocalTranslationOptions.fromJson(value.toJson()).backend,
          backend,
        );
        expect(value.copyWith(threads: 4).backend, backend);
        expect(value.copyWith(backend: 'auto').toJson(), old.toJson());
      }
      expect(
        LocalTranslationOptions.fromJson({'backend': 'qnn'}).backend,
        'auto',
      );
    },
  );
  test('measured profiles never cross user-selected GPU routes', () {
    String signature(String route) => translationPerformanceSignature(
      modelIdentity: 'model@revision',
      threads: 4,
      batchSize: 8,
      gpuLayers: 32,
      backend: route,
    );
    expect(signature('cuda'), isNot(signature('vulkan')));
    expect(signature('auto'), isNot(signature('opencl')));
  });
}
