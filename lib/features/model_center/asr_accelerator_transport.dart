import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'inference_resource_governor.dart';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

abstract class AsrAcceleratorTransport {
  Future<Map<String, dynamic>> request(Map<String, dynamic> message);
  Future<void> close();

  /// Cheap local installation identity, with no driver/session initialization.
  /// Mobile app updates and desktop component replacements invalidate failures.
  static Future<Object?> environment() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        return await const MethodChannel(
          'com.example.video_player_app/asr_acceleration',
        ).invokeMethod<Object?>('environment');
      }
      final worker = desktopExecutable();
      if (worker == null) return 'no-asr-worker';
      final files = [
        worker,
        p.join(p.dirname(worker), 'manifest.json'),
        if (Platform.isWindows) ...[
          p.join(p.dirname(worker), 'onnxruntime.dll'),
          p.join(p.dirname(worker), 'DirectML.dll'),
        ],
      ];
      return [
        for (final path in files)
          await File(path).stat().then(
            (s) => [
              p.basename(path),
              s.size,
              s.modified.millisecondsSinceEpoch,
            ],
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  static String? desktopExecutable({String? executable}) {
    final base = p.dirname(executable ?? Platform.resolvedExecutable);
    final file = Platform.isMacOS
        ? p.normalize(p.join(base, '..', 'Helpers', 'asr', 'asr_worker'))
        : p.join(
            base,
            'resources',
            'asr',
            Platform.isWindows ? 'asr_worker.exe' : 'asr_worker',
          );
    return File(file).existsSync() ? file : null;
  }

  static Future<AsrAcceleratorTransport> open({String? executable}) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final transport = _MobileAsrTransport();
      try {
        await transport.request({'op': 'open'});
        return transport;
      } catch (_) {
        await transport.close();
        rethrow;
      }
    }
    final worker = executable ?? desktopExecutable();
    if (worker == null) throw StateError('当前安装未提供匹配的转录加速组件');
    if (Platform.isWindows &&
        [
          'onnxruntime.dll',
          'DirectML.dll',
        ].any((name) => !File(p.join(p.dirname(worker), name)).existsSync())) {
      throw StateError('转录加速运行组件不完整，使用 CPU');
    }
    return ProcessAsrAcceleratorTransport.start(worker);
  }
}

/// CPU libraries in the player are never replaced by a desktop GPU runtime.
class ProcessAsrAcceleratorTransport implements AsrAcceleratorTransport {
  ProcessAsrAcceleratorTransport._(
    this._process, {
    this.loadTimeout = const Duration(seconds: 120),
    this.requestTimeout = const Duration(seconds: 60),
  }) {
    _unregister = InferenceProcessRegistry.instance.retain(_process.pid);
    _stdout = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final message = jsonDecode(line);
            if (message is! Map || message['id'] != _nextId) return;
            final pending = _pending;
            _pending = null;
            if (message['ok'] == true) {
              pending?.complete(Map<String, dynamic>.from(message));
            } else {
              pending?.completeError(
                StateError('${message['error'] ?? 'GPU 推理失败'}'),
              );
            }
          } catch (_) {
            /* Native diagnostics cannot become protocol messages. */
          }
        }, onError: (Object error) => _fail(error));
    _stderr = _process.stderr.listen((_) {});
    unawaited(_process.stdin.done.catchError((Object _) {}));
    unawaited(
      _process.exitCode.then((code) {
        _unregister();
        _dead = true;
        _fail(StateError('转录 GPU 工作进程已退出（$code）'));
      }),
    );
  }
  final Process _process;
  final Duration loadTimeout, requestTimeout;
  late final void Function() _unregister;
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<List<int>> _stderr;
  Completer<Map<String, dynamic>>? _pending;
  int _nextId = 0;
  bool _dead = false;
  int get processId => _process.pid;

  static Future<ProcessAsrAcceleratorTransport> start(
    String executable, {
    Duration loadTimeout = const Duration(seconds: 120),
    Duration requestTimeout = const Duration(seconds: 60),
    Map<String, String> environment = const {},
  }) async => ProcessAsrAcceleratorTransport._(
    await Process.start(
      executable,
      const [],
      workingDirectory: p.dirname(executable),
      environment: {
        ...environment,
        if (Platform.isWindows)
          'PATH':
              '${p.dirname(Platform.resolvedExecutable)};${Platform.environment['PATH'] ?? ''}',
        if (Platform.isLinux)
          'LD_LIBRARY_PATH':
              '${p.dirname(executable)}:${Platform.environment['LD_LIBRARY_PATH'] ?? ''}',
      },
    ),
    loadTimeout: loadTimeout,
    requestTimeout: requestTimeout,
  );

  void _fail(Object error) {
    final pending = _pending;
    _pending = null;
    pending?.completeError(error);
  }

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> message) async {
    if (_dead) throw StateError('转录 GPU 工作进程不可用');
    if (_pending != null) throw StateError('转录加速器正忙');
    final result = _pending = Completer<Map<String, dynamic>>();
    _nextId++;
    try {
      _process.stdin.writeln(jsonEncode({...message, 'id': _nextId}));
      // Subscribe to the reply immediately: a driver can terminate the child
      // before an asynchronous pipe flush has completed.
      unawaited(
        _process.stdin.flush().then<void>(
          (_) {},
          onError: (Object error) {
            _fail(error);
          },
        ),
      );
      return await result.future.timeout(
        message['op'] == 'load' ? loadTimeout : requestTimeout,
      );
    } on TimeoutException {
      await close();
      throw StateError('转录 GPU 响应超时，已停止工作进程');
    } finally {
      if (identical(_pending, result)) _pending = null;
    }
  }

  @override
  Future<void> close() async {
    _unregister();
    _dead = true;
    _fail(StateError('转录加速器已关闭'));
    _process.kill();
    await _process.exitCode;
    await _stdout.cancel();
    await _stderr.cancel();
  }
}

class _MobileAsrTransport implements AsrAcceleratorTransport {
  static const _channel = MethodChannel(
    'com.example.video_player_app/asr_acceleration',
  );
  bool _closed = false;
  void Function()? _unregister;
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> message) async {
    if (_closed) throw StateError('转录加速器已关闭');
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'request',
      message,
    );
    if (value == null || value['ok'] != true) {
      throw StateError('${value?['error'] ?? '当前设备没有可用的转录加速组件'}');
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
    _unregister?.call();
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {}
  }
}
