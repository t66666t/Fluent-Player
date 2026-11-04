import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'inference_resource_governor.dart';
import 'translation_inference.dart';

const _bridge = MethodChannel(
  'com.example.video_player_app/translation_acceleration',
);
const _service = MethodChannel(
  'com.example.video_player_app/translation_worker',
);

/// Headless entry point in :translation_gpu, with no playback/plugin startup.
@pragma('vm:entry-point')
void translationBackgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  final server = TranslationWorkerServer();
  var chain = Future<void>.value();
  _service.setMethodCallHandler((call) async {
    if (call.method != 'request') throw MissingPluginException();
    final command = Map<String, dynamic>.from(call.arguments as Map);
    final response = Completer<Map<String, Object?>>();
    chain = chain.then((_) async {
      Timer? timer;
      final buffer = StringBuffer();
      var writes = Future<void>.value();
      Object? writeError;
      void flush() {
        timer?.cancel();
        timer = null;
        if (buffer.isEmpty) return;
        final text = buffer.toString();
        buffer.clear();
        writes = writes
            .then(
              (_) => _service.invokeMethod<void>('delta', {
                'id': command['id'],
                'transportId': command['transportId'],
                'text': text,
              }),
            )
            .catchError((Object error) {
              writeError = error;
            });
      }

      try {
        final result = await server.request(
          command,
          onDelta: (text) {
            buffer.write(text);
            if (buffer.length >= 256) {
              flush();
            } else {
              timer ??= Timer(const Duration(milliseconds: 40), flush);
            }
          },
        );
        flush();
        await writes;
        if (writeError != null) throw writeError!;
        response.complete(result);
      } catch (error) {
        timer?.cancel();
        // Await queued IPC too, so a cancelled client cannot produce an
        // unhandled asynchronous exception in this process.
        try {
          await writes;
        } catch (_) {}
        response.complete({
          'event': 'error',
          'format': error is FormatException,
          'pressure': isTransientInferencePressure(error),
          'message': error is FormatException ? error.message : 'GPU 推理失败',
        });
      } finally {
        timer?.cancel();
      }
    });
    return response.future;
  });
  unawaited(_service.invokeMethod<void>('ready'));
}

class AndroidTranslationInference implements TranslationInference {
  AndroidTranslationInference._();
  static AndroidTranslationInference? _active;
  bool _closed = false;
  int _id = 0;
  Timer? _deadline;
  Completer<void>? _interrupted;
  void Function(String)? _onDelta;
  void Function()? _releasePid;
  @override
  String backend = 'GPU';
  @override
  int gpuLayers = 0;

  void _rememberPid(Map<Object?, Object?> value) {
    final pid = value['workerPid'];
    if (pid is int && pid > 0) {
      _releasePid ??= InferenceProcessRegistry.instance.retain(pid);
    }
  }

  void _armDeadline() {
    _deadline?.cancel();
    _deadline = Timer(const Duration(seconds: 90), () {
      final pending = _interrupted;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(
          TranslationWorkerFailure('worker_stalled', '翻译加速长时间没有响应，改用 CPU'),
        );
      }
      unawaited(dispose());
    });
  }

  static Future<AndroidTranslationInference> load({
    required String modelPath,
    required String backend,
    required int threads,
    required int promptThreads,
    required int gpuLayers,
    Future<void>? cancelSignal,
  }) async {
    if (_active != null) throw StateError('本地翻译加速进程正在使用中');
    final worker = _active = AndroidTranslationInference._();
    _bridge.setMethodCallHandler((call) async {
      if (call.method != 'delta') throw MissingPluginException();
      final event = Map<Object?, Object?>.from(call.arguments as Map);
      if (!worker._closed &&
          event['id'] == worker._id &&
          worker._interrupted != null) {
        worker._rememberPid(event);
        worker._armDeadline();
        final text = event['text'];
        if (text is String) worker._onDelta?.call(text);
      }
    });
    var loading = true;
    cancelSignal?.then((_) {
      if (loading) worker.cancel();
    });
    try {
      final result = await worker._request({
        'op': 'load',
        'model': modelPath,
        'backend': backend,
        'threads': threads,
        'promptThreads': promptThreads,
        'gpuLayers': gpuLayers,
      });
      worker.backend = result['backend'] as String;
      worker.gpuLayers = result['gpuLayers'] as int;
      if (worker.gpuLayers <= 0) throw StateError('当前设备没有可用的翻译 GPU 后端');
      return worker;
    } catch (_) {
      await worker.dispose();
      rethrow;
    } finally {
      loading = false;
    }
  }

  Future<Map<String, dynamic>> _request(Map<String, Object?> command) async {
    if (_closed) throw TranslationWorkerFailure('worker_closed', '翻译加速进程已关闭');
    if (_interrupted != null) throw StateError('翻译加速进程正在推理');
    final interrupted = _interrupted = Completer<void>();
    _armDeadline();
    try {
      final value = await Future.any<Map<Object?, Object?>?>([
        _bridge.invokeMapMethod<Object?, Object?>('request', {
          'command': {...command, 'id': ++_id},
        }),
        interrupted.future.then<Map<Object?, Object?>?>(
          (_) => throw TranslationWorkerFailure('worker_closed', '翻译已停止'),
        ),
      ]);
      if (value == null || value['workerFailure'] == true) {
        throw TranslationWorkerFailure('worker_exit', '手机翻译加速进程已退出，改用 CPU');
      }
      _rememberPid(value);
      if (value['event'] == 'error' || value['error'] != null) {
        final message = value['pressure'] == true
            ? 'GPU 暂时内存不足，使用 CPU'
            : value['message'] as String? ?? '翻译加速失败';
        if (value['format'] == true) throw FormatException(message);
        throw TranslationWorkerFailure('worker_inference', message);
      }
      return Map<String, dynamic>.from(value);
    } on PlatformException {
      throw TranslationWorkerFailure('worker_service', '手机翻译加速连接中断，改用 CPU');
    } finally {
      _deadline?.cancel();
      if (identical(_interrupted, interrupted)) _interrupted = null;
    }
  }

  @override
  Future<TranslationGeneration> generate(
    String prompt, {
    String? grammar,
    bool structured = false,
    bool reusePromptPrefix = true,
    void Function(String)? onDelta,
  }) async {
    _onDelta = onDelta;
    try {
      return TranslationGeneration.fromJson(
        await _request({
          'op': 'generate',
          'prompt': prompt,
          'grammar': grammar,
          'structured': structured,
          'reusePromptPrefix': reusePromptPrefix,
        }),
      );
    } finally {
      _onDelta = null;
    }
  }

  @override
  void cancel() => unawaited(dispose());
  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _deadline?.cancel();
    _releasePid?.call();
    final interrupted = _interrupted;
    if (interrupted != null && !interrupted.isCompleted) interrupted.complete();
    try {
      await _bridge
          .invokeMethod<void>('close')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      /* The Binder death path also closes the private process. */
    } finally {
      if (identical(_active, this)) _active = null;
    }
  }
}
