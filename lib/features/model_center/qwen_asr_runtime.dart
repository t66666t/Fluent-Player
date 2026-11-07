import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'asr_accelerator_transport.dart';
import 'asr_acceleration.dart';
import 'asr_enhancement_processing.dart';
import 'inference_resource_governor.dart';

bool isQwenWorkerUnavailable(Object error, {String label = 'Qwen'}) => [
  '$label 音频进程已退出',
  '$label 音频组件已关闭',
  '$label 原生组件不可用（IllegalStateException）',
].any(error.toString().contains);

/// Each owner has its own native context. No text-translation runtime is used.
class QwenAsrRuntime {
  QwenAsrRuntime({
    this.executable,
    this.runtimeDirectory,
    this.component = 'qwen_asr',
    this.label = 'Qwen',
    this.maximumAudioSeconds = 25,
    Future<AsrAcceleratorTransport> Function()? openTransport,
  }) : _openTransport = openTransport;

  final String? executable, runtimeDirectory;
  final String component, label;
  final int maximumAudioSeconds;
  final Future<AsrAcceleratorTransport> Function()? _openTransport;
  AsrAcceleratorTransport? _transport;
  Directory? _temporary;
  String? _identity;
  bool _closed = false;
  int _generation = 0;
  Future<void>? _releasing;
  String backend = 'CPU';
  Map<String, dynamic> capabilities = const {};
  bool get hasLoadedModel => _identity != null;
  bool get isOpen => _transport != null;

  /// Size and mtime only. Content hashing would reread multi-gigabyte weights
  /// on every task just to decide whether an old GPU record still applies.
  static String? desktopRuntimeStamp({String component = 'qwen_asr'}) {
    if (Platform.isAndroid || Platform.isIOS) return null;
    final file = File(desktopExecutable(component: component));
    if (!file.existsSync()) return null;
    final stat = file.statSync();
    return '${stat.size}:${stat.modified.toUtc().toIso8601String()}';
  }

  /// Android records a native crash or a hung GPU fence on the bridge. A
  /// low-memory process kill must not be stored as a broken GPU.
  static Future<bool> gpuFaultConfirmed(String component) async {
    if (!Platform.isAndroid) return false;
    try {
      final value = await MethodChannel(
        'com.example.video_player_app/$component',
      ).invokeMapMethod<String, dynamic>('gpuStatus');
      return value?['gpuNativeCrash'] == true || value?['gpuTimedOut'] == true;
    } catch (_) {
      return false;
    }
  }

  static String desktopExecutable({
    String? executable,
    String component = 'qwen_asr',
  }) {
    final base = p.dirname(executable ?? Platform.resolvedExecutable);
    return Platform.isMacOS
        ? p.normalize(
            p.join(base, '..', 'Helpers', component, '${component}_worker'),
          )
        : p.join(
            base,
            'resources',
            component,
            Platform.isWindows
                ? '${component}_worker.exe'
                : '${component}_worker',
          );
  }

  Future<AsrAcceleratorTransport> _open() async {
    if (_openTransport != null) return _openTransport();
    if (Platform.isAndroid || Platform.isIOS) {
      return _QwenMobileTransport.open(component: component, label: label);
    }
    final path = executable ?? desktopExecutable(component: component);
    if (!await File(path).exists()) {
      throw StateError('当前安装未提供匹配的 $label 音频组件');
    }
    return ProcessAsrAcceleratorTransport.start(
      path,
      loadTimeout: const Duration(minutes: 5),
      requestTimeout: const Duration(minutes: 12),
      environment: {'GGML_BACKEND_PATH': p.dirname(path)},
    );
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> message) async {
    await _releasing;
    if (_closed) throw StateError('$label 音频组件已关闭');
    final generation = _generation;
    if (_transport == null) {
      final transport = await _open();
      if (_closed || generation != _generation) {
        await transport.close();
        throw StateError('转录已取消');
      }
      _transport = transport;
    }
    final response = await _transport!.request(message);
    if (_closed || generation != _generation) throw StateError('转录已取消');
    return response;
  }

  Future<String> preferredBackend() async {
    final response = capabilities = await request({'op': 'capabilities'});
    final devices = (response['devices'] as List? ?? const [])
        .whereType<Map>()
        .where((d) => d['gpu'] == true)
        .map((d) => '${d['name']}'.toLowerCase());
    for (final backend in ['cuda', 'vulkan', 'metal']) {
      if (devices.any((name) => name.startsWith(backend))) return backend;
    }
    return 'cpu';
  }

  String performanceSignature(
    String identity,
    int threads,
    String language,
    String hotwords,
  ) => jsonEncode({
    'scope': 'qwen-audio-v1',
    'model': identity,
    'build': capabilities['build'],
    'devices': capabilities['devices'],
    'os': Platform.operatingSystemVersion,
    'threads': threads,
    'language': language,
    'hotwords': hotwords,
  });

  Future<void> load({
    required String kind,
    required String model,
    required int threads,
    String backend = 'cpu',
    String language = 'auto',
    String hotwords = '',
  }) async {
    language = normalizeAsrLanguage(language);
    final identity = '$kind\n$model\n$threads\n$backend\n$language\n$hotwords';
    if (_identity == identity) return;
    _identity = null;
    final response = await request({
      'op': 'load',
      'kind': kind,
      'model': model,
      'threads': threads,
      'backend': backend,
      'language': language,
      'hotwords': hotwords,
    });
    this.backend = response['backend'] as String? ?? 'CPU';
    _identity = identity;
  }

  Future<Map<String, dynamic>> audioRequest(
    String operation,
    Float32List audio,
    void Function() check, {
    Map<String, dynamic> fields = const {},
  }) async {
    check();
    if (audio.isEmpty || audio.length > maximumAudioSeconds * 16000) {
      throw ArgumentError(
        '$label 单段输入必须为 0–$maximumAudioSeconds 秒的 16 kHz 单声道音频',
      );
    }
    final generation = _generation;
    if (_temporary == null) {
      final parent = Directory(
        Platform.isAndroid || Platform.isIOS
            ? Directory.systemTemp.path
            : runtimeDirectory ?? Directory.systemTemp.path,
      );
      await parent.create(recursive: true);
      _temporary = await parent.createTemp('qwen-pcm-');
    }
    final file = File(
      p.join(_temporary!.path, '${DateTime.now().microsecondsSinceEpoch}.f32'),
    );
    try {
      await file.writeAsBytes(
        audio.buffer.asUint8List(audio.offsetInBytes, audio.lengthInBytes),
      );
      check();
      if (generation != _generation) throw StateError('转录已取消');
      final result = await request({
        'op': operation,
        'path': file.path,
        ...fields,
      });
      check();
      return result;
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> release() => _releasing ??= _release().whenComplete(() {
    _releasing = null;
  });
  Future<void> _release() async {
    _generation++;
    _identity = null;
    final transport = _transport;
    final temporary = _temporary;
    _transport = null;
    _temporary = null;
    await transport?.close();
    if (temporary != null && await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  }

  Future<void> close() async {
    _closed = true;
    await release();
  }
}

/// Uses the same PCM contract in the Android private service / Apple queue.
/// Owner IDs keep recognition and enhancement handles independent.
class _QwenMobileTransport implements AsrAcceleratorTransport {
  _QwenMobileTransport(this.owner, String component, this.label)
    : _channel = MethodChannel('com.example.video_player_app/$component');
  final MethodChannel _channel;
  final String label;
  final String owner;
  bool _closed = false;
  void Function()? _unregister;
  static Future<_QwenMobileTransport> open({
    required String component,
    required String label,
  }) async {
    final value = _QwenMobileTransport(
      '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 31)}',
      component,
      label,
    );
    await value.request({'op': 'open'});
    return value;
  }

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> message) async {
    if (_closed) throw StateError('$label 音频组件已关闭');
    final value = await _channel.invokeMapMethod<String, dynamic>('request', {
      'owner': owner,
      ...message,
    });
    if (_closed) throw StateError('转录已取消');
    if (value == null || value['ok'] != true) {
      throw StateError('${value?['error'] ?? '$label 音频推理失败'}');
    }
    final pid = (value['workerPid'] as num?)?.toInt();
    if (pid != null && pid > 0) {
      _unregister ??= InferenceProcessRegistry.instance.retain(pid);
    }
    return value;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.invokeMethod<void>('close', {'owner': owner});
    } catch (_) {
      /* Already exited. */
    } finally {
      _unregister?.call();
    }
  }
}

class QwenAsrDecoder {
  QwenAsrDecoder({
    required this.model,
    required this.identity,
    required this.language,
    required this.hotwords,
    required this.onLoad,
    required this.onState,
    required this.threads,
    this.mode = 'auto',
    this.executable,
    this.runtimeDirectory,
    this.profiles = const [],
    this.runtimeFactory,
    this.conservativeGpu = false,
    this.component = 'qwen_asr',
    this.accelerationEnvironment,
    this.runtimeStamp,
    DateTime Function()? now,
    this.confirmGpuFault,
  }) : _now = now ?? DateTime.now;
  final String model, identity, language, hotwords, mode;
  final String? executable, runtimeDirectory;
  final List<AsrPerformanceProfile> profiles;
  final QwenAsrRuntime Function()? runtimeFactory;
  final void Function() onLoad;
  final void Function(Map<String, dynamic>) onState;

  /// Phones skip an unproven GPU. Desktop keeps the existing eager probe.
  final bool conservativeGpu;
  final String component;
  final Object? accelerationEnvironment, runtimeStamp;
  final DateTime Function() _now;
  final Future<bool> Function()? confirmGpuFault;
  int threads;
  QwenAsrRuntime? _runtime;
  bool _cpuFallback = false;
  bool _lastForcedCpu = false;
  int _generation = 0;
  bool get hasLoadedModel => _runtime?.hasLoadedModel == true;
  bool get usingGpu =>
      hasLoadedModel && !(_runtime!.backend.toLowerCase().startsWith('cpu'));

  Map<String, dynamic> get _availability => {
    'accelerationEnvironment': accelerationEnvironment,
    'identity': identity,
    'language': language,
    'hotwords': hotwords,
    'runtimeStamp': runtimeStamp,
  };
  Future<Map<String, dynamic>> decode(
    Float32List audio,
    void Function() check, {
    bool forceCpu = false,
  }) async {
    if (_lastForcedCpu != forceCpu) {
      // A CPU session can serve a later forced-CPU probe. Reloading it only
      // spends another full weight read.
      if (forceCpu && usingGpu) await release();
      _lastForcedCpu = forceCpu;
    }
    final generation = _generation;
    void valid() {
      check();
      if (generation != _generation) throw StateError('转录已取消');
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      var selected = 'cpu';
      try {
        valid();
        final runtime = _runtime ??=
            runtimeFactory?.call() ??
            QwenAsrRuntime(
              executable: executable,
              runtimeDirectory: runtimeDirectory,
              component: component,
            );
        if (!runtime.hasLoadedModel) {
          if (!forceCpu && mode != 'cpu' && !_cpuFallback) {
            final now = _now();
            final seconds = audio.length / 16000;
            final availability = qwenAvailabilitySignature(
              _availability,
              component: component,
            );
            final failed = profiles.any(
              (profile) => profile.failed && profile.matches(availability, now),
            );
            final fresh = profiles.any(
              (profile) => freshGpuWin(
                profile,
                weights: {identity},
                threads: threads,
                seconds: seconds,
                now: now,
              ),
            );
            // No driver init and no weight load when the phone has nothing
            // that already proved GPU is faster for these exact threads.
            if (failed || (conservativeGpu && mode == 'auto' && !fresh)) {
              selected = 'cpu';
              if (failed) _cpuFallback = true;
            } else {
              selected = 'gpu';
              onState({
                'backend': 'GPU',
                'reason': '正在检查 GPU 能力',
                'weights': identity,
                'selecting': true,
              });
              selected = await runtime.preferredBackend();
              if (mode == 'auto') {
                final signature = runtime.performanceSignature(
                  identity,
                  threads,
                  language,
                  hotwords,
                );
                final profile = profiles
                    .where((p) => p.matches(signature, now))
                    .firstOrNull;
                if (profile != null && !profile.useGpu(seconds)) {
                  selected = 'cpu';
                } else if (conservativeGpu && profile == null) {
                  selected = 'cpu';
                }
              }
            }
          }
          valid();
          onLoad();
          await runtime.load(
            kind: 'asr',
            model: model,
            threads: threads,
            backend: selected,
            language: language,
            hotwords: hotwords,
          );
          valid();
          onState({
            'backend': runtime.backend,
            'reason': _cpuFallback
                ? 'GPU 不可用，已回退 CPU'
                : runtime.capabilities['gpuUnavailableReason'] ??
                      '原生 FP16 音频识别',
            'weights': identity,
          });
        } else {
          selected = runtime.backend.toLowerCase().startsWith('cpu')
              ? 'cpu'
              : runtime.backend;
        }
        final response = await runtime.audioRequest('decode', audio, valid);
        final result = Map<String, dynamic>.from(response['result'] as Map);
        if (!runtime.backend.toLowerCase().startsWith('cpu') &&
            (result['gpuOperators'] as num? ?? 0) <= 0) {
          throw StateError('此模型未在 GPU 执行有效算子，使用 CPU');
        }
        if (result['text'] is! String ||
            result['timingKind'] != 'segment' ||
            result['lang'] is! String) {
          throw StateError('Qwen 返回的识别结果无效');
        }
        return {...result, '_backend': runtime.backend, '_weights': identity};
      } catch (error) {
        final gpuAttempt = selected != 'cpu';
        await _runtime?.close();
        _runtime = null;
        final cancelled =
            '$error'.contains('转录已取消') || generation != _generation;
        if (!cancelled) valid();
        if (gpuAttempt && !cancelled && !isTransientInferencePressure(error)) {
          final exited = isQwenWorkerUnavailable(error);
          final confirmed =
              !exited ||
              await (confirmGpuFault ??
                  () => QwenAsrRuntime.gpuFaultConfirmed(component))();
          if (confirmed && generation == _generation) {
            onState({
              'backend': 'CPU',
              'reason': 'GPU 不可用，已回退 CPU',
              'weights': identity,
              'profile': AsrPerformanceProfile(
                signature: qwenAvailabilitySignature(
                  _availability,
                  component: component,
                ),
                testedAt: _now(),
                backend: 'GPU',
                device: 'preflight',
                weights: identity,
                sampleSeconds: 1,
                cpuMs: 0,
                gpuMs: 0,
                failed: true,
                failureReason: '$error',
              ).toJson(),
            });
          }
        }
        if (cancelled) throw StateError('转录已取消');
        if (attempt == 1 ||
            selected == 'cpu' && !isQwenWorkerUnavailable(error)) {
          rethrow;
        }
        _cpuFallback = _cpuFallback || selected != 'cpu';
      }
    }
    throw StateError('Qwen 音频推理失败');
  }

  Future<void> release() async {
    _generation++;
    final runtime = _runtime;
    _runtime = null;
    await runtime?.close();
  }

  Future<void> close() => release();
}
