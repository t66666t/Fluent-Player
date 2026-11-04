import 'dart:async';
import 'package:video_player_app/services/network/network_http.dart';
import 'dart:convert';
import 'dart:io';

import 'ai_chat_settings.dart';
import 'ai_native_api_transport.dart';
import 'ai_cli_locator.dart';
import 'ai_token_usage.dart';
import 'ai_codex_app_server.dart';
import 'ai_acp_client.dart';
import 'ai_agent_catalog.dart';

class AiChatDelta {
  const AiChatDelta({
    this.content = '',
    this.reasoning = '',
    this.usage,
    this.usageSnapshot,
    this.finishReason,
    this.stage,
    this.contentSnapshot,
    this.reasoningSnapshot,
    this.reconnecting,
  });
  final String content;
  final String reasoning;
  final Map<String, dynamic>? usage;
  final Map<String, dynamic>? usageSnapshot;
  final String? finishReason;
  final String? stage, contentSnapshot, reasoningSnapshot;
  final bool? reconnecting;
}

class AiChatException implements Exception {
  const AiChatException(
    this.message, {
    this.statusCode,
    this.retryable = false,
    this.contextOverflow = false,
  });
  final String message;
  final int? statusCode;
  final bool retryable;
  final bool contextOverflow;

  /// Explicit context errors only. Authentication/rate limits/payload size and
  /// output-length finishes are not evidence of an input context overflow.
  static bool isContextOverflow(String text, {int? statusCode}) {
    if (statusCode != null && !const {400, 413, 422}.contains(statusCode)) {
      return false;
    }
    return RegExp(
      r'context_length_exceeded|context_window_exceeded|context window (?:is |has been )?exceeded|maximum context length|prompt is too long|input token count.*exceeds|input.*exceeds.*(?:context|token limit)|exceed.*context (?:window|length)|上下文.*超[出过]|输入.*超过.*(?:token|预算)',
      caseSensitive: false,
    ).hasMatch(text);
  }

  @override
  String toString() => message;
}

class AiChatCancellation {
  final _completion = Completer<void>();
  final _listeners = <void Function()>{};
  bool get isCancelled => _completion.isCompleted;
  Future<void> get whenCancelled => _completion.future;

  void cancel() {
    if (isCancelled) return;
    _completion.complete();
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  /// Returns a function that unregisters the listener after a request ends.
  void Function() onCancel(void Function() listener) {
    if (isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

class AiChatCliInvocation {
  const AiChatCliInvocation({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.environment,
    this.backend = AiBackend.codex,
    this.networkRequired = true,
  });
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
  final AiBackend backend;
  final bool networkRequired;
}

class AiCliStatus {
  const AiCliStatus({
    required this.executablePath,
    required this.version,
    this.loggedIn,
  });
  final String executablePath;
  final String version;
  final bool? loggedIn;
  String get description =>
      '$version${loggedIn == null
          ? ''
          : loggedIn!
          ? ' · 已登录'
          : ' · 尚未登录'}';
}

typedef AiChatProcessLauncher =
    Future<Process> Function(AiChatCliInvocation invocation);

typedef AiChatProcessTreeRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// OpenAI-compatible chat completions and optional locally installed CLIs.
/// Each request owns its resources, so cancelling one request cannot abort
/// another conversation or a connection test.
class AiChatTransport {
  AiChatTransport({
    HttpClient Function()? httpClientFactory,
    AiChatProcessLauncher? processLauncher,
    AiChatProcessTreeRunner? processTreeRunner,
    Future<Directory> Function()? temporaryDirectory,
    AiCliLocator? cliLocator,
    this.connectionTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(minutes: 3),
    this.processTimeout = const Duration(minutes: 10),
    this.useCodexAppServer = true,
    this.networkRetryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
      Duration(seconds: 30),
      Duration(seconds: 30),
    ],
  }) : _httpClientFactory =
           httpClientFactory ??
           (() => NetworkHttp.instance.createClient(cancelOnChange: false)),
       _processLauncher =
           processLauncher ??
           ((invocation) =>
               _startProcess(invocation, cliLocator ?? AiCliLocator())),
       _cliLocator = cliLocator ?? AiCliLocator(),
       _processTreeRunner = processTreeRunner ?? _runProcessTreeCommand,
       _temporaryDirectory =
           temporaryDirectory ??
           (() => Directory.systemTemp.createTemp('video_ai_chat_'));

  final HttpClient Function() _httpClientFactory;
  final AiChatProcessLauncher _processLauncher;
  final AiChatProcessTreeRunner _processTreeRunner;
  final AiCliLocator _cliLocator;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration connectionTimeout;
  final Duration idleTimeout;
  final Duration processTimeout;
  final bool useCodexAppServer;

  /// Each retry opens a new request with the original settings and messages.
  final List<Duration> networkRetryDelays;
  final _cliStatusCache = <String, ({AiCliStatus status, DateTime time})>{};
  late final AiCodexAppServer _codex = AiCodexAppServer(
    launch: _processLauncher,
    temporaryDirectory: _temporaryDirectory,
    terminate: (process) =>
        _CliProcessLifetime(process, _processTreeRunner).terminate(),
    connectionTimeout: connectionTimeout,
    idleTimeout: idleTimeout,
    processTimeout: processTimeout,
  );
  late final AiAcpClient _acp = AiAcpClient(
    launch: _processLauncher,
    temporaryDirectory: _temporaryDirectory,
    terminate: (process) =>
        _CliProcessLifetime(process, _processTreeRunner).terminate(),
    connectionTimeout: connectionTimeout,
    idleTimeout: idleTimeout,
    processTimeout: processTimeout,
    connectionIdentity: () => jsonEncode([
      NetworkSettingsService.instance.imageGeneration(NetworkScope.other),
      NetworkSettingsService.instance.configuration.toJson(),
    ]),
  );
  Future<void> dispose() async {
    await Future.wait([_codex.dispose(), _acp.dispose()]);
  }

  static Future<Process> _startProcess(
    AiChatCliInvocation invocation,
    AiCliLocator locator,
  ) async {
    final executable = await locator.resolve(
      invocation.backend,
      invocation.executable,
    );
    final command = locator.command(executable, invocation.arguments);
    final environment = {
      ...locator.childEnvironment(executable),
      ...invocation.environment,
    };
    if (invocation.networkRequired) {
      final context = await NetworkSettingsService.instance.context(
        NetworkScope.other,
        cancelOnChange: false,
      );
      final proxy = await NetworkHttp.instance.externalProxy(
        NetworkScope.other,
        context: context,
      );
      environment
        ..clear()
        ..addAll(
          NetworkHttp.childEnvironment(
            environment: {
              ...locator.childEnvironment(executable),
              ...invocation.environment,
            },
          ),
        )
        ..addAll({
          for (final key in [
            'HTTP_PROXY',
            'HTTPS_PROXY',
            'ALL_PROXY',
            'http_proxy',
            'https_proxy',
            'all_proxy',
          ])
            key: proxy.toString(),
        });
    }
    return Process.start(
      command.executable,
      command.arguments,
      workingDirectory: invocation.workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
  }

  static Future<ProcessResult> _runProcessTreeCommand(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments, runInShell: false);

  /// The exact application-owned text sent to either CLI over stdin.
  /// The CLI's own built-in instructions and external configuration are
  /// managed by that CLI and are not part of this application's prompt.
  static String buildCliInput(
    AiChatSettings settings,
    List<Map<String, String>> messages,
  ) {
    final instruction = settings.cliPrompt;
    return '${instruction.isEmpty ? '' : '$instruction\n'}${jsonEncode(messages)}\n';
  }

  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (cancellation.isCancelled) return;
    if (messages.isEmpty) throw const AiChatException('请先输入一条消息。');
    try {
      await for (final delta in _streamWithRecovery(
        settings,
        List.unmodifiable(
          messages.map((message) => Map<String, String>.unmodifiable(message)),
        ),
        cancellation,
      )) {
        if (cancellation.isCancelled) return;
        yield delta;
      }
    } on _RequestCancelled {
      return;
    } on TimeoutException {
      if (!cancellation.isCancelled) {
        throw const AiChatException('AI 响应超时，请检查网络或稍后重试。');
      }
    } on SocketException {
      if (!cancellation.isCancelled) {
        throw const AiChatException('无法连接 AI 服务，请检查 API 地址和网络。');
      }
    } on HandshakeException {
      if (!cancellation.isCancelled) {
        throw const AiChatException('AI 服务的 HTTPS 证书验证失败。');
      }
    } on HttpException {
      if (!cancellation.isCancelled) {
        throw const AiChatException('AI 连接中断，请重试。');
      }
    } on AiCliPathException catch (exception) {
      if (!cancellation.isCancelled) throw AiChatException(exception.message);
    } on ProcessException catch (exception) {
      if (!cancellation.isCancelled) {
        throw AiChatException(_launchError(settings, exception));
      }
    } catch (_) {
      if (!cancellation.isCancelled) rethrow;
    }
  }

  Stream<AiChatDelta> _streamWithRecovery(
    AiChatSettings settings,
    List<Map<String, String>> messages,
    AiChatCancellation cancellation,
  ) async* {
    var retries = 0;
    Map<String, dynamic>? previousUsage;
    while (!cancellation.isCancelled) {
      final content = StringBuffer(), reasoning = StringBuffer();
      Map<String, dynamic>? attemptUsage;
      var finished = false;
      var resumed = false;
      try {
        final source = settings.backend == AiBackend.api
            ? settings.apiProtocol == AiApiProtocol.openAiCompatible
                  ? _streamApi(settings, messages, cancellation)
                  : AiNativeApiTransport(
                      httpClientFactory: _httpClientFactory,
                      connectionTimeout: connectionTimeout,
                      idleTimeout: idleTimeout,
                    ).stream(
                      settings: settings,
                      messages: messages,
                      cancellation: cancellation,
                    )
            : _streamCli(settings, messages, cancellation);
        // await-for catches the source's error events; yield* forwards those
        // events directly and would leak internal cancellation exceptions.
        await for (final delta in source) {
          if (cancellation.isCancelled) return;
          if (delta.contentSnapshot != null) content.clear();
          if (delta.reasoningSnapshot != null) reasoning.clear();
          content.write(delta.contentSnapshot ?? delta.content);
          reasoning.write(delta.reasoningSnapshot ?? delta.reasoning);
          attemptUsage = AiTokenUsage.merge(attemptUsage, delta.usage);
          finished = finished || delta.finishReason != null;
          final hasContent =
              delta.content.isNotEmpty || delta.contentSnapshot != null;
          final hasReasoning =
              delta.reasoning.isNotEmpty || delta.reasoningSnapshot != null;
          if (retries == 0) {
            yield delta;
          } else {
            // Regeneration can differ from the interrupted answer. Replace its
            // text using snapshots rather than appending a second answer to it.
            // Keep the previous partial answer until fresh content arrives.
            final received = hasContent || hasReasoning || finished;
            yield AiChatDelta(
              content: delta.content,
              reasoning: delta.reasoning,
              contentSnapshot: hasContent || finished
                  ? content.toString()
                  : null,
              reasoningSnapshot: hasContent || hasReasoning || finished
                  ? reasoning.toString()
                  : null,
              usage: delta.usage == null
                  ? null
                  : _sumReportedUsage(previousUsage, attemptUsage),
              finishReason: delta.finishReason,
              stage: !resumed && received ? '网络已恢复，正在生成回答…' : delta.stage,
              reconnecting: !resumed && received ? false : null,
            );
            resumed = resumed || received;
          }
        }
        if (retries > 0 && !cancellation.isCancelled) {
          yield AiChatDelta(
            contentSnapshot: content.toString(),
            reasoningSnapshot: reasoning.toString(),
            reconnecting: false,
          );
        }
        return;
      } catch (error) {
        if (cancellation.isCancelled) return;
        // A dropped usage trailer must not regenerate an already finished reply.
        if (finished && _isRecoverable(error, settings.backend)) return;
        if (!_isRecoverable(error, settings.backend)) rethrow;
        if (retries >= networkRetryDelays.length) {
          if (networkRetryDelays.isEmpty) rethrow;
          throw AiChatException(
            'AI 连接持续中断，已自动重试 $retries 次。已保留收到的内容，请恢复网络后重新生成。',
            statusCode: error is AiChatException ? error.statusCode : null,
          );
        }
        previousUsage = _sumReportedUsage(previousUsage, attemptUsage);
        final delay = networkRetryDelays[retries++];
        yield AiChatDelta(
          stage: '连接暂时中断，正在自动重连（$retries/${networkRetryDelays.length}）…',
          reconnecting: true,
        );
        await _waitForRetry(delay, cancellation);
      }
    }
  }

  static bool _isRecoverable(Object error, AiBackend backend) {
    if (error is HandshakeException) {
      final detail = '${error.message} ${error.osError?.message ?? ''}';
      return !RegExp(
            r'certificate|cert_verify|unknown ca',
            caseSensitive: false,
          ).hasMatch(detail) &&
          RegExp(
            r'connection.*(closed|reset|terminated|abort)|unexpected eof|timed out|network.*unreachable',
            caseSensitive: false,
          ).hasMatch(detail);
    }
    if (error is SocketException || error is HttpException) return true;
    if (error is TimeoutException) return error.message != 'CLI deadline';
    if (error is FormatException &&
        error.message == 'Unfinished UTF-8 octet sequence') {
      return true;
    }
    if (error is! AiChatException) return false;
    if (error.retryable ||
        const {408, 500, 502, 503, 504}.contains(error.statusCode)) {
      return true;
    }
    if (backend == AiBackend.api) return false;
    // CLIs report provider failures as text. Match transport failures narrowly;
    // invalid credentials, models, certificates and exhausted quotas need a fix.
    if (RegExp(
      r'certificate|unauthorized|authentication|quota|insufficient.*(funds|balance)',
      caseSensitive: false,
    ).hasMatch(error.message)) {
      return false;
    }
    return RegExp(
      r'connection (reset|closed|refused|aborted)|network (error|unreachable)|network.*failed|socket|stream (disconnected|closed)|error sending request|failed to (connect|lookup)|timed out|HTTP (408|500|502|503|504)',
      caseSensitive: false,
    ).hasMatch(error.message);
  }

  /// Providers can report a temporary server failure inside a successful SSE
  /// connection. Use their structured codes, not arbitrary message text.
  static bool isTransientProviderError(dynamic error) {
    if (error is! Map) return false;
    return [error['type'], error['code'], error['status']].any(
      (code) => const {
        '408',
        '500',
        '502',
        '503',
        '504',
        'server_error',
        'overloaded_error',
        'api_error',
        'internal_error',
        'internal',
        'unavailable',
        'deadline_exceeded',
      }.contains(code?.toString().toLowerCase()),
    );
  }

  static Map<String, dynamic>? _sumReportedUsage(
    Map<String, dynamic>? previous,
    Map<String, dynamic>? current,
  ) {
    if (previous == null) return current;
    if (current == null) return previous;
    final a = AiTokenUsage.fromMap(previous), b = AiTokenUsage.fromMap(current);
    int? sum(int? x, int? y) =>
        x == null && y == null ? null : (x ?? 0) + (y ?? 0);
    return {
      ...current,
      ...AiTokenUsage(
        input: sum(a.input, b.input),
        output: sum(a.output, b.output),
        total: sum(a.total, b.total),
        cached: sum(a.cached, b.cached),
        cacheWrite: sum(a.cacheWrite, b.cacheWrite),
        reasoning: sum(a.reasoning, b.reasoning),
        cacheMiss: sum(a.cacheMiss, b.cacheMiss),
      ).toMap(),
    };
  }

  static Future<void> _waitForRetry(
    Duration delay,
    AiChatCancellation cancellation,
  ) async {
    final completion = Completer<void>();
    final timer = Timer(delay, completion.complete);
    final unregister = cancellation.onCancel(() {
      timer.cancel();
      if (!completion.isCompleted) completion.complete();
    });
    try {
      await completion.future;
    } finally {
      unregister();
      timer.cancel();
    }
  }

  Future<String> testConnection(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    final content = StringBuffer();
    var received = false;
    final token = cancellation ?? AiChatCancellation();
    final info = settings.selectedModelInfo;
    final needsThinking =
        info?.canDisableThinking == false ||
        (settings.backend == AiBackend.api &&
            settings.apiProtocol != AiApiProtocol.openAiCompatible &&
            info?.canDisableThinking != true);
    var output = needsThinking ? 4096 : 64;
    if (info?.maxOutputTokens != null && output > info!.maxOutputTokens!) {
      output = info.maxOutputTokens!;
    }
    if (output >= settings.contextTokens - 256) {
      output = (settings.contextTokens - 256).clamp(1, output).toInt();
    }
    try {
      await for (final delta in stream(
        settings: settings.copyWith(
          maxOutputTokens: output,
          thinkingEnabled: needsThinking,
          reasoningEffort: settings.backend != AiBackend.api && info != null
              ? info.lowestReasoningEffort ?? ''
              : needsThinking &&
                    info != null &&
                    info.reasoningEfforts.isNotEmpty
              ? info.lowestReasoningEffort!
              : '',
          thinkingBudget: 0,
        ),
        messages: const [
          {'role': 'user', 'content': 'Reply with OK.'},
        ],
        cancellation: token,
      ).timeout(idleTimeout)) {
        received =
            received ||
            delta.content.isNotEmpty ||
            delta.reasoning.isNotEmpty ||
            delta.usage != null;
        if (delta.contentSnapshot != null) content.clear();
        content.write(delta.contentSnapshot ?? delta.content);
      }
      if (token.isCancelled) throw const AiChatException('连接测试已取消。');
      if (!received) throw const AiChatException('服务返回了空响应，请检查模型名称。');
      final response = content.toString().trim();
      return response.isEmpty ? '连接成功（已收到模型响应）。' : '连接成功：$response';
    } finally {
      token.cancel();
    }
  }

  /// Accepts a provider root, a /v1 root, or a full completion endpoint.
  static Uri completionUri(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const AiChatException('请输入有效的 HTTP(S) API 地址。');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (uri.host.toLowerCase() == 'api.openai.com' && path.isEmpty) {
      path = '/v1';
    }
    if (!path.endsWith('/chat/completions')) path += '/chat/completions';
    return uri.replace(path: path);
  }

  static Uri modelsUri(String baseUrl) {
    final uri = completionUri(baseUrl);
    var path = uri.path.substring(
      0,
      uri.path.length - '/chat/completions'.length,
    );
    if (!path.endsWith('/models')) path += '/models';
    return uri.replace(path: path);
  }

  /// Exactly the non-secret OpenAI-compatible request body shown in developer mode.
  static Map<String, dynamic> apiRequestBody(
    AiChatSettings settings,
    List<Map<String, String>> messages,
  ) {
    validateApiSettings(settings, messages: messages);
    final uri = completionUri(settings.baseUrl);
    final model = settings.model.trim();
    final reasoningModel = RegExp(
      r'(^o[134]([\-.]|$)|^gpt-[56]([\-.]|$))',
      caseSensitive: false,
    ).hasMatch(model);
    final info = settings.selectedModelInfo;
    final host = uri.host.toLowerCase();
    final deepSeek =
        host == 'api.deepseek.com' && info?.supportsThinking == true;
    final alibaba =
        AiModelInfo.isAlibabaHost(host) && info?.supportsThinking == true;
    final glmHost = const {'open.bigmodel.cn', 'api.z.ai'}.contains(host);
    final glm = glmHost && info?.supportsThinking == true;
    final openRouter = host == 'openrouter.ai';
    final mandatoryThinking =
        info?.supportsThinking == true && info?.canDisableThinking == false;
    final thinking =
        info?.supportsThinking != false &&
        (settings.thinkingEnabled || mandatoryThinking);
    final effort =
        !settings.thinkingEnabled &&
            mandatoryThinking &&
            info!.reasoningEfforts.isNotEmpty
        ? info.lowestReasoningEffort!
        : settings.reasoningEffort.trim();
    final supportsEffort =
        info?.supportsThinking != false &&
        info?.supportsReasoningEffort == true;
    final routerBudget =
        openRouter &&
        thinking &&
        info?.supportsThinkingBudget == true &&
        settings.thinkingBudget > 0;
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      (reasoningModel ? 'max_completion_tokens' : 'max_tokens'):
          settings.maxOutputTokens,
      if (deepSeek || glm)
        'thinking': {'type': thinking ? 'enabled' : 'disabled'},
      if (alibaba && info?.canDisableThinking == true)
        'enable_thinking': thinking,
      if (alibaba &&
          thinking &&
          info?.supportsThinkingBudget == true &&
          settings.thinkingBudget > 0)
        'thinking_budget': settings.thinkingBudget,
      if (!openRouter && thinking && supportsEffort && effort.isNotEmpty)
        'reasoning_effort': effort,
      if (host == 'api.openai.com' &&
          !thinking &&
          supportsEffort &&
          info?.canDisableThinking == true)
        'reasoning_effort': 'none',
      if (routerBudget) 'reasoning': {'max_tokens': settings.thinkingBudget},
      if (openRouter &&
          thinking &&
          !routerBudget &&
          supportsEffort &&
          effort.isNotEmpty)
        'reasoning': {'effort': effort},
      if (openRouter &&
          thinking &&
          !routerBudget &&
          info?.supportsThinking == true &&
          (!supportsEffort || effort.isEmpty))
        'reasoning': {'enabled': true},
      if (openRouter && !thinking && info?.canDisableThinking == true)
        'reasoning': {'enabled': false},
      if (!reasoningModel && !(thinking && info?.supportsThinking == true))
        'temperature': glmHost
            ? settings.temperature.clamp(0.0, 1.0).toDouble()
            : settings.temperature,
    };
    return body;
  }

  /// Reads the service's real directory only when requested by the user.
  /// The caller decides whether to save this non-secret metadata as a cache.
  Future<List<AiModelInfo>> fetchModels(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    if (settings.backend != AiBackend.api) {
      return _fetchCliModels(settings, cancellation ?? AiChatCancellation());
    }
    if (settings.apiProtocol != AiApiProtocol.openAiCompatible) {
      return AiNativeApiTransport(
        httpClientFactory: _httpClientFactory,
        connectionTimeout: connectionTimeout,
        idleTimeout: idleTimeout,
      ).fetchModels(settings, cancellation: cancellation);
    }
    final requestCancellation = cancellation ?? AiChatCancellation();
    if (requestCancellation.isCancelled) {
      throw const AiChatException('模型列表读取已取消。');
    }
    final uri = modelsUri(settings.baseUrl);
    final apiKey = settings.apiKey.trim();
    _validateApiKey(apiKey);
    final client = _httpClientFactory();
    client.connectionTimeout = connectionTimeout;
    final unregister = requestCancellation.onCancel(
      () => client.close(force: true),
    );
    try {
      final request = await _cancellable(
        client.getUrl(uri).timeout(connectionTimeout),
        requestCancellation,
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      final response = await _cancellable(
        request.close().timeout(connectionTimeout),
        requestCancellation,
      );
      final body = await _readBounded(
        response,
        requestCancellation,
        response.statusCode >= 200 && response.statusCode < 300
            ? 4 * 1024 * 1024
            : 64 * 1024,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiChatException(
          _apiError(response.statusCode, body, apiKey),
          contextOverflow: AiChatException.isContextOverflow(
            body,
            statusCode: response.statusCode,
          ),
          statusCode: response.statusCode,
        );
      }
      dynamic decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        throw const AiChatException('服务返回了无法解析的模型列表；可以直接填写模型 ID。');
      }
      if (decoded is Map && decoded['error'] != null) {
        throw AiChatException(_apiError(null, body, apiKey));
      }
      final data = decoded is Map ? decoded['data'] : decoded;
      if (data is! List) {
        throw const AiChatException('服务没有返回兼容的模型目录；可以直接填写模型 ID。');
      }
      final models = <String, AiModelInfo>{};
      for (final raw in data) {
        AiModelInfo info;
        try {
          info = raw is String
              ? AiModelInfo(id: raw.trim())
              : raw is Map<String, dynamic>
              ? AiModelInfo.fromJson(raw)
              : throw const FormatException('Invalid model entry');
        } on FormatException {
          continue;
        }
        if (info.id.isEmpty || models.containsKey(info.id)) continue;
        final known = AiModelInfo.knownForProvider(settings.baseUrl, info.id);
        final deniedThinking = info.supportsThinking == false;
        final deniedEffort =
            deniedThinking || info.supportsReasoningEffort == false;
        final routerMetadata = raw is Map && raw['reasoning'] is Map
            ? raw['reasoning'] as Map
            : null;
        final openRouterReasoning =
            !deniedThinking &&
            !(raw is Map &&
                (raw['supports_reasoning_effort'] == false ||
                    raw['supportsReasoningEffort'] == false)) &&
            uri.host.toLowerCase() == 'openrouter.ai' &&
            (routerMetadata != null ||
                (raw is Map &&
                    raw['supported_parameters'] is List &&
                    (raw['supported_parameters'] as List).contains(
                      'reasoning',
                    )));
        final routerEffort =
            openRouterReasoning &&
            (routerMetadata == null ||
                routerMetadata.containsKey('supported_efforts'));
        models[info.id] = AiModelInfo(
          id: info.id,
          name: info.name,
          contextWindow: info.contextWindow ?? known?.contextWindow,
          maxOutputTokens: info.maxOutputTokens ?? known?.maxOutputTokens,
          maxInputTokens: info.maxInputTokens ?? known?.maxInputTokens,
          separateInputOutputLimits: info.separateInputOutputLimits,
          maxThinkingInputTokens:
              info.maxThinkingInputTokens ?? known?.maxThinkingInputTokens,
          reasoningEfforts: openRouterReasoning && !routerEffort
              ? const []
              : deniedEffort && !routerEffort
              ? const []
              : info.reasoningEfforts.isNotEmpty
              ? info.reasoningEfforts
              : known?.reasoningEfforts ??
                    (routerEffort
                        ? const [
                            'minimal',
                            'low',
                            'medium',
                            'high',
                            'xhigh',
                            'max',
                          ]
                        : const []),
          defaultReasoningEffort: deniedEffort && !routerEffort
              ? null
              : info.defaultReasoningEffort ?? known?.defaultReasoningEffort,
          supportsThinking:
              info.supportsThinking ??
              known?.supportsThinking ??
              (openRouterReasoning ? true : null),
          supportsReasoningEffort: deniedThinking
              ? false
              : openRouterReasoning
              ? routerEffort
              : info.supportsReasoningEffort ?? known?.supportsReasoningEffort,
          supportsThinkingBudget: deniedThinking
              ? false
              : info.supportsThinkingBudget ?? known?.supportsThinkingBudget,
          thinkingTypes: deniedThinking
              ? const []
              : info.thinkingTypes.isNotEmpty
              ? info.thinkingTypes
              : known?.thinkingTypes ?? const [],
          canDisableThinking:
              info.canDisableThinking ??
              known?.canDisableThinking ??
              (openRouterReasoning ? true : null),
          releasedAt: info.releasedAt,
          description: info.description,
          inputModalities: info.inputModalities,
          outputModalities: info.outputModalities,
        );
      }
      return List.unmodifiable(models.values);
    } on _RequestCancelled {
      throw const AiChatException('模型列表读取已取消。');
    } on TimeoutException {
      throw const AiChatException('读取模型列表超时，可以稍后重试或直接填写模型 ID。');
    } on SocketException {
      throw const AiChatException('无法连接模型目录，请检查 API 地址和网络。');
    } on HandshakeException {
      throw const AiChatException('模型目录的 HTTPS 证书验证失败。');
    } on HttpException {
      throw const AiChatException('模型目录连接中断，请重试。');
    } catch (_) {
      if (requestCancellation.isCancelled) {
        throw const AiChatException('模型列表读取已取消。');
      }
      rethrow;
    } finally {
      unregister();
      client.close(force: true);
    }
  }

  static void validateApiSettings(
    AiChatSettings settings, {
    List<Map<String, String>>? messages,
  }) {
    if (settings.model.trim().isEmpty) throw const AiChatException('请填写模型名称。');
    if (settings.contextTokens <= 0 ||
        settings.maxOutputTokens <= 0 ||
        settings.maxOutputTokens >= settings.contextTokens ||
        settings.thinkingBudget < 0 ||
        !settings.temperature.isFinite ||
        settings.temperature < 0 ||
        settings.temperature > 2) {
      throw const AiChatException('请检查上下文窗口、输出 token 上限和温度；输出上限必须小于上下文窗口。');
    }
    _validateApiKey(settings.apiKey);
    final info = settings.selectedModelInfo;
    if (info?.contextWindow != null &&
        settings.contextTokens > info!.contextWindow!) {
      throw AiChatException(
        '上下文窗口超过模型 ${info.id} 声明的 ${info.contextWindow} token 上限。',
      );
    }
    if (info?.maxOutputTokens != null &&
        settings.maxOutputTokens > info!.maxOutputTokens!) {
      throw AiChatException(
        '输出上限超过模型 ${info.id} 声明的 ${info.maxOutputTokens} token 上限。',
      );
    }
    final effort = settings.reasoningEffort.trim();
    if (settings.thinkingEnabled &&
        effort.isNotEmpty &&
        info?.supportsThinking != false &&
        info?.supportsReasoningEffort == true &&
        info!.reasoningEfforts.isNotEmpty &&
        !info.reasoningEfforts.contains(effort)) {
      throw AiChatException('模型 ${info.id} 不支持思考等级 $effort，请从服务声明的等级中选择。');
    }
    if (messages != null) {
      final conservativeInput =
          settings.requestInputTokens ??
          messages.fold<int>(
            0,
            (sum, message) =>
                sum + AiTokenEstimate.text(message['content'] ?? '') + 16,
          );
      if (conservativeInput +
              (info?.separateInputOutputLimits == true
                  ? 0
                  : settings.maxOutputTokens) >
          settings.contextTokens) {
        throw const AiChatException(
          '本次输入与输出预留超过配置的上下文窗口，请减少资料或提高窗口。',
          contextOverflow: true,
        );
      }
      final inputLimit = info?.inputLimit(
        thinking:
            info.supportsThinking != false &&
            (settings.thinkingEnabled || info.canDisableThinking == false),
      );
      if (inputLimit != null && conservativeInput > inputLimit) {
        throw AiChatException(
          '本次输入超过模型 ${info!.id} 的 $inputLimit token 输入上限，请减少资料或调整文稿处理方式。',
          contextOverflow: true,
        );
      }
    }
  }

  Stream<AiChatDelta> _streamApi(
    AiChatSettings settings,
    List<Map<String, String>> messages,
    AiChatCancellation cancellation,
  ) async* {
    final uri = completionUri(settings.baseUrl);
    final apiKey = settings.apiKey.trim();
    validateApiSettings(settings, messages: messages);
    final client = _httpClientFactory();
    client.connectionTimeout = connectionTimeout;
    final unregister = cancellation.onCancel(() => client.close(force: true));
    try {
      final request = await _cancellable(
        client.postUrl(uri).timeout(connectionTimeout),
        cancellation,
      );
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      request.write(jsonEncode(apiRequestBody(settings, messages)));
      final response = await _cancellable(
        request.close().timeout(idleTimeout),
        cancellation,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await _readBounded(response, cancellation, 64 * 1024);
        throw AiChatException(
          _apiError(response.statusCode, body, apiKey),
          contextOverflow: AiChatException.isContextOverflow(
            body,
            statusCode: response.statusCode,
          ),
          statusCode: response.statusCode,
        );
      }
      if (response.headers.contentType?.mimeType == 'application/json') {
        final body = await _readBounded(
          response,
          cancellation,
          8 * 1024 * 1024,
        );
        final decoded = _decodeObject(body);
        yield _apiDelta(decoded, apiKey, completeMessage: true);
        return;
      }
      final data = StringBuffer();
      var sawFrame = false;
      var sawFinish = false;
      final lines = response
          .timeout(idleTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (cancellation.isCancelled) return;
        if (line.isEmpty) {
          if (data.isEmpty) continue;
          final payload = data.toString().trim();
          data.clear();
          if (payload == '[DONE]') return;
          final event = _decodeObject(payload);
          sawFrame = true;
          sawFinish = sawFinish || _hasFinishReason(event);
          yield _apiDelta(event, apiKey);
        } else if (line.startsWith('data:')) {
          if (data.isNotEmpty) data.write('\n');
          data.write(line.substring(5).trimLeft());
          if (data.length > 8 * 1024 * 1024) {
            throw const AiChatException('AI 返回的单条流式消息过大。');
          }
        }
      }
      // Some compatible services close at finish_reason without [DONE].
      if (data.toString().trim() == '[DONE]') return;
      if (data.isNotEmpty) {
        Map<String, dynamic> event;
        try {
          event = _decodeObject(data.toString().trim());
        } on AiChatException {
          if (sawFinish) rethrow;
          // EOF can cut the last SSE frame in the middle of its JSON payload.
          throw const AiChatException('AI 流式数据在接收完成前中断。', retryable: true);
        }
        sawFrame = true;
        sawFinish = sawFinish || _hasFinishReason(event);
        yield _apiDelta(event, apiKey);
      }
      if (!cancellation.isCancelled && (!sawFrame || !sawFinish)) {
        throw const AiChatException('AI 响应在完成前中断，请重试或继续生成。', retryable: true);
      }
    } finally {
      unregister();
      client.close(force: true);
    }
  }

  Future<String> _readBounded(
    Stream<List<int>> response,
    AiChatCancellation cancellation,
    int maximum,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(idleTimeout)) {
      if (cancellation.isCancelled) throw const _RequestCancelled();
      if (bytes.length + chunk.length > maximum) {
        throw const AiChatException('AI 服务返回的响应过大。');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static bool _hasFinishReason(Map<String, dynamic> event) {
    final choices = event['choices'];
    return choices is List &&
        choices.any(
          (choice) => choice is Map && choice['finish_reason'] != null,
        );
  }

  static Map<String, dynamic> _decodeObject(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Return a user-facing error without printing any provider data.
    }
    throw const AiChatException('AI 服务返回了无法解析的 JSON 响应。');
  }

  static AiChatDelta _apiDelta(
    Map<String, dynamic> event,
    String apiKey, {
    bool completeMessage = false,
  }) {
    if (event['error'] != null) {
      throw AiChatException(
        _apiError(null, jsonEncode(event), apiKey),
        contextOverflow: AiChatException.isContextOverflow(jsonEncode(event)),
        retryable: isTransientProviderError(event['error']),
      );
    }
    final choices = event['choices'];
    Map? delta;
    String? finishReason;
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final choice = choices.first as Map;
      finishReason = choice['finish_reason'] is String
          ? choice['finish_reason'] as String
          : null;
      final value = choice[completeMessage ? 'message' : 'delta'];
      if (value is Map) delta = value;
    }
    final usage = event['usage'];
    return AiChatDelta(
      content: delta?['content'] is String ? delta!['content'] as String : '',
      reasoning: delta?['reasoning_content'] is String
          ? delta!['reasoning_content'] as String
          : delta?['reasoning'] is String
          ? delta!['reasoning'] as String
          : '',
      usage: usage is Map ? Map<String, dynamic>.from(usage) : null,
      finishReason: finishReason,
    );
  }

  static String _apiError(int? status, String body, String apiKey) {
    var detail = '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          detail = error['message'] as String;
        } else if (error is String) {
          detail = error;
        } else if (decoded['message'] is String) {
          detail = decoded['message'] as String;
        }
      }
    } on FormatException {
      // HTML proxy pages and response bodies are not safe diagnostics.
    }
    detail = _sanitize(detail, apiKey);
    final prefix = switch (status) {
      401 || 403 => 'API 认证失败，请检查密钥和访问权限。',
      402 => 'API 余额不足，请检查服务账户。',
      404 => 'API 地址或模型不存在，请检查设置。',
      429 => 'API 请求过于频繁或额度不足，请稍后重试。',
      int code when code >= 500 => 'AI 服务暂时不可用（HTTP $code）。',
      int code => 'AI 请求失败（HTTP $code）。',
      _ => 'AI 服务返回错误。',
    };
    return detail.isEmpty ? prefix : '$prefix $detail';
  }

  Stream<AiChatDelta> _streamCli(
    AiChatSettings settings,
    List<Map<String, String>> messages,
    AiChatCancellation cancellation,
  ) async* {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      throw const AiChatException('命令行 AI 后端仅支持桌面端。');
    }
    if (settings.backend.usesAcp) {
      if (cancellation.isCancelled) return;
      final resolved = settings.copyWith(
        executablePath: await detectCli(settings),
      );
      if (cancellation.isCancelled) return;
      yield* _acp.stream(resolved, messages, cancellation);
      return;
    }
    if (settings.backend == AiBackend.codex && useCodexAppServer) {
      try {
        await for (final delta in _codex.stream(
          settings: settings,
          messages: messages,
          cancellation: cancellation,
        )) {
          yield delta;
        }
      } on AiChatException catch (error) {
        if (!cancellation.isCancelled) {
          throw AiChatException(
            _cliError({'message': error.message}, settings.apiKey),
            statusCode: error.statusCode,
            contextOverflow: error.contextOverflow,
            retryable: error.retryable,
          );
        }
      }
      return;
    }
    final model = settings.model.trim();
    if (model.isNotEmpty && !RegExp(r'^[A-Za-z0-9_./:\-]+$').hasMatch(model)) {
      throw const AiChatException('命令行模型名称只能包含字母、数字、斜线和常用分隔符。');
    }
    final codex = settings.backend == AiBackend.codex;
    final effort = settings.reasoningEffort.trim();
    final useEffort =
        settings.selectedModelInfo?.reasoningEfforts.contains(effort) == true &&
        RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(effort);
    final executable = settings.executablePath.trim().isEmpty
        ? (codex ? 'codex' : 'opencode')
        : settings.executablePath.trim();
    final directory = await _temporaryDirectory();
    Process? process;
    _CliProcessLifetime? lifetime;
    void Function()? unregister;
    Timer? deadline;
    StreamSubscription<String>? stderrSubscription;
    var timedOut = false;
    var launchAbandoned = false;
    final outputStop = AiChatCancellation();
    final stderr = StringBuffer();
    try {
      if (cancellation.isCancelled) return;
      // The prompt is sent through stdin, including on Windows where npm
      // launchers may themselves be .cmd files. It never enters a shell argv.
      final arguments = codex
          ? <String>[
              '--ask-for-approval',
              'never',
              'exec',
              '--json',
              '--color',
              'never',
              '--sandbox',
              'read-only',
              '--skip-git-repo-check',
              '--ephemeral',
              if (useEffort) ...['-c', 'model_reasoning_effort=$effort'],
              if (model.isNotEmpty &&
                  model != 'deepseek-chat' &&
                  model != 'deepseek-flash') ...[
                '--model',
                model,
              ],
              '-',
            ]
          : <String>[
              'run',
              '--format',
              'json',
              '--thinking',
              '--agent',
              'video-chat',
              if (useEffort) ...['--variant', effort],
              if (model.isNotEmpty &&
                  model != 'deepseek-chat' &&
                  model != 'deepseek-flash') ...[
                '--model',
                model,
              ],
            ];
      final environment = <String, String>{
        if (!codex) ...{
          'OPENCODE_CONFIG_CONTENT': jsonEncode({
            'share': 'disabled',
            'permission': {'*': 'deny'},
            'agent': {
              'video-chat': {
                'description': 'Video transcript chat without tools',
                'mode': 'primary',
                'prompt': settings.cliPrompt,
                'permission': {'*': 'deny'},
              },
            },
          }),
          'OPENCODE_PERMISSION': '{"*":"deny"}',
          'OPENCODE_AUTO_SHARE': 'false',
          'OPENCODE_DISABLE_AUTOUPDATE': 'true',
          'OPENCODE_DISABLE_DEFAULT_PLUGINS': 'true',
          'OPENCODE_DISABLE_LSP_DOWNLOAD': 'true',
          'OPENCODE_DISABLE_CLAUDE_CODE': 'true',
          'OPENCODE_DISABLE_AUTOCOMPACT': 'true',
          'OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX':
              '${settings.maxOutputTokens}',
        },
      };
      final launchFuture = _processLauncher(
        AiChatCliInvocation(
          backend: settings.backend,
          executable: executable,
          arguments: arguments,
          workingDirectory: directory.path,
          environment: environment,
        ),
      ).then((process) => _CliProcessLifetime(process, _processTreeRunner));
      // Late process creation must not leave an orphan after cancellation.
      unawaited(
        launchFuture.then<void>((lateProcess) {
          if (launchAbandoned || cancellation.isCancelled) {
            unawaited(lateProcess.terminate());
          }
        }, onError: (Object _, StackTrace _) {}),
      );
      final managed = await _cancellable(
        launchFuture.timeout(connectionTimeout),
        cancellation,
      );
      lifetime = managed;
      final launched = managed.process;
      process = launched;
      unregister = cancellation.onCancel(() {
        outputStop.cancel();
        unawaited(managed.terminate());
      });
      deadline = Timer(processTimeout, () {
        timedOut = true;
        outputStop.cancel();
        unawaited(managed.terminate());
      });
      stderrSubscription = launched.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (text) {
              final remaining = 8192 - stderr.length;
              if (remaining > 0) {
                stderr.write(
                  text.substring(0, text.length.clamp(0, remaining).toInt()),
                );
              }
            },
            onError: (Object _, StackTrace _) {
              // Error-channel failures must not become uncaught zone errors;
              // raw exception details may contain private CLI configuration.
              if (stderr.length < 8192) stderr.write(' 无法读取 CLI 错误输出。');
            },
          );
      launched.stdin.encoding = utf8;
      launched.stdin.write(buildCliInput(settings, messages));
      await _cancellable(launched.stdin.close(), cancellation);
      final emitted = <String, String>{};
      var received = false;
      await for (final line
          in _cancelAware(launched.stdout, outputStop)
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(idleTimeout)) {
        if (cancellation.isCancelled) return;
        if (timedOut) throw TimeoutException('CLI deadline');
        if (line.trim().isEmpty) continue;
        final event = _decodeObject(line);
        final type = event['type'];
        if (type == 'error' || type == 'turn.failed') {
          throw AiChatException(
            _cliError(event, settings.apiKey),
            contextOverflow: AiChatException.isContextOverflow(
              jsonEncode(event),
            ),
          );
        }
        Map? item;
        if (codex && event['item'] is Map) {
          item = event['item'] as Map;
        } else if (!codex && event['part'] is Map) {
          item = event['part'] as Map;
        }
        if (item != null) {
          final itemType = item['type'] ?? type;
          final text = item['text'];
          if (text is String &&
              const ['agent_message', 'text', 'reasoning'].contains(itemType)) {
            final id = '${item['id'] ?? itemType}';
            final previous = emitted[id] ?? '';
            // CLI item.updated/completed events can repeat cumulative text.
            final addition = text.startsWith(previous)
                ? text.substring(previous.length)
                : text;
            emitted[id] = text;
            if (addition.isNotEmpty) {
              received = true;
              yield AiChatDelta(
                content: itemType == 'reasoning' ? '' : addition,
                reasoning: itemType == 'reasoning' ? addition : '',
              );
            }
          }
          if (item['tokens'] is Map) {
            yield AiChatDelta(
              usage: Map<String, dynamic>.from(item['tokens'] as Map),
              finishReason: item['reason'] is String
                  ? item['reason'] as String
                  : null,
            );
          }
        }
        if (event['usage'] is Map) {
          yield AiChatDelta(
            usage: Map<String, dynamic>.from(event['usage'] as Map),
          );
        }
      }
      if (timedOut) throw TimeoutException('CLI deadline');
      final exitCode = await _cancellable(launched.exitCode, cancellation);
      if (exitCode != 0) {
        throw AiChatException(
          'AI 命令行退出（代码 $exitCode）。${_sanitize(stderr.toString(), settings.apiKey)}',
        );
      }
      if (!received) {
        throw const AiChatException('命令行没有返回回答，请检查登录、模型和 CLI 版本。');
      }
    } finally {
      launchAbandoned = true;
      deadline?.cancel();
      unregister?.call();
      await lifetime?.terminate();
      await stderrSubscription?.cancel();
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
        }
      }
      // This directory was created exclusively for this request.
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // A CLI may briefly hold files open after termination on Windows.
      }
    }
  }

  static String _cliError(Map<String, dynamic> event, String apiKey) {
    final error = event['error'];
    final data = error is Map ? error['data'] : null;
    final message = data is Map && data['message'] is String
        ? data['message'] as String
        : error is Map && error['message'] is String
        ? error['message'] as String
        : event['message'] is String
        ? event['message'] as String
        : '请检查 CLI 登录状态和模型配置。';
    var detail = message;
    // Codex sometimes puts an entire provider error JSON inside message.
    for (var level = 0; level < 3; level++) {
      try {
        final nested = jsonDecode(detail);
        if (nested is! Map) break;
        final cause = nested['error'];
        final next = cause is Map ? cause['message'] : nested['message'];
        if (next is! String || next == detail) break;
        detail = next;
      } on FormatException {
        break;
      }
    }
    final safe = _sanitize(detail, apiKey);
    if (RegExp(
      r'not supported.*(ChatGPT|account)|model.*not (available|supported)|model_not_found',
      caseSensitive: false,
    ).hasMatch(safe)) {
      return '当前账号或供应商不支持这个模型。请在 AI 设置中刷新 CLI 模型目录并选择其他模型；目录不等于账号授权，连接测试会验证实际访问。\n$safe';
    }
    if (RegExp(
      r'not logged in|login required|unauthorized|authentication|token.*expired',
      caseSensitive: false,
    ).hasMatch(safe)) {
      return 'CLI 登录或凭据验证失败，请在对应工具中重新登录后重试。\n$safe';
    }
    if (RegExp(
      r'proxy connection failed|HTTP CONNECT failed|connection refused|certificate|network.*(error|failed)',
      caseSensitive: false,
    ).hasMatch(safe)) {
      return 'CLI 网络连接失败，请检查“媒体库设置 → 网络设置”中的“其他联网功能”及代理配置后重试。\n$safe';
    }
    return 'AI 命令行错误：$safe';
  }

  static String _launchError(
    AiChatSettings settings,
    ProcessException exception,
  ) {
    final label = settings.backend.label;
    return '无法启动 $label（系统错误 ${exception.errorCode}）。请使用“自动检测”确认可执行文件；若路径正确，请检查文件访问权限。${_sanitize(exception.message, settings.apiKey)}';
  }

  Future<String> detectCli(AiChatSettings settings) async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      throw const AiChatException('命令行 AI 后端仅支持桌面端。');
    }
    try {
      return await _cliLocator.resolve(
        settings.backend,
        settings.executablePath,
      );
    } on AiCliPathException catch (error) {
      throw AiChatException(error.message);
    }
  }

  Future<AiCliStatus> inspectCli(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    final token = cancellation ?? AiChatCancellation();
    final cacheKey = jsonEncode([
      settings.backend.name,
      settings.executablePath.trim(),
      if (settings.backend.usesAcp) settings.cliArguments,
    ]);
    final cached = _cliStatusCache[cacheKey];
    if (!token.isCancelled &&
        cached != null &&
        DateTime.now().difference(cached.time) < const Duration(seconds: 30)) {
      return cached.status;
    }
    final path = await detectCli(settings);
    final resolved = settings.copyWith(executablePath: path);
    if (settings.backend.usesAcp) {
      // ACP adapters do not necessarily expose --version. Complete their real
      // handshake/session setup so connection checks also detect login errors.
      return _acp.inspectCli(resolved, cancellation: token);
    }
    final version = await _captureCli(resolved, ['--version'], token);
    if (version.code != 0) {
      throw AiChatException(_commandError(version, settings));
    }
    bool? loggedIn;
    if (settings.backend == AiBackend.codex) {
      final login = await _captureCli(resolved, ['login', 'status'], token);
      loggedIn = login.code == 0;
    }
    final text =
        version.output.trim().split(RegExp(r'[\r\n]+')).firstOrNull ?? '';
    final status = AiCliStatus(
      executablePath: path,
      version: text.isEmpty ? 'CLI 已启动' : _sanitize(text, settings.apiKey),
      loggedIn: loggedIn,
    );
    if (loggedIn != false) {
      _cliStatusCache[cacheKey] = (status: status, time: DateTime.now());
    }
    return status;
  }

  Future<List<AiModelInfo>> _fetchCliModels(
    AiChatSettings settings,
    AiChatCancellation token,
  ) async {
    if (settings.backend.usesAcp) {
      final resolved = settings.copyWith(
        executablePath: await detectCli(settings),
      );
      return _acp.fetchModels(resolved, cancellation: token);
    }
    final codex = settings.backend == AiBackend.codex;
    final result = await _captureCli(
      settings,
      codex ? ['debug', 'models'] : ['models', '--verbose', '--refresh'],
      token,
    );
    if (result.code != 0) {
      throw AiChatException(_commandError(result, settings));
    }
    final models = parseCliModels(settings.backend, result.output);
    if (models.isEmpty) {
      throw const AiChatException('CLI 没有返回模型目录。请检查 CLI 版本与供应商配置；仍可手动填写模型 ID。');
    }
    return models;
  }

  static List<AiModelInfo> parseCliModels(AiBackend backend, String output) {
    final clean = output.replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '');
    final models = <AiModelInfo>[];
    final ids = <String>{};
    if (backend == AiBackend.codex) {
      dynamic decoded;
      try {
        decoded = jsonDecode(clean.trim());
      } on FormatException {
        final start = clean.indexOf('{');
        final end = clean.lastIndexOf('}');
        if (start >= 0 && end > start) {
          try {
            decoded = jsonDecode(clean.substring(start, end + 1));
          } on FormatException {
            /* Report an empty catalog below. */
          }
        }
      }
      final entries = decoded is Map
          ? decoded['models'] ?? decoded['data']
          : decoded;
      if (entries is! List) return models;
      for (final entry in entries.whereType<Map>()) {
        if (entry['visibility'] == 'hide' || entry['hidden'] == true) continue;
        final id = entry['slug'] ?? entry['model'] ?? entry['id'];
        if (id is! String || id.isEmpty || !ids.add(id)) continue;
        final rawEfforts =
            entry['supported_reasoning_levels'] ??
            entry['supportedReasoningEfforts'];
        final efforts = rawEfforts is List
            ? rawEfforts
                  .whereType<Map>()
                  .map((level) => level['effort'] ?? level['reasoningEffort'])
                  .whereType<String>()
                  .where(
                    (level) =>
                        RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(level),
                  )
                  .toSet()
                  .toList()
            : <String>[];
        final context = entry['context_window'] ?? entry['contextWindow'];
        models.add(
          AiModelInfo(
            id: id,
            name: entry['display_name'] is String
                ? entry['display_name']
                : entry['displayName'] is String
                ? entry['displayName']
                : id,
            contextWindow: context is int && context > 0 ? context : null,
            reasoningEfforts: efforts,
            defaultReasoningEffort:
                entry['default_reasoning_level'] ??
                entry['defaultReasoningEffort'],
            supportsThinking: efforts.isEmpty ? null : true,
            supportsReasoningEffort: efforts.isNotEmpty,
          ),
        );
      }
    } else {
      // OpenCode verbose format is provider/model followed by a pretty JSON
      // object, rather than one JSON array. Older CLIs may return IDs only.
      String? id;
      final metadata = StringBuffer();
      void finish() {
        final modelId = id;
        if (modelId == null || !ids.add(modelId)) return;
        Map<String, dynamic> data = {};
        try {
          if (metadata.isNotEmpty) {
            data = Map<String, dynamic>.from(jsonDecode(metadata.toString()));
          }
        } catch (_) {
          /* Keep the ID when optional metadata is malformed. */
        }
        final variants = data['variants'];
        final efforts = variants is Map
            ? variants.keys
                  .whereType<String>()
                  .where(
                    (level) =>
                        RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(level),
                  )
                  .toList()
            : <String>[];
        final info = AiModelInfo.fromJson({...data, 'id': modelId});
        models.add(
          AiModelInfo(
            id: modelId,
            name: info.name,
            contextWindow: info.contextWindow,
            maxOutputTokens: info.maxOutputTokens,
            reasoningEfforts: efforts,
            supportsThinking: efforts.isNotEmpty ? true : info.supportsThinking,
            supportsReasoningEffort: efforts.isNotEmpty,
          ),
        );
      }

      for (final line in const LineSplitter().convert(clean)) {
        final value = line.trim();
        if (RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_./:\-]+$').hasMatch(value)) {
          finish();
          id = value;
          metadata.clear();
        } else if (id != null) {
          metadata.writeln(line);
        }
      }
      finish();
    }
    return models;
  }

  static String _commandError(
    ({int code, String output, String error}) result,
    AiChatSettings settings,
  ) {
    final detail = _sanitize(
      result.error.isNotEmpty ? result.error : result.output,
      settings.apiKey,
    );
    return 'CLI 检查失败（退出代码 ${result.code}）。$detail';
  }

  Future<({int code, String output, String error})> _captureCli(
    AiChatSettings settings,
    List<String> arguments,
    AiChatCancellation token,
  ) async {
    if (token.isCancelled) throw const AiChatException('CLI 检查已取消。');
    final directory = await _temporaryDirectory();
    _CliProcessLifetime? lifetime;
    StreamSubscription<String>? errors;
    Timer? deadline;
    void Function()? unregister;
    var abandoned = false, timedOut = false;
    final stop = AiChatCancellation();
    final output = StringBuffer(), error = StringBuffer();
    try {
      final launch = _processLauncher(
        AiChatCliInvocation(
          backend: settings.backend,
          executable: settings.executablePath.isEmpty
              ? settings.backend.name
              : settings.executablePath,
          networkRequired:
              arguments.first != '--version' && arguments.first != 'login',
          arguments: arguments,
          workingDirectory: directory.path,
          environment: const {
            'NO_COLOR': '1',
            'FORCE_COLOR': '0',
            'OPENCODE_DISABLE_AUTOUPDATE': 'true',
          },
        ),
      );
      unawaited(
        launch.then<void>((process) {
          if (abandoned || token.isCancelled) {
            unawaited(
              _CliProcessLifetime(process, _processTreeRunner).terminate(),
            );
          }
        }, onError: (Object _, StackTrace _) {}),
      );
      final process = await _cancellable(
        launch.timeout(connectionTimeout),
        token,
      );
      lifetime = _CliProcessLifetime(process, _processTreeRunner);
      unregister = token.onCancel(() {
        stop.cancel();
        unawaited(lifetime!.terminate());
      });
      deadline = Timer(connectionTimeout, () {
        timedOut = true;
        stop.cancel();
        unawaited(lifetime!.terminate());
      });
      errors = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((value) {
            if (error.length < 8192) {
              error.write(
                value.substring(0, value.length.clamp(0, 8192 - error.length)),
              );
            }
          }, onError: (Object _, StackTrace _) {});
      await _cancellable(process.stdin.close(), stop);
      await for (final value in _cancelAware(
        process.stdout,
        stop,
      ).transform(const Utf8Decoder(allowMalformed: true))) {
        output.write(value);
        if (output.length > 16 * 1024 * 1024) {
          throw const AiChatException('CLI 模型目录超过读取上限，请检查工具输出。');
        }
      }
      if (timedOut) throw const AiChatException('CLI 检查超时，请检查网络与工具配置后重试。');
      final code = await _cancellable(process.exitCode, stop);
      if (token.isCancelled) throw const AiChatException('CLI 检查已取消。');
      return (code: code, output: output.toString(), error: error.toString());
    } on _RequestCancelled {
      throw AiChatException(
        timedOut ? 'CLI 检查超时，请检查网络与工具配置后重试。' : 'CLI 检查已取消。',
      );
    } on TimeoutException {
      throw const AiChatException('CLI 启动超时，请检查工具配置。');
    } on AiCliPathException catch (exception) {
      throw AiChatException(exception.message);
    } on ProcessException catch (exception) {
      throw AiChatException(_launchError(settings, exception));
    } finally {
      abandoned = true;
      deadline?.cancel();
      unregister?.call();
      await lifetime?.terminate();
      await errors?.cancel();
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        /* Windows may still release handles. */
      }
    }
  }

  static String _sanitize(String message, String apiKey) {
    final credential = apiKey.trim();
    var safe = credential.isEmpty
        ? message
        : message.replaceAll(credential, '[已隐藏密钥]');
    safe = safe.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]{8,}\b'), '[已隐藏密钥]');
    safe = safe.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    return safe.length > 500 ? '${safe.substring(0, 500)}…' : safe;
  }

  static void _validateApiKey(String raw) {
    final credential = raw.trim();
    if (credential.isNotEmpty &&
        !RegExp(r'^[\x21-\x7e]+$').hasMatch(credential)) {
      throw const AiChatException('API 密钥包含空格或控制字符，请重新检查粘贴内容。');
    }
  }

  static Future<T> _cancellable<T>(
    Future<T> operation,
    AiChatCancellation cancellation,
  ) => Future.any<T>([
    operation,
    cancellation.whenCancelled.then<T>((_) => throw const _RequestCancelled()),
  ]);

  static Stream<T> _cancelAware<T>(
    Stream<T> source,
    AiChatCancellation cancellation,
  ) {
    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;
    void Function()? unregister;
    var ended = false;
    void finish() {
      if (ended) return;
      ended = true;
      unregister?.call();
      unawaited(subscription?.cancel());
      unawaited(controller.close());
    }

    controller = StreamController<T>(
      onListen: () {
        if (cancellation.isCancelled) {
          finish();
          return;
        }
        subscription = source.listen(
          (event) {
            if (!ended) controller.add(event);
          },
          onError: (Object error, StackTrace stack) {
            if (!ended && !cancellation.isCancelled) {
              controller.addError(error, stack);
            }
          },
          onDone: finish,
        );
        unregister = cancellation.onCancel(finish);
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        ended = true;
        unregister?.call();
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }
}

/// Owns exactly one launched process. Once its exit is observed we never
/// issue taskkill against its old PID, which may subsequently be reused.
class _CliProcessLifetime {
  _CliProcessLifetime(this.process, this._runTreeCommand) {
    unawaited(
      process.exitCode.then<void>(
        (_) => _exited = true,
        onError: (Object _, StackTrace _) => _exited = true,
      ),
    );
  }

  final Process process;
  final AiChatProcessTreeRunner _runTreeCommand;
  bool _exited = false;
  Future<void>? _termination;

  Future<void> terminate() {
    if (_exited) return Future<void>.value();
    return _termination ??= _terminate();
  }

  Future<void> _terminate() async {
    if (_exited) return;
    // npm .cmd launchers can leave their Node child alive on Windows.
    // Only the positive integer PID of this request's child is accepted.
    final processId = process.pid;
    if (Platform.isWindows && processId > 0 && !_exited) {
      try {
        await _runTreeCommand('taskkill.exe', [
          '/PID',
          processId.toString(),
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 2));
      } catch (_) {
        // Missing taskkill or an already exited process still permits the
        // platform Process handle to make a best-effort termination.
      }
    }
    if (!_exited) process.kill();
  }
}

class _RequestCancelled implements Exception {
  const _RequestCancelled();
}
