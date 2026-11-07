import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'asr_acceleration.dart';
import 'inference_resource_governor.dart';
import 'asr_accelerator_transport.dart';

typedef AsrCpuDecode = Future<Map<String, dynamic>> Function();

/// Owns one native session at a time. Failed acceleration is disabled for the
/// rest of this task; cancelling never turns into a CPU retry.
class AsrAcceleratedDecoder {
  AsrAcceleratedDecoder({
    required this.configuration,
    required this.releaseCpu,
    required this.onState,
    Future<AsrAcceleratorTransport> Function()? openTransport,
    DateTime Function()? now,
  }) : _open =
           openTransport ??
           (() => AsrAcceleratorTransport.open(
             executable: configuration['workerExecutable'] as String?,
           )),
       _now = now ?? DateTime.now;

  final Map<String, dynamic> configuration;
  final FutureOr<void> Function() releaseCpu;
  final void Function(Map<String, dynamic>) onState;
  final Future<AsrAcceleratorTransport> Function() _open;
  final DateTime Function() _now;
  AsrAcceleratorTransport? _transport;
  Directory? _privateDirectory;
  Future<void>? _dropping;
  Map<String, dynamic>? _chosen;
  Map<String, dynamic>? _capabilities;
  Float32List? _measuredAudio;
  Map<String, dynamic>? _measuredCpu;
  bool _decided = false, _disabled = false, _cancelled = false;
  String backend = 'CPU', weights = '';
  bool get hasLoadedModel => _chosen != null;
  bool get _deferUnprovenGpu {
    if (configuration['conservativeGpu'] != true) return false;
    if (mode != AsrAcceleration.auto) return false;
    if (configuration['benchmark'] == true) return false;
    final threads = (configuration['threads'] as num?)?.toInt() ?? 0;
    final seconds = (configuration['durationSeconds'] as num?)?.toDouble() ?? 0;
    final weights = {
      configuration['identity'],
      configuration['gpuIdentity'],
    }.whereType<String>().toSet();
    final profiles = (configuration['profiles'] as List? ?? const [])
        .map(AsrPerformanceProfile.fromJson)
        .whereType<AsrPerformanceProfile>();
    return !profiles.any(
      (profile) => freshGpuWin(
        profile,
        weights: weights,
        threads: threads,
        seconds: seconds,
        now: _now(),
      ),
    );
  }

  bool get needsExclusiveLoad =>
      !_disabled &&
      _chosen == null &&
      !_deferUnprovenGpu &&
      (!_decided || _chosenTarget != null) &&
      (mode == AsrAcceleration.gpu ||
          configuration['benchmark'] == true ||
          mode == AsrAcceleration.auto &&
              (configuration['automaticTuningAllowed'] != false ||
                  (configuration['profiles'] as List? ?? const []).isNotEmpty));

  void _state(
    String reason, {
    AsrPerformanceProfile? profile,
    bool selecting = false,
  }) => onState({
    'backend': backend,
    'weights': weights,
    'reason': reason,
    if (selecting) 'selecting': true,
    if (_transport is ProcessAsrAcceleratorTransport)
      'processId': (_transport as ProcessAsrAcceleratorTransport).processId,
    if (profile != null) 'profile': profile.toJson(),
    if (profile != null && !profile.failed) ...{
      'clearProfileSignature': asrAvailabilitySignature(configuration),
      'clearProfileSignatures': [
        asrAvailabilitySignature(configuration),
        asrAvailabilitySignatureV1(configuration),
      ],
    },
  });

  void _rememberUnavailable(String reason) => _state(
    reason,
    profile: AsrPerformanceProfile(
      signature: asrAvailabilitySignature(configuration),
      testedAt: _now(),
      backend: 'GPU / 硬件加速',
      device: 'preflight',
      weights: configuration['identity'] as String? ?? '',
      sampleSeconds: 1,
      cpuMs: 0,
      gpuMs: 0,
      failed: true,
      failureReason: reason,
    ),
  );

  AsrAcceleration get mode => AsrAcceleration.values.firstWhere(
    (v) => v.name == configuration['mode'],
    orElse: () => AsrAcceleration.cpu,
  );

  Future<AsrAcceleratorTransport> _connection() async {
    if (_cancelled) throw StateError('转录已取消');
    if (_transport != null) return _transport!;
    final opened = await _open();
    if (_cancelled) {
      await opened.close();
      throw StateError('转录已取消');
    }
    return _transport = opened;
  }

  void _check(void Function() check) {
    if (_cancelled) throw StateError('转录已取消');
    check();
  }

  Future<void> _dropGpu() => _dropping ??= _dropOwnedGpu().whenComplete(() {
    _dropping = null;
  });

  Future<void> _dropOwnedGpu() async {
    final transport = _transport;
    _transport = null;
    final directory = _privateDirectory;
    _privateDirectory = null;
    try {
      await transport?.close();
    } finally {
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  Future<Map<String, dynamic>> _gpu(
    Float32List audio,
    Map<String, dynamic> choice,
    void Function() check,
  ) async {
    _check(check);
    if (_chosen == null) await releaseCpu();
    final transport = await _connection();
    _check(check);
    if (_chosen == null) {
      final root = Directory(configuration['runtimeDirectory'] as String);
      await root.create(recursive: true);
      _check(check);
      _privateDirectory ??= await root.createTemp('asr-gpu-run-');
      _check(check);
      _state('正在加载并验证 ${choice['label']}', selecting: true);
      await transport.request({
        'op': 'load',
        ...configuration,
        'directory': choice['directory'],
        'weightsIdentity': choice['weights'],
        'floatWeights': choice['floatWeights'],
        'backend': choice['backend'],
        'device': choice['device'],
        'profileRoot': _privateDirectory!.path,
        'cacheRoot': configuration['runtimeDirectory'],
        'cacheSignature': choice['signature'],
      });
      _chosen = choice;
    }
    _check(check);
    // Binder opens only application-private PCM. A user-selected model storage
    // root can be elsewhere; keep mobile transport files in the private cache.
    final dir = Platform.isAndroid || Platform.isIOS
        ? Directory.systemTemp
        : Directory(configuration['runtimeDirectory'] as String);
    await dir.create(recursive: true);
    final temporary = await dir.createTemp('asr-gpu-pcm-');
    final file = File('${temporary.path}${Platform.pathSeparator}samples.f32');
    try {
      await file.writeAsBytes(
        audio.buffer.asUint8List(audio.offsetInBytes, audio.lengthInBytes),
      );
      _check(check);
      final response = await transport.request({
        'op': 'decode',
        'path': file.path,
      });
      _check(check);
      if (response['acceleratedNodes'] is! num ||
          (response['acceleratedNodes'] as num) <= 0) {
        throw StateError('后端未将识别计算分配给硬件加速器');
      }
      final result = Map<String, dynamic>.from(response['result'] as Map);
      if (result['text'] is! String ||
          (result['text'] as String).trim().isEmpty) {
        throw StateError('GPU 没有返回有效识别文字');
      }
      final tokens = result['tokens'];
      if (tokens is! List || tokens.any((v) => v is! String)) {
        throw StateError('GPU 返回的识别词块无效');
      }
      final starts = result['timestamps'];
      if (starts is! List ||
          (starts.isNotEmpty && starts.length != tokens.length)) {
        throw StateError('GPU 返回的词块时间数量不匹配');
      }
      if (result['lang'] != null && result['lang'] is! String) {
        throw StateError('GPU 返回的语言信息无效');
      }
      final durations = result['durations'];
      if (durations != null &&
          (durations is! List ||
              (durations.isNotEmpty && durations.length != tokens.length))) {
        throw StateError('GPU 返回的词块时长无效');
      }
      for (final key in ['timestamps', 'durations']) {
        if (result[key] case final List values) {
          if (values.any(
            (v) =>
                v is! num ||
                !v.isFinite ||
                v < 0 ||
                v > audio.length / 16000 + 1,
          )) {
            throw StateError('GPU 返回的时间轴无效');
          }
          if (key == 'timestamps') {
            for (var i = 1; i < values.length; i++) {
              if ((values[i] as num) < (values[i - 1] as num)) {
                throw StateError('GPU 时间轴没有按顺序返回');
              }
            }
          }
        }
      }
      return result;
    } finally {
      if (await file.exists()) await file.delete();
      await temporary.delete();
    }
  }

  Future<void> _select(
    Float32List audio,
    AsrCpuDecode cpu,
    void Function() check,
  ) async {
    if (mode == AsrAcceleration.cpu) {
      _decided = true;
      _state(configuration['legacy'] == true ? '旧任务沿用 CPU' : '用户选择 CPU');
      return;
    }
    final force = configuration['benchmark'] == true;
    final profiles = (configuration['profiles'] as List? ?? const [])
        .map(AsrPerformanceProfile.fromJson)
        .whereType<AsrPerformanceProfile>()
        .toList();
    if (!force &&
        profiles.any(
          (profile) =>
              profile.failed &&
              asrAvailabilityMatches(profile, configuration, _now()),
        )) {
      _decided = true;
      _state('沿用本机 CPU 选择，可在模型中心重新测速');
      return;
    }
    // Memory pressure is transient. Recheck this cheap budget on the next job,
    // without launching GPU or presenting it as a hardware failure.
    if (configuration['gpuAllowed'] == false) {
      _decided = true;
      _state('当前内存预算优先使用 CPU');
      return;
    }
    final seconds = (configuration['durationSeconds'] as num?)?.toDouble() ?? 0;
    if (!force &&
        mode == AsrAcceleration.auto &&
        seconds < 60 &&
        (configuration['profiles'] as List? ?? const []).isEmpty) {
      _decided = true;
      _state('短音频优先 CPU，可在模型中心主动测速');
      return;
    }
    if (!force &&
        mode == AsrAcceleration.auto &&
        configuration['automaticTuningAllowed'] == false &&
        profiles.isEmpty) {
      _decided = true;
      _state('先使用 CPU 开始识别；新硬件组合可在模型中心测速');
      return;
    }
    if (!force && _deferUnprovenGpu) {
      _decided = true;
      _state('尚无更快的 GPU 记录，直接使用 CPU');
      return;
    }
    _state('正在检查 GPU 能力', selecting: true);
    final capabilities = _capabilities ??= await _probeCapabilities();
    _check(check);
    final devices = (capabilities['devices'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (devices.isEmpty) {
      throw StateError(
        capabilities['reason'] as String? ?? '当前设备没有通过检查的 GPU 后端',
      );
    }
    final available = (configuration['gpuAvailableMemoryBytes'] as num?)
        ?.toInt();
    bool fits(Object? bytes) =>
        available == null ||
        bytes is! num ||
        available >= bytes * 2 + 256 * 1024 * 1024;
    final candidates = <Map<String, dynamic>>[
      for (final device in devices)
        for (final variant in [
          if (device['requiresFloatWeights'] != true &&
              fits(configuration['modelBytes']))
            {
              'directory': configuration['directory'],
              'weights': configuration['identity'],
              'floatWeights': false,
            },
          if (configuration['gpuDirectory'] != null &&
              fits(configuration['gpuModelBytes']))
            {
              'directory': configuration['gpuDirectory'],
              'weights': configuration['gpuIdentity'],
              'floatWeights': true,
            },
        ])
          {...device, ...variant},
    ];
    if (candidates.isEmpty) {
      _decided = true;
      await _dropGpu();
      _state(
        devices.any((d) => d['requiresFloatWeights'] == true) &&
                configuration['gpuDirectory'] == null
            ? '此硬件路线需要模型中心的 FP32 加速包，当前使用 CPU'
            : '当前内存余量优先使用 CPU',
      );
      return;
    }
    // DML/CoreML compilation and dispatch can behave very differently on a
    // two-second sentence versus a twelve-second tensor. Do not reuse an
    // optimistic long-probe profile for a fragmented recording. A shape
    // mismatch conservatively chooses CPU; it must not rebenchmark every file.
    Map<String, dynamic>? best;
    AsrPerformanceProfile? fastest;
    final chunkSeconds =
        (configuration['chunkSeconds'] as num?)?.toDouble() ?? 120;
    final loads =
        configuration['pipeline'] == true ||
            configuration['reuseModels'] == true
        ? 1
        : 1 +
              math.max<int>(
                0,
                ((seconds - chunkSeconds) / math.max(1, chunkSeconds - 2))
                    .ceil(),
              );
    final speechSeconds =
        seconds *
        ((configuration['voiceFraction'] as num?)?.toDouble() ?? 1).clamp(0, 1);
    final segmentRate = (configuration['segmentsPerSecond'] as num?)
        ?.toDouble();
    final calls = segmentRate == null ? null : segmentRate * seconds;
    for (final candidate in candidates) {
      candidate['signature'] = asrPerformanceSignature(
        configuration: configuration,
        device: candidate,
        weights: candidate['weights'] as String,
      );
      final cached = profiles
          .where(
            (v) =>
                v.matches(candidate['signature'] as String, _now()) &&
                (mode == AsrAcceleration.gpu ||
                    v.supportsProbe(audio.length / 16000)),
          )
          .firstOrNull;
      if (!force &&
          cached != null &&
          !cached.failed &&
          (mode == AsrAcceleration.gpu ||
              cached.useGpu(speechSeconds, loads: loads, calls: calls)) &&
          (fastest == null ||
              cached.estimate(true, speechSeconds, loads, calls: calls) <
                  fastest.estimate(true, speechSeconds, loads, calls: calls))) {
        best = candidate;
        fastest = cached;
      }
    }
    if (!force && best != null) {
      _chosen = null;
      _decided = true;
      _chosenTarget = best;
      return;
    }
    if (!force && mode == AsrAcceleration.gpu) {
      // Remember failed combinations until the user explicitly re-benchmarks.
      final eligible = candidates
          .where(
            (candidate) => !profiles.any(
              (profile) =>
                  profile.failed &&
                  profile.matches(candidate['signature'] as String, _now()),
            ),
          )
          .toList();
      if (eligible.isEmpty) {
        _decided = true;
        await _dropGpu();
        _rememberUnavailable('此组合上次未通过检查，使用 CPU；可在模型中心重新测速');
        return;
      }
      _chosenTarget = eligible.first;
      _manualAlternatives = eligible.skip(1).toList();
      _decided = true;
      return;
    }
    final allCached = candidates.every(
      (c) => profiles.any((v) => v.matches(c['signature'] as String, _now())),
    );
    if (!force && (allCached || seconds < 60)) {
      _decided = true;
      await _dropGpu();
      final hasVerified = candidates.any(
        (c) => profiles.any(
          (v) => !v.failed && v.matches(c['signature'] as String, _now()),
        ),
      );
      final reason = !allCached
          ? '短音频优先 CPU，可在模型中心主动测速'
          : hasVerified
          ? '沿用本机测速记录，当前任务优先使用 CPU'
          : '此设备组合没有通过 GPU 检查，使用 CPU；可重新测速';
      if (allCached && !hasVerified) {
        _rememberUnavailable(reason);
      } else {
        _state(reason);
      }
      return;
    }
    if (!force && configuration['automaticTuningAllowed'] == false) {
      _decided = true;
      _state('先开始识别；空闲且有测速预算时再调优');
      return;
    }
    // Avoid comparing a one-word fragment; wait for a representative VAD span.
    if (audio.length < 3 * 16000 && !force) {
      _state('短语音先使用 CPU，等待可测速片段');
      return;
    }
    _state('同段语音 CPU / GPU 本机测速中', selecting: true);
    // Earlier short VAD spans may already have loaded CPU weights. Measure a
    // cold warm-up here so the persistent startup estimate is reusable.
    await releaseCpu();
    final watch = Stopwatch()..start();
    final reference = await cpu();
    final cpuWarm = watch.elapsedMilliseconds;
    _measuredAudio = audio;
    _measuredCpu = reference;
    final cpuTimes = <int>[];
    for (var i = 0; i < 3; i++) {
      _check(check);
      watch
        ..reset()
        ..start();
      await cpu();
      cpuTimes.add(watch.elapsedMilliseconds);
    }
    await releaseCpu();
    final cpuMedian = asrMedian(cpuTimes);
    var verified = profiles.any(
      (p) =>
          !p.failed &&
          candidates.any((c) => p.matches(c['signature'] as String, _now())),
    );
    String lastFailure = '';
    for (final candidate in candidates) {
      _check(check);
      if (!force &&
          profiles.any(
            (profile) =>
                profile.matches(candidate['signature'] as String, _now()),
          )) {
        continue;
      }
      _chosen = null;
      var startup = 0, elapsed = 0, failed = false;
      var failureReason = '';
      try {
        watch
          ..reset()
          ..start();
        final probe = await _gpu(audio, candidate, check);
        startup = watch.elapsedMilliseconds;
        if (!asrProbeAgrees(
          reference['text'] as String? ?? '',
          probe['text'] as String? ?? '',
        )) {
          throw StateError('GPU 测试原文与 CPU 相差过大');
        }
        final timings = <int>[];
        for (var i = 0; i < 3; i++) {
          _check(check);
          watch
            ..reset()
            ..start();
          await _gpu(audio, candidate, check);
          timings.add(watch.elapsedMilliseconds);
        }
        elapsed = asrMedian(timings);
        verified = true;
      } catch (error) {
        _check(check);
        if (isTransientInferencePressure(error)) {
          _decided = true;
          _state('暂时内存不足，当前任务使用 CPU');
          return;
        }
        failed = true;
        lastFailure = failureReason = '$error';
      } finally {
        await _dropGpu();
        _chosen = null;
      }
      final profile = AsrPerformanceProfile(
        signature: candidate['signature'] as String,
        testedAt: _now(),
        backend: candidate['label'] as String,
        device: candidate['fingerprint'] as String,
        weights: candidate['weights'] as String,
        sampleSeconds: audio.length / 16000,
        cpuMs: cpuMedian,
        gpuMs: elapsed,
        cpuStartupMs: math.max(0, cpuWarm - cpuMedian),
        gpuStartupMs: math.max(0, startup - elapsed),
        failed: failed,
        failureReason: failureReason,
      );
      _state(profile.summary, profile: profile);
      if (!failed &&
          profile.useGpu(speechSeconds, loads: loads, calls: calls) &&
          (fastest == null ||
              profile.estimate(true, speechSeconds, loads, calls: calls) <
                  fastest.estimate(true, speechSeconds, loads, calls: calls))) {
        fastest = profile;
        best = candidate;
      }
    }
    _chosenTarget = best;
    _decided = true;
    final reason = best != null
        ? '本机测速已选择 ${best['label']}'
        : verified
        ? '本机测速预计 CPU 更快'
        : 'GPU 未通过检查，已使用 CPU：$lastFailure';
    if (!verified) {
      _rememberUnavailable(reason);
    } else {
      _state(reason);
    }
  }

  Map<String, dynamic>? _chosenTarget;
  Future<Map<String, dynamic>> _probeCapabilities() async {
    // A native CPU architecture and mobile GPU use the same private service.
    // Finish releasing its previous owner before probing a fresh connection.
    if (configuration['nativeCpu'] == true) await releaseCpu();
    final query = <String, dynamic>{
      'op': 'capabilities',
      'modelId': configuration['modelId'],
      'identity': configuration['identity'],
    };
    Map<String, dynamic> base;
    try {
      base = await (await _connection()).request(query);
    } catch (_) {
      if (_cancelled) rethrow;
      await _dropGpu();
      // Probe independent native APIs even if NNAPI/DirectML discovery died.
      // This proposes no hardware: each route still has to detect a real GPU.
      base = {
        'devices': <Object>[],
        'optionalBackends': Platform.isMacOS || Platform.isIOS
            ? ['metal']
            : ['vulkan', 'opencl'],
      };
    }
    final optional = List<String>.from(
      base['optionalBackends'] as List? ?? const [],
    );
    if (optional.isEmpty) return base;
    final devices = List<dynamic>.from(base['devices'] as List? ?? const []);
    await _dropGpu();
    for (final route in optional) {
      if (_cancelled) throw StateError('转录已取消');
      try {
        final response = await (await _connection()).request({
          ...query,
          'probeBackend': route,
        });
        for (final device in response['devices'] as List? ?? const []) {
          if (device is Map && device['backend'] == route) devices.add(device);
        }
      } catch (_) {
        if (_cancelled) rethrow;
        // A vendor failure is contained in this process; keep prior devices.
      } finally {
        await _dropGpu();
      }
    }
    return {...base, 'devices': devices};
  }

  List<Map<String, dynamic>> _manualAlternatives = [];

  Future<Map<String, dynamic>> decode(
    Float32List audio, {
    required AsrCpuDecode cpu,
    required void Function() check,
    Future<Map<String, dynamic>> Function(Float32List)? cpuProbe,
  }) async {
    weights = configuration['identity'] as String? ?? '';
    try {
      if (!_disabled && !_decided) {
        final probe = audio.length > 12 * 16000 && cpuProbe != null
            ? Float32List.sublistView(audio, 0, 12 * 16000)
            : audio;
        await _select(
          probe,
          cpuProbe == null ? cpu : () => cpuProbe(probe),
          check,
        );
      }
      _check(check);
      if (!_disabled && _chosenTarget != null) {
        while (true) {
          final target = _chosenTarget!;
          try {
            final result = await _gpu(audio, target, check);
            backend = target['label'] as String;
            weights = target['weights'] as String;
            _manualAlternatives.clear();
            _state('正在使用 $backend');
            _measuredAudio = null;
            _measuredCpu = null;
            return {...result, '_backend': backend, '_weights': weights};
          } catch (error) {
            _check(check);
            _state(
              '此 GPU / 权重组合未通过检查',
              profile: AsrPerformanceProfile(
                signature: target['signature'] as String,
                testedAt: _now(),
                backend: target['label'] as String,
                device: target['fingerprint'] as String,
                weights: target['weights'] as String,
                sampleSeconds: math.max(.01, audio.length / 16000),
                cpuMs: 0,
                gpuMs: 0,
                failed: true,
                failureReason: '$error',
              ),
            );
            await _dropGpu();
            _chosen = null;
            if (mode != AsrAcceleration.gpu || _manualAlternatives.isEmpty) {
              rethrow;
            }
            _chosenTarget = _manualAlternatives.removeAt(0);
          }
        }
      }
    } catch (error) {
      _check(check);
      _disabled = true;
      _chosen = null;
      await _dropGpu();
      backend = 'CPU';
      if (isTransientInferencePressure(error)) {
        _state('暂时内存不足，已回退 CPU');
      } else {
        _rememberUnavailable('GPU 不可用，已回退 CPU：$error');
      }
    }
    _check(check);
    backend = 'CPU';
    final measured = identical(_measuredAudio, audio) ? _measuredCpu : null;
    _measuredAudio = null;
    _measuredCpu = null;
    final result = measured ?? await cpu();
    return {
      ...result,
      '_backend': backend,
      '_weights': result['_weights'] ?? weights,
    };
  }

  /// Low-memory mode must release GPU weights before loading CTC alignment.
  Future<void> releaseForEnhancement() async {
    _chosen = null;
    await _dropGpu();
  }

  Future<void> cancel() async {
    _cancelled = true;
    await _dropGpu();
  }

  Future<void> close() => cancel();
}
