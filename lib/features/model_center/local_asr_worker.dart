import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:ffi/ffi.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
// Retain TDT durations omitted by the pinned public result wrapper.
// ignore: implementation_imports
import 'package:sherpa_onnx/src/sherpa_onnx_bindings.dart' as bindings;

import '../../models/subtitle_model.dart';
import '../../models/subtitle_asr_info.dart';
import 'asr_enhancement_options.dart';
import 'asr_enhancement_processing.dart';
import 'asr_native_enhancer.dart';
import 'local_asr_model_adapter.dart';
import 'qwen_asr_runtime.dart';
import 'cohere_asr_runtime.dart';
import 'native_asr_cpu_decoder.dart';
import 'model_adapters.dart';
import 'model_token_timing.dart';
import 'asr_accelerated_decoder.dart';
import 'asr_acceleration.dart';
import 'inference_resource_governor.dart';
import 'inference_tuning.dart';

/// Strict PCM input contract. Kept separate from FFI for format regression tests.
Float32List decodeModelWave(Uint8List bytes) {
  if (bytes.length < 44) throw const FormatException('PCM 音频头不完整');
  final view = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('需要 WAV PCM 音频');
  }
  var validFormat = false;
  var dataOffset = -1;
  var dataSize = 0;
  for (var at = 12; at + 8 <= bytes.length;) {
    final size = view.getUint32(at + 4, Endian.little);
    if (at + 8 + size > bytes.length) throw const FormatException('WAV 数据不完整');
    if (tag(at) == 'fmt ' && size >= 16) {
      validFormat =
          view.getUint16(at + 8, Endian.little) == 1 &&
          view.getUint16(at + 10, Endian.little) == 1 &&
          view.getUint32(at + 12, Endian.little) == 16000 &&
          view.getUint16(at + 22, Endian.little) == 16;
    } else if (tag(at) == 'data') {
      dataOffset = at + 8;
      dataSize = size;
    }
    at += 8 + size + (size & 1);
  }
  if (!validFormat || dataOffset < 0 || dataSize.isOdd) {
    throw const FormatException('需要 16 kHz / 单声道 / 16-bit PCM');
  }
  final samples = Float32List(dataSize ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = view.getInt16(dataOffset + i * 2, Endian.little) / 32768;
  }
  return samples;
}

enum LocalAsrStage { complete, recognition, enhancement }

class LocalAsrWorker {
  LocalAsrWorker({
    this.libraryDirectory,
    this.nativeWorkerExecutable,
    this.qwenWorkerExecutable,
    this.cohereWorkerExecutable,
    this.parakeetJapaneseWorkerExecutable,
  });
  final String? libraryDirectory;
  final String? nativeWorkerExecutable;
  final String? qwenWorkerExecutable;
  final String? cohereWorkerExecutable;
  final String? parakeetJapaneseWorkerExecutable;
  final ReceivePort _events = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _closed = Completer<void>();
  SendPort? _commands;
  Isolate? _isolate;
  Completer<List<SubtitleItem>>? _pending;
  void Function(double)? _onProgress;
  AsrPhaseProgress? _onPhase;
  Future<void> Function(List<SubtitleItem>)? _onRecognized;
  Future<void> _rawWrite = Future<void>.value();
  TransferableTypedData? _preparedAudio;
  int modelLoads = 0;
  double _lastProgress = 0;
  Map<String, dynamic>? _acceleration;
  InferenceResourceSession? _resources;
  final _permits = <int, InferenceComputePermit>{};
  final _workerPids = <int, void Function()>{};
  Completer<InferenceProbeResult>? _probe;
  Completer<void>? _trimmed;
  void Function()? _unregisterIdle, _unlistenPressure;
  int probeEstimateMs = 5000;
  final _lifetimeCancellation = Completer<void>();
  Completer<void>? _runCancellation;
  int _modelAllocationBytes = 0;
  String _modelLabel = '';
  bool hasResidentPrimary = false;
  int residentAlignmentBytes = 0;
  String? residentAlignmentId;
  int residentPunctuationBytes = 0;
  int get primaryAllocationBytes => _modelAllocationBytes;
  void Function(InferenceLane, int, InferenceBudgetDecision)? onBudget;
  void configureResources(
    InferenceResourceSession resources, {
    int modelBytes = 0,
    String modelLabel = '',
    int? workingSetBytes,
  }) {
    _unregisterIdle?.call();
    _unlistenPressure?.call();
    _resources = resources;
    _modelAllocationBytes = workingSetBytes ?? modelBytes * 2;
    _modelLabel = modelLabel;
    probeEstimateMs = math.max(
      5000,
      (modelBytes * 4 / (200 * 1024 * 1024) * 1000).ceil() + 6000,
    );
    _unregisterIdle = resources.registerIdleModel(releaseIdle);
    _unlistenPressure = resources.governor.listen(() {
      if (!resources.decision.retainModels) unawaited(releaseIdle());
    });
  }

  Future<void> releaseIdle() async {
    if (_pending != null ||
        _probe != null ||
        _commands == null ||
        _lifetimeCancellation.isCompleted) {
      return;
    }
    if (_trimmed != null) return _trimmed!.future;
    final result = _trimmed = Completer<void>();
    _commands!.send({'type': 'trim'});
    try {
      await result.future;
      hasResidentPrimary = false;
      residentAlignmentBytes = 0;
      residentAlignmentId = null;
      residentPunctuationBytes = 0;
    } finally {
      _trimmed = null;
    }
  }

  Future<void> _grant(Map value) async {
    final id = value['id'] as int;
    final lane = InferenceLane.values.firstWhere(
      (v) => v.name == value['lane'],
    );
    InferenceComputePermit? permit;
    try {
      final resources = _resources!;
      final cancelled = _runCancellation;
      permit = await resources.acquire(
        lane,
        requested: (value['threads'] as num?)?.toInt() ?? 0,
        cancelSignal: Future.any<void>([
          _lifetimeCancellation.future,
          ?cancelled?.future,
        ]),
      );
      if (_lifetimeCancellation.isCompleted || cancelled?.isCompleted == true) {
        throw StateError('任务已取消');
      }
      final allocation = (value['allocationBytes'] as num?)?.toInt() ?? 0;
      if (allocation > 0) {
        await resources.checkAllocation(
          allocation,
          permit: permit,
          modelLabel:
              lane == InferenceLane.recognition ||
                  lane == InferenceLane.compilation
              ? '本地转录模型${_modelLabel.isEmpty ? '' : '「$_modelLabel」'}'
              : '字幕增强模型',
        );
      }
      if (_lifetimeCancellation.isCompleted || cancelled?.isCompleted == true) {
        throw StateError('任务已取消');
      }
      _permits[id] = permit;
      onBudget?.call(lane, permit.threads, permit.decision);
      _commands?.send({
        'type': 'permit',
        'id': id,
        'threads': permit.threads,
        'retainModels': permit.decision.retainModels,
        'availableMemoryBytes':
            resources.governor.snapshot.availableMemoryBytes,
        'yieldMs': permit.decision.yieldDuration.inMilliseconds,
      });
    } catch (error) {
      permit?.release();
      _commands?.send({'type': 'permit', 'id': id, 'error': '$error'});
    }
  }

  void Function(Map<String, dynamic>)? _onAccelerationState;
  void configureAcceleration(
    Map<String, dynamic> configuration, {
    void Function(Map<String, dynamic>)? onState,
  }) {
    _acceleration = configuration;
    _onAccelerationState = onState;
  }

  TransferableTypedData? takePreparedAudio() {
    final audio = _preparedAudio;
    _preparedAudio = null;
    return audio;
  }

  Future<InferenceProbeResult> probeCpu(
    int threads, {
    Future<void>? cancelSignal,
  }) async {
    if (_pending != null || _probe != null) throw StateError('识别器正忙');
    final result = _probe = Completer<InferenceProbeResult>();
    final cancel = _runCancellation = Completer<void>();
    var finished = false;
    final unlisten = _resources?.governor.listen(() {
      if (_resources?.decision.allowTuning == false) {
        _commands?.send({'type': 'cancel'});
      }
    });
    cancelSignal?.then((_) {
      if (!finished) {
        if (!cancel.isCompleted) cancel.complete();
        _commands?.send({'type': 'cancel'});
      }
    });
    try {
      await _trimmed?.future;
      if (cancel.isCompleted) throw StateError('任务已取消');
      _commands!.send({'type': 'probeCpu', 'threads': threads});
      return await result.future;
    } finally {
      unlisten?.call();
      finished = true;
      _probe = null;
      if (!cancel.isCompleted) cancel.complete();
    }
  }

  Future<void> start({
    required String engine,
    required String directory,
    required String vadPath,
    required String language,
    required int threads,
    String? libraryDirectory,
    AsrEnhancementOptions enhancements = AsrEnhancementOptions.disabled,
    Map<String, String> enhancementDirectories = const {},
    bool naturalPunctuationContext = false,
    int? textProcessingVersion,
    String qwenAcceleration = 'cpu',
    LocalAsrStage stage = LocalAsrStage.complete,
    bool retainModels = false,
    String? runtimeDirectory,
  }) async {
    _events.listen((dynamic value) {
      if (value == null || value is List) {
        final error = StateError('本地识别工作线程已退出，已保留有效断点');
        if (!_ready.isCompleted) _ready.completeError(error);
        if (!_closed.isCompleted) _closed.complete();
        final pending = _pending;
        _pending = null;
        pending?.completeError(error);
        if (_probe?.isCompleted == false) _probe!.completeError(error);
        for (final permit in _permits.values) {
          permit.release();
        }
        _permits.clear();
        return;
      }
      if (value is! Map) return;
      switch (value['type']) {
        case 'trimmed':
          if (_trimmed?.isCompleted == false) _trimmed!.complete();
        case 'workerPids':
          final pids = List<int>.from(value['pids'] as List);
          for (final pid in _workerPids.keys.toList()) {
            if (!pids.contains(pid)) _workerPids.remove(pid)!();
          }
          for (final pid in pids) {
            _workerPids.putIfAbsent(
              pid,
              () => InferenceProcessRegistry.instance.retain(pid),
            );
          }
        case 'probeResult':
          probeEstimateMs = math.max(
            probeEstimateMs,
            ((value['costMs'] as int) * 1.2).ceil(),
          );
          _probe?.complete(
            InferenceProbeResult(
              baselineMs: value['baselineMs'] as int,
              candidateMs: value['candidateMs'] as int,
              startupMs: value['startupMs'] as int,
              costMs: value['costMs'] as int,
              valid: value['valid'] == true,
            ),
          );
        case 'permit':
          unawaited(_grant(value));
        case 'releasePermit':
          _permits.remove(value['id'])?.release();
        case 'ready':
          _commands = value['port'] as SendPort;
          _ready.complete();
        case 'progress':
          _lastProgress = (value['value'] as num).toDouble();
          _onProgress?.call(_lastProgress);
        case 'acceleration':
          final state = Map<String, dynamic>.from(value['state'] as Map);
          _onAccelerationState?.call(state);
          _onPhase?.call(
            'acceleration',
            _lastProgress,
            '${state['backend']} · ${state['reason']}',
          );
        case 'phase':
          _onPhase?.call(
            value['phase'] as String,
            (value['value'] as num).toDouble(),
            value['message'] as String,
          );
        case 'recognized':
          final raw = (value['cues'] as List)
              .map((e) => SubtitleItem.fromTimingJson(e as Map))
              .toList();
          _rawWrite = _onRecognized?.call(raw) ?? Future<void>.value();
          unawaited(
            _rawWrite.catchError((Object error, StackTrace stack) {
              final pending = _pending;
              _pending = null;
              pending?.completeError(error, stack);
              if (_runCancellation?.isCompleted == false) {
                _runCancellation!.complete();
              }
              _commands?.send({'type': 'cancel'});
            }),
          );
        case 'result':
          residentAlignmentId = value['alignmentResidentId'] as String?;
          hasResidentPrimary = value['primaryResident'] == true;
          residentAlignmentBytes =
              (value['alignmentResidentBytes'] as num?)?.toInt() ?? 0;
          residentPunctuationBytes =
              (value['punctuationResidentBytes'] as num?)?.toInt() ?? 0;
          probeEstimateMs =
              (value['probeEstimateMs'] as int?) ?? probeEstimateMs;
          _preparedAudio = value['audio'] as TransferableTypedData?;
          modelLoads = (value['modelLoads'] as num?)?.toInt() ?? modelLoads;
          final pending = _pending;
          _pending = null;
          pending?.complete(
            (value['cues'] as List)
                .map((e) => SubtitleItem.fromTimingJson(e as Map))
                .toList(),
          );
        case 'error':
          final error = StateError('本地识别：${value['message']}');
          if (!_ready.isCompleted) _ready.completeError(error);
          final pending = _pending;
          _pending = null;
          pending?.completeError(error);
          if (_probe?.isCompleted == false) _probe!.completeError(error);
        case 'closed':
          if (!_closed.isCompleted) _closed.complete();
      }
    });
    _isolate = await Isolate.spawn(
      _asrEntry,
      {
        'port': _events.sendPort,
        'engine': engine,
        'directory': directory,
        'vad': vadPath,
        'language': language,
        'threads': threads,
        'libraryDirectory': libraryDirectory ?? this.libraryDirectory,
        'nativeWorkerExecutable': nativeWorkerExecutable,
        'qwenWorkerExecutable': qwenWorkerExecutable,
        'cohereWorkerExecutable': cohereWorkerExecutable,
        'parakeetJapaneseWorkerExecutable': parakeetJapaneseWorkerExecutable,
        'textProcessingVersion': textProcessingVersion,
        'qwenAcceleration': qwenAcceleration,
        'enhancements': enhancements.toJson(),
        'enhancementDirectories': enhancementDirectories,
        'naturalPunctuationContext': naturalPunctuationContext,
        'stage': stage.name,
        'retainModels': retainModels,
        'resourceGates': _resources != null,
        'modelAllocationBytes': _modelAllocationBytes,
        'probeEstimateMs': probeEstimateMs,
        'runtimeDirectory': runtimeDirectory,
        'acceleration': _acceleration,
        if (Platform.isAndroid || Platform.isIOS)
          'rootToken': RootIsolateToken.instance,
      },
      onExit: _events.sendPort,
      onError: _events.sendPort,
    );
    await _ready.future.timeout(const Duration(minutes: 2));
  }

  Future<List<SubtitleItem>> recognize(
    String path, {
    void Function(double)? onProgress,
    Future<void>? cancelSignal,
    bool probe = false,
    List<SubtitleItem>? recognizedCues,
    Future<void> Function(List<SubtitleItem>)? onRecognized,
    AsrPhaseProgress? onPhase,
    TransferableTypedData? preparedAudio,
    bool prepareOnly = false,
  }) async {
    if (_pending != null) throw StateError('本地识别器正忙');
    final pending = _pending = Completer<List<SubtitleItem>>();
    final runCancellation = _runCancellation = Completer<void>();
    var finished = false;
    _onProgress = onProgress;
    _lastProgress = 0;
    _onPhase = onPhase;
    _onRecognized = onRecognized;
    _rawWrite = Future<void>.value();
    _preparedAudio = null;
    cancelSignal?.then((_) {
      if (!finished) {
        if (!runCancellation.isCompleted) runCancellation.complete();
        _commands?.send({'type': 'cancel'});
      }
    });
    try {
      await _trimmed?.future;
      if (runCancellation.isCompleted) throw StateError('任务已取消');
      _commands!.send({
        'type': 'run',
        'path': path,
        'probe': probe,
        'prepareOnly': prepareOnly,
        'audio': ?preparedAudio,
        if (recognizedCues != null)
          'recognized': recognizedCues.map((c) => c.toTimingJson()).toList(),
      });
      final result = await pending.future;
      await _rawWrite;
      return result;
    } finally {
      finished = true;
      if (identical(_pending, pending)) _pending = null;
      if (!runCancellation.isCompleted) runCancellation.complete();
      _onProgress = null;
      _onPhase = null;
      _onRecognized = null;
      await _rawWrite;
    }
  }

  Future<void> close() async {
    _unregisterIdle?.call();
    _unlistenPressure?.call();
    if (_trimmed?.isCompleted == false) _trimmed!.complete();
    if (!_lifetimeCancellation.isCompleted) _lifetimeCancellation.complete();
    if (_commands != null) {
      _commands!.send({'type': 'close'});
      await _closed.future;
    } else {
      _isolate?.kill();
    }
    _events.close();
    for (final permit in _permits.values) {
      permit.release();
    }
    _permits.clear();
    for (final unregister in _workerPids.values) {
      unregister();
    }
    _workerPids.clear();
  }
}

Future<void> _asrEntry(Map<String, dynamic> options) async {
  final events = options['port'] as SendPort;
  final commands = ReceivePort();
  InferenceProcessRegistry.instance.onChanged = (pids) =>
      events.send({'type': 'workerPids', 'pids': pids});
  Float32List? probeAudio;
  final probeEstimateMs = options['probeEstimateMs'] as int? ?? 5000;
  sherpa.OfflineRecognizer? recognizer;
  sherpa.OnlineRecognizer? streamingRecognizer;
  var cancelled = false;
  var running = false;
  var closing = false;
  var usedOrt = false;
  File? hotwordFile;
  AsrNativeEnhancer? persistentEnhancer;
  sherpa.VoiceActivityDetector? persistentVad;
  AsrAcceleratedDecoder? accelerated;
  NativeAsrCpuDecoder? nativeCpu;
  QwenAsrDecoder? qwen;
  CohereAsrDecoder? cohere;
  var asrLoads = 0;
  Future<void> close() async {
    await accelerated?.close();
    await nativeCpu?.close();
    await qwen?.close();
    await cohere?.close();
    recognizer?.free();
    recognizer = null;
    streamingRecognizer?.free();
    streamingRecognizer = null;
    await persistentEnhancer?.dispose();
    persistentEnhancer = null;
    persistentVad?.free();
    persistentVad = null;
    if (usedOrt) OrtEnv.instance.release();
    try {
      hotwordFile?.deleteSync();
    } catch (_) {
      /* A stale runtime file is safe to clean on the next storage pass. */
    }
    commands.close();
    events.send({'type': 'closed'});
  }

  try {
    if (options['rootToken'] case final RootIsolateToken token) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }
    sherpa.initBindings(options['libraryDirectory'] as String?);
    final directory = options['directory'] as String;
    final engine = options['engine'] as String;
    final adapter = localAsrAdapter(engine);
    if (adapter.architecture == LocalAsrArchitecture.qwen3Asr) {
      final weights = qwenAsrWeightFiles
          .map((name) => p.join(directory, name))
          .where((path) => File(path).existsSync())
          .toList();
      if (weights.length != 1) throw StateError('Qwen 音频模型目录必须包含一份匹配的 FP16 权重');
      final acceleration = options['acceleration'] as Map?;
      final requested = AsrEnhancementOptions.fromJson(options['enhancements']);
      qwen = QwenAsrDecoder(
        model: weights.single,
        identity: acceleration?['identity'] as String? ?? '',
        language: options['language'] as String,
        hotwords: requested.enabled ? requested.hotwords : '',
        threads: options['threads'] as int,
        mode: acceleration?['gpuAllowed'] == false
            ? 'cpu'
            : acceleration?['mode'] as String? ?? 'cpu',
        executable: options['qwenWorkerExecutable'] as String?,
        runtimeDirectory: options['runtimeDirectory'] as String?,
        profiles: [
          for (final raw in acceleration?['profiles'] as List? ?? const [])
            ?AsrPerformanceProfile.fromJson(raw),
        ],
        onLoad: () {
          asrLoads++;
          events.send({
            'type': 'phase',
            'phase': 'loading',
            'value': 0.0,
            'message': '正在加载 Qwen3-ASR FP16 模型',
          });
        },
        onState: (state) =>
            events.send({'type': 'acceleration', 'state': state}),
      );
    } else if (adapter.architecture == LocalAsrArchitecture.cohereAsr ||
        adapter.architecture == LocalAsrArchitecture.parakeetJapanese) {
      final parakeet =
          adapter.architecture == LocalAsrArchitecture.parakeetJapanese;
      final label = parakeet ? 'Parakeet 日语' : 'Cohere Transcribe';
      cohere = CohereAsrDecoder(
        model: p.join(
          directory,
          parakeet ? 'parakeet-tdt-0.6b-ja-q8_0.gguf' : cohereAsrFile,
        ),
        identity:
            (options['acceleration'] as Map?)?['identity'] as String? ?? '',
        threads: options['threads'] as int,
        executable:
            options[parakeet
                    ? 'parakeetJapaneseWorkerExecutable'
                    : 'cohereWorkerExecutable']
                as String?,
        kind: parakeet ? 'parakeet-ja' : 'cohere-asr',
        component: parakeet ? 'parakeet_ja' : 'cohere_asr',
        label: parakeet ? 'Parakeet' : 'Cohere',
        nativeTokenTiming: parakeet,
        runtimeDirectory: options['runtimeDirectory'] as String?,
        onLoad: () {
          asrLoads++;
          events.send({
            'type': 'phase',
            'phase': 'loading',
            'value': 0.0,
            'message': '正在加载 $label Q8 模型',
          });
        },
        onState: (state) =>
            events.send({'type': 'acceleration', 'state': state}),
      );
    } else if (adapter.nativeWorker ||
        Platform.isWindows && adapter.windowsNativeWorker) {
      nativeCpu = NativeAsrCpuDecoder(
        configuration: {
          'engine': engine,
          'directory': directory,
          'modelId': (options['acceleration'] as Map?)?['modelId'] ?? engine,
          'identity': (options['acceleration'] as Map?)?['identity'],
          'threads': options['threads'],
          'workerExecutable':
              options['nativeWorkerExecutable'] ??
              (options['acceleration'] as Map?)?['workerExecutable'],
          'runtimeDirectory':
              options['runtimeDirectory'] ?? Directory.systemTemp.path,
        },
        onLoad: () {
          asrLoads++;
          events.send({
            'type': 'phase',
            'phase': 'loading',
            'value': 0.0,
            'message': '正在加载主识别模型',
          });
        },
        onReady: () => events.send({
          'type': 'phase',
          'phase': 'recognizing',
          'value': 0.0,
          'message': '主识别模型已就绪',
        }),
      );
    }
    final stage = options['stage'] as String? ?? 'complete';
    var retainModels = options['retainModels'] == true;
    final gates = <int, Completer<Map>>{};
    var gateSequence = 0;
    Future<T> compute<T>(
      String lane,
      Future<T> Function(Map grant) work, {
      int allocation = 0,
      int requested = 0,
    }) async {
      if (options['resourceGates'] != true) {
        return work({
          'threads': options['threads'],
          'retainModels': retainModels,
        });
      }
      final id = ++gateSequence;
      final result = gates[id] = Completer<Map>();
      events.send({
        'type': 'permit',
        'id': id,
        'lane': lane,
        'threads': requested,
        'allocationBytes': allocation,
      });
      final grant = await result.future;
      gates.remove(id);
      if (grant['error'] != null) throw StateError('${grant['error']}');
      try {
        if (cancelled) throw StateError('任务已取消');
        final delay = (grant['yieldMs'] as num?)?.toInt() ?? 0;
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
        if (cancelled) throw StateError('任务已取消');
        return await work(grant);
      } finally {
        events.send({'type': 'releasePermit', 'id': id});
      }
    }

    Future<void> cpuThreads(int threads) async {
      if (options['threads'] == threads) return;
      await accelerated?.releaseForEnhancement();
      await nativeCpu?.release();
      await qwen?.release();
      await cohere?.release();
      recognizer?.free();
      recognizer = null;
      streamingRecognizer?.free();
      streamingRecognizer = null;
      options['threads'] = threads;
      accelerated?.configuration['threads'] = threads;
      nativeCpu?.configuration['threads'] = threads;
      if (qwen != null) qwen.threads = threads;
      if (cohere != null) cohere.threads = threads;
    }

    Future<void> trim() async {
      await accelerated?.releaseForEnhancement();
      await nativeCpu?.release();
      await qwen?.release();
      await cohere?.release();
      recognizer?.free();
      recognizer = null;
      streamingRecognizer?.free();
      streamingRecognizer = null;
      await persistentEnhancer?.dispose();
      persistentVad?.free();
      persistentVad = null;
    }

    final enhancements = AsrEnhancementOptions.fromJson(
      options['enhancements'],
    );
    sherpa.OfflineRecognizer createRecognizer() {
      return sherpa.OfflineRecognizer(
        localOfflineAsrConfiguration(
          engine: engine,
          directory: directory,
          language: options['language'] as String,
          threads: options['threads'] as int,
          hotwordsFile: hotwordFile?.path ?? '',
        ),
      );
    }

    final cohereLanguage =
        adapter.fixedLanguage ??
        normalizeAsrLanguage(options['language'] as String);
    Future<Map<String, dynamic>> decodeCpu(
      Float32List audio,
      void Function() check,
    ) async {
      if (nativeCpu != null) return nativeCpu.decode(audio, check);
      if (qwen != null) return qwen.decode(audio, check, forceCpu: true);
      if (cohere != null) {
        return cohere.decode(audio, check, language: cohereLanguage);
      }
      if (!adapter.streaming) {
        if (recognizer == null) {
          events.send({
            'type': 'phase',
            'phase': 'loading',
            'value': 0.0,
            'message': '正在加载主识别模型',
          });
          asrLoads++;
          recognizer = createRecognizer();
          events.send({
            'type': 'phase',
            'phase': 'recognizing',
            'value': 0.0,
            'message': '主识别模型已就绪',
          });
        }
        final stream = recognizer!.createStream();
        try {
          stream.acceptWaveform(samples: audio, sampleRate: 16000);
          recognizer!.decode(stream);
          final result = _nativeAsrResult(stream);
          return adapter.architecture == LocalAsrArchitecture.whisper
              ? {
                  ...result,
                  '_backend': 'CPU',
                  '_weights':
                      (options['acceleration'] as Map?)?['identity'] ?? '',
                }
              : result;
        } finally {
          stream.free();
        }
      }
      // This Tiny export has cached encoder states and a fixed 39-frame input.
      // It must use the streaming runtime even for file transcription. Loading
      // it as an offline encoder can terminate the native process.
      if (streamingRecognizer == null) {
        events.send({
          'type': 'phase',
          'phase': 'loading',
          'value': 0.0,
          'message': '正在加载主识别模型',
        });
        asrLoads++;
      }
      streamingRecognizer ??= sherpa.OnlineRecognizer(
        localStreamingAsrConfiguration(
          engine: engine,
          directory: directory,
          threads: options['threads'] as int,
          hotwordsFile: hotwordFile?.path ?? '',
        ),
      );
      final stream = streamingRecognizer!.createStream();
      try {
        Future<void> drain() async {
          while (streamingRecognizer!.isReady(stream)) {
            check();
            streamingRecognizer!.decode(stream);
            await Future<void>.delayed(Duration.zero);
          }
        }

        for (var at = 0; at < audio.length; at += 5120) {
          check();
          stream.acceptWaveform(
            samples: Float32List.sublistView(
              audio,
              at,
              math.min(at + 5120, audio.length),
            ),
            sampleRate: 16000,
          );
          await drain();
        }
        stream.acceptWaveform(samples: Float32List(4800), sampleRate: 16000);
        stream.inputFinished();
        await drain();
        return streamingRecognizer!.getResult(stream).toJson();
      } finally {
        stream.free();
      }
    }

    if (options['acceleration'] is Map && qwen == null && cohere == null) {
      accelerated = AsrAcceleratedDecoder(
        configuration: {
          ...Map<String, dynamic>.from(options['acceleration'] as Map),
          'engine': engine,
          'nativeCpu': nativeCpu != null,
          if (options['nativeWorkerExecutable'] != null)
            'workerExecutable': options['nativeWorkerExecutable'],
          'directory': directory,
          'language': options['language'],
          'threads': options['threads'],
          'runtimeDirectory': options['runtimeDirectory'] ?? directory,
        },
        releaseCpu: () async {
          await nativeCpu?.release();
          await qwen?.release();
          recognizer?.free();
          recognizer = null;
          streamingRecognizer?.free();
          streamingRecognizer = null;
        },
        onState: (state) =>
            events.send({'type': 'acceleration', 'state': state}),
      );
    }
    Future<Map<String, dynamic>> decode(
      Float32List audio,
      void Function() check,
    ) async {
      if (adapter.supportsHotwords &&
          qwen == null &&
          enhancements.enabled &&
          enhancements.hotwords.trim().isNotEmpty &&
          hotwordFile == null) {
        encodeAsrHotwords(
          enhancements.hotwords,
          await File(p.join(directory, 'tokens.txt')).readAsString(),
        );
        hotwordFile = File(
          p.join(
            options['runtimeDirectory'] as String? ?? directory,
            'asr-hotwords-${DateTime.now().microsecondsSinceEpoch}.txt',
          ),
        );
        // Native BPE expects source phrases, rather than pre-encoded pieces.
        await hotwordFile!.writeAsString(
          enhancements.hotwords.toUpperCase(),
          flush: true,
        );
      }
      accelerated?.configuration['hotwordsFile'] = hotwordFile?.path ?? '';
      return compute(
        accelerated?.needsExclusiveLoad == true ? 'compilation' : 'recognition',
        (grant) async {
          if (grant['availableMemoryBytes'] is num && accelerated != null) {
            final bytes = (grant['availableMemoryBytes'] as num).toInt();
            final old =
                (accelerated.configuration['gpuAvailableMemoryBytes'] as num?)
                    ?.toInt();
            accelerated.configuration['gpuAvailableMemoryBytes'] = old == null
                ? bytes
                : math.min(old, bytes);
          }
          await cpuThreads(grant['threads'] as int);
          retainModels =
              options['retainModels'] == true && grant['retainModels'] != false;
          if (qwen != null) return qwen.decode(audio, check);
          return accelerated?.decode(
                audio,
                cpu: () => decodeCpu(audio, check),
                cpuProbe: (probe) => decodeCpu(probe, check),
                check: check,
              ) ??
              decodeCpu(audio, check);
        },
        allocation:
            recognizer == null &&
                nativeCpu?.hasLoadedModel != true &&
                qwen?.hasLoadedModel != true &&
                cohere?.hasLoadedModel != true &&
                streamingRecognizer == null &&
                accelerated?.hasLoadedModel != true
            ? (options['modelAllocationBytes'] as int? ?? 0)
            : 0,
      );
    }

    commands.listen((dynamic value) async {
      if (value is! Map) return;
      if (value['type'] == 'permit') {
        gates[value['id']]?.complete(value);
        return;
      }
      if (value['type'] == 'cancel') {
        cancelled = true;
        await accelerated?.cancel();
        await nativeCpu?.release();
        await qwen?.release();
        await cohere?.release();
        return;
      }
      if (value['type'] == 'trim') {
        if (!running) {
          running = true;
          try {
            await trim();
          } finally {
            running = false;
          }
        }
        events.send({'type': 'trimmed'});
        if (closing) await close();
        return;
      }
      if (value['type'] == 'close') {
        cancelled = true;
        closing = true;
        await accelerated?.cancel();
        await nativeCpu?.release();
        await qwen?.release();
        await cohere?.release();
        if (!running) await close();
        return;
      }
      if (value['type'] == 'probeCpu' && !running) {
        running = true;
        cancelled = false;
        final baselineThreads = options['threads'] as int;
        final watch = Stopwatch()..start();
        Map<String, Object?>? report;
        try {
          await compute('tuning', (grant) async {
            final audio = probeAudio;
            if (audio == null || accelerated?.hasLoadedModel == true) {
              throw StateError('暂无可对照的 CPU 样本');
            }
            void check() {
              if (cancelled) throw StateError('任务已取消');
            }

            String identity(Map value) => jsonEncode([
              value['text'],
              value['tokens'],
              value['timestamps'],
            ]);
            // Recreate both instances, so candidate load costs are not hidden.
            await cpuThreads(-1);
            await cpuThreads(baselineThreads);
            final loading = Stopwatch()..start();
            final baseline = await decodeCpu(audio, check);
            final base = loading.elapsedMilliseconds.clamp(1, 1 << 31);
            check();
            await cpuThreads(
              (value['threads'] as int).clamp(1, grant['threads'] as int),
            );
            loading
              ..reset()
              ..start();
            final candidate = await decodeCpu(audio, check);
            final next = loading.elapsedMilliseconds.clamp(1, 1 << 31);
            check();
            report = {
              'type': 'probeResult',
              'baselineMs': base,
              'candidateMs': next,
              'startupMs': math.max(base, next),
              'costMs': watch.elapsedMilliseconds,
              'valid': identity(baseline) == identity(candidate),
            };
          }, requested: math.max(baselineThreads, value['threads'] as int));
        } catch (error) {
          report = {'type': 'error', 'message': '$error'};
        } finally {
          await cpuThreads(baselineThreads);
          running = false;
          if (report != null) {
            if (report!['type'] == 'probeResult') {
              report!['costMs'] = watch.elapsedMilliseconds;
            }
            events.send(report);
          }
          if (closing) await close();
        }
        return;
      }
      if (value['type'] != 'run' || running) return;
      running = true;
      cancelled = false;
      sherpa.VoiceActivityDetector? vad;
      try {
        final preparedAudio = value['audio'] as TransferableTypedData?;
        var samples = preparedAudio != null
            ? preparedAudio.materialize().asFloat32List()
            : decodeModelWave(
                await File(value['path'] as String).readAsBytes(),
              );
        void check() {
          if (cancelled) throw StateError('任务已取消');
        }

        final enhancer = persistentEnhancer ??= AsrNativeEnhancer(
          options: enhancements,
          directories: Map<String, String>.from(
            options['enhancementDirectories'] as Map? ?? const {},
          ),
          threads: options['resourceGates'] == true
              ? 1
              : options['threads'] as int,
          language: options['language'] as String,
          recognitionEngine: engine,
          naturalPunctuationContext:
              options['naturalPunctuationContext'] == true,
          textProcessingVersion: options['textProcessingVersion'] as int?,
          qwenWorkerExecutable: options['qwenWorkerExecutable'] as String?,
          qwenAcceleration: options['qwenAcceleration'] as String? ?? 'cpu',
          retainModels: retainModels,
          beforeAlignment: stage == 'complete'
              ? () async {
                  await accelerated?.releaseForEnhancement();
                  await nativeCpu?.release();
                  await qwen?.release();
                  await cohere?.release();
                  recognizer?.free();
                  recognizer = null;
                  streamingRecognizer?.free();
                  streamingRecognizer = null;
                }
              : null,
          checkCancelled: check,
          progress: (phase, fraction, message) => events.send({
            'type': 'phase',
            'phase': phase,
            'value': fraction,
            'message': message,
          }),
        );
        if (stage == 'complete' && value['recognized'] is! List) {
          await enhancer.releaseAlignment();
        }
        final benchmarking =
            value['probe'] == true &&
            accelerated?.configuration['benchmark'] == true;
        if (value['probe'] == true && !benchmarking) {
          await decode(samples, check);
          events.send({'type': 'result', 'cues': <Map<String, Object?>>[]});
          return;
        }
        if (preparedAudio == null) {
          samples = await compute('auxiliary', (grant) {
            enhancer.retainModels =
                options['retainModels'] == true &&
                grant['retainModels'] != false;
            return enhancer.denoise(samples);
          }, allocation: enhancer.denoiseAllocationBytes);
        }
        check();
        // This owner also performs refinement, serially. Its next-piece
        // denoising can overlap recognition on a different isolate without
        // loading a second ASR model or passing a native handle across threads.
        if (value['prepareOnly'] == true) {
          events.send({
            'type': 'result',
            'cues': <Map<String, Object?>>[],
            'audio': TransferableTypedData.fromList([
              samples.buffer.asUint8List(
                samples.offsetInBytes,
                samples.lengthInBytes,
              ),
            ]),
            'modelLoads': asrLoads,
            'alignmentResidentBytes': enhancer.residentAlignmentBytes,
            'alignmentResidentId': enhancer.residentAlignmentId,
            'punctuationResidentBytes': enhancer.residentPunctuationBytes,
          });
          return;
        }
        var cues = <SubtitleItem>[
          if (value['recognized'] is List)
            ...(value['recognized'] as List).map(
              (e) => SubtitleItem.fromTimingJson(e as Map),
            ),
        ];
        if (stage == 'enhancement' && value['recognized'] is! List) {
          throw StateError('增强阶段需要已经识别的原文');
        }
        if (value['recognized'] is! List) {
          events.send({
            'type': 'phase',
            'phase': 'vad',
            'value': 0.0,
            'message': '正在检测语音区间',
          });
          var segments = await compute('auxiliary', (grant) async {
            persistentVad?.reset();
            vad =
                persistentVad ??
                sherpa.VoiceActivityDetector(
                  config: sherpa.VadModelConfig(
                    sileroVad: sherpa.SileroVadModelConfig(
                      model: options['vad'] as String,
                      threshold: enhancements.enabled
                          ? enhancements.vadThreshold
                          : .5,
                      minSilenceDuration: cohere != null
                          ? math.min(
                                  enhancements.enabled
                                      ? enhancements.minSilenceMs
                                      : 300,
                                  adapter.architecture ==
                                          LocalAsrArchitecture.parakeetJapanese
                                      ? 150
                                      : 220,
                                ) /
                                1000
                          : enhancements.enabled
                          ? enhancements.minSilenceMs / 1000
                          : .3,
                      minSpeechDuration: enhancements.enabled
                          ? enhancements.minSpeechMs / 1000
                          : .2,
                      maxSpeechDuration: cohere != null
                          ? math.min(
                              enhancements.enabled
                                  ? enhancements.maxSpeechMs / 1000
                                  : 8,
                              8,
                            )
                          : qwen != null
                          ? math.min(
                              enhancements.enabled
                                  ? enhancements.maxSpeechMs / 1000
                                  : 12,
                              23.5,
                            )
                          : enhancements.enabled
                          ? enhancements.maxSpeechMs / 1000
                          : 12,
                    ),
                    sampleRate: 16000,
                    numThreads: 1,
                    debug: false,
                  ),
                  bufferSizeInSeconds: 60,
                );
            if (retainModels) persistentVad = vad;
            final segments = <({int start, int end})>[];
            Future<void> drain() async {
              while (!vad!.isEmpty()) {
                check();
                final segment = _nativeVadRange(vad!);
                vad!.pop();
                final start = segment.start.clamp(0, samples.length);
                final end = (segment.start + segment.length).clamp(
                  start,
                  samples.length,
                );
                if (end > start) segments.add((start: start, end: end));
                await Future<void>.delayed(Duration.zero);
              }
            }

            // Keep the pinned Silero API's exact 512-sample cadence. Larger calls
            // change detected boundaries in this runtime. Reuse PCM views instead.
            for (var at = 0; at < samples.length; at += 512) {
              check();
              final available = math.min(512, samples.length - at);
              final window = available == 512
                  ? Float32List.sublistView(samples, at, at + available)
                  : (Float32List(512)..setRange(0, available, samples, at));
              vad!.acceptWaveform(window);
              await drain();
              if (at % 16384 == 0) {
                events.send({
                  'type': 'phase',
                  'phase': 'vad',
                  'value': at / math.max(1, samples.length),
                  'message': '正在检测语音区间',
                });
                events.send({
                  'type': 'progress',
                  'value': at / math.max(1, samples.length) * .1,
                });
                await Future<void>.delayed(Duration.zero);
              }
            }
            vad!.flush();
            await drain();
            events.send({
              'type': 'phase',
              'phase': 'vad',
              'value': 1.0,
              'message': '语音区间检测完成',
            });
            return segments;
          });
          if (cohere != null) {
            segments = splitCohereSpeechRanges(segments, samples);
          }
          final ranges = <({int start, int end})>[];
          for (var i = 0; i < segments.length; i++) {
            check();
            final segment = segments[i];
            final pad = enhancements.enabled ? enhancements.paddingMs * 16 : 0;
            final lower = i > 0
                ? (segments[i - 1].end + segment.start) ~/ 2
                : 0;
            final upper = i + 1 < segments.length
                ? (segment.end + segments[i + 1].start) ~/ 2
                : samples.length;
            final start = math.max(lower, segment.start - pad);
            final end = math.min(upper, segment.end + pad);
            ranges.add((start: start, end: end));
          }
          if (accelerated != null && samples.isNotEmpty) {
            accelerated.configuration.addAll({
              'voiceFraction':
                  ranges.fold<int>(0, (n, r) => n + r.end - r.start) /
                  samples.length,
              'segmentsPerSecond': ranges.length * 16000 / samples.length,
            });
          }
          if (benchmarking) {
            if (ranges.isEmpty) throw StateError('测速样本中没有有效语音');
            final selected = ranges
                .where((r) => r.end - r.start >= 3 * 16000)
                .firstOrNull;
            final chosen = <({int start, int end})>[];
            var count = 0;
            for (final range in selected == null ? ranges : [selected]) {
              final available = math.min(
                range.end - range.start,
                (cohere != null ? 8 : 12) * 16000 - count,
              );
              chosen.add((start: range.start, end: range.start + available));
              count += available;
              if (count >= 3 * 16000) break;
            }
            final probe = Float32List(math.max(3 * 16000, count));
            var at = 0;
            for (final range in chosen) {
              probe.setRange(
                at,
                at + range.end - range.start,
                samples,
                range.start,
              );
              at += range.end - range.start;
            }
            await decode(probe, check);
            events.send({'type': 'result', 'cues': <Map<String, Object?>>[]});
            return;
          }
          for (var i = 0; i < ranges.length; i++) {
            check();
            final start = ranges[i].start, end = ranges[i].end;
            if (accelerated != null) {
              accelerated.configuration['hotwordsFile'] =
                  hotwordFile?.path ?? '';
            }
            final raw = await decode(
              Float32List.sublistView(samples, start, end),
              check,
            );
            // Keep at most three seconds in this model owner, until it closes.
            // Only statistics cross the isolate boundary during CPU tuning.
            if ((end - start >= 3 * 16000 || probeAudio == null) &&
                (raw['text'] as String? ?? '').trim().isNotEmpty) {
              probeAudio = Float32List.fromList(
                Float32List.sublistView(
                  samples,
                  start,
                  math.min(samples.length, start + 3 * 16000),
                ),
              );
            }
            final text = (raw['text'] as String? ?? '')
                .replaceAll(RegExp(r'<\|[^>]*\|>'), '')
                .trim();
            final tokens = List<String>.from(
              raw['tokens'] as List? ?? const [],
            );
            final starts = (raw['timestamps'] as List? ?? const [])
                .map((e) => (e as num).toDouble())
                .toList();
            final durations = (raw['durations'] as List? ?? const [])
                .map((e) => (e as num).toDouble())
                .toList();
            if (text.isNotEmpty) {
              cues.add(
                SubtitleItem(
                  index: cues.length + 1,
                  startTime: Duration(microseconds: start * 1000000 ~/ 16000),
                  endTime: Duration(microseconds: end * 1000000 ~/ 16000),
                  text: text,
                  asrInfo: SubtitleAsrInfo(
                    backend: raw['_backend'] as String? ?? '',
                    weights: raw['_weights'] as String? ?? '',
                    language: normalizeAsrLanguage(
                      raw['lang'] as String? ?? '',
                    ),
                    notes: [
                      if (enhancements.enabled &&
                          enhancements.hotwords.isNotEmpty &&
                          !adapter.supportsHotwords)
                        '当前识别引擎不支持热词，词表未用于改写原文',
                    ],
                  ),
                  timedSpans: alignModelTokens(
                    text: text,
                    tokens: tokens,
                    starts: starts,
                    ends: durations.length == starts.length && starts.isNotEmpty
                        ? [
                            for (var j = 0; j < starts.length; j++)
                              starts[j] + durations[j],
                          ]
                        : null,
                    offset: start / 16000,
                    cueEnd: end / 16000,
                  ),
                ),
              );
            }
            events.send({
              'type': 'progress',
              'value': .1 + end / math.max(1, samples.length) * .9,
            });
            await Future<void>.delayed(Duration.zero);
          }
          events.send({
            'type': 'recognized',
            'cues': cues.map((c) => c.toTimingJson()).toList(),
          });
        }
        if (stage == 'recognition') {
          if (!retainModels) {
            await accelerated?.releaseForEnhancement();
            await nativeCpu?.release();
            await qwen?.release();
            await cohere?.release();
            recognizer?.free();
            recognizer = null;
            streamingRecognizer?.free();
            streamingRecognizer = null;
          }
          events.send({
            'type': 'result',
            'cues': cues.map((c) => c.toTimingJson()).toList(),
            'audio': TransferableTypedData.fromList([
              samples.buffer.asUint8List(
                samples.offsetInBytes,
                samples.lengthInBytes,
              ),
            ]),
            'modelLoads': asrLoads,
            'probeEstimateMs': probeEstimateMs,
            'primaryResident':
                recognizer != null ||
                nativeCpu?.hasLoadedModel == true ||
                qwen?.hasLoadedModel == true ||
                cohere?.hasLoadedModel == true ||
                streamingRecognizer != null ||
                accelerated?.hasLoadedModel == true,
          });
          return;
        }
        if (!retainModels) {
          await accelerated?.releaseForEnhancement();
          await nativeCpu?.release();
          await qwen?.release();
          await cohere?.release();
          recognizer?.free();
          recognizer = null;
          streamingRecognizer?.free();
          streamingRecognizer = null;
        }
        // ASR weights are released before the larger CTC alignment model loads.
        try {
          // Resolve inexpensive language routing before admitting any large
          // aligner. An unresolved Han/Latin segment must not reserve every
          // prepared language's largest model as if it were about to load it.
          if (enhancements.enabled &&
              usesAsrTextProcessing(options['textProcessingVersion'] as int?)) {
            final languageAllocation = enhancer.languageAllocationBytes(cues);
            if (languageAllocation > 0) await enhancer.releaseAlignment();
            try {
              cues = await compute(
                'auxiliary',
                (_) => enhancer.resolveLanguages(cues, samples),
                allocation: languageAllocation,
              );
            } catch (error) {
              check();
              if (!isTransientInferencePressure(error)) rethrow;
              cues = await enhancer.resolveLanguages(
                cues,
                samples,
                allowAudioModel: false,
              );
            }
          }
          check();
          await enhancer.releaseUnusedModels(cues);
          var alignmentAllocation = enhancer.alignmentAllocationBytes(
            cues,
            languagesResolved: true,
          );
          if (alignmentAllocation > 0) {
            await enhancer.beforeAlignment?.call();
            await enhancer.releaseAlignment();
          }
          final heavyAlignment = enhancer.needsQwenAlignment(
            cues,
            languagesResolved: true,
          );
          Future<List<SubtitleItem>> refine({bool alignment = true}) => compute(
            alignment && heavyAlignment ? 'alignment' : 'auxiliary',
            (grant) {
              enhancer.qwenThreads = grant['threads'] as int;
              enhancer.retainModels =
                  options['retainModels'] == true &&
                  grant['retainModels'] != false;
              return enhancer.enhance(
                cues,
                samples,
                languagesResolved: true,
                allowAlignment: alignment,
              );
            },
            allocation:
                (alignment ? alignmentAllocation : 0) +
                enhancer.punctuationAllocationBytes(
                  cues,
                  languagesResolved: true,
                ) +
                enhancer.resolvedTextAllocationBytes,
            requested: alignment && heavyAlignment ? 6 : 0,
          );
          List<SubtitleItem> memoryFallback(String reason) => [
            for (final cue in cues)
              cue.copyWith(
                asrInfo: cue.asrInfo.copyWith(
                  reviewReason: enhancements.review
                      ? reason
                      : cue.asrInfo.reviewReason,
                  notes: [...cue.asrInfo.notes, reason],
                ),
              ),
          ];
          late List<SubtitleItem> result;
          try {
            result = await refine();
          } catch (error) {
            check();
            if (!isTransientInferencePressure(error)) {
              rethrow;
            }
            if (alignmentAllocation == 0) {
              result = memoryFallback('增强可用内存不足，已保留识别文字和原有时间');
            } else {
              await enhancer.releaseAlignment();
              var cpuSucceeded = false;
              if (heavyAlignment && options['qwenAcceleration'] != 'cpu') {
                enhancer.useCpuAlignmentForMemory();
                alignmentAllocation = enhancer.alignmentAllocationBytes(
                  cues,
                  languagesResolved: true,
                );
                try {
                  result = await refine();
                  result = [
                    for (final cue in result)
                      cue.copyWith(
                        asrInfo: cue.asrInfo.copyWith(
                          notes: [...cue.asrInfo.notes, '内存预算不足，本批共享精校改用 CPU'],
                        ),
                      ),
                  ];
                  cpuSucceeded = true;
                } catch (cpuError) {
                  check();
                  if (!isTransientInferencePressure(cpuError)) rethrow;
                }
              }
              if (!cpuSucceeded) {
                cues = memoryFallback('精校可用内存不足，保留原有时间并继续转录');
                await enhancer.releaseAlignment();
                try {
                  result = await refine(alignment: false);
                } catch (fallbackError) {
                  check();
                  if (!isTransientInferencePressure(fallbackError)) rethrow;
                  result = memoryFallback('增强可用内存不足，已保留识别文字和原有时间');
                }
              }
            }
          }
          check();
          events.send({
            'type': 'result',
            'cues': result.map((c) => c.toTimingJson()).toList(),
            'modelLoads': asrLoads,
            'probeEstimateMs': probeEstimateMs,
            'alignmentResidentBytes': enhancer.residentAlignmentBytes,
            'alignmentResidentId': enhancer.residentAlignmentId,
            'punctuationResidentBytes': enhancer.residentPunctuationBytes,
            'primaryResident':
                recognizer != null ||
                nativeCpu?.hasLoadedModel == true ||
                qwen?.hasLoadedModel == true ||
                cohere?.hasLoadedModel == true ||
                streamingRecognizer != null ||
                accelerated?.hasLoadedModel == true,
          });
        } finally {
          usedOrt = usedOrt || enhancer.usedOrt;
        }
      } catch (error) {
        events.send({'type': 'error', 'message': '$error'});
      } finally {
        if (!identical(vad, persistentVad)) vad?.free();
        running = false;
        if (closing) await close();
      }
    });
    events.send({'type': 'ready', 'port': commands.sendPort});
  } catch (error) {
    events.send({'type': 'error', 'message': '$error'});
    await close();
  }
}

({int start, int length}) _nativeVadRange(sherpa.VoiceActivityDetector vad) {
  final segment =
      bindings.SherpaOnnxBindings.voiceActivityDetectorFront?.call(vad.ptr) ??
      nullptr;
  if (segment == nullptr) throw StateError('语音区间读取失败');
  try {
    // The chunk already owns the PCM; only retain segment coordinates.
    return (start: segment.ref.start, length: segment.ref.n);
  } finally {
    bindings.SherpaOnnxBindings.destroySpeechSegment?.call(segment);
  }
}

Map<String, dynamic> _nativeAsrResult(sherpa.OfflineStream stream) {
  final pointer =
      bindings.SherpaOnnxBindings.getOfflineStreamResultAsJson?.call(
        stream.ptr,
      ) ??
      nullptr;
  if (pointer == nullptr) throw StateError('识别模型没有返回原生结果');
  try {
    return Map<String, dynamic>.from(
      jsonDecode(pointer.cast<Utf8>().toDartString()) as Map,
    );
  } finally {
    bindings.SherpaOnnxBindings.destroyOfflineStreamResultJson?.call(pointer);
  }
}
