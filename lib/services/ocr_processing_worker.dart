import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;

import 'ocr_inference_engine.dart';
import '../models/ocr_model_files.dart';
import 'ocr_runtime_cache.dart';
import 'ocr_execution_policy.dart';
import 'ocr_device_probe.dart';

class OcrFrameAnalysis {
  final bool candidate;
  final String text;
  final double confidence, difference;
  final int boundaryMs;
  final String backend;
  final Map<String, dynamic>? tuning;
  final Map<String, int> timingsUs;
  final bool warmup;
  final Map<String, dynamic>? checkpoint;
  const OcrFrameAnalysis({
    required this.candidate,
    required this.text,
    required this.confidence,
    required this.difference,
    required this.boundaryMs,
    required this.backend,
    this.tuning,
    this.timingsUs = const {},
    this.warmup = false,
    this.checkpoint,
  });
  Map<String, Object?> toMessage() => {
    'candidate': candidate,
    'text': text,
    'confidence': confidence,
    'difference': difference,
    'boundaryMs': boundaryMs,
    'backend': backend,
    'tuning': tuning,
    'timingsUs': timingsUs,
    'warmup': warmup,
    'checkpoint': checkpoint,
  };
  factory OcrFrameAnalysis.fromMessage(Map<Object?, Object?> r, int atMs) =>
      OcrFrameAnalysis(
        candidate: r['candidate'] == true,
        text: r['text']?.toString() ?? '',
        confidence: (r['confidence'] as num?)?.toDouble() ?? 0,
        difference: (r['difference'] as num?)?.toDouble() ?? 0,
        boundaryMs: r['boundaryMs'] as int? ?? atMs,
        backend: r['backend']?.toString() ?? 'CPU',
        tuning: r['tuning'] is Map
            ? Map<String, dynamic>.from(r['tuning'] as Map)
            : null,
        timingsUs: Map<String, int>.from(r['timingsUs'] as Map? ?? const {}),
        warmup: r['warmup'] == true,
        checkpoint: r['checkpoint'] is Map
            ? Map<String, dynamic>.from(r['checkpoint'] as Map)
            : null,
      );
}

abstract interface class OcrWorker {
  String get runtimeVersion;
  List<String> get availableBackends;
  bool get isolated;
  Map<int, Map<String, dynamic>> get checkpoints;
  Future<OcrFrameAnalysis> analyzeCommand(Map<String, Object?> command);
  Future<void> restoreFrameHistory(Map<int, Map<String, dynamic>> states);
  Future<void> resetFrameHistory();
  Future<void> closeFrameFiles();
  Future<void> releaseIdleModels();
  Future<void> close();
}

extension OcrRawWorkerCommands on OcrWorker {
  Future<OcrFrameAnalysis> analyzeRawFrame({
    required String path,
    required int offset,
    required int width,
    required int height,
    required int atMs,
    required int track,
    required int threads,
    required int batchLimit,
    int residentModels = 2,
    String provider = 'CPU',
    int? preferredThreads,
    int probeCreditMs = 0,
    String probeStage = 'cpu',
    List<String> testedProviders = const [],
    List<int> testedThreads = const [],
    int remainingMediaMs = 0,
    int deviceId = 0,
    String coreMLUnits = 'ALL',
    List<String>? allowedProviders,
    bool validateAcceleration = false,
    int? gpuMemoryLimit,
    bool conservative = false,
  }) => analyzeCommand({
    'type': 'frame',
    'path': path,
    'offset': offset,
    'width': width,
    'height': height,
    'atMs': atMs,
    'track': track,
    'threads': threads,
    'batchLimit': batchLimit,
    'residentModels': residentModels,
    'provider': provider,
    'preferredThreads': preferredThreads,
    'probeCreditMs': probeCreditMs,
    'probeStage': probeStage,
    'testedProviders': testedProviders,
    'testedThreads': testedThreads,
    'remainingMediaMs': remainingMediaMs,
    'deviceId': deviceId,
    'coreMLUnits': coreMLUnits,
    'allowedProviders': allowedProviders,
    'validateAcceleration': validateAcceleration,
    'gpuMemoryLimit': gpuMemoryLimit,
    'conservative': conservative,
  });
}

class OcrProcessingWorker implements OcrWorker {
  final Isolate _isolate;
  final ReceivePort _responses;
  final Completer<void> _ready = Completer<void>();
  SendPort? _commands;
  final _pending = <int, Completer<Map<Object?, Object?>>>{};
  late final StreamSubscription<dynamic> _subscription;
  int _nextId = 1;
  bool _closed = false;
  bool _failed = false;
  final Future<void> Function(int bytes)? _checkAllocation;
  @override
  String runtimeVersion = '';
  @override
  List<String> availableBackends = const ['CPU'];
  @override
  bool get isolated => false;
  @override
  final checkpoints = <int, Map<String, dynamic>>{};
  OcrProcessingWorker._(this._isolate, this._responses, this._checkAllocation) {
    _subscription = _responses.listen((dynamic message) {
      if (message is SendPort && _commands == null) {
        _commands = message;
        _ready.complete();
        return;
      }
      if (message == null || message is List) {
        if (!_closed) _fail(StateError('OCR 工作线程意外退出：$message'));
        return;
      }
      if (message is! Map) return;
      final map = Map<Object?, Object?>.from(message);
      if (map['type'] == 'allocation') {
        unawaited(_admitAllocation(map));
        return;
      }
      if (map['type'] == 'ready') {
        _commands = map['commands']! as SendPort;
        runtimeVersion = map['runtimeVersion']! as String;
        availableBackends = List<String>.from(map['backends'] as List);
        _ready.complete();
        return;
      }
      if (!_ready.isCompleted && map['error'] != null) {
        _ready.completeError(StateError(map['error'].toString()));
        return;
      }
      final completer = _pending.remove(map['id']);
      if (completer == null) return;
      if (map['error'] != null) {
        completer.completeError(StateError(map['error'].toString()));
      } else {
        completer.complete(map);
      }
    });
  }
  Future<void> _admitAllocation(Map<Object?, Object?> message) async {
    final response = message['reply']! as SendPort;
    try {
      if (_closed || _failed) throw StateError('OCR 工作线程已经关闭');
      await _checkAllocation?.call(message['bytes']! as int);
      response.send(null);
    } catch (error) {
      response.send('$error');
    }
  }

  void _fail(Object error) {
    _failed = true;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
  }

  static Future<OcrProcessingWorker> start(
    OcrModelFiles files, {
    Map<int, OcrModelFiles> tracks = const {},
    int cpuThreads = 2,
    int batchLimit = 1,
    Future<void> Function(int bytes)? checkAllocation,
    bool conservative = false,
  }) async {
    final responses = ReceivePort();
    final isolate = await Isolate.spawn<Map<String, Object?>>(
      _ocrWorkerMain,
      {
        'reply': responses.sendPort,
        'files': files.toMessage(),
        'threads': cpuThreads,
        'batchLimit': batchLimit,
        'conservative': conservative,
        'tracks': {
          for (final entry in tracks.entries)
            entry.key: entry.value.toMessage(),
        },
      },
      debugName: 'ocr-subtitle-worker',
      onError: responses.sendPort,
      onExit: responses.sendPort,
    );
    final worker = OcrProcessingWorker._(isolate, responses, checkAllocation);
    try {
      await worker._ready.future.timeout(const Duration(seconds: 60));
      return worker;
    } catch (_) {
      await worker._subscription.cancel();
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  Future<OcrFrameAnalysis> analyzeFrame(String path, int atMs) =>
      _analyze({'type': 'frame', 'path': path, 'atMs': atMs});
  Future<OcrFrameAnalysis> _analyze(Map<String, Object?> message) async {
    return analyzeCommand(message);
  }

  @override
  Future<OcrFrameAnalysis> analyzeCommand(Map<String, Object?> message) async {
    final r = await _request(message);
    final analysis = OcrFrameAnalysis.fromMessage(r, message['atMs']! as int);
    if (analysis.checkpoint != null) {
      checkpoints[message['track'] as int? ?? 0] = analysis.checkpoint!;
    }
    return analysis;
  }

  @override
  Future<void> restoreFrameHistory(
    Map<int, Map<String, dynamic>> states,
  ) async {
    await _request({'type': 'restore', 'states': states});
    checkpoints.addAll(states);
  }

  @override
  Future<void> resetFrameHistory() async {
    await _request({'type': 'reset'});
    checkpoints.clear();
  }

  @override
  Future<void> closeFrameFiles() async {
    await _request({'type': 'closeFrames'});
  }

  @override
  Future<void> releaseIdleModels() async {
    await _request({'type': 'releaseModels'});
  }

  Future<Map<Object?, Object?>> _request(Map<String, Object?> command) {
    if (_closed || _failed) throw StateError('OCR 工作线程已经关闭');
    final id = _nextId++;
    final completer = Completer<Map<Object?, Object?>>();
    _pending[id] = completer;
    _commands!.send({...command, 'id': id});
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await _request({'type': 'close'}).timeout(const Duration(seconds: 10));
    } finally {
      _closed = true;
      _fail(StateError('OCR 工作线程已经关闭'));
      await _subscription.cancel();
      _responses.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

class _TrackHistory {
  String backend = 'CPU';
  Uint8List? signature, pixels, previousPixels;
  int width = 0, height = 0;
  OcrTextResult? lastResult;
  int lastForcedMs = -100000, lastCandidateMs = -100000, lastChangeMs = 0;
  bool pendingChange = false;
  ({String text, double confidence, int boundaryMs})? pending;
  final style = OcrSubtitleStyleFilter();
  Map<String, Object?> toMessage() => {
    'backend': backend,
    'signature': signature?.toList(),
    'width': width,
    'height': height,
    'lastForcedMs': lastForcedMs,
    'lastCandidateMs': lastCandidateMs,
    'lastChangeMs': lastChangeMs,
    'pendingChange': pendingChange,
    if (pending != null)
      'pending': {
        'text': pending!.text,
        'confidence': pending!.confidence,
        'boundaryMs': pending!.boundaryMs,
      },
    'style': {'heights': style._heights, 'centers': style._centers},
  };
  factory _TrackHistory.fromMessage(Map m) {
    final h = _TrackHistory();
    final signature = m['signature'];
    if (signature is List && signature.length == 768) {
      h.signature = Uint8List.fromList(List<int>.from(signature));
    }
    h.backend = m['backend'] as String? ?? 'CPU';
    h.width = m['width'] as int? ?? 0;
    h.height = m['height'] as int? ?? 0;
    h.lastForcedMs = m['lastForcedMs'] as int? ?? -100000;
    h.lastCandidateMs = m['lastCandidateMs'] as int? ?? -100000;
    h.lastChangeMs = m['lastChangeMs'] as int? ?? 0;
    h.pendingChange = m['pendingChange'] == true;
    final p = m['pending'];
    if (p is Map) {
      h.pending = (
        text: p['text'] as String,
        confidence: (p['confidence'] as num).toDouble(),
        boundaryMs: p['boundaryMs'] as int,
      );
    }
    final style = m['style'];
    if (style is Map) {
      h.style._heights.addAll(
        List<num>.from(
          style['heights'] as List,
        ).take(32).map((v) => v.toDouble()),
      );
      h.style._centers.addAll(
        List<num>.from(
          style['centers'] as List,
        ).take(32).map((v) => v.toDouble()),
      );
    }
    return h;
  }
  _TrackHistory();
}

bool _identicalPixels(Uint8List? a, Uint8List b) {
  if (a == null || a.length != b.length) return false;
  final left = ByteData.sublistView(a), right = ByteData.sublistView(b);
  var i = 0;
  for (; i + 8 <= a.length; i += 8) {
    if (left.getUint64(i) != right.getUint64(i)) return false;
  }
  for (; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

@pragma('vm:entry-point')
Future<void> _ocrWorkerMain(Map<String, Object?> bootstrap) async {
  final reply = bootstrap['reply']! as SendPort;
  final commands = ReceivePort();
  final initial = OcrModelFiles.fromMessage(bootstrap['files']! as Map);
  final filesByTrack = <int, OcrModelFiles>{
    0: initial,
    for (final e in (bootstrap['tracks'] as Map).entries)
      e.key as int: OcrModelFiles.fromMessage(e.value as Map),
  };
  final histories = <int, _TrackHistory>{};
  final engines = OcrRuntimeCache<OcrInferenceEngine>(
    dispose: (engine) => engine.dispose(),
  );
  final frameReader = OcrRawFrameReader();
  final modelBytes = <String, int>{};
  final warmedEngines = Expando<bool>();
  final failedProviders = <String>{};
  final validatedProviders = <String>{};
  final probed = <String>{};
  var deviceId = 0;
  var coreMLUnits = 'ALL';
  int? gpuMemoryLimit;
  var conservative = bootstrap['conservative'] == true;
  Future<OcrInferenceEngine> engineFor(
    OcrModelFiles files,
    int threads,
    int batch,
    String provider,
    int resident,
  ) async {
    // Changing a line batch does not change an ONNX session. In particular a
    // pressure downgrade must not duplicate the same weights just for batch=1.
    final modelKey = '${files.detection}|${files.recognition}';
    final key =
        '${files.identity}|$modelKey|$threads|$provider|$deviceId|$coreMLUnits|$conservative';
    final engine = await engines.obtain(
      key,
      capacity: resident,
      create: () async {
        final weights = modelBytes[modelKey] ??=
            await File(files.detection).length() +
            await File(files.recognition).length();
        if (provider == 'DirectML') {
          final headroom = ocrDirectMlHeadroom(deviceId);
          if (headroom != null && headroom < weights * 8 + 128 * 1024 * 1024) {
            throw StateError('显卡当前的系统内存预算不足，使用 CPU');
          }
        }
        final allocation = ReceivePort();
        try {
          reply.send({
            'type': 'allocation',
            'bytes':
                weights * (provider == 'CPU' ? 4 : 8) +
                (provider == 'CPU' ? 64 : 128) * 1024 * 1024,
            'reply': allocation.sendPort,
          });
          final error = await allocation.first.timeout(
            const Duration(seconds: 30),
          );
          if (error != null) throw StateError('$error');
        } finally {
          allocation.close();
        }
        final created = OcrInferenceEngine(
          files,
          cpuThreads: threads,
          batchLimit: batch,
          provider: provider,
          deviceId: deviceId,
          coreMLUnits: coreMLUnits,
          gpuMemoryLimit: gpuMemoryLimit,
          conservative: conservative,
        );
        try {
          await created.initialize();
          return created;
        } catch (_) {
          await created.dispose();
          rethrow;
        }
      },
    );
    engine.batchLimit = batch;
    return engine;
  }

  try {
    await engineFor(
      initial,
      bootstrap['threads']! as int,
      bootstrap['batchLimit']! as int,
      'CPU',
      2,
    );
    reply.send({
      'type': 'ready',
      'commands': commands.sendPort,
      'runtimeVersion': OcrInferenceEngine.runtimeVersion,
      'backends': OcrInferenceEngine.availableBackends(),
    });
  } catch (error) {
    try {
      await engines.clear();
      OcrInferenceEngine.releaseWorkerEnvironment();
    } catch (_) {}
    commands.close();
    reply.send({'error': '$error'});
    return;
  }

  await for (final dynamic raw in commands) {
    if (raw is! Map) continue;
    final m = Map<Object?, Object?>.from(raw), id = raw['id'];
    if (id is! int) continue;
    if (m['type'] == 'close') {
      await frameReader.close();
      await engines.clear();
      OcrInferenceEngine.releaseWorkerEnvironment();
      reply.send({'id': id});
      commands.close();
      return;
    }
    if (m['type'] == 'reset') {
      histories.clear();
      await frameReader.close();
      reply.send({'id': id});
      continue;
    }
    if (m['type'] == 'restore') {
      try {
        for (final entry in (m['states'] as Map).entries) {
          final track = int.parse(entry.key.toString());
          if (filesByTrack.containsKey(track)) {
            histories[track] = _TrackHistory.fromMessage(entry.value as Map);
          }
        }
        reply.send({'id': id});
      } catch (error) {
        reply.send({'id': id, 'error': '$error'});
      }
      continue;
    }
    if (m['type'] == 'closeFrames' || m['type'] == 'releaseModels') {
      try {
        await frameReader.close();
        if (m['type'] == 'releaseModels') await engines.clear();
        reply.send({'id': id});
      } catch (error) {
        reply.send({'id': id, 'error': '$error'});
      }
      continue;
    }
    if (m['type'] != 'frame') continue;
    try {
      final loadWatch = Stopwatch()..start();
      final timingsUs = <String, int>{};
      final atMs = m['atMs']! as int, track = m['track'] as int? ?? 0;
      final history = histories.putIfAbsent(track, _TrackHistory.new);
      final files = filesByTrack[track]!;
      final path = m['path']! as String;
      im.Image? decodedImage;
      late final Uint8List pixels;
      late final int width, height;
      if (m['offset'] != null) {
        width = m['width']! as int;
        height = m['height']! as int;
        if (width <= 0 || height <= 0) throw StateError('OCR 原始帧尺寸无效');
        pixels = await frameReader.read(
          track: track,
          path: path,
          offset: m['offset']! as int,
          length: width * height * 3,
        );
      } else {
        final decoded = im.decodeImage(await File(path).readAsBytes());
        if (decoded == null) throw StateError('无法解码 OCR 临时帧');
        decodedImage = decoded;
        width = decoded.width;
        height = decoded.height;
        pixels = decoded.getBytes(order: im.ChannelOrder.rgb);
      }
      im.Image image() => decodedImage ??= im.Image.fromBytes(
        width: width,
        height: height,
        bytes: pixels.buffer,
        bytesOffset: pixels.offsetInBytes,
        numChannels: 3,
        order: im.ChannelOrder.rgb,
      );
      final sameGeometry = history.width == width && history.height == height;
      final unchanged =
          sameGeometry && _identicalPixels(history.previousPixels, pixels);
      final signature = unchanged ? history.signature! : _signature(image());
      timingsUs['frameLoadUs'] = loadWatch.elapsedMicroseconds;
      final difference = history.signature == null
          ? 1.0
          : _signatureDifference(history.signature!, signature);
      history.signature = signature;
      history.previousPixels = pixels;
      history.width = width;
      history.height = height;
      final forced = atMs - history.lastForcedMs >= 2000;
      if (difference >= 0.08) {
        history.lastChangeMs = atMs;
        history.pendingChange = true;
      }
      final isNew =
          forced ||
          (history.pendingChange && atMs - history.lastCandidateMs >= 300);
      final boundary = history.pendingChange ? history.lastChangeMs : atMs;
      if (forced) history.lastForcedMs = atMs;
      if (isNew) {
        history.lastCandidateMs = atMs;
        history.pendingChange = false;
      }
      var result = const OcrTextResult('', 0);
      final recognize = isNew || history.pending != null;
      // All backend comparisons for this frame use the same per-region
      // snapshot; cached model sessions themselves hold no subtitle geometry.
      final geometry = recognize ? history.style.geometry : null;
      var backend = history.backend;
      var warmup = false;
      Map<String, dynamic>? tuning;
      if (recognize) {
        conservative = m['conservative'] == true;
        final cap = math.max(1, m['threads'] as int? ?? 2);
        final threads = (m['preferredThreads'] as int? ?? 2).clamp(1, cap);
        final batch = m['batchLimit'] as int? ?? 1;
        final resident = m['residentModels'] as int? ?? 2;
        deviceId = m['deviceId'] as int? ?? 0;
        coreMLUnits = m['coreMLUnits'] as String? ?? 'ALL';
        gpuMemoryLimit = m['gpuMemoryLimit'] as int?;
        final allowed = List<String>.from(
          m['allowedProviders'] as List? ?? const ['CPU', 'XNNPACK'],
        );
        var provider = m['provider'] as String? ?? 'CPU';
        if (!allowed.contains(provider)) provider = 'CPU';
        String keyFor(String p) =>
            '${files.identity}:$p:$deviceId:$coreMLUnits';
        final providerKey = keyFor(provider);
        if (failedProviders.contains(providerKey)) provider = 'CPU';
        late OcrInferenceEngine engine;
        final exact = sameGeometry && _identicalPixels(history.pixels, pixels);
        var reused = false;
        try {
          engine = await engineFor(files, threads, batch, provider, resident);
          warmup = warmedEngines[engine] != true;
          if (provider != 'CPU' && engine.activeBackend != provider) {
            throw StateError('加速后端未能启用');
          }
          reused =
              exact &&
              history.lastResult != null &&
              history.backend == engine.activeBackend &&
              !warmup;
          result = reused
              ? history.lastResult!
              : await engine.recognizeImage(image(), geometry: geometry);
          final validationKey =
              '$providerKey:$track:$width:$height:${engine.executionShape}';
          if (provider != 'CPU' &&
              !reused &&
              m['validateAcceleration'] == true &&
              !validatedProviders.contains(validationKey)) {
            final cpu = await engineFor(
              files,
              threads,
              batch,
              'CPU',
              math.max(2, resident),
            );
            final reference = await cpu.recognizeImage(
              image(),
              geometry: geometry,
            );
            if (reference.text != result.text ||
                (reference.confidence - result.confidence).abs() > .08) {
              throw StateError('加速识别结果与 CPU 校验不一致');
            }
            // Empty images cannot establish text recognition compatibility.
            if (reference.text.trim().isNotEmpty) {
              validatedProviders.add(validationKey);
              if (validatedProviders.length > 256) {
                validatedProviders.remove(validatedProviders.first);
              }
            }
          }
        } catch (error) {
          if (provider == 'CPU') rethrow;
          failedProviders.add(providerKey);
          reused = false;
          // Discard the failed provider before allocating the fallback.
          await engines.clear();
          engine = await engineFor(files, threads, batch, 'CPU', resident);
          warmup = warmedEngines[engine] != true;
          result = await engine.recognizeImage(image(), geometry: geometry);
          tuning = {
            'provider': 'CPU',
            'threads': threads,
            'failedProvider': provider,
            'failureReason': String.fromCharCodes('$error'.runes.take(1024)),
            'costMs': 0,
          };
        }
        backend = engine.activeBackend;
        warmedEngines[engine] = true;
        if (!reused) timingsUs.addAll(engine.lastTimingsUs);
        history.backend = backend;
        // Probes are funded only after productive work, and run under the same
        // compute reservation. No extra work is performed to estimate an ETA.
        final credit = m['probeCreditMs'] as int? ?? 0;
        final stage = m['probeStage'] as String? ?? 'cpu';
        final testedProviders = List<String>.from(
          m['testedProviders'] as List? ?? const [],
        );
        final candidates = OcrInferenceEngine.availableBackends()
            .where(
              (p) =>
                  p != 'CPU' &&
                  p != provider &&
                  !testedProviders.contains(p) &&
                  allowed.contains(p) &&
                  !failedProviders.contains(keyFor(p)),
            )
            .toList();
        final candidateProvider = stage == 'backend' && candidates.isNotEmpty
            ? candidates.first
            : provider;
        final testedThreads = List<int>.from(
          m['testedThreads'] as List? ?? const [],
        );
        final cpuCandidates = ocrCpuThreadCandidates(
          threads,
          cap,
          testedThreads,
        );
        final candidateThreads =
            stage == 'cpu' && provider == 'CPU' && cpuCandidates.isNotEmpty
            ? cpuCandidates.first
            : threads;
        if (!exact &&
            credit >= 2000 &&
            probed.add(
              '${files.identity}:$cap:$provider:$stage:$candidateProvider:$candidateThreads',
            )) {
          final watch = Stopwatch()..start();
          if (stage == 'backend' &&
              !testedProviders.contains(candidateProvider)) {
            testedProviders.add(candidateProvider);
          }
          final stageComplete = <String, dynamic>{
            if (stage == 'cpu') ...{
              'threadsTuned': cpuCandidates.length <= 1,
              'testedThreads': {
                ...testedThreads,
                threads,
                candidateThreads,
              }.toList(),
            },
            if (stage == 'backend') ...{
              'testedProviders': testedProviders,
              'backendTuned': candidates.length <= 1,
            },
          };
          if (candidateProvider != provider || candidateThreads != threads) {
            final baseWatch = Stopwatch()..start();
            final base = await engine.recognizeImage(
              image(),
              geometry: geometry,
            );
            final base2 = await engine.recognizeImage(
              image(),
              geometry: geometry,
            );
            baseWatch.stop();
            try {
              final candidate = await engineFor(
                files,
                candidateThreads,
                batch,
                candidateProvider,
                math.max(2, resident),
              );
              if (candidateProvider != 'CPU' &&
                  candidate.activeBackend != candidateProvider) {
                throw StateError('候选后端未实际启用');
              }
              await candidate.recognizeImage(image(), geometry: geometry);
              // Accelerator graph compilation often happens on its first run.
              // Include that warm-up when estimating whether switching pays off.
              final startupMs =
                  watch.elapsedMilliseconds - baseWatch.elapsedMilliseconds;
              final nextWatch = Stopwatch()..start();
              final next = await candidate.recognizeImage(
                image(),
                geometry: geometry,
              );
              final next2 = await candidate.recognizeImage(
                image(),
                geometry: geometry,
              );
              nextWatch.stop();
              final same = base.text == next.text && base2.text == next2.text;
              final remainingCalls = math.max(
                1,
                (m['remainingMediaMs'] as int? ?? 0) ~/ 1000,
              );
              final faster =
                  nextWatch.elapsedMicroseconds +
                      startupMs * 2000 / remainingCalls <
                  baseWatch.elapsedMicroseconds * .9;
              tuning = {
                'provider': same && faster ? candidateProvider : provider,
                'threads': same && faster ? candidateThreads : threads,
                'costMs': watch.elapsedMilliseconds,
                'cpuMs': baseWatch.elapsedMilliseconds,
                'candidateMs': nextWatch.elapsedMilliseconds,
                'startupMs': startupMs,
                'candidateProvider': candidateProvider,
                'valid': same,
                ...stageComplete,
              };
              if (same && faster && next.text.trim().isNotEmpty) {
                validatedProviders.add(
                  '${keyFor(candidateProvider)}:$track:$width:$height',
                );
              } else if (!(same && faster)) {
                await engines.remove(candidate);
              }
            } catch (_) {
              if (candidateProvider != 'CPU') {
                failedProviders.add(keyFor(candidateProvider));
              }
              tuning = {
                'provider': provider,
                'threads': threads,
                'costMs': watch.elapsedMilliseconds,
                'failedProvider': candidateProvider,
                ...stageComplete,
              };
            }
          } else {
            tuning = {
              'provider': provider,
              'threads': threads,
              'costMs': 0,
              ...stageComplete,
            };
          }
        }
        history.lastResult = result;
        history.pixels = pixels;
        result = history.style.filter(result, width, height);
      }
      var emit = false;
      var text = '';
      var confidence = 0.0;
      var emittedBoundary = boundary;
      final pending = history.pending;
      if (pending != null && recognize) {
        final agrees = _roughlySameText(pending.text, result.text);
        final preferred = result.confidence >= pending.confidence
            ? (text: result.text, confidence: result.confidence)
            : (text: pending.text, confidence: pending.confidence);
        if ((agrees &&
                (preferred.text.trim().isEmpty ||
                    preferred.confidence >= .38)) ||
            (!agrees && preferred.confidence >= .55)) {
          emit = true;
          text = preferred.text;
          confidence = preferred.confidence;
          emittedBoundary = agrees || pending.confidence > result.confidence
              ? pending.boundaryMs
              : atMs;
        }
        // A confirmation pair can straddle a real subtitle change. Even when
        // the previous text wins on confidence, confirm the current frame next
        // rather than consuming the forced check and losing the new subtitle.
        history.pending = agrees
            ? null
            : (
                text: result.text,
                confidence: result.confidence,
                boundaryMs: atMs,
              );
      } else if (isNew) {
        history.pending = (
          text: result.text,
          confidence: result.confidence,
          boundaryMs: boundary,
        );
      }
      reply.send({
        'id': id,
        'candidate': emit,
        'text': text,
        'confidence': confidence,
        'difference': difference,
        'boundaryMs': emittedBoundary,
        'backend': backend,
        'warmup': warmup,
        'tuning': tuning,
        'timingsUs': timingsUs,
        'checkpoint': history.toMessage(),
      });
    } catch (error) {
      reply.send({'id': id, 'error': '$error'});
    }
  }
}

/// Learns the dominant geometry independently for each user-selected OCR
/// region. This removes small logos/UI labels that happen to be inside the
/// region while still allowing one- and two-line subtitles.
class OcrSubtitleStyleFilter {
  static const _historyLimit = 32;
  final List<double> _heights = <double>[];
  final List<double> _centers = <double>[];

  OcrSubtitleGeometry? get geometry {
    if (_heights.length < 4 || _centers.length != _heights.length) return null;
    final profile = OcrSubtitleGeometry(
      height: _median(_heights),
      center: _median(_centers),
    );
    return profile.isValid ? profile : null;
  }

  void reset() {
    _heights.clear();
    _centers.clear();
  }

  OcrTextResult filter(OcrTextResult result, int width, int height) {
    if (result.lines.isEmpty || width <= 0 || height <= 0) return result;
    var accepted = result.lines;
    final profile = geometry;
    if (profile != null) {
      final expectedHeight = profile.height;
      final expectedCenter = profile.center;
      final boxes = [
        for (final line in result.lines)
          OcrDetectedBox(
            line.left,
            line.top,
            line.right,
            line.bottom,
            line.confidence,
          ),
      ];
      var index = 0;
      accepted = result.lines.where((line) {
        final box = boxes[index++];
        final normalizedHeight = line.height / height;
        final normalizedCenter = (line.top + line.bottom) / (2 * height);
        final heightRatio = normalizedHeight / math.max(0.001, expectedHeight);
        final centerTolerance = math.max(0.14, expectedHeight * 2.5);
        return heightRatio >= 0.55 &&
            heightRatio <= 1.80 &&
            (!profile.isSmallOutlier(normalizedHeight, normalizedCenter) ||
                hasOcrSubtitleCompanionRow(
                  box,
                  boxes,
                  expectedHeight * height,
                )) &&
            (normalizedCenter - expectedCenter).abs() <= centerTolerance;
      }).toList();
      if (accepted.isEmpty) {
        // Small pre-roll labels must not lock the region to their scale and
        // suppress the first real subtitle (or a later increase in font size).
        // Keep the stricter small-text rejection through subtitle-free gaps.
        final larger = result.lines
            .where((line) => line.height / height > expectedHeight * 1.8)
            .toList();
        if (larger.isEmpty) return const OcrTextResult('', 0);
        reset();
        accepted = larger;
      }
    }

    // Update with the strongest line(s), not every detector fragment. The
    // inference layer has already merged words sharing the same baseline.
    // Do not let a tiny always-on watermark seen before the first subtitle
    // become the learned style. With the default/tight user ROI, real subtitle
    // rows are normally comfortably above this conservative bootstrap floor.
    final profileLines = accepted
        .where((line) => line.height / height >= 0.07)
        .toList();
    for (final line in profileLines) {
      _heights.add(line.height / height);
      _centers.add((line.top + line.bottom) / (2 * height));
    }
    while (_heights.length > _historyLimit) {
      _heights.removeAt(0);
      _centers.removeAt(0);
    }
    final confidence =
        accepted.fold<double>(0, (value, line) => value + line.confidence) /
        accepted.length;
    return OcrTextResult(
      accepted.map((line) => line.text).join('\n'),
      confidence,
      accepted,
    );
  }

  double _median(List<double> values) {
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

bool _roughlySameText(String a, String b) {
  final left = a.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  final right = b.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  if (left == right) return true;
  if (left.isEmpty || right.isEmpty) return false;
  final longest = math.max(left.length, right.length);
  var previous = List<int>.generate(right.length + 1, (index) => index);
  for (var i = 0; i < left.length; i++) {
    final current = List<int>.filled(right.length + 1, 0)..[0] = i + 1;
    for (var j = 0; j < right.length; j++) {
      current[j + 1] = math.min(
        math.min(current[j] + 1, previous[j + 1] + 1),
        previous[j] + (left.codeUnitAt(i) == right.codeUnitAt(j) ? 0 : 1),
      );
    }
    previous = current;
  }
  return 1 - previous.last / longest >= 0.78;
}

Uint8List _signature(im.Image image) {
  final small = im.copyResize(image, width: 48, height: 16);
  return Uint8List.fromList(<int>[
    for (final pixel in small)
      ((pixel.r * 299 + pixel.g * 587 + pixel.b * 114) / 1000).round(),
  ]);
}

double _signatureDifference(Uint8List a, Uint8List b) {
  final length = math.min(a.length, b.length);
  if (length == 0) return 1;
  var meanA = 0.0;
  var meanB = 0.0;
  for (var i = 0; i < length; i++) {
    meanA += a[i];
    meanB += b[i];
  }
  meanA /= length;
  meanB /= length;
  var varianceA = 0.0;
  var varianceB = 0.0;
  var covariance = 0.0;
  for (var i = 0; i < length; i++) {
    final da = a[i] - meanA;
    final db = b[i] - meanB;
    varianceA += da * da;
    varianceB += db * db;
    covariance += da * db;
  }
  final divisor = math.max(1, length - 1);
  varianceA /= divisor;
  varianceB /= divisor;
  covariance /= divisor;
  const c1 = 6.5025;
  const c2 = 58.5225;
  final numerator = (2 * meanA * meanB + c1) * (2 * covariance + c2);
  final denominator =
      (meanA * meanA + meanB * meanB + c1) * (varianceA + varianceB + c2);
  if (denominator <= 0) return 1;
  return (1 - numerator / denominator).clamp(0.0, 1.0);
}
