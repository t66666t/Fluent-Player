import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' show Abi;
import 'inference_resource_governor.dart';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'translation_compute_policy.dart';

// Keep this file free of Flutter imports: the desktop GPU worker is a small
// standalone Dart executable, with its own address space and native libraries.
const translationWorkerProtocol = 'fluent-translation-v1:';

/// Machine-readable failure details, without model prompts or subtitle text.
class TranslationWorkerFailure extends StateError {
  TranslationWorkerFailure(this.code, String message, {this.exitCode})
    : super(message);
  final String code;
  final int? exitCode;
}

class TranslationGeneration {
  const TranslationGeneration({
    required this.text,
    this.truncated = false,
    this.promptTokens = 0,
    this.generatedTokens = 0,
    this.promptMs = 0,
    this.decodeMs = 0,
    this.sampleMs = 0,
  });
  final String text;
  final bool truncated;
  final int promptTokens, generatedTokens;
  final double promptMs, decodeMs, sampleMs;

  Map<String, Object> toJson() => {
    'text': text,
    'truncated': truncated,
    'promptTokens': promptTokens,
    'generatedTokens': generatedTokens,
    'promptMs': promptMs,
    'decodeMs': decodeMs,
    'sampleMs': sampleMs,
  };

  factory TranslationGeneration.fromJson(Map<String, dynamic> json) =>
      TranslationGeneration(
        text: json['text'] as String,
        truncated: json['truncated'] == true,
        promptTokens: (json['promptTokens'] as num).toInt(),
        generatedTokens: (json['generatedTokens'] as num).toInt(),
        promptMs: (json['promptMs'] as num).toDouble(),
        decodeMs: (json['decodeMs'] as num).toDouble(),
        sampleMs: (json['sampleMs'] as num).toDouble(),
      );
}

abstract class TranslationInference {
  String get backend;
  int get gpuLayers;
  Future<TranslationGeneration> generate(
    String prompt, {
    String? grammar,
    bool structured = false,
    bool reusePromptPrefix = true,
    void Function(String)? onDelta,
  });
  void cancel();
  Future<void> dispose();
}

class NativeTranslationInference implements TranslationInference {
  NativeTranslationInference._(this.engine, this.backend, this.gpuLayers);
  final LlamaEngine engine;
  @override
  final String backend;
  @override
  final int gpuLayers;

  static Future<NativeTranslationInference> load(
    String path,
    ModelParams params,
  ) async {
    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.path(path)),
      params: params,
    );
    try {
      final layers = await engine.getResolvedGpuLayers() ?? 0;
      return NativeTranslationInference._(
        engine,
        layers > 0 ? await engine.getBackendName() : 'CPU',
        layers,
      );
    } catch (_) {
      await engine.dispose();
      rethrow;
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
    final messages = [
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt),
    ];
    final template = await engine.chatTemplate(messages, enableThinking: false);
    final inputTokens =
        template.tokenCount ?? (await engine.tokenize(template.prompt)).length;
    final remaining = 4096 - inputTokens - 32;
    if (remaining < 256) {
      throw const FormatException('字幕批次超过模型上下文，需要缩小批次');
    }
    final output = StringBuffer();
    var truncated = false;
    await for (final chunk in engine.create(
      messages,
      params: GenerationParams(
        maxTokens: remaining.clamp(1, 2048),
        temp: 0.2,
        topP: 0.8,
        topK: 20,
        seed: reusePromptPrefix ? null : 42,
        penalty: structured ? 1.0 : 1.05,
        grammar: grammar,
        reusePromptPrefix: reusePromptPrefix,
      ),
      enableThinking: false,
    )) {
      for (final choice in chunk.choices) {
        if (choice.finishReason == 'length') truncated = true;
        final delta = choice.delta.content ?? '';
        output.write(delta);
        if (delta.isNotEmpty) onDelta?.call(delta);
      }
    }
    final perf = await engine.getPerformanceContext();
    return TranslationGeneration(
      text: output
          .toString()
          .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
          .trim(),
      truncated: truncated,
      promptTokens: perf?.promptEvalTokens ?? inputTokens,
      generatedTokens: perf?.evalTokens ?? 0,
      promptMs: perf?.promptEvalMs ?? 0,
      decodeMs: perf?.decodeMs ?? perf?.evalMs ?? 0,
      sampleMs: perf?.sampleMs ?? 0,
    );
  }

  @override
  void cancel() => engine.cancelGeneration();
  @override
  Future<void> dispose() => engine.dispose();
}

/// The player never loads the desktop Vulkan module. A bad driver can only
/// terminate this child; the caller retries the unfinished batch on CPU.
class ProcessTranslationInference implements TranslationInference {
  ProcessTranslationInference._(this._process) {
    _unregister = InferenceProcessRegistry.instance.retain(_process.pid);
    _output = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_receive, onError: _fail);
    // Drain native diagnostics without retaining or logging subtitle content.
    _errors = _process.stderr.listen((_) {});
    unawaited(
      _process.exitCode.then((code) {
        _unregister();
        _unavailable = true;
        _fail(
          TranslationWorkerFailure(
            'worker_exit',
            'GPU 工作进程已退出（$code），将使用 CPU',
            exitCode: code,
          ),
        );
      }),
    );
  }
  final Process _process;
  late final void Function() _unregister;
  late final StreamSubscription<String> _output;
  late final StreamSubscription<List<int>> _errors;
  Completer<Map<String, dynamic>>? _pending;
  void Function(String)? _onDelta;
  Timer? _deadline;
  int _id = 0;
  bool _closed = false;
  bool _unavailable = false;
  @override
  String backend = 'GPU';
  @override
  int gpuLayers = 0;

  static String? bundledExecutable({String? appExecutable}) {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return null;
    }
    final path = Platform.isMacOS
        ? p.normalize(
            p.join(
              p.dirname(appExecutable ?? Platform.resolvedExecutable),
              '..',
              'Resources',
              'translation',
              Abi.current() == Abi.macosArm64 ? 'arm64' : 'x64',
              'translation_worker',
            ),
          )
        : p.join(
            p.dirname(appExecutable ?? Platform.resolvedExecutable),
            'resources',
            'translation',
            Platform.isWindows
                ? 'translation_worker.exe'
                : 'translation_worker',
          );
    return File(path).existsSync() ? path : null;
  }

  static Future<ProcessTranslationInference> load({
    required String executable,
    required String modelPath,
    required int threads,
    int? promptThreads,
    int gpuLayers = 999,
    String backend = 'vulkan',
    Future<void>? cancelSignal,
  }) async {
    final process = await Process.start(
      executable,
      const [],
      workingDirectory: p.dirname(executable),
      environment: {
        'LLAMADART_NATIVE_LIB_DIR': p.dirname(executable),
        'LLAMADART_BACKEND_MODULE_DIR': p.dirname(executable),
        if (Platform.isLinux)
          'LD_LIBRARY_PATH':
              '${p.dirname(executable)}:${Platform.environment['LD_LIBRARY_PATH'] ?? ''}',
        if (Platform.isMacOS)
          'DYLD_LIBRARY_PATH':
              '${p.dirname(executable)}:${Platform.environment['DYLD_LIBRARY_PATH'] ?? ''}',
      },
      mode: ProcessStartMode.normal,
    );
    final worker = ProcessTranslationInference._(process);
    var loading = true;
    cancelSignal?.then((_) {
      if (loading) worker.cancel();
    });
    try {
      final info = await worker._request({
        'op': 'load',
        'model': modelPath,
        'threads': threads,
        'promptThreads': promptThreads ?? threads,
        'gpuLayers': gpuLayers,
        'backend': backend,
      });
      worker.backend = info['backend'] as String;
      worker.gpuLayers = info['gpuLayers'] as int;
      if (worker.gpuLayers <= 0) throw StateError('此设备没有可用的 GPU 后端');
      return worker;
    } catch (_) {
      await worker.dispose();
      rethrow;
    } finally {
      loading = false;
    }
  }

  void _armDeadline() {
    _deadline?.cancel();
    // An unresponsive desktop driver must not hold the inference lease forever.
    // Reset on every output token, rather than limiting total translation time.
    _deadline = Timer(const Duration(seconds: 90), () {
      _fail(TranslationWorkerFailure('worker_stalled', 'GPU 长时间没有响应，改用 CPU'));
      _process.kill();
    });
  }

  Future<Map<String, dynamic>> _request(Map<String, Object?> message) async {
    if (_closed || _unavailable) throw StateError('GPU 工作进程已关闭');
    if (_pending != null) throw StateError('GPU 工作进程正在推理');
    final response = Completer<Map<String, dynamic>>();
    _pending = response;
    _armDeadline();
    try {
      _process.stdin.writeln(jsonEncode({...message, 'id': ++_id}));
      unawaited(
        _process.stdin.flush().catchError((Object error, StackTrace stack) {
          _fail(error, stack);
        }),
      );
      return await response.future;
    } finally {
      _pending = null;
      _deadline?.cancel();
    }
  }

  void _receive(String line) {
    if (!line.startsWith(translationWorkerProtocol)) return;
    try {
      final event =
          jsonDecode(line.substring(translationWorkerProtocol.length))
              as Map<String, dynamic>;
      if (event['id'] != _id || _pending == null || _pending!.isCompleted) {
        return;
      }
      _armDeadline();
      if (event['event'] == 'delta') {
        _onDelta?.call(event['text'] as String);
      } else if (event['event'] == 'error') {
        final message = event['pressure'] == true
            ? 'GPU 暂时内存不足，使用 CPU'
            : event['message'] as String;
        _pending!.completeError(
          event['format'] == true
              ? FormatException(message)
              : TranslationWorkerFailure('worker_inference', message),
        );
      } else if (event['event'] == 'result') {
        _pending!.complete(event);
      }
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error, stack);
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
  void cancel() {
    _unavailable = true;
    _fail(StateError('字幕翻译已取消'));
    _process.kill();
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _unregister();
    _deadline?.cancel();
    _fail(StateError('GPU 工作进程已关闭'));
    _process.kill();
    await _output.cancel();
    await _errors.cancel();
    await _process.stdin.close().catchError((Object _) {});
    await _process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}

/// Same protocol and generation contract on desktop and Android. The native
/// engine lives entirely in the private process; callbacks carry bounded text
/// deltas to the controller, never native handles or allocators.
class TranslationWorkerServer {
  TranslationWorkerServer({
    Future<TranslationInference> Function(String, ModelParams)? load,
  }) : _load = load ?? NativeTranslationInference.load,
       _nativeLogging = load == null;
  final Future<TranslationInference> Function(String, ModelParams) _load;
  final bool _nativeLogging;
  TranslationInference? _engine;
  Future<Map<String, Object?>> request(
    Map<String, dynamic> command, {
    required void Function(String text) onDelta,
    String? platform,
  }) async {
    switch (command['op']) {
      case 'load':
        if (_engine != null) throw StateError('翻译模型已经加载');
        final path = command['model'] as String;
        if (!File(path).isAbsolute || !await File(path).exists()) {
          throw ArgumentError('翻译模型路径不可用');
        }
        final os = platform ?? Platform.operatingSystem;
        final route = translationGpuRoutes(
          os,
          backend: command['backend'] as String? ?? 'vulkan',
        ).firstOrNull;
        if (route == null) throw StateError('当前系统不支持所选翻译加速路线');
        if (_nativeLogging) {
          await LlamaLogging.configure(level: LlamaLogLevel.error);
        }
        _engine = await _load(
          path,
          isolatedTranslationModelParams(
            platform: os,
            backend: route,
            threads: command['threads'] as int,
            promptThreads:
                (command['promptThreads'] as num?)?.toInt() ??
                command['threads'] as int,
            gpuLayers: command['gpuLayers'] as int,
          ),
        );
        if (_engine!.gpuLayers <= 0 ||
            !_engine!.backend.toLowerCase().contains(route.name)) {
          await close();
          throw StateError('此设备没有可用的 GPU 后端');
        }
        return {
          'event': 'result',
          'backend': _engine!.backend,
          'gpuLayers': _engine!.gpuLayers,
        };
      case 'generate':
        if (_engine == null) throw StateError('翻译模型尚未加载');
        final output = await _engine!.generate(
          command['prompt'] as String,
          grammar: command['grammar'] as String?,
          structured: command['structured'] == true,
          reusePromptPrefix: command['reusePromptPrefix'] != false,
          onDelta: onDelta,
        );
        return {'event': 'result', ...output.toJson()};
      default:
        throw ArgumentError('未知翻译操作');
    }
  }

  Future<void> close() async {
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }
}
