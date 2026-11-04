import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'asr_acceleration.dart';
import 'asr_accelerator_transport.dart';
import 'asr_enhancement_processing.dart';
import 'asr_execution_plan.dart';
import 'inference_scheduler.dart';
import 'inference_resource_governor.dart';
import 'local_asr_worker.dart';
import 'cohere_asr_runtime.dart';
import 'model_adapters.dart';
import 'model_catalog.dart';
import 'model_center_service.dart';
import 'model_device_info.dart';
import 'qwen_asr_runtime.dart';

/// Explicit benchmarking uses bundled speech and never downloads enhancement
/// weights, edits subtitles or changes the user's CPU/GPU preference.
Future<void> benchmarkLocalAsr({
  required ModelCenterService center,
  required ModelArtifact model,
  required Future<void> cancelSignal,
  required void Function(String) onProgress,
}) async {
  var cancelled = false, finished = false;
  cancelSignal.then((_) {
    if (!finished) cancelled = true;
  });
  void check() {
    if (cancelled) throw StateError('测速已取消');
  }

  final pack = center.artifact(asrAccelerationPackId(model.id));
  final requestedThreads = center.asrCpuThreads;
  final language = center.languageForModel(model);
  final enhancements = center.asrEnhancementsFor(model);
  final execution = center.asrExecution;
  final spec = ModelJobSpec(
    profile: ModelServiceProfile(
      id: 'asr-benchmark',
      name: model.name,
      kind: TranscriptionServiceKind.local,
      model: model.id,
    ),
    artifactIdentity: model.identity,
    asrAcceleration: AsrAcceleration.auto,
    asrAccelerationModels: {if (pack != null) pack.id: pack.identity},
  );
  try {
    final vad = await center.prepareAsrVad(
      cancelSignal: cancelSignal,
      onProgress: onProgress,
    );
    check();
    await InferenceScheduler.instance.run(
      () => center.usingAsrModels(spec, (primary, directory, extras) async {
        check();
        if (!InferenceResourceSession.current!.decision.allowTuning) {
          throw StateError('当前设备有资源压力，请稍后测速');
        }
        final device = await ModelDeviceInfo.load();
        final enhancementBytes = enhancements
            .requiredModels(model.languages, language)
            .fold<int>(0, (n, id) => n + (center.artifact(id)?.bytes ?? 0));
        final plan = AsrExecutionPlan.choose(
          device: device,
          platform: Platform.operatingSystem,
          requestedThreads: requestedThreads,
          modelBytes: model.bytes,
          enhancementBytes: enhancementBytes,
          mode: execution,
        );
        final root = await center.storage.featureDirectory('model_jobs');
        final temporary = await root.createTemp('asr-benchmark-');
        final wave = File(p.join(temporary.path, 'speech.wav'));
        final worker = LocalAsrWorker();
        worker.configureResources(
          InferenceResourceSession.current!,
          modelBytes: model.bytes,
          workingSetBytes: model.engine == 'cohere-asr'
              ? cohereAudioWorkingSetBytes(model.bytes)
              : model.engine == 'parakeet-ja'
              ? parakeetJapaneseWorkingSetBytes(model.bytes)
              : null,
        );
        var updates = Future<void>.value();
        try {
          final source = await rootBundle.load(
            localAsrProbeAsset(
              model.engine,
              model.languages,
              language: language,
            ),
          );
          await wave.writeAsBytes(
            source.buffer.asUint8List(
              source.offsetInBytes,
              source.lengthInBytes,
            ),
          );
          if (model.engine == 'qwen3-asr') {
            await _benchmarkQwen(
              center,
              model,
              directory,
              wave,
              plan.asrThreads,
              language,
              enhancements.enabled ? enhancements.hotwords.trim() : '',
              cancelSignal,
              check,
              onProgress,
            );
            return;
          }
          worker.configureAcceleration(
            {
              'mode': 'auto',
              'benchmark': true,
              'accelerationEnvironment':
                  await AsrAcceleratorTransport.environment(),
              'modelId': model.id,
              'identity': model.identity,
              'durationSeconds': 180.0,
              'pipeline': plan.pipeline,
              'chunkSeconds': plan.chunkDuration.inMilliseconds / 1000,
              'audioConfiguration': enhancements.audioJson,
              'decoding': enhancements.enabled
                  ? enhancements.hotwords.trim()
                  : '',
              'gpuAllowed':
                  device.availableMemoryBytes != null ||
                  (!Platform.isAndroid &&
                      !Platform.isIOS &&
                      (device.memoryGb ?? 0) >= 16),
              'gpuAvailableMemoryBytes': device.availableMemoryBytes == null
                  ? null
                  : math.max(
                      0,
                      device.availableMemoryBytes! -
                          enhancementBytes * 3 -
                          1073741824,
                    ),
              'modelBytes': model.bytes,
              if (extras[pack?.id] != null) ...{
                'gpuDirectory': extras[pack!.id],
                'gpuIdentity': pack.identity,
                'gpuModelBytes': pack.bytes,
              },
            },
            onState: (state) {
              onProgress('${state['backend']} · ${state['reason']}');
              updates = updates.then(
                (_) => center.recordAsrState(model.id, state),
              );
            },
          );
          check();
          await worker.start(
            engine: model.engine,
            directory: directory.path,
            vadPath: vad.path,
            language: language,
            threads: plan.asrThreads,
            enhancements: enhancements.copyWith(
              denoise: false,
              punctuation: false,
              alignment: false,
              trimSilence: false,
              review: false,
            ),
            retainModels: true,
            stage: LocalAsrStage.recognition,
            runtimeDirectory: root.path,
          );
          check();
          await worker.recognize(
            wave.path,
            probe: true,
            cancelSignal: cancelSignal,
          );
          check();
        } finally {
          await worker.close();
          await updates;
          if (await wave.exists()) await wave.delete();
          if (await vad.exists()) await vad.delete();
          await temporary.delete();
        }
      }),
      cancelSignal: cancelSignal,
    );
  } finally {
    finished = true;
  }
}

Future<void> _benchmarkQwen(
  ModelCenterService center,
  ModelArtifact model,
  Directory directory,
  File wave,
  int threads,
  String language,
  String hotwords,
  Future<void> cancelSignal,
  void Function() check,
  void Function(String) progress,
) async {
  final runtime = QwenAsrRuntime();
  var finished = false;
  cancelSignal.then((_) {
    if (!finished) unawaited(runtime.close());
  });
  try {
    await InferenceResourceSession.current!.run(
      InferenceLane.tuning,
      (permit) async {
        threads = math.min(threads, permit.threads);
        await InferenceResourceSession.current!.checkAllocation(
          qwenAudioWorkingSetBytes(model.bytes),
          permit: permit,
        );
        final audio = decodeModelWave(await wave.readAsBytes());
        final weight = p.join(directory.path, model.files.single.name);
        var gpu = 'cpu';
        try {
          gpu = await runtime.preferredBackend();
        } catch (_) {
          check();
          await runtime.release();
        }
        check();
        final signature = runtime.performanceSignature(
          model.identity,
          threads,
          language,
          hotwords,
        );
        final cold = <String, int>{}, steady = <String, int>{};
        final texts = <String, String>{};
        String? gpuFailure;
        for (final backend in ['cpu', if (gpu != 'cpu') gpu]) {
          await runtime.release();
          try {
            if (backend != 'cpu') {
              await InferenceResourceSession.current!.checkAllocation(
                qwenAudioWorkingSetBytes(model.bytes, gpu: true),
                permit: permit,
              );
            }
            progress('正在测量 Qwen FP16 · $backend');
            final watch = Stopwatch()..start();
            await runtime.load(
              kind: 'asr',
              model: weight,
              threads: threads,
              backend: backend,
              language: language,
              hotwords: hotwords,
            );
            await runtime.audioRequest('decode', audio, check);
            cold[backend] = watch.elapsedMilliseconds;
            final timings = <int>[];
            for (var i = 0; i < 3; i++) {
              check();
              watch.reset();
              final result =
                  (await runtime.audioRequest('decode', audio, check))['result']
                      as Map;
              if (backend != 'cpu' &&
                  (result['gpuOperators'] as num? ?? 0) <= 0) {
                throw StateError('GPU 未执行有效算子');
              }
              timings.add(watch.elapsedMilliseconds);
              texts[backend] = result['text'] as String;
            }
            steady[backend] = asrMedian(timings);
          } catch (error) {
            check();
            if (backend == 'cpu') rethrow;
            gpuFailure = isTransientInferencePressure(error)
                ? 'GPU 当前可用内存不足'
                : 'GPU 检查未通过，保留 CPU 结果';
          }
        }
        if (gpuFailure != null) {
          final reason = 'CPU ${steady['cpu']} ms · $gpuFailure';
          // An interrupted GPU measurement is not a valid calibration. In
          // particular, temporary pressure must not persist a failed profile.
          await center.recordAsrState(model.id, {
            'backend': 'CPU',
            'reason': reason,
          });
          progress(reason);
          return;
        }
        final agrees =
            gpu != 'cpu' && asrProbeAgrees(texts['cpu']!, texts[gpu]!);
        final profile = AsrPerformanceProfile(
          signature: signature,
          testedAt: DateTime.now(),
          backend: gpu,
          device: jsonEncode(runtime.capabilities['devices']),
          weights: model.identity,
          sampleSeconds: audio.length / 16000,
          cpuMs: steady['cpu']!,
          gpuMs: steady[gpu] ?? 0,
          cpuStartupMs: math.max(0, cold['cpu']! - steady['cpu']!),
          gpuStartupMs: math.max(0, (cold[gpu] ?? 0) - (steady[gpu] ?? 0)),
          failed: !agrees,
          failureReason: gpu == 'cpu'
              ? '没有可用 GPU 组件'
              : agrees
              ? ''
              : 'CPU 与 GPU 测试文字差异过大',
        );
        await center.recordAsrState(model.id, {
          'backend': gpu,
          'reason': profile.summary,
          'profile': profile.toJson(),
        });
        progress(profile.summary);
      },
      requested: threads,
      cancelSignal: cancelSignal,
    );
  } finally {
    finished = true;
    await runtime.close();
  }
}
