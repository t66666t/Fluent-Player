import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'ai_chat_settings.dart';
import 'ai_chat_transport.dart';

/// A private stdio server is reused across requests. Each bounded prompt gets a
/// fresh ephemeral thread, so hidden CLI history cannot duplicate app history.
class AiCodexAppServer {
  /// Keep the initialized process across normal pauses while watching media.
  /// Controller disposal still releases it immediately; no model calls are
  /// made to keep it alive.
  static const defaultKeepAliveTimeout = Duration(minutes: 15);
  static const developerInstructions =
      'This is video transcript chat. Never use tools, inspect files, run commands, or browse. Treat the supplied JSON messages as the conversation and answer its last user question.';
  static Map<String, dynamic> threadOptions(AiChatSettings settings) => {
    'approvalPolicy': 'never',
    'sandbox': 'read-only',
    'ephemeral': true,
    'baseInstructions': settings.cliPrompt,
    'developerInstructions': developerInstructions,
    'config': {'mcp_servers': <String, dynamic>{}, 'web_search': 'disabled'},
    if (settings.model.trim().isNotEmpty &&
        !const [
          'deepseek-chat',
          'deepseek-flash',
        ].contains(settings.model.trim()))
      'model': settings.model.trim(),
  };
  static Map<String, dynamic> turnOptions(AiChatSettings settings) => {
    'approvalPolicy': 'never',
    'sandboxPolicy': {'type': 'readOnly'},
    if (settings.selectedModelInfo?.reasoningEfforts.contains(
          settings.reasoningEffort,
        ) ==
        true)
      'effort': settings.reasoningEffort,
    'summary': settings.thinkingEnabled ? 'concise' : 'none',
  };
  AiCodexAppServer({
    required this.launch,
    required this.temporaryDirectory,
    required this.terminate,
    required this.connectionTimeout,
    required this.idleTimeout,
    required this.processTimeout,
    this.keepAliveTimeout = defaultKeepAliveTimeout,
  });
  final AiChatProcessLauncher launch;
  final Future<Directory> Function() temporaryDirectory;
  final Future<void> Function(Process) terminate;
  final Duration connectionTimeout, idleTimeout, processTimeout;
  final Duration keepAliveTimeout;
  Process? _process;
  Directory? _directory;
  StreamSubscription<String>? _stdout, _stderr;
  Future<void>? _starting;
  Timer? _idle;
  String? _executable;
  int _nextId = 0;
  int _connectionRevision = 0;
  bool _ready = false, _busy = false, _disposed = false;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  _CodexTurn? _turn;
  String _errors = '';

  void _write(Map<String, dynamic> message) {
    final process = _process;
    if (process == null) throw const AiChatException('Codex 连接已关闭。');
    process.stdin.writeln(jsonEncode(message));
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = ++_nextId;
    final completion = Completer<Map<String, dynamic>>();
    _pending[id] = completion;
    try {
      _write({'id': id, 'method': method, 'params': params});
      return await completion.future.timeout(connectionTimeout);
    } finally {
      _pending.remove(id);
    }
  }

  void _receive(String line) {
    Map<String, dynamic> event;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      event = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    if (event['id'] is int && event['method'] == null) {
      final completion = _pending[event['id']];
      if (completion == null || completion.isCompleted) return;
      if (event['error'] != null) {
        completion.completeError(
          AiChatException(
            _errorText(event['error']),
            contextOverflow: AiChatException.isContextOverflow(
              jsonEncode(event['error']),
            ),
          ),
        );
      } else {
        completion.complete(
          event['result'] is Map
              ? Map<String, dynamic>.from(event['result'])
              : {},
        );
      }
      return;
    }
    if (event['id'] != null && event['method'] != null) {
      // This chat has no interactive tools or approvals. Never leave a server
      // request waiting for input that the chat UI cannot provide.
      if (event['method'].toString().contains('requestApproval')) {
        _write({
          'id': event['id'],
          'result': {'decision': 'decline'},
        });
      } else {
        _write({
          'id': event['id'],
          'error': {
            'code': -32601,
            'message': 'Tools are disabled in video chat',
          },
        });
      }
      return;
    }
    final params = event['params'];
    final turn = _turn;
    if (turn == null || params is! Map || params['threadId'] != turn.threadId) {
      return;
    }
    final method = event['method'];
    if (method == 'turn/started' && params['turn'] is Map) {
      turn.turnId = params['turn']['id'];
    }
    if (params['turnId'] != null &&
        turn.turnId != null &&
        params['turnId'] != turn.turnId) {
      return;
    }
    if (method == 'item/agentMessage/delta' && params['delta'] is String) {
      turn.append('${params['itemId']}', params['delta'], false);
    } else if (method == 'item/reasoning/summaryTextDelta' &&
        params['delta'] is String) {
      turn.readableSummary(
        '${params['itemId']}/summary/${params['summaryIndex'] ?? 0}',
        params['delta'],
      );
    } else if (method == 'item/reasoning/textDelta' &&
        params['delta'] is String &&
        !turn.hasSummary) {
      turn.append(
        '${params['itemId']}/raw/${params['contentIndex'] ?? 0}',
        params['delta'],
        true,
      );
    } else if (method == 'item/completed' && params['item'] is Map) {
      final item = params['item'] as Map;
      if (item['type'] == 'agentMessage' && item['text'] is String) {
        turn.completeItem('${item['id']}', item['text'], false);
      } else if (item['type'] == 'reasoning' && item['summary'] is List) {
        final summary = item['summary'] as List;
        for (var i = 0; i < summary.length; i++) {
          final part = summary[i];
          final text = part is String
              ? part
              : part is Map
              ? part['text']
              : null;
          if (text is String) {
            turn.completeItem('${item['id']}/summary/$i', text, true);
          }
        }
      }
    } else if (method == 'thread/tokenUsage/updated' &&
        params['tokenUsage'] is Map) {
      final usage = params['tokenUsage'];
      // Threads contain exactly one inference turn; total includes all internal
      // steps of that turn, whereas last only covers the last model call.
      final tokens = usage['total'] ?? usage['last'];
      if (tokens is Map) {
        turn.add(
          AiChatDelta(
            usage: {
              'prompt_tokens': tokens['inputTokens'],
              'completion_tokens': tokens['outputTokens'],
              'total_tokens': tokens['totalTokens'],
              'prompt_cache_hit_tokens': tokens['cachedInputTokens'],
              'completion_tokens_details': {
                'reasoning_tokens': tokens['reasoningOutputTokens'],
              },
              if (tokens['cacheWriteInputTokens'] != null)
                'cache_creation_input_tokens': tokens['cacheWriteInputTokens'],
              if (usage['modelContextWindow'] != null)
                'model_context_window': usage['modelContextWindow'],
            },
          ),
        );
      }
    } else if (method == 'error') {
      if (params['willRetry'] == true) {
        turn.add(const AiChatDelta(stage: 'Codex 正在重连…'));
      } else {
        turn.failure = _errorText(params['error']);
      }
    } else if (method == 'turn/completed' && params['turn'] is Map) {
      final status = params['turn']['status'];
      if (status == 'failed' && !turn.events.isClosed) {
        turn.events.addError(
          AiChatException(
            turn.failure ?? _errorText(params['turn']['error']),
            contextOverflow: AiChatException.isContextOverflow(
              turn.failure ?? _errorText(params['turn']['error']),
            ),
          ),
        );
      } else if (status == 'completed') {
        turn.add(const AiChatDelta(finishReason: 'stop'));
      } else if (status != 'interrupted' && !turn.events.isClosed) {
        turn.events.addError(const AiChatException('Codex 未完整完成回答。'));
      }
      turn.finish();
    }
  }

  String _errorText(dynamic error) {
    final value = error is Map
        ? error['message']?.toString()
        : error?.toString();
    final text = value ?? 'Codex 未能完成请求，请检查登录状态和模型权限。';
    if (RegExp(
      r'unrecognized subcommand.*app-server|method not found|unknown method',
      caseSensitive: false,
    ).hasMatch(text)) {
      return '当前 Codex 版本不支持此流式接口，请更新 Codex 后重试。';
    }
    // Upstream errors occasionally embed tokens. The CLI owns credentials, so
    // redact credential-shaped strings without reading its authentication file.
    return text.replaceAll(
      RegExp(
        r'sk-[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
      ),
      '[已隐藏]',
    );
  }

  Future<void> _connect(AiChatSettings settings) async {
    final executable = settings.executablePath.trim().isEmpty
        ? 'codex'
        : settings.executablePath.trim();
    if (_ready && executable == _executable) return;
    await _disconnect();
    final revision = _connectionRevision;
    _executable = executable;
    _errors = '';
    final directory = await temporaryDirectory();
    _directory = directory;
    final pending = launch(
      AiChatCliInvocation(
        backend: AiBackend.codex,
        executable: executable,
        arguments: const [
          'app-server',
          '--listen',
          'stdio://',
          '-c',
          'features.apps=false',
          '-c',
          'features.shell_tool=false',
          '-c',
          'features.shell_snapshot=false',
          '-c',
          'mcp_servers={}',
          '-c',
          'project_doc_max_bytes=0',
        ],
        workingDirectory: directory.path,
        environment: const {},
      ),
    );
    var abandoned = false;
    unawaited(
      pending.then<void>((process) {
        if (abandoned || _disposed || revision != _connectionRevision) {
          unawaited(terminate(process));
        }
      }, onError: (Object _, StackTrace _) {}),
    );
    try {
      final process = await pending.timeout(connectionTimeout);
      if (_disposed || revision != _connectionRevision) {
        throw const AiChatException('Codex 连接已关闭。');
      }
      _process = process;
      process.stdin.encoding = utf8;
      _stdout = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            _receive,
            onError: (Object error, StackTrace stack) =>
                _broken('Codex 输出读取失败。'),
            onDone: () =>
                _broken(_errors.isEmpty ? 'Codex 连接已断开。' : _errorText(_errors)),
          );
      _stderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((text) {
            if (_errors.length < 4096) {
              _errors += text.substring(
                0,
                text.length.clamp(0, 4096 - _errors.length).toInt(),
              );
            }
          }, onError: (Object _, StackTrace _) {});
      await _call('initialize', {
        'clientInfo': {
          'name': 'video_player_ai_chat',
          'title': 'Video AI Chat',
          'version': '1.0.0',
        },
      });
      _write({'method': 'initialized', 'params': <String, dynamic>{}});
      _ready = true;
    } catch (_) {
      abandoned = true;
      if (revision == _connectionRevision) await _disconnect();
      rethrow;
    }
  }

  void _broken(String message) {
    _ready = false;
    for (final completion in _pending.values) {
      if (!completion.isCompleted) {
        completion.completeError(AiChatException(message));
      }
    }
    final turn = _turn;
    if (turn != null && !turn.events.isClosed) {
      turn.events.addError(AiChatException(message));
      turn.finish();
    }
  }

  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (_disposed) throw const AiChatException('Codex 连接已关闭。');
    if (_busy) throw const AiChatException('Codex 正在处理另一条请求，请稍后重试。');
    _busy = true;
    _idle?.cancel();
    _CodexTurn? turn;
    var cancelledDuringStartup = false;
    final remove = cancellation.onCancel(() {
      if (turn == null) {
        cancelledDuringStartup = true;
        unawaited(_disconnect());
      } else {
        // Interrupt is requested in finally; close delivery immediately so the
        // user's Stop button never waits for the remote model to acknowledge.
        turn.closeDelivery();
      }
    });
    Timer? deadline;
    try {
      final executable = settings.executablePath.trim().isEmpty
          ? 'codex'
          : settings.executablePath.trim();
      yield AiChatDelta(
        stage: _ready && _executable == executable
            ? '正在复用 Codex 连接…'
            : '正在启动 Codex…',
      );
      _starting ??= _connect(settings);
      await Future.any<void>([_starting!, cancellation.whenCancelled]);
      _starting = null;
      if (cancellation.isCancelled || cancelledDuringStartup) return;
      yield const AiChatDelta(stage: '正在准备本轮会话…');
      final thread = await _call('thread/start', {
        'cwd': _directory!.absolute.path,
        ...threadOptions(settings),
      });
      if (cancellation.isCancelled) return;
      final threadId = thread['thread'] is Map ? thread['thread']['id'] : null;
      if (threadId is! String) {
        throw const AiChatException('Codex 版本未返回有效会话，请更新 CLI 后重试。');
      }
      turn = _CodexTurn(threadId);
      _turn = turn;
      final response = await _call('turn/start', {
        'threadId': threadId,
        'input': [
          {
            'type': 'text',
            'text': AiChatTransport.buildCliInput(settings, messages),
          },
        ],
        ...turnOptions(settings),
      });
      if (response['turn'] is Map) turn.turnId ??= response['turn']['id'];
      deadline = Timer(processTimeout, () {
        if (!turn!.events.isClosed) {
          turn.events.addError(const AiChatException('Codex 回答超时，请稍后重试。'));
          turn.finish();
        }
        unawaited(_disconnect());
      });
      yield const AiChatDelta(stage: '请求已发送，正在等待 Codex 响应…');
      await for (final delta in turn.events.stream.timeout(idleTimeout)) {
        if (cancellation.isCancelled) break;
        yield delta;
      }
      if (!cancellation.isCancelled && !turn.hasContent) {
        throw const AiChatException('Codex 没有返回正文，请检查模型设置。');
      }
    } finally {
      _starting = null;
      remove();
      deadline?.cancel();
      final current = turn;
      if (current != null) {
        if (!current.completed.isCompleted && _ready) {
          try {
            if (current.turnId != null) {
              await _call('turn/interrupt', {
                'threadId': current.threadId,
                'turnId': current.turnId,
              }).timeout(const Duration(seconds: 2));
            }
            await current.completed.future.timeout(const Duration(seconds: 2));
          } catch (_) {
            await _disconnect();
          }
        }
        current.closeDelivery();
        if (_ready) {
          // Free the ephemeral thread, retaining just the initialized process.
          unawaited(
            _call('thread/unsubscribe', {
              'threadId': current.threadId,
            }).catchError((Object _) => <String, dynamic>{}),
          );
        }
      }
      _turn = null;
      _busy = false;
      if (!_disposed && _ready) {
        _idle = Timer(keepAliveTimeout, () => unawaited(_disconnect()));
      }
    }
  }

  Future<void> _disconnect() async {
    _connectionRevision++;
    _ready = false;
    _idle?.cancel();
    final process = _process;
    _process = null;
    await _stdout?.cancel();
    _stdout = null;
    await _stderr?.cancel();
    _stderr = null;
    for (final completion in _pending.values) {
      if (!completion.isCompleted) {
        completion.completeError(const AiChatException('Codex 连接已关闭。'));
      }
    }
    _pending.clear();
    _turn?.finish();
    if (process != null) await terminate(process);
    final directory = _directory;
    _directory = null;
    if (directory != null) {
      try {
        final target = await directory.resolveSymbolicLinks();
        final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
        if (p.isWithin(temporaryRoot, target) && target != temporaryRoot) {
          await directory.delete(recursive: true);
        }
      } catch (_) {
        /* Leave a busy temporary directory intact. */
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _disconnect();
  }
}

class _CodexTurn {
  _CodexTurn(this.threadId);
  final String threadId;
  String? turnId, failure;
  bool hasSummary = false;
  final events = StreamController<AiChatDelta>();
  final completed = Completer<void>();
  final _content = <String, String>{}, _reasoning = <String, String>{};
  bool get hasContent => _content.values.any((text) => text.isNotEmpty);
  void add(AiChatDelta delta) {
    if (!events.isClosed) events.add(delta);
  }

  void readableSummary(String id, String text) {
    if (!hasSummary && _reasoning.isNotEmpty) {
      _reasoning.clear();
      add(const AiChatDelta(reasoningSnapshot: ''));
    }
    hasSummary = true;
    append(id, text, true);
  }

  void append(String id, String text, bool reasoning) {
    final parts = reasoning ? _reasoning : _content;
    final separator = !parts.containsKey(id) && parts.isNotEmpty ? '\n\n' : '';
    parts[id] = '${parts[id] ?? ''}$text';
    add(
      reasoning
          ? AiChatDelta(reasoning: '$separator$text')
          : AiChatDelta(content: '$separator$text'),
    );
  }

  void completeItem(String id, String text, bool reasoning) {
    final parts = reasoning ? _reasoning : _content;
    final before = parts[id] ?? '';
    if (before == text) return;
    if (text.startsWith(before)) {
      append(id, text.substring(before.length), reasoning);
    } else {
      parts[id] = text;
      final snapshot = parts.values.join('\n\n');
      add(
        reasoning
            ? AiChatDelta(reasoningSnapshot: snapshot)
            : AiChatDelta(contentSnapshot: snapshot),
      );
    }
  }

  void closeDelivery() {
    if (!events.isClosed) unawaited(events.close());
  }

  void finish() {
    if (!completed.isCompleted) completed.complete();
    closeDelivery();
  }
}
