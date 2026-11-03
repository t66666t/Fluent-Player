import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ai_agent_catalog.dart';
import 'ai_chat_settings.dart';
import 'ai_chat_transport.dart';
import 'ai_cli_locator.dart';

/// Desktop ACP v1 transport. Healthy processes are leased exclusively; each
/// bounded application request still creates its own session and working dir.
/// Agents own authentication; the client never reads their credential files.
class AiAcpClient {
  AiAcpClient({
    required this.launch,
    required this.temporaryDirectory,
    required this.terminate,
    required this.connectionTimeout,
    required this.idleTimeout,
    required this.processTimeout,
    this.keepAliveTimeout = defaultKeepAliveTimeout,
    this.maxIdleConnections = 2,
    this.maxSessionsPerProcess = 32,
    this.connectionIdentity,
  }) : assert(maxIdleConnections >= 0),
       assert(maxSessionsPerProcess > 0);

  static const defaultKeepAliveTimeout = Duration(minutes: 15);
  final AiChatProcessLauncher launch;
  final Future<Directory> Function() temporaryDirectory;
  final Future<void> Function(Process) terminate;
  final Duration connectionTimeout, idleTimeout, processTimeout;
  final Duration keepAliveTimeout;
  final int maxIdleConnections, maxSessionsPerProcess;
  // Includes external launch state, e.g. the app's current proxy generation.
  final String Function()? connectionIdentity;
  final _connections = <_AcpConnection>{};
  final _idle = <_AcpConnection, Timer>{};
  final _singleSessionOnly = <String>{};
  bool _disposed = false;

  _AcpConnection _operation(
    AiChatSettings settings,
    AiChatCancellation cancellation,
  ) {
    if (_disposed) throw const AiChatException('Agent 连接已关闭。');
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      throw const AiChatException('命令行 AI 后端仅支持桌面端。');
    }
    final key = jsonEncode([
      settings.backend.name,
      settings.executablePath.trim(),
      settings.backend == AiBackend.acp
          ? settings.cliArguments
          : settings.backend.agentPreset?.arguments,
      connectionIdentity?.call(),
    ]);
    if (!_singleSessionOnly.contains(key)) {
      for (final connection in _idle.keys.toList().reversed) {
        if (connection.key != key || !connection.reusable) continue;
        _idle.remove(connection)!.cancel();
        connection.begin(settings, cancellation);
        return connection;
      }
    }
    final connection = _AcpConnection(
      key: key,
      settings: settings,
      cancellation: cancellation,
      launch: launch,
      temporaryDirectory: temporaryDirectory,
      terminate: terminate,
      connectionTimeout: connectionTimeout,
      onBroken: (connection) {
        if (_idle.containsKey(connection)) unawaited(_close(connection));
      },
    );
    _connections.add(connection);
    return connection;
  }

  Future<void> _close(_AcpConnection connection) async {
    _idle.remove(connection)?.cancel();
    await connection.close();
    _connections.remove(connection);
  }

  Future<void> _finish(
    _AcpConnection connection, {
    bool success = false,
  }) async {
    await connection.release();
    if (!_disposed &&
        success &&
        connection.reusable &&
        !_singleSessionOnly.contains(connection.key) &&
        connection.sessionCount < maxSessionsPerProcess &&
        maxIdleConnections > 0 &&
        keepAliveTimeout > Duration.zero) {
      _idle[connection] = Timer(keepAliveTimeout, () {
        unawaited(_close(connection));
      });
      while (_idle.length > maxIdleConnections) {
        await _close(_idle.keys.first);
      }
    } else {
      await _close(connection);
    }
  }

  Future<_AcpConnection> _session(_AcpConnection connection) async {
    try {
      await connection.open();
      await connection.createSession();
      return connection;
    } catch (_) {
      if (!connection.reused ||
          connection.cancellation.isCancelled ||
          _disposed) {
        rethrow;
      }
      // Some adapters cannot create a second independent session. Retry only
      // this preparation step, before any prompt/model request is submitted.
      // Protocol-level session failures use one-shot processes for this launch
      // signature. A lost process alone does not disable healthy reuse.
      if (connection._failure == null) _singleSessionOnly.add(connection.key);
      final settings = connection.settings;
      final cancellation = connection.cancellation;
      await _close(connection);
      final fresh = _operation(settings, cancellation);
      try {
        await fresh.open();
        await fresh.createSession();
        return fresh;
      } catch (_) {
        await _close(fresh);
        rethrow;
      }
    }
  }

  Stream<AiChatDelta> stream(
    AiChatSettings settings,
    List<Map<String, String>> messages,
    AiChatCancellation cancellation,
  ) async* {
    if (cancellation.isCancelled) return;
    var operation = _operation(settings, cancellation);
    var success = false;
    try {
      yield AiChatDelta(
        stage: operation.reused
            ? '正在复用 ${settings.backend.label} 连接…'
            : '正在启动 ${settings.backend.label}…',
      );
      operation = await _session(operation);
      await operation.configure();
      if (cancellation.isCancelled) return;
      yield AiChatDelta(stage: '正在等待 ${settings.backend.label} 响应…');
      unawaited(operation.prompt(messages, processTimeout));
      await for (final delta in operation.events.stream.timeout(idleTimeout)) {
        if (cancellation.isCancelled) break;
        yield delta;
      }
      success = operation.promptSucceeded && !cancellation.isCancelled;
    } on _AcpCancelled {
      // Stop reclaims only the exclusively leased connection.
    } on TimeoutException {
      if (!cancellation.isCancelled) {
        throw AiChatException('${settings.backend.label} 回答等待超时，请稍后重试。');
      }
    } finally {
      await _finish(operation, success: success);
    }
  }

  Future<List<AiModelInfo>> fetchModels(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    var operation = _operation(settings, cancellation ?? AiChatCancellation());
    var success = false;
    try {
      operation = await _session(operation);
      await operation.selectModel(requireAvailable: false);
      final models = operation.models;
      success = true;
      return models;
    } on _AcpCancelled {
      throw const AiChatException('Agent 检查已取消。');
    } finally {
      await _finish(operation, success: success);
    }
  }

  Future<AiCliStatus> inspectCli(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    var operation = _operation(settings, cancellation ?? AiChatCancellation());
    var success = false;
    try {
      operation = await _session(operation);
      final info = operation.initialized['agentInfo'];
      final name = info is Map ? info['name'] : null;
      final version = info is Map ? info['version'] : null;
      success = true;
      return AiCliStatus(
        executablePath: operation.executable,
        version:
            '${name ?? settings.backend.label}${version == null ? '' : ' $version'} · ACP 已连接',
        // session/new verifies the protocol/configuration, not model access.
        loggedIn: null,
      );
    } on _AcpCancelled {
      throw const AiChatException('Agent 检查已取消。');
    } finally {
      await _finish(operation, success: success);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await Future.wait(_connections.toList().map(_close));
  }
}

class _AcpCancelled implements Exception {
  const _AcpCancelled();
}

class _AcpConnection {
  _AcpConnection({
    required this.settings,
    required this.cancellation,
    required this.launch,
    required this.temporaryDirectory,
    required this.terminate,
    required this.connectionTimeout,
    required this.key,
    required this.onBroken,
  }) {
    _removeCancellation = cancellation.onCancel(cancel);
  }

  final String key;
  final void Function(_AcpConnection) onBroken;
  AiChatSettings settings;
  AiChatCancellation cancellation;
  final AiChatProcessLauncher launch;
  final Future<Directory> Function() temporaryDirectory;
  final Future<void> Function(Process) terminate;
  final Duration connectionTimeout;
  var events = StreamController<AiChatDelta>();
  var _cancelled = Completer<void>();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  void Function()? _removeCancellation;
  Process? _process;
  Directory? _directory;
  Future<Directory>? _sessionDirectory;
  StreamSubscription<String>? _stdout, _stderr;
  Future<void>? _closing, _releasing;
  String _buffer = '', _errors = '';
  String? sessionId;
  int _nextId = 0;
  bool _closed = false, _prompting = false, _hasContent = false;
  bool _ready = false, reused = false, promptSucceeded = false;
  final _sessionIds = <String>{};
  int get sessionCount => _sessionIds.length;
  bool get reusable =>
      _ready &&
      !_closed &&
      _failure == null &&
      !_cancelled.isCompleted &&
      !_prompting &&
      _pending.isEmpty;

  void begin(AiChatSettings nextSettings, AiChatCancellation nextCancellation) {
    settings = nextSettings;
    cancellation = nextCancellation;
    reused = true;
    _releasing = null;
    promptSucceeded = false;
    _hasContent = false;
    _errors = '';
    sessionId = null;
    session = {};
    _configOptions = [];
    events = StreamController<AiChatDelta>();
    _cancelled = Completer<void>();
    _removeCancellation = cancellation.onCancel(cancel);
  }

  // Dispose can race the stream's finally. Serialize directory cleanup so the
  // process root is not removed while its session directory is being removed.
  Future<void> release() => _releasing ??= _release();
  Future<void> _release() async {
    _removeCancellation?.call();
    _removeCancellation = null;
    if (!events.isClosed) unawaited(events.close());
    // Ignore all late updates from the completed session.
    sessionId = null;
    final pending = _sessionDirectory;
    _sessionDirectory = null;
    if (pending != null) {
      try {
        await _cleanDirectory(await pending);
      } on FileSystemException {
        // A cancelled directory creation may already have failed.
      }
    }
  }

  AiChatException? _failure;
  Map<String, dynamic> initialized = {}, session = {};
  List<Map<String, dynamic>> _configOptions = [];
  String get label => settings.backend.label;
  String get executable => settings.executablePath.trim().isNotEmpty
      ? settings.executablePath.trim()
      : settings.backend.agentPreset?.executable ?? '';

  void _check() {
    if (cancellation.isCancelled || _cancelled.isCompleted) {
      throw const _AcpCancelled();
    }
    if (_closed) throw AiChatException('$label 连接已关闭。');
    if (_failure != null) throw _failure!;
  }

  Future<T> _wait<T>(Future<T> future) => Future.any<T>([
    future,
    _cancelled.future.then<T>((_) => throw const _AcpCancelled()),
  ]);

  Future<void> open() async {
    _check();
    if (_ready) return;
    if (executable.isEmpty) {
      throw const AiChatException('请选择已安装的 ACP Agent 可执行文件。');
    }
    _directory = await temporaryDirectory();
    if (_closed) {
      // dispose() may finish while the directory factory is pending.
      await _cleanDirectory(_directory!);
      _directory = null;
    }
    _check();
    final args = settings.backend == AiBackend.acp
        ? settings.cliArguments
        : settings.backend.agentPreset?.arguments ?? const <String>[];
    final pending = Future<Process>.sync(
      () => launch(
        AiChatCliInvocation(
          backend: settings.backend,
          executable: executable,
          arguments: List.unmodifiable(args),
          workingDirectory: _directory!.absolute.path,
          environment: const {},
        ),
      ),
    );
    var abandoned = false;
    unawaited(
      pending.then<void>((process) {
        if (abandoned || _closed) unawaited(_terminate(process));
      }, onError: (Object _, StackTrace _) {}),
    );
    try {
      final process = await _wait(pending.timeout(connectionTimeout));
      if (_closed) {
        await _terminate(process);
        throw const _AcpCancelled();
      }
      _process = process;
      _check();
      process.stdin.encoding = utf8;
      // IOSink may fail asynchronously after a process exits.
      unawaited(
        process.stdin.done.catchError((Object _) {
          _broken('$label 输入连接已断开。');
        }),
      );
      _stdout = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            _receiveChunk,
            onError: (Object _, StackTrace _) => _broken('$label 输出读取失败。'),
            onDone: () => _broken(
              _errors.isEmpty ? '$label 连接已断开，请检查工具版本和登录状态。' : _safe(_errors),
            ),
          );
      _stderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((text) {
            if (_errors.length < 4096) {
              _errors += text.substring(
                0,
                text.length.clamp(0, 4096 - _errors.length),
              );
            }
          }, onError: (Object _, StackTrace _) {});
      unawaited(
        process.exitCode.then<void>((_) {
          _broken(_errors.isEmpty ? '$label 进程已退出，请检查登录状态。' : _safe(_errors));
        }, onError: (Object _, StackTrace _) => _broken('$label 进程已退出。')),
      );
      initialized = await _call('initialize', {
        'protocolVersion': 1,
        'clientCapabilities': {
          'fs': {'readTextFile': false, 'writeTextFile': false},
          'terminal': false,
        },
        'clientInfo': {
          'name': 'video_player_ai_chat',
          'title': 'Video AI Chat',
          'version': '1.0.0',
        },
      });
      if (initialized['protocolVersion'] != 1) {
        throw AiChatException('$label 未提供兼容的 ACP v1 接口，请检查工具版本或启动参数。');
      }
      _ready = true;
    } on AiCliPathException catch (error) {
      abandoned = true;
      throw AiChatException(_safe(error.message));
    } on ProcessException {
      abandoned = true;
      throw AiChatException('$label 启动失败，请检查已安装的工具路径、启动参数和运行依赖。');
    } catch (_) {
      abandoned = true;
      rethrow;
    }
  }

  void _send(Map<String, dynamic> value) {
    if (_process == null || _closed) throw AiChatException('$label 连接已关闭。');
    _process!.stdin.writeln(jsonEncode({'jsonrpc': '2.0', ...value}));
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    _check();
    final id = ++_nextId;
    final pending = Completer<Map<String, dynamic>>();
    _pending[id] = pending;
    try {
      _send({'id': id, 'method': method, 'params': params});
      return await _wait(pending.future.timeout(timeout ?? connectionTimeout));
    } on TimeoutException {
      throw AiChatException(
        '$label ${method == 'session/prompt' ? '回答' : '连接'}超时，请检查工具配置和网络后重试。',
      );
    } finally {
      _pending.remove(id);
    }
  }

  void _receiveChunk(String text) {
    if (_closed) return;
    _buffer += text;
    while (true) {
      final newline = _buffer.indexOf('\n');
      if (newline < 0) break;
      if (newline > 4 * 1024 * 1024) {
        _broken('$label 返回的单条消息过大。');
        return;
      }
      final line = _buffer.substring(0, newline).trim();
      _buffer = _buffer.substring(newline + 1);
      if (line.isNotEmpty) {
        try {
          _receive(line);
        } catch (_) {
          // Server requests can race a closed stdin. Keep listener write
          // failures inside the operation instead of the asynchronous zone.
          _broken('$label 协议响应处理失败，请检查工具连接后重试。');
        }
      }
    }
    if (_buffer.length > 4 * 1024 * 1024) {
      _buffer = '';
      _broken('$label 返回的单条消息过大。');
    }
  }

  void _receive(String line) {
    Map<String, dynamic> event;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      event = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Ignore CLI banners, but do not hide a corrupted protocol frame.
      if (line.startsWith('{')) _broken('$label 返回了无效的 ACP 消息。');
      return;
    }
    if (event['id'] != null && event['method'] == null) {
      final pending = _pending[event['id']];
      if (pending == null || pending.isCompleted) return;
      if (event['error'] != null) {
        final error = event['error'];
        final text = _rpcErrorText(error);
        final code = error is Map ? error['code'] : null;
        final auth =
            code == -32000 ||
            RegExp(
              r'auth_required|authentication required|not logged in|unauthenticated|invalid_api_key|incorrect api key|invalid api key',
              caseSensitive: false,
            ).hasMatch(text);
        pending.completeError(
          AiChatException(
            auth
                ? '$label 尚未登录或凭据已失效，请先在该工具中登录或检查服务配置，再重试。\n${_safe(text)}'
                : '$label：${_safe(text)}',
            contextOverflow: AiChatException.isContextOverflow(text),
          ),
        );
      } else if (event['result'] is Map) {
        pending.complete(Map<String, dynamic>.from(event['result']));
      } else {
        pending.completeError(AiChatException('$label 返回了无效的 ACP 响应。'));
      }
      return;
    }
    if (event['id'] != null && event['method'] != null) {
      // Never grant tool access through a chat that has no permission UI.
      if (event['method'] == 'session/request_permission') {
        _send({
          'id': event['id'],
          'result': {
            'outcome': {'outcome': 'cancelled'},
          },
        });
      } else {
        _send({
          'id': event['id'],
          'error': {
            'code': -32601,
            'message':
                'File, terminal and interactive tools are disabled in video chat',
          },
        });
      }
      return;
    }
    final params = event['params'];
    if (event['method'] != 'session/update' ||
        params is! Map ||
        params['sessionId'] != sessionId) {
      return;
    }
    final update = params['update'];
    if (update is! Map) return;
    final kind = update['sessionUpdate'];
    if (kind == 'config_option_update' && update['configOptions'] is List) {
      _readOptions(update['configOptions']);
    }
    if (!_prompting || events.isClosed) return;
    final content = update['content'];
    if ((kind == 'agent_message_chunk' || kind == 'agent_thought_chunk') &&
        content is Map &&
        content['type'] == 'text' &&
        content['text'] is String) {
      final text = content['text'] as String;
      if (kind == 'agent_message_chunk') {
        _hasContent = _hasContent || text.isNotEmpty;
        events.add(AiChatDelta(content: text));
      } else if (settings.thinkingEnabled) {
        events.add(AiChatDelta(reasoning: text));
      }
    } else if (kind == 'usage_update') {
      // ACP context occupancy is not billed input/output token usage.
      events.add(
        AiChatDelta(
          usage: {
            if (update['size'] is num) 'model_context_window': update['size'],
            if (update['used'] is num) 'acp_context_used': update['used'],
            if (update['cost'] is Map) 'acp_cost': update['cost'],
          },
        ),
      );
    } else if (kind == 'tool_call' || kind == 'tool_call_update') {
      _broken('$label 尝试使用工具，已停止本次回答。请使用纯对话模式或检查该工具的配置。');
    }
  }

  void _broken(String message) {
    if (_closed) return;
    final error = AiChatException(message);
    _failure ??= error;
    onBroken(this);
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
  }

  String _safe(String text) {
    var result = text.replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '');
    if (settings.apiKey.isNotEmpty) {
      result = result.replaceAll(settings.apiKey, '[已隐藏]');
    }
    result = result
        .replaceAll(
          RegExp(
            r'sk-[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
          ),
          '[已隐藏]',
        )
        .replaceAll(
          RegExp(
            r'(?:Bearer|Basic)\s+[A-Za-z0-9._~+/-]+=*',
            caseSensitive: false,
          ),
          '[已隐藏]',
        )
        .replaceAllMapped(
          RegExp(
            r'''(["']?(?:authorization|proxy-authorization|x-api-key|[a-z0-9_]*(?:api[\s_-]?key|access[_-]?token|secret[_-]?key|password|client[_-]?secret)|token|secret)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)''',
            caseSensitive: false,
          ),
          (match) => '${match[1]}[已隐藏]',
        )
        .replaceAllMapped(
          RegExp(
            r'([?&](?:key|api_?key|token|access_token)=)[^&\s"\x27<>]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}[已隐藏]',
        );
    return result.length <= 1800 ? result : '${result.substring(0, 1800)}…';
  }

  /// SDKs often wrap an actionable upstream error in JSON-RPC "Internal error".
  /// Read only known scalar diagnostics: never stringify arbitrary error.data,
  /// which can also contain request prompts, headers and provider configuration.
  String _rpcErrorText(dynamic error) {
    final base = error is Map && error['message'] is String
        ? error['message'] as String
        : error is String
        ? error
        : 'Agent 请求失败';
    final messages = <String>[];
    void add(dynamic value) {
      if (value is! String || value.trim().isEmpty) return;
      final text = value.trim();
      // A JSON object is structured data, not a scalar diagnostic message.
      if (text.startsWith('{') ||
          text.startsWith('[') && !text.startsWith('[API Error:')) {
        return;
      }
      final bounded = text.length > 600 ? '${text.substring(0, 600)}…' : text;
      if (!messages.contains(bounded)) messages.add(bounded);
    }

    add(base);
    final data = error is Map ? error['data'] : null;
    void readDetails(dynamic value, int depth) {
      if (depth > 3 || messages.length >= 4) return;
      if (value is Map) {
        add(value['message']);
        readDetails(value['details'], depth + 1);
        readDetails(value['error'], depth + 1);
      } else if (value is String) {
        if (value.trimLeft().startsWith('{') && value.length <= 4096) {
          try {
            readDetails(jsonDecode(value), depth + 1);
          } on FormatException {
            // Do not display a partial structured request/configuration dump.
          }
        } else {
          add(value);
        }
      }
    }

    readDetails(data, 0);
    final generic = RegExp(
      r'^(?:internal error|server error|request failed|agent 请求失败)[.!。]?$',
      caseSensitive: false,
    ).hasMatch(base.trim());
    if (generic && messages.length <= 1 && _errors.isNotEmpty) {
      final lines = _errors
          .split(RegExp(r'[\r\n]+'))
          .where(
            (line) =>
                !line.trimLeft().startsWith('at ') &&
                RegExp(
                  r'error|failed|exception|401|403|404|429|timeout|unauth|missing|invalid|ECONN|ENOTFOUND|错误|失败',
                  caseSensitive: false,
                ).hasMatch(line),
          );
      for (final line in lines.toList().reversed.take(2).toList().reversed) {
        add(line);
      }
    }
    return messages.isEmpty
        ? 'Agent 请求失败，请检查工具的登录和模型配置。'
        : messages.take(4).join('\n');
  }

  void _readOptions(dynamic value) {
    if (value is! List) return;
    _configOptions = [
      for (final option in value)
        if (option is Map) Map<String, dynamic>.from(option),
    ];
  }

  Future<void> createSession() async {
    _check();
    final pending = _directory!.createTemp('session_');
    _sessionDirectory = pending;
    final Directory directory;
    try {
      directory = await pending;
    } catch (_) {
      _check();
      rethrow;
    }
    _check();
    session = await _call('session/new', {
      'cwd': directory.absolute.path,
      'mcpServers': [],
    });
    final id = session['sessionId'];
    if (id is! String || id.isEmpty) {
      throw AiChatException('$label 没有返回有效的 ACP 会话。');
    }
    if (!_sessionIds.add(id)) {
      throw AiChatException('$label 未创建独立的新会话，正在重建连接。');
    }
    sessionId = id;
    _readOptions(session['configOptions']);
  }

  Map<String, dynamic>? _option(String category, {Set<String> ids = const {}}) {
    for (final option in _configOptions) {
      if (option['type'] == 'select' &&
          (option['category'] == category || ids.contains(option['id']))) {
        return option;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _values(Map<String, dynamic>? option) {
    final values = <Map<String, dynamic>>[];
    void read(dynamic items) {
      if (items is! List) return;
      for (final item in items) {
        if (item is! Map) continue;
        if (item['options'] is List) {
          read(item['options']);
        } else if (item['value'] is String) {
          values.add(Map<String, dynamic>.from(item));
        }
      }
    }

    read(option?['options']);
    return values;
  }

  List<AiModelInfo> get models {
    final modelOption = _option('model', ids: const {'model'});
    final reasoning = _option(
      'thought_level',
      ids: const {'reasoning_effort', 'reasoning-effort', 'thought_level'},
    );
    final efforts = _values(
      reasoning,
    ).map((e) => e['value'] as String).toList();
    final infos = <AiModelInfo>[];
    if (modelOption != null) {
      for (final value in _values(modelOption)) {
        infos.add(
          AiModelInfo(
            id: value['value'],
            name: value['name'] is String ? value['name'] : '',
            description: value['description'] is String
                ? value['description']
                : '',
            // Reasoning choices may depend on the model. Advertise only those
            // for the currently selected model, never copy them to all models.
            reasoningEfforts: value['value'] == modelOption['currentValue']
                ? efforts
                : const [],
            defaultReasoningEffort:
                value['value'] == modelOption['currentValue'] &&
                    efforts.contains(reasoning?['currentValue'])
                ? reasoning!['currentValue'] as String
                : null,
            supportsReasoningEffort:
                value['value'] == modelOption['currentValue'] &&
                    efforts.isNotEmpty
                ? true
                : null,
          ),
        );
      }
    } else if (session['models'] is Map) {
      final available = session['models']['availableModels'];
      if (available is List) {
        for (final value in available) {
          if (value is Map && value['modelId'] is String) {
            infos.add(
              AiModelInfo(
                id: value['modelId'],
                name: value['name'] is String ? value['name'] : '',
                description: value['description'] is String
                    ? value['description']
                    : '',
              ),
            );
          }
        }
      }
    }
    final unique = <String, AiModelInfo>{
      for (final info in infos)
        if (info.id.isNotEmpty) info.id: info,
    };
    return List.unmodifiable(unique.values);
  }

  Future<void> _setOption(Map<String, dynamic> option, String value) async {
    if (option['currentValue'] == value) return;
    final result = await _call('session/set_config_option', {
      'sessionId': sessionId,
      'configId': option['id'],
      'value': value,
    });
    _readOptions(result['configOptions']);
  }

  Future<void> selectModel({required bool requireAvailable}) async {
    final model = settings.model.trim();
    if (model.isNotEmpty) {
      final option = _option('model', ids: const {'model'});
      if (!models.any((candidate) => candidate.id == model)) {
        if (!requireAvailable ||
            const {'deepseek-chat', 'deepseek-flash'}.contains(model)) {
          return;
        }
        throw AiChatException('$label 当前会话未提供所选模型，请刷新模型目录后重新选择。');
      }
      if (option != null) {
        await _setOption(option, model);
      } else {
        final legacy = session['models'];
        if (legacy is Map && legacy['currentModelId'] != model) {
          await _call('session/set_model', {
            'sessionId': sessionId,
            'modelId': model,
          });
        }
      }
    }
  }

  Future<void> configure() async {
    await selectModel(requireAvailable: true);
    final effort = _option(
      'thought_level',
      ids: const {'reasoning_effort', 'reasoning-effort', 'thought_level'},
    );
    if (effort != null &&
        _values(
          effort,
        ).any((value) => value['value'] == settings.reasoningEffort)) {
      await _setOption(effort, settings.reasoningEffort);
    }
  }

  Future<void> prompt(
    List<Map<String, String>> messages,
    Duration deadline,
  ) async {
    _prompting = true;
    try {
      final result = await _call('session/prompt', {
        'sessionId': sessionId,
        'prompt': [
          {
            'type': 'text',
            'text': AiChatTransport.buildCliInput(settings, messages),
          },
        ],
      }, timeout: deadline);
      final reason = result['stopReason'];
      if (reason == 'cancelled') {
        if (!cancellation.isCancelled) {
          throw AiChatException('$label 中止了回答，请重试。');
        }
      } else if (!const {
        'end_turn',
        'max_tokens',
        'max_turn_requests',
        'refusal',
      }.contains(reason)) {
        throw AiChatException('$label 没有返回有效的回答完成状态。');
      } else if (!_hasContent) {
        throw AiChatException('$label 没有返回正文，请检查模型设置。');
      } else if (!events.isClosed) {
        promptSucceeded = true;
        events.add(
          AiChatDelta(
            finishReason:
                const {'max_tokens', 'max_turn_requests'}.contains(reason)
                ? 'length'
                : 'stop',
          ),
        );
      }
    } on _AcpCancelled {
      // Caller owns Stop; do not report it as an error.
    } catch (error, stack) {
      if (!events.isClosed && !cancellation.isCancelled) {
        events.addError(error, stack);
      }
    } finally {
      _prompting = false;
      if (!events.isClosed) unawaited(events.close());
    }
  }

  void cancel() {
    if (_cancelled.isCompleted) return;
    if (!_closed && _process != null && sessionId != null && _prompting) {
      try {
        _send({
          'method': 'session/cancel',
          'params': {'sessionId': sessionId},
        });
      } catch (_) {}
    }
    _cancelled.complete();
    if (!events.isClosed) unawaited(events.close());
  }

  Future<void> _terminate(Process process) async {
    try {
      await terminate(process).timeout(const Duration(seconds: 3));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    cancel();
    _closed = true;
    _removeCancellation?.call();
    _removeCancellation = null;
    final process = _process;
    _process = null;
    await _stdout?.cancel();
    await _stderr?.cancel();
    if (process != null) await _terminate(process);
    await release();
    // Only delete a private directory within the OS temporary root.
    final directory = _directory;
    _directory = null;
    if (directory != null) await _cleanDirectory(directory);
  }

  Future<void> _cleanDirectory(Directory directory) async {
    try {
      final target = await directory.resolveSymbolicLinks();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      if (p.isWithin(root, target) && target != root) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // A CLI may briefly keep files open after process termination.
    }
  }
}
