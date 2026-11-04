import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' show Abi;

import 'package:path/path.dart' as p;

import '../features/model_center/inference_resource_governor.dart';
import '../models/ocr_compute_preferences.dart';
import '../models/ocr_model_files.dart';
import 'ocr_processing_worker.dart';
import 'ocr_worker_protocol.dart';

class OcrWorkerProcessFailure extends StateError {
  OcrWorkerProcessFailure(this.code, String message) : super(message);
  final String code;
}

class ProcessOcrWorker implements OcrWorker {
  ProcessOcrWorker._(this._process, this._checkAllocation) {
    _releasePid = InferenceProcessRegistry.instance.retain(_process.pid);
    _output = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_receive, onError: (Object error) => _fail(error));
    // Native diagnostics are drained without logging model inputs/subtitles.
    _errors = _process.stderr.listen((_) {});
    unawaited(
      _process.exitCode.then((code) {
        _releasePid();
        _fail(
          OcrWorkerProcessFailure('exit', 'OCR 加速进程已退出（$code），正在恢复 CPU 识别'),
        );
      }),
    );
  }
  final Process _process;
  final Future<void> Function(int bytes)? _checkAllocation;
  late final void Function() _releasePid;
  late final StreamSubscription<String> _output;
  late final StreamSubscription<List<int>> _errors;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  bool _closed = false, _dead = false;
  Future<void> _writes = Future<void>.value();
  int _nextId = 0;
  @override
  String runtimeVersion = '';
  @override
  List<String> availableBackends = const ['CPU'];
  @override
  bool get isolated => true;
  @override
  final checkpoints = <int, Map<String, dynamic>>{};

  static String? bundledExecutable({String? appExecutable}) {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return null;
    }
    final folder = p.dirname(appExecutable ?? Platform.resolvedExecutable);
    final path = Platform.isMacOS
        ? p.normalize(
            p.join(
              folder,
              '..',
              'Resources',
              'ocr',
              Abi.current() == Abi.macosArm64 ? 'arm64' : 'x64',
              'ocr_worker',
            ),
          )
        : p.join(
            folder,
            'resources',
            'ocr',
            Platform.isWindows ? 'ocr_worker.exe' : 'ocr_worker',
          );
    return File(path).existsSync() ? path : null;
  }

  static Future<Process> _launch(String executable, List<String> arguments) {
    final directory = p.dirname(executable);
    final environment = <String, String>{};
    if (Platform.isWindows) {
      environment['PATH'] =
          '$directory;${p.dirname(Platform.resolvedExecutable)};${Platform.environment['PATH'] ?? ''}';
    } else if (Platform.isLinux) {
      environment['LD_LIBRARY_PATH'] =
          '$directory:${p.join(p.dirname(Platform.resolvedExecutable), 'lib')}:${Platform.environment['LD_LIBRARY_PATH'] ?? ''}';
    } else if (Platform.isMacOS) {
      final frameworks = p.normalize(
        p.join(p.dirname(Platform.resolvedExecutable), '..', 'Frameworks'),
      );
      environment['DYLD_LIBRARY_PATH'] =
          '$directory:$frameworks:${Platform.environment['DYLD_LIBRARY_PATH'] ?? ''}';
    }
    return Process.start(
      executable,
      arguments,
      workingDirectory: directory,
      environment: environment,
      runInShell: false,
    );
  }

  static Future<OcrComputeCapabilities> probe(String executable) async {
    var capabilities = OcrComputeCapabilities(
      platform: Platform.operatingSystem,
      isolated: true,
    );
    final failed = <String>[];
    try {
      capabilities = await _probeOne(executable, '--capabilities');
    } catch (_) {
      failed.add('系统加速');
    }
    final providers = {...capabilities.providers};
    final devices = [...capabilities.devices];
    for (final provider
        in Platform.isMacOS ? const ['Metal'] : const ['Vulkan', 'OpenCL']) {
      if (!providers.contains(provider) && failed.isEmpty) continue;
      try {
        final result = await _probeOne(
          executable,
          '--capabilities-provider=$provider',
        );
        providers.addAll(result.providers);
        devices.addAll(result.devices);
      } catch (_) {
        failed.add(provider);
      }
    }
    return OcrComputeCapabilities(
      platform: capabilities.platform,
      isolated: true,
      providers: providers.toList(),
      devices: devices,
      note: failed.isEmpty
          ? capabilities.note
          : '${failed.join('、')} 检测未完成，已保留其他可用路线',
    );
  }

  static Future<OcrComputeCapabilities> _probeOne(
    String executable,
    String argument,
  ) async {
    final process = await _launch(executable, [argument]);
    final release = InferenceProcessRegistry.instance.retain(process.pid);
    try {
      final outputs = await Future.wait<Object?>([
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.drain<void>(),
        process.exitCode,
      ]).timeout(const Duration(seconds: 20));
      if (outputs[2] != 0) throw StateError('无法读取加速设备');
      final line = (outputs[0] as String)
          .split('\n')
          .lastWhere((v) => v.startsWith(ocrWorkerProtocol));
      return OcrComputeCapabilities.fromJson(
        jsonDecode(line.substring(ocrWorkerProtocol.length))
            as Map<String, dynamic>,
      );
    } finally {
      process.kill();
      release();
    }
  }

  static Future<ProcessOcrWorker> start(
    OcrModelFiles files, {
    required String executable,
    Map<int, OcrModelFiles> tracks = const {},
    int cpuThreads = 2,
    int batchLimit = 1,
    Future<void> Function(int bytes)? checkAllocation,
    String? deviceKey,
    bool conservative = false,
    Future<void>? cancelSignal,
  }) async {
    final process = await _launch(executable, const []);
    final worker = ProcessOcrWorker._(process, checkAllocation);
    var starting = true;
    cancelSignal?.then((_) {
      if (starting) worker.cancel();
    });
    try {
      final ready = await worker._request({
        'op': 'start',
        'files': files.toMessage(),
        'tracks': {
          for (final entry in tracks.entries)
            '${entry.key}': entry.value.toMessage(),
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

  void _send(Map<String, Object?> command) {
    if (_closed || _dead) {
      throw OcrWorkerProcessFailure('closed', 'OCR 加速进程已关闭');
    }
    final payload = jsonEncode(command);
    // IOSink cannot accept another write/close while flush is bound. Native
    // allocation replies and cancellation can arrive before that flush ends.
    _writes = _writes
        .then((_) async {
          if (_closed || _dead) return;
          _process.stdin.writeln(payload);
          await _process.stdin.flush();
        })
        .catchError((Object error) {
          _fail(error);
          _process.kill();
        });
  }

  Future<Map<String, dynamic>> _request(Map<String, Object?> command) async {
    final id = ++_nextId;
    final pending = Completer<Map<String, dynamic>>();
    _pending[id] = pending;
    try {
      _send({...command, 'id': id});
      return await pending.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          final error = OcrWorkerProcessFailure(
            'timeout',
            'OCR 加速设备响应超时，正在恢复 CPU 识别',
          );
          _dead = true;
          _process.kill();
          throw error;
        },
      );
    } finally {
      _pending.remove(id);
    }
  }

  void _receive(String line) {
    if (!line.startsWith(ocrWorkerProtocol) || _closed || _dead) return;
    try {
      final message =
          jsonDecode(line.substring(ocrWorkerProtocol.length))
              as Map<String, dynamic>;
      if (message['event'] == 'allocation') {
        unawaited(_admit(message));
        return;
      }
      final pending = _pending[message['id']];
      if (pending == null || pending.isCompleted) return;
      if (message['error'] != null) {
        pending.completeError(StateError(message['error'] as String));
      } else {
        pending.complete(message);
      }
    } catch (_) {
      _fail(OcrWorkerProcessFailure('protocol', 'OCR 加速进程响应无效，正在恢复 CPU 识别'));
      _process.kill();
    }
  }

  Future<void> _admit(Map<String, dynamic> event) async {
    Object? error;
    try {
      if (_closed || _dead) return;
      final bytes = event['bytes'];
      if (bytes is! int || bytes <= 0 || bytes > 64 * 1073741824) {
        throw StateError('OCR 内存请求无效');
      }
      await _checkAllocation?.call(bytes);
    } catch (e) {
      error = e;
    }
    if (!_closed && !_dead) {
      try {
        _send({
          'op': 'allocationReply',
          'allocationId': event['allocationId'],
          'error': error?.toString(),
        });
      } catch (e) {
        _fail(e);
      }
    }
  }

  void _fail(Object error) {
    _dead = true;
    final failure = error is OcrWorkerProcessFailure
        ? error
        : OcrWorkerProcessFailure('communication', 'OCR 加速进程连接中断，正在恢复 CPU 识别');
    for (final request in _pending.values) {
      if (!request.isCompleted) request.completeError(failure);
    }
  }

  @override
  Future<OcrFrameAnalysis> analyzeCommand(Map<String, Object?> command) async {
    final message = await _request({'op': 'frame', 'command': command});
    final result = OcrFrameAnalysis.fromMessage(
      message,
      command['atMs']! as int,
    );
    if (result.checkpoint != null) {
      checkpoints[command['track'] as int? ?? 0] = result.checkpoint!;
    }
    return result;
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

  void cancel() {
    _fail(OcrWorkerProcessFailure('cancelled', 'OCR 已取消'));
    _process.kill();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (!_dead && _pending.isEmpty) {
      try {
        await _request({'op': 'close'}).timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    _closed = true;
    _fail(OcrWorkerProcessFailure('closed', 'OCR 加速进程已关闭'));
    _process.kill();
    await _output.cancel();
    await _errors.cancel();
    try {
      await _writes.timeout(const Duration(seconds: 1));
      await _process.stdin.close();
    } catch (_) {
      /* A killed process may have closed its pipe mid-flush. */
    }
    await _process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    _releasePid();
  }
}
