import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_acp_client.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';

class _WriteFailureSink implements IOSink {
  @override
  void writeln([Object? object = '']) =>
      throw StateError('Closed fixture stdin');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedSessionRoot implements Directory {
  _DelayedSessionRoot(this.directory, this.createSession);
  final Directory directory;
  final Future<Directory> Function() createSession;
  @override
  Directory get absolute => directory.absolute;
  @override
  Future<Directory> createTemp([String? prefix]) => createSession();
  @override
  Future<String> resolveSymbolicLinks() => directory.resolveSymbolicLinks();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      directory.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Agent implements Process {
  _Agent() {
    _input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          unawaited(receive(Map<String, dynamic>.from(jsonDecode(line))));
        });
    sink = IOSink(_input.sink);
  }
  final _input = StreamController<List<int>>();
  final _output = StreamController<List<int>>();
  final _errors = StreamController<List<int>>();
  final _exit = Completer<int>();
  final requests = <Map<String, dynamic>>[];
  late final IOSink sink;
  Completer<void>? gate;
  int protocol = 1, kills = 0;
  bool legacy = false, authRequired = false, toolCall = false;
  bool clientRequests = false, disconnect = false, malformed = false;
  bool wrongSession = false, silent = false;
  bool advertiseDeepseek = false, failClientResponseWrites = false;
  bool _failWrites = false;
  String? error;
  Object? errorData;
  String? errorDiagnostics;
  String model = 'first', effort = 'low';
  String stopReason = 'end_turn';
  int sessionCount = 0;
  bool duplicateSession = false;
  String get session => 'session-${duplicateSession ? 1 : sessionCount}';

  List<Map<String, dynamic>> get options => [
    {
      'id': 'model',
      'type': 'select',
      'category': 'model',
      'currentValue': model,
      'options': [
        {
          'group': 'fixture',
          'options': [
            {'value': 'first', 'name': 'First'},
            {'value': 'second', 'name': 'Second'},
            if (advertiseDeepseek)
              {'value': 'deepseek-flash', 'name': 'DeepSeek'},
          ],
        },
      ],
    },
    {
      'id': 'effort',
      'type': 'select',
      'category': 'thought_level',
      'currentValue': effort,
      'options': [
        {'value': 'low', 'name': 'Low'},
        {'value': 'high', 'name': 'High'},
      ],
    },
  ];
  void send(Map<String, dynamic> value) {
    if (!_output.isClosed) {
      _output.add(utf8.encode('${jsonEncode({'jsonrpc': '2.0', ...value})}\n'));
    }
  }

  void reply(Map request, Map<String, dynamic> result) =>
      send({'id': request['id'], 'result': result});
  void update(String kind, Map<String, dynamic> extra, {String? id}) => send({
    'method': 'session/update',
    'params': {
      'sessionId': id ?? session,
      'update': {'sessionUpdate': kind, ...extra},
    },
  });
  void text(String kind, String content, {String? id}) => update(kind, {
    'content': {'type': 'text', 'text': content},
  }, id: id);
  Future<void> receive(Map<String, dynamic> request) async {
    requests.add(request);
    final method = request['method'];
    final params = request['params'] as Map? ?? {};
    if (method == 'initialize') {
      if (malformed) {
        _output.add(utf8.encode('{invalid json\n'));
      } else {
        reply(request, {
          'protocolVersion': protocol,
          'agentInfo': {'name': 'Fixture Agent', 'version': '1.2.3'},
        });
      }
    } else if (method == 'session/new') {
      sessionCount++;
      model = 'first';
      effort = 'low';
      if (authRequired) {
        send({
          'id': request['id'],
          'error': {'code': -32000, 'message': 'Authentication required'},
        });
      } else {
        reply(request, {
          'sessionId': session,
          if (!legacy) 'configOptions': options,
          if (legacy)
            'models': {
              'currentModelId': model,
              'availableModels': [
                {'modelId': 'first', 'name': 'First'},
                {'modelId': 'second', 'name': 'Second'},
              ],
            },
        });
      }
    } else if (method == 'session/set_config_option') {
      if (params['configId'] == 'model') model = params['value'];
      if (params['configId'] == 'effort') effort = params['value'];
      reply(request, {'configOptions': options});
    } else if (method == 'session/set_model') {
      model = params['modelId'];
      reply(request, {});
    } else if (method == 'session/prompt') {
      _failWrites = failClientResponseWrites;
      if (disconnect) {
        kill();
        return;
      }
      if (error != null) {
        if (errorDiagnostics != null) {
          _errors.add(utf8.encode(errorDiagnostics!));
          await Future<void>.delayed(Duration.zero);
        }
        send({
          'id': request['id'],
          'error': {
            'code': -32603,
            'message': error,
            if (errorData != null) 'data': errorData,
          },
        });
        return;
      }
      if (clientRequests) {
        send({
          'id': 'permission',
          'method': 'session/request_permission',
          'params': {
            'sessionId': session,
            'options': [
              {'kind': 'allow_once', 'optionId': 'yes'},
            ],
          },
        });
        send({
          'id': 'file',
          'method': 'fs/read_text_file',
          'params': {'sessionId': session, 'path': '/private/file'},
        });
        send({
          'id': 'terminal',
          'method': 'terminal/create',
          'params': {'sessionId': session, 'command': 'forbidden'},
        });
      }
      if (toolCall) {
        update('tool_call', {
          'toolCallId': 'tool-1',
          'title': 'Read file',
          'kind': 'read',
        });
        return;
      }
      if (wrongSession) {
        text('agent_message_chunk', '别的会话', id: 'different-session');
      }
      if (!silent) {
        text('agent_thought_chunk', '核对字幕。');
        text('agent_message_chunk', '你');
        update('usage_update', {'used': 120, 'size': 64000});
      }
      await gate?.future;
      if (_output.isClosed) return;
      if (!silent) text('agent_message_chunk', '好');
      reply(request, {'stopReason': stopReason});
    } else if (method == 'session/cancel') {
      if (gate?.isCompleted == false) gate!.complete();
    }
  }

  @override
  IOSink get stdin => _failWrites ? _WriteFailureSink() : sink;
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => _errors.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 777;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (!_exit.isCompleted) _exit.complete(0);
    if (!_output.isClosed) unawaited(_output.close());
    if (!_errors.isClosed) unawaited(_errors.close());
    unawaited(sink.close());
    return true;
  }
}

void main() {
  const settings = AiChatSettings(
    backend: AiBackend.geminiCli,
    model: 'second',
    executablePath: 'gemini',
    reasoningEffort: 'high',
  );
  const messages = [
    {'role': 'user', 'content': '解释字幕，保留中文与换行\n第二行'},
  ];
  late AiAcpClient client;
  final servers = <_Agent>[];
  final launches = <AiChatCliInvocation>[];
  final directories = <Directory>[];
  _Agent Function() factory = _Agent.new;

  AiAcpClient makeClient({
    Duration keepAlive = AiAcpClient.defaultKeepAliveTimeout,
    int maxIdle = 2,
    int maxSessions = 32,
    String Function()? identity,
    Future<Directory> Function()? directoryFactory,
  }) {
    return AiAcpClient(
      launch: (invocation) async {
        launches.add(invocation);
        final server = factory();
        servers.add(server);
        return server;
      },
      temporaryDirectory:
          directoryFactory ??
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'video_acp_test_',
            );
            directories.add(directory);
            return directory;
          },
      terminate: (process) async {
        process.kill();
      },
      connectionTimeout: const Duration(seconds: 1),
      idleTimeout: const Duration(seconds: 1),
      processTimeout: const Duration(seconds: 3),
      keepAliveTimeout: keepAlive,
      maxIdleConnections: maxIdle,
      maxSessionsPerProcess: maxSessions,
      connectionIdentity: identity,
    );
  }

  setUp(() {
    servers.clear();
    launches.clear();
    directories.clear();
    factory = _Agent.new;
    client = makeClient();
  });
  tearDown(() async {
    for (final server in servers) {
      if (server.gate?.isCompleted == false) server.gate!.complete();
    }
    await client.dispose();
    for (final directory in directories) {
      expect(await directory.exists(), isFalse);
    }
  });

  test(
    'streams content before completion, separates thoughts, selects advertised configuration',
    () async {
      final gate = Completer<void>();
      factory = () => _Agent()..gate = gate;
      final first = Completer<void>();
      final deltas = <AiChatDelta>[];
      final done = client
          .stream(settings, messages, AiChatCancellation())
          .forEach((delta) {
            deltas.add(delta);
            if (delta.content == '你' && !first.isCompleted) first.complete();
          });
      await first.future.timeout(const Duration(seconds: 2));
      expect(deltas.map((e) => e.content).join(), '你');
      expect(deltas.map((e) => e.reasoning).join(), '核对字幕。');
      gate.complete();
      await done;
      expect(deltas.map((e) => e.content).join(), '你好');
      expect(deltas.last.finishReason, 'stop');
      final server = servers.single;
      expect(server.model, 'second');
      expect(server.effort, 'high');
      final init = server.requests.first['params'];
      expect(init['clientCapabilities']['terminal'], isFalse);
      expect(init['clientCapabilities']['fs']['readTextFile'], isFalse);
      final session = server.requests.firstWhere(
        (e) => e['method'] == 'session/new',
      )['params'];
      expect(session['mcpServers'], isEmpty);
      expect(
        session['cwd'],
        startsWith(
          '${directories.single.absolute.path}${Platform.pathSeparator}',
        ),
      );
      expect(session['cwd'], isNot(directories.single.absolute.path));
      final prompt = server.requests.firstWhere(
        (e) => e['method'] == 'session/prompt',
      )['params']['prompt'][0]['text'];
      expect(prompt, contains('解释字幕'));
      expect(prompt, contains('第二行'));
      expect(launches.single.arguments, isNot(contains('解释字幕')));
      final usage = deltas.firstWhere((e) => e.usage != null).usage!;
      expect(usage['model_context_window'], 64000);
      expect(usage.containsKey('prompt_tokens'), isFalse);
    },
  );

  test(
    'catalog parses grouped options and does not invent capabilities for other models',
    () async {
      final models = await client.fetchModels(settings);
      expect(models.map((e) => e.id), ['first', 'second']);
      expect(models.first.reasoningEfforts, isEmpty);
      expect(models.last.reasoningEfforts, ['low', 'high']);
      expect(models.last.defaultReasoningEffort, 'low');
      expect(servers.single.effort, 'low');
      expect(
        servers.single.requests.any((e) => e['method'] == 'session/prompt'),
        isFalse,
      );
    },
  );
  test(
    'legacy ACP models are supported without assuming configOptions',
    () async {
      factory = () => _Agent()..legacy = true;
      final models = await client.fetchModels(settings);
      expect(models.map((e) => e.id), ['first', 'second']);
      await client
          .stream(settings, messages, AiChatCancellation())
          .drain<void>();
      expect(
        servers.last.requests.any((e) => e['method'] == 'session/set_model'),
        isTrue,
      );
    },
  );
  test(
    'inspection, catalog and bounded prompts reuse one initialization with fresh sessions',
    () async {
      await client.inspectCli(settings);
      await client.fetchModels(settings);
      for (var run = 0; run < 2; run++) {
        final events = await client.stream(settings, [
          {'role': 'user', 'content': 'private question $run'},
        ], AiChatCancellation()).toList();
        expect(events.first.stage, contains('复用'));
      }
      final server = servers.single;
      expect(server.kills, 0);
      expect(
        server.requests.where((e) => e['method'] == 'initialize'),
        hasLength(1),
      );
      final sessions = server.requests
          .where((e) => e['method'] == 'session/new')
          .toList();
      expect(sessions, hasLength(4));
      expect(sessions.map((e) => e['params']['cwd']).toSet(), hasLength(4));
      for (final session in sessions) {
        expect(await Directory(session['params']['cwd']).exists(), isFalse);
      }
      final prompts = server.requests
          .where((e) => e['method'] == 'session/prompt')
          .toList();
      expect(
        prompts.map((e) => e['params']['sessionId']).toSet(),
        hasLength(2),
      );
      for (var run = 0; run < 2; run++) {
        final text = prompts[run]['params']['prompt'][0]['text'] as String;
        expect(text, contains('private question $run'));
        expect(text, isNot(contains('private question ${1 - run}')));
      }
      expect(server.effort, 'high');
      expect(await directories.single.exists(), isTrue);
      await client.dispose();
      expect(server.kills, greaterThan(0));
    },
  );
  test(
    'simultaneous requests lease separate processes and Stop is isolated',
    () async {
      factory = () => _Agent()..gate = Completer<void>();
      final firstChunk = Completer<void>(), secondChunk = Completer<void>();
      final stopFirst = AiChatCancellation();
      final first = client.stream(settings, messages, stopFirst).forEach((
        delta,
      ) {
        if (delta.content == '你' && !firstChunk.isCompleted) {
          firstChunk.complete();
        }
      });
      await firstChunk.future;
      final secondEvents = <AiChatDelta>[];
      final second = client
          .stream(settings, messages, AiChatCancellation())
          .forEach((delta) {
            secondEvents.add(delta);
            if (delta.content == '你' && !secondChunk.isCompleted) {
              secondChunk.complete();
            }
          });
      await secondChunk.future;
      stopFirst.cancel();
      await first;
      expect(servers, hasLength(2));
      expect(servers.first.kills, greaterThan(0));
      expect(servers.last.kills, 0);
      servers.last.gate!.complete();
      await second;
      expect(secondEvents.map((e) => e.content).join(), '你好');
      await client
          .stream(settings, messages, AiChatCancellation())
          .drain<void>();
      expect(servers, hasLength(2));
      expect(
        servers.last.requests.where((e) => e['method'] == 'initialize'),
        hasLength(1),
      );
    },
  );

  test(
    'old cancellation and old session updates cannot affect a new lease',
    () async {
      final oldCancellation = AiChatCancellation();
      await client.stream(settings, messages, oldCancellation).drain<void>();
      final server = servers.single;
      final oldSession = server.session;
      oldCancellation.cancel();
      server.gate = Completer<void>();
      final events = <AiChatDelta>[];
      await client
          .stream(
            settings.copyWith(
              model: 'first',
              reasoningEffort: 'low',
              thinkingEnabled: false,
            ),
            messages,
            AiChatCancellation(),
          )
          .forEach((delta) {
            events.add(delta);
            if (delta.content == '你') {
              oldCancellation.cancel();
              server.text(
                'agent_message_chunk',
                'private old answer',
                id: oldSession,
              );
              server.gate!.complete();
            }
          });
      expect(server.kills, 0);
      expect(server.model, 'first');
      expect(server.effort, 'low');
      expect(events.map((e) => e.content).join(), '你好');
      expect(events.map((e) => e.reasoning).join(), isEmpty);
    },
  );

  test(
    'a warm process lost before submission reconnects without duplicating a prompt',
    () async {
      await client.inspectCli(settings);
      var lost = false;
      await client.stream(settings, messages, AiChatCancellation()).forEach((
        delta,
      ) {
        if (!lost && delta.stage?.contains('复用') == true) {
          lost = true;
          servers.single.kill();
        }
      });
      expect(servers, hasLength(2));
      expect(
        servers.first.requests.any((r) => r['method'] == 'session/prompt'),
        isFalse,
      );
      expect(
        servers.last.requests.where((r) => r['method'] == 'session/prompt'),
        hasLength(1),
      );
      await client.inspectCli(settings);
      expect(servers, hasLength(2));
    },
  );

  test(
    'path, backend, custom arguments and external launch state are keyed separately',
    () async {
      await client.dispose();
      var network = 'first-proxy';
      client = makeClient(identity: () => network);
      await client.inspectCli(settings);
      await client.inspectCli(
        settings.copyWith(executablePath: 'other-gemini'),
      );
      const custom = AiChatSettings(
        backend: AiBackend.acp,
        executablePath: 'custom',
        cliArguments: ['acp'],
      );
      await client.inspectCli(custom);
      await client.inspectCli(custom.copyWith(cliArguments: ['--acp']));
      network = 'second-proxy';
      await client.inspectCli(custom.copyWith(cliArguments: ['--acp']));
      expect(servers, hasLength(5));
      expect(servers.where((s) => s.kills == 0), hasLength(2));
    },
  );

  test(
    'idle expiry and an exited process both start a fresh connection',
    () async {
      await client.dispose();
      client = makeClient(keepAlive: const Duration(milliseconds: 200));
      await client.inspectCli(settings);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (servers.first.kills == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(servers.first.kills, greaterThan(0));
      await client.inspectCli(settings);
      expect(servers, hasLength(2));
      servers.last.kill();
      await Future<void>.delayed(Duration.zero);
      await client.inspectCli(settings);
      expect(servers, hasLength(3));
    },
  );

  test(
    'processes recycle at the session limit without changing the default idle policy',
    () async {
      await client.dispose();
      client = makeClient(maxSessions: 2);
      expect(client.keepAliveTimeout, const Duration(minutes: 15));
      await client.inspectCli(settings);
      await client.fetchModels(settings);
      expect(servers, hasLength(1));
      expect(servers.single.kills, greaterThan(0));
      await client
          .stream(settings, messages, AiChatCancellation())
          .drain<void>();
      expect(servers, hasLength(2));
      expect(servers.last.effort, 'high');
    },
  );

  test(
    'a reused session ID falls back before inference and disables reuse for that signature',
    () async {
      factory = () => _Agent()..duplicateSession = true;
      await client.inspectCli(settings);
      await client.fetchModels(settings);
      expect(servers, hasLength(2));
      expect(
        servers.first.requests.where((e) => e['method'] == 'session/new'),
        hasLength(2),
      );
      expect(servers.every((s) => s.kills > 0), isTrue);
      await client
          .stream(settings, messages, AiChatCancellation())
          .drain<void>();
      expect(servers, hasLength(3));
      expect(
        servers
            .expand((s) => s.requests)
            .where((e) => e['method'] == 'session/prompt'),
        hasLength(1),
      );
      expect(servers.last.kills, greaterThan(0));
    },
  );

  test(
    'dispose closes busy and idle leases and refuses further work',
    () async {
      await client.inspectCli(settings);
      servers.single.gate = Completer<void>();
      final started = Completer<void>();
      final done = client
          .stream(settings, messages, AiChatCancellation())
          .forEach((delta) {
            if (delta.content == '你' && !started.isCompleted) {
              started.complete();
            }
          });
      await started.future;
      await client.inspectCli(settings);
      await client.dispose();
      await done;
      expect(servers, hasLength(2));
      expect(servers.every((s) => s.kills > 0), isTrue);
      await expectLater(
        client.inspectCli(settings),
        throwsA(isA<AiChatException>()),
      );
    },
  );

  test(
    'unknown model fails before inference rather than silently using a different model',
    () async {
      await expectLater(
        client
            .stream(
              settings.copyWith(model: 'unknown'),
              messages,
              AiChatCancellation(),
            )
            .drain<void>(),
        throwsA(isA<AiChatException>()),
      );
      expect(
        servers.single.requests.any((e) => e['method'] == 'session/prompt'),
        isFalse,
      );
    },
  );
  test(
    'wrong-session notifications are ignored and thoughts respect the display setting',
    () async {
      factory = () => _Agent()..wrongSession = true;
      final deltas = await client
          .stream(
            settings.copyWith(thinkingEnabled: false),
            messages,
            AiChatCancellation(),
          )
          .toList();
      expect(deltas.map((e) => e.content).join(), '你好');
      expect(deltas.map((e) => e.reasoning).join(), isEmpty);
    },
  );
  test(
    'permission, filesystem and terminal requests cannot grant tools',
    () async {
      factory = () => _Agent()..clientRequests = true;
      await client
          .stream(settings, messages, AiChatCancellation())
          .drain<void>();
      final replies = servers.single.requests
          .where((e) => e['method'] == null)
          .toList();
      expect(
        replies.firstWhere(
          (e) => e['id'] == 'permission',
        )['result']['outcome']['outcome'],
        'cancelled',
      );
      expect(
        replies.firstWhere((e) => e['id'] == 'file')['error']['code'],
        -32601,
      );
      expect(
        replies.firstWhere((e) => e['id'] == 'terminal')['error']['code'],
        -32601,
      );
    },
  );
  test(
    'a tool execution notification stops inference and reclaims the process',
    () async {
      factory = () => _Agent()..toolCall = true;
      await expectLater(
        client.stream(settings, messages, AiChatCancellation()).drain<void>(),
        throwsA(
          predicate(
            (e) => e is AiChatException && e.message.contains('尝试使用工具'),
          ),
        ),
      );
      expect(servers.single.kills, greaterThan(0));
    },
  );
  test('Stop sends session/cancel and finishes without a failure', () async {
    factory = () => _Agent()..gate = Completer<void>();
    final token = AiChatCancellation();
    await client.stream(settings, messages, token).forEach((delta) {
      if (delta.content == '你') token.cancel();
    });
    expect(
      servers.single.requests.any((e) => e['method'] == 'session/cancel'),
      isTrue,
    );
    expect(servers.single.kills, greaterThan(0));
  });
  test(
    'authentication errors explain the agent login and never claim authenticated access',
    () async {
      factory = () => _Agent()..authRequired = true;
      await expectLater(
        client.fetchModels(settings),
        throwsA(
          predicate((e) => e is AiChatException && e.message.contains('登录')),
        ),
      );
    },
  );
  test(
    'status uses protocol agent information without claiming inference authorization',
    () async {
      final status = await client.inspectCli(settings);
      expect(status.version, contains('Fixture Agent 1.2.3'));
      expect(status.loggedIn, isNull);
    },
  );
  test('protocol mismatch and malformed JSON fail promptly', () async {
    factory = () => _Agent()..protocol = 2;
    await expectLater(
      client.fetchModels(settings),
      throwsA(isA<AiChatException>()),
    );
    factory = () => _Agent()..malformed = true;
    await expectLater(
      client.fetchModels(settings),
      throwsA(isA<AiChatException>()),
    );
  });
  test(
    'RPC error output is redacted and context overflow survives the protocol boundary',
    () async {
      factory = () => _Agent()
        ..error =
            'maximum context length exceeded sk-secret123 Bearer private-token';
      await expectLater(
        client.stream(settings, messages, AiChatCancellation()).drain<void>(),
        throwsA(
          predicate(
            (e) =>
                e is AiChatException &&
                e.contextOverflow &&
                !e.message.contains('secret123') &&
                !e.message.contains('private-token'),
          ),
        ),
      );
    },
  );
  test(
    'EOF and empty replies are failures, token limit retains the length finish reason',
    () async {
      factory = () => _Agent()..disconnect = true;
      await expectLater(
        client.stream(settings, messages, AiChatCancellation()).drain<void>(),
        throwsA(isA<AiChatException>()),
      );
      factory = () => _Agent()..silent = true;
      await expectLater(
        client.stream(settings, messages, AiChatCancellation()).drain<void>(),
        throwsA(isA<AiChatException>()),
      );
      factory = () => _Agent()..stopReason = 'max_tokens';
      final events = await client
          .stream(settings, messages, AiChatCancellation())
          .toList();
      expect(events.last.finishReason, 'length');
    },
  );
  test('a pre-cancelled request launches no process', () async {
    final token = AiChatCancellation()..cancel();
    expect(await client.stream(settings, messages, token).toList(), isEmpty);
    expect(launches, isEmpty);
  });
  test(
    'Qwen Internal error exposes bounded SDK details without dumping configuration',
    () async {
      factory = () => _Agent()
        ..error = 'Internal error'
        ..errorData = {
          'details': '[API Error: 404 Model not exist.]',
          'request': {
            'messages': 'private transcript',
            'api_key': 'unrelated-provider-key',
          },
          'config': {'secret': 'private-configuration'},
        };
      await expectLater(
        client.stream(settings, messages, AiChatCancellation()).drain<void>(),
        throwsA(
          predicate(
            (e) =>
                e is AiChatException &&
                e.message.contains('404 Model not exist') &&
                !e.message.contains('private transcript') &&
                !e.message.contains('unrelated-provider-key') &&
                !e.message.contains('private-configuration'),
          ),
        ),
      );
    },
  );
  test(
    'nested upstream diagnostics redact unknown credential assignments',
    () async {
      factory = () => _Agent()
        ..error = 'Internal error'
        ..errorData = {
          'details': {
            'error': {
              'message':
                  '404 Model not exist. api_key="unknown-provider-key" Authorization: Bearer raw-auth-token X-API-Key=another-key OPENAI_API_KEY=environment-key',
            },
          },
        };
      await expectLater(
        client.stream(settings, messages, AiChatCancellation()).drain<void>(),
        throwsA(
          predicate(
            (e) =>
                e is AiChatException &&
                e.message.contains('404 Model not exist') &&
                !e.message.contains('unknown-provider-key') &&
                !e.message.contains('raw-auth-token') &&
                !e.message.contains('another-key') &&
                !e.message.contains('environment-key'),
          ),
        ),
      );
    },
  );
  test(
    'generic RPC failures use only bounded relevant stderr diagnostics',
    () async {
      factory = () => _Agent()
        ..error = 'Internal error'
        ..errorDiagnostics =
            'Agent banner\nAPI Error: 404 Model not exist. api_key=stderr-secret\n';
      await expectLater(
        client.stream(settings, messages, AiChatCancellation()).drain<void>(),
        throwsA(
          predicate(
            (e) =>
                e is AiChatException &&
                e.message.contains('404 Model not exist') &&
                !e.message.contains('stderr-secret') &&
                !e.message.contains('Agent banner'),
          ),
        ),
      );
    },
  );
  test(
    'advertised model IDs that match migrated API defaults are selected',
    () async {
      factory = () => _Agent()..advertiseDeepseek = true;
      await client
          .stream(
            settings.copyWith(model: 'deepseek-flash'),
            messages,
            AiChatCancellation(),
          )
          .drain<void>();
      expect(servers.single.model, 'deepseek-flash');
    },
  );
  test(
    'a server-request response racing closed stdin fails inside the operation',
    () async {
      factory = () => _Agent()
        ..clientRequests = true
        ..failClientResponseWrites = true;
      await expectLater(
        client.stream(settings, messages, AiChatCancellation()).drain<void>(),
        throwsA(
          predicate(
            (e) => e is AiChatException && e.message.contains('协议响应处理失败'),
          ),
        ),
      );
      expect(servers.single.kills, greaterThan(0));
    },
  );
  test(
    'dispose waits for a pending session directory before deleting its root',
    () async {
      await client.dispose();
      final root = await Directory.systemTemp.createTemp(
        'video_acp_pending_session_',
      );
      directories.add(root);
      final requested = Completer<void>();
      final child = Completer<Directory>();
      client = makeClient(
        directoryFactory: () async => _DelayedSessionRoot(root, () {
          requested.complete();
          return child.future;
        }),
      );
      final done = client
          .stream(settings, messages, AiChatCancellation())
          .drain<void>();
      await requested.future;
      final disposed = client.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(await root.exists(), isTrue);
      child.complete(await root.createTemp('session_'));
      await disposed;
      await done;
      expect(await root.exists(), isFalse);
    },
  );

  test(
    'dispose cleans a temporary directory returned after disposal completes',
    () async {
      await client.dispose();
      final requested = Completer<void>();
      final directoryResult = Completer<Directory>();
      client = AiAcpClient(
        launch: (_) async => throw StateError('Must not launch after disposal'),
        temporaryDirectory: () {
          requested.complete();
          return directoryResult.future;
        },
        terminate: (process) async {
          process.kill();
        },
        connectionTimeout: const Duration(seconds: 1),
        idleTimeout: const Duration(seconds: 1),
        processTimeout: const Duration(seconds: 2),
      );
      final done = client
          .stream(settings, messages, AiChatCancellation())
          .drain<void>();
      await requested.future;
      await client.dispose();
      final directory = await Directory.systemTemp.createTemp(
        'video_acp_late_dir_',
      );
      directories.add(directory);
      directoryResult.complete(directory);
      await done;
      expect(await directory.exists(), isFalse);
    },
  );
  test(
    'a retired selected model does not prevent refreshing the catalog',
    () async {
      final models = await client.fetchModels(
        settings.copyWith(model: 'retired'),
      );
      expect(models.map((e) => e.id), ['first', 'second']);
      expect(servers.single.model, 'first');
      expect(servers.single.effort, 'low');
    },
  );
  test(
    'cancellation racing process startup still terminates the late process',
    () async {
      await client.dispose();
      final launched = Completer<void>();
      final process = Completer<Process>();
      client = AiAcpClient(
        launch: (_) {
          launched.complete();
          return process.future;
        },
        temporaryDirectory: () async {
          final directory = await Directory.systemTemp.createTemp(
            'video_acp_race_',
          );
          directories.add(directory);
          return directory;
        },
        terminate: (process) async {
          process.kill();
        },
        connectionTimeout: const Duration(seconds: 1),
        idleTimeout: const Duration(seconds: 1),
        processTimeout: const Duration(seconds: 2),
      );
      final cancellation = AiChatCancellation();
      final done = client
          .stream(settings, messages, cancellation)
          .drain<void>();
      await launched.future;
      final agent = _Agent();
      servers.add(agent);
      process.complete(agent);
      cancellation.cancel();
      await done;
      await Future<void>.delayed(Duration.zero);
      expect(agent.kills, greaterThan(0));
    },
  );
}
