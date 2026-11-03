import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../features/model_center/inference_resource_governor.dart';
import '../models/ocr_compute_preferences.dart';
import '../models/ocr_model_files.dart';
import 'ocr_processing_worker.dart';
import 'ocr_process_worker.dart';
import 'ocr_worker_server.dart';

const _bridge = MethodChannel('com.example.video_player_app/ocr_acceleration');
const _service = MethodChannel('com.example.video_player_app/ocr_worker');

/// This entry point is launched only in Android's private :ocr_accel process.
/// It does not register playback, downloads, notifications or other plugins.
@pragma('vm:entry-point')
void ocrBackgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  final server = OcrWorkerServer((bytes) async {
    await _service.invokeMethod<void>('allocation', {'bytes': bytes});
  });
  var chain = Future<void>.value();
  _service.setMethodCallHandler((call) async {
    if (call.method != 'request') throw MissingPluginException();
    final result = Completer<Map<String, Object?>>();
    chain = chain.then((_) async {
      try {
        result.complete(
          await server.request(
            Map<String, dynamic>.from(call.arguments as Map),
          ),
        );
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  });
  unawaited(_service.invokeMethod<void>('ready'));
}

class AndroidOcrWorker implements OcrWorker {
  AndroidOcrWorker._(this._slot, this._checkAllocation);
  final int _slot;
  final Future<void> Function(int bytes)? _checkAllocation;
  static final _workers = <int, AndroidOcrWorker>{};
  static AndroidOcrWorker _reserve(Future<void> Function(int)? allocation) {
    final slot = const [
      0,
      1,
    ].where((v) => !_workers.containsKey(v)).firstOrNull;
    if (slot == null) throw StateError('OCR 独立进程正在使用中');
    final worker = AndroidOcrWorker._(slot, allocation);
    _workers[slot] = worker;
    _installHandler();
    return worker;
  }

  bool _closed = false;
  Future<void>? _closing;
  void Function()? _releasePid;
  @override
  String runtimeVersion = '';
  @override
  List<String> availableBackends = const ['CPU'];
  @override
  bool get isolated => true;
  @override
  final checkpoints = <int, Map<String, dynamic>>{};

  static Future<OcrComputeCapabilities> probe() async {
    if (_workers.isNotEmpty) throw StateError('OCR 正在使用中');
    var temporary = _reserve(null);
    try {
      var capabilities = OcrComputeCapabilities(
        platform: 'android',
        isolated: true,
      );
      final failed = <String>[];
      try {
        capabilities = OcrComputeCapabilities.fromJson(
          await temporary._request({
            'op': 'capabilities',
            'probeNativeHardware': false,
          }, timeout: const Duration(seconds: 20)),
        );
      } catch (_) {
        await temporary.close();
        temporary = _reserve(null);
        failed.add('系统加速');
      }
      final devices = [...capabilities.devices];
      final providers = {...capabilities.providers};
      for (final provider in const ['OpenCL', 'Vulkan', 'QNN GPU', 'QNN HTP']) {
        try {
          final result = OcrComputeCapabilities.fromJson(
            await temporary._request({
              'op': 'capabilities',
              'onlyProvider': provider,
            }, timeout: const Duration(seconds: 20)),
          );
          devices.addAll(result.devices);
          providers.addAll(result.providers);
        } catch (_) {
          // Preserve completed detections even if a vendor driver terminates
          // this process. The next API is checked in a fresh service process.
          failed.add(provider);
          await temporary.close();
          temporary = _reserve(null);
        }
      }
      return OcrComputeCapabilities(
        platform: 'android',
        isolated: true,
        providers: providers.toList(),
        devices: devices,
        note: failed.isEmpty
            ? capabilities.note
            : '${failed.join('、')} 检测未完成，已保留其他可用路线',
      );
    } finally {
      await temporary.close();
    }
  }

  static void _installHandler() {
    _bridge.setMethodCallHandler((call) async {
      if (call.method == 'allocation') {
        final worker = _workers[(call.arguments as Map)['slot']];
        if (worker == null || worker._closed) throw StateError('OCR 已停止');
        final bytes = (call.arguments as Map)['bytes'];
        if (bytes is! int || bytes <= 0 || bytes > 64 * 1073741824) {
          throw StateError('OCR 内存请求无效');
        }
        await worker._checkAllocation?.call(bytes);
        if (worker._closed) throw StateError('OCR 已停止');
        return null;
      }
      throw MissingPluginException();
    });
  }

  static Future<AndroidOcrWorker> start(
    OcrModelFiles files, {
    Map<int, OcrModelFiles> tracks = const {},
    int cpuThreads = 2,
    int batchLimit = 1,
    Future<void> Function(int bytes)? checkAllocation,
    String? deviceKey,
    bool conservative = false,
    Future<void>? cancelSignal,
  }) async {
    final worker = _reserve(checkAllocation);
    var starting = true;
    cancelSignal?.then((_) {
      if (starting) unawaited(worker.cancel());
    });
    try {
      final ready = await worker._request({
        'op': 'start',
        'files': files.toMessage(),
        'tracks': {
          for (final e in tracks.entries) '${e.key}': e.value.toMessage(),
        },
        'threads': cpuThreads,
        'batchLimit': batchLimit,
        'conservative': conservative,
        'deviceKey': ?deviceKey,
      });
      worker.runtimeVersion = ready['runtimeVersion'] as String;
      worker.availableBackends = List<String>.from(ready['backends'] as List);
      return worker;
    } catch (_) {
      await worker.close();
      rethrow;
    } finally {
      starting = false;
    }
  }

  Future<Map<String, dynamic>> _request(
    Map<String, Object?> command, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (_closed) throw OcrWorkerProcessFailure('closed', 'OCR 加速已关闭');
    try {
      final result = Map<String, dynamic>.from(
        (await _bridge
            .invokeMethod<Map<Object?, Object?>>('request', {
              'slot': _slot,
              'command': command,
            })
            .timeout(timeout))!,
      );
      if (_closed) throw OcrWorkerProcessFailure('closed', 'OCR 加速已关闭');
      final pid = result['workerPid'];
      if (_releasePid == null && pid is int && pid > 0) {
        _releasePid = InferenceProcessRegistry.instance.retain(pid);
      }
      if (result['workerFailure'] == true) {
        throw OcrWorkerProcessFailure('exit', '手机加速进程已退出，正在恢复 CPU 识别');
      }
      if (result['error'] != null) throw StateError(result['error'] as String);
      return result;
    } on OcrWorkerProcessFailure {
      rethrow;
    } on PlatformException {
      throw OcrWorkerProcessFailure('service', '手机加速连接中断，正在恢复 CPU 识别');
    } on TimeoutException {
      await cancel();
      throw OcrWorkerProcessFailure('timeout', '手机加速响应超时，正在恢复 CPU 识别');
    }
  }

  @override
  Future<OcrFrameAnalysis> analyzeCommand(Map<String, Object?> command) async {
    final r = OcrFrameAnalysis.fromMessage(
      await _request({'op': 'frame', 'command': command}),
      command['atMs'] as int,
    );
    if (r.checkpoint != null) {
      checkpoints[command['track'] as int? ?? 0] = r.checkpoint!;
    }
    return r;
  }

  @override
  Future<void> restoreFrameHistory(
    Map<int, Map<String, dynamic>> states,
  ) async {
    await _request({
      'op': 'restore',
      'states': {for (final e in states.entries) '${e.key}': e.value},
    });
    checkpoints.addAll(states);
  }

  @override
  Future<void> resetFrameHistory() async {
    await _request({'op': 'reset'});
    checkpoints.clear();
  }

  @override
  Future<void> closeFrameFiles() async {
    await _request({'op': 'closeFrames'});
  }

  @override
  Future<void> releaseIdleModels() async {
    await _request({'op': 'releaseModels'});
  }

  Future<void> cancel() => close();
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    try {
      await _bridge.invokeMethod<void>('close', {'slot': _slot});
    } catch (_) {
      /* The remote process may already be gone. */
    } finally {
      _releasePid?.call();
      _releasePid = null;
      if (identical(_workers[_slot], this)) _workers.remove(_slot);
    }
  }
}
