import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_settings_dialog.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/features/ai_chat/ai_codex_app_server.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';

class _Server implements Process {
  _Server() {
    _input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _receive(jsonDecode(line) as Map<String, dynamic>));
    sink = IOSink(_input.sink);
  }
  final _input = StreamController<List<int>>(),
      _output = StreamController<List<int>>(),
      _error = StreamController<List<int>>();
  final _exit = Completer<int>();
  late final IOSink sink;
  final requests = <Map<String, dynamic>>[];
  Completer<void>? gate;
  bool fail = false, correction = false;
  int kills = 0, threads = 0;
  int networkFailures = 0;
  final _interrupted = <String>{};
  void send(Map<String, dynamic> value) {
    if (!_output.isClosed) _output.add(utf8.encode('${jsonEncode(value)}\n'));
  }

  void notify(String method, Map<String, dynamic> params) =>
      send({'method': method, 'params': params});
  void reply(Map request, Map<String, dynamic> result) =>
      send({'id': request['id'], 'result': result});
  Future<void> _receive(Map<String, dynamic> request) async {
    requests.add(request);
    final method = request['method'];
    final params = request['params'] as Map? ?? {};
    if (method == 'initialize') reply(request, {'userAgent': 'fixture'});
    if (method == 'thread/start') {
      reply(request, {
        'thread': {'id': 'thread-${++threads}'},
      });
    }
    if (method == 'thread/unsubscribe') reply(request, {});
    if (method == 'turn/interrupt') {
      _interrupted.add(params['threadId']);
      reply(request, {});
      notify('turn/completed', {
        'threadId': params['threadId'],
        'turn': {'id': 'turn-1', 'status': 'interrupted'},
      });
    }
    if (method != 'turn/start') return;
    final thread = params['threadId'] as String;
    final scope = {'threadId': thread, 'turnId': 'turn-1'};
    reply(request, {
      'turn': {'id': 'turn-1', 'status': 'inProgress'},
    });
    if (fail || networkFailures > 0) {
      final networkFailure = networkFailures > 0;
      if (networkFailure) {
        networkFailures--;
        notify('item/agentMessage/delta', {
          ...scope,
          'itemId': 'a',
          'delta': '残稿',
        });
      }
      notify('error', {
        ...scope,
        'error': {
          'message': networkFailure
              ? 'stream disconnected before completion: connection reset'
              : '模型请求失败',
        },
      });
      notify('turn/completed', {
        'threadId': thread,
        'turn': {'id': 'turn-1', 'status': 'failed'},
      });
      return;
    }
    notify('item/reasoning/summaryTextDelta', {
      ...scope,
      'itemId': 'r',
      'summaryIndex': 0,
      'delta': '核对',
    });
    notify('item/reasoning/summaryTextDelta', {
      ...scope,
      'itemId': 'r',
      'summaryIndex': 0,
      'delta': '字幕依据。',
    });
    notify('item/agentMessage/delta', {...scope, 'itemId': 'a', 'delta': '你'});
    await gate?.future;
    if (_interrupted.contains(thread) || _output.isClosed) return;
    notify('item/agentMessage/delta', {...scope, 'itemId': 'a', 'delta': '好'});
    notify('item/completed', {
      ...scope,
      'item': {
        'id': 'a',
        'type': 'agentMessage',
        'text': correction ? '修正后的答案' : '你好',
      },
    });
    notify('item/completed', {
      ...scope,
      'item': {
        'id': 'r',
        'type': 'reasoning',
        'summary': ['核对字幕依据。'],
      },
    });
    notify('thread/tokenUsage/updated', {
      ...scope,
      'tokenUsage': {
        'total': {
          'inputTokens': 100,
          'cachedInputTokens': 80,
          'cacheWriteInputTokens': 0,
          'outputTokens': 20,
          'reasoningOutputTokens': 10,
          'totalTokens': 120,
        },
        'modelContextWindow': 128000,
      },
    });
    notify('turn/completed', {
      'threadId': thread,
      'turn': {'id': 'turn-1', 'status': 'completed'},
    });
  }

  @override
  IOSink get stdin => sink;
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => _error.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 888;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (!_exit.isCompleted) _exit.complete(0);
    if (!_output.isClosed) unawaited(_output.close());
    if (!_error.isClosed) unawaited(_error.close());
    unawaited(sink.close());
    return true;
  }
}

void main() {
  const settings = AiChatSettings(
    backend: AiBackend.codex,
    model: 'account-model',
    executablePath: 'codex',
  );
  const messages = [
    {'role': 'user', 'content': '解释视频当前内容'},
  ];
  late _Server server;
  late AiChatTransport transport;
  final launches = <AiChatCliInvocation>[];
  setUp(() {
    launches.clear();
    server = _Server();
    transport = AiChatTransport(
      processLauncher: (request) async {
        launches.add(request);
        return server;
      },
      processTreeRunner: (_, _) async => ProcessResult(0, 0, '', ''),
    );
  });
  tearDown(() async {
    if (server.gate?.isCompleted == false) server.gate!.complete();
    await transport.dispose();
  });

  test(
    'connection keep-alive is bounded and disposal closes the idle process',
    () async {
      expect(
        AiCodexAppServer.defaultKeepAliveTimeout,
        const Duration(minutes: 15),
      );
      final servers = <_Server>[];
      final client = AiCodexAppServer(
        launch: (_) async {
          final next = _Server();
          servers.add(next);
          return next;
        },
        temporaryDirectory: () =>
            Directory.systemTemp.createTemp('codex_keepalive_'),
        terminate: (process) async {
          process.kill();
        },
        connectionTimeout: const Duration(seconds: 5),
        idleTimeout: const Duration(seconds: 5),
        processTimeout: const Duration(seconds: 10),
        keepAliveTimeout: const Duration(milliseconds: 500),
      );
      addTearDown(client.dispose);
      Future<List<AiChatDelta>> send() => client
          .stream(
            settings: settings,
            messages: messages,
            cancellation: AiChatCancellation(),
          )
          .toList();
      await send();
      final reused = await send();
      expect(servers, hasLength(1));
      expect(reused.first.stage, contains('复用 Codex'));
      expect(
        servers.single.requests.where((r) => r['method'] == 'initialize'),
        hasLength(1),
      );
      expect(servers.single.threads, 2);
      for (var i = 0; i < 60 && servers.single.kills == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(servers.single.kills, 1);
      final restarted = await send();
      expect(servers, hasLength(2));
      expect(restarted.first.stage, contains('启动 Codex'));
      await client.dispose();
      expect(servers.last.kills, 1);
    },
  );
  test(
    'connection reuse preserves the selected reasoning settings',
    () async {
      final configured = settings.copyWith(
        reasoningEffort: 'high',
        thinkingEnabled: true,
        cliProfiles: const {
          'codex': AiCliProfile(
            executablePath: 'codex',
            models: [
              AiModelInfo(id: 'account-model', reasoningEfforts: ['high']),
            ],
          ),
        },
      );
      for (var run = 0; run < 2; run++) {
        await transport
            .stream(
              settings: configured,
              messages: messages,
              cancellation: AiChatCancellation(),
            )
            .toList();
      }
      expect(launches, hasLength(1));
      for (final request in server.requests.where(
        (r) => r['method'] == 'turn/start',
      )) {
        expect(request['params']['effort'], 'high');
        expect(request['params']['summary'], 'concise');
      }
    },
  );
  testWidgets(
    'closing settings preserves the borrowed Codex connection for the next chat message',
    (tester) async {
      final controller = AiChatController(
        video: VideoItem(
          id: 'connection',
          path: 'video.mp4',
          title: '连接测试',
          durationMs: 0,
          lastUpdated: 0,
        ),
        initialSettings: settings,
        transport: transport,
      );
      addTearDown(controller.dispose);
      expect(controller.settingsTransport, same(transport));
      await tester.runAsync(
        () => controller.settingsTransport!.testConnection(settings),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AiSettingsDialog(
            settings: settings,
            transport: controller.settingsTransport,
            onSave: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(server.kills, 0);
      final result = await tester.runAsync(
        () => controller.settingsTransport!
            .stream(
              settings: settings,
              messages: messages,
              cancellation: AiChatCancellation(),
            )
            .toList(),
      );
      expect(result!.map((delta) => delta.content).join(), '你好');
      expect(launches, hasLength(1));
      expect(
        server.requests.where((r) => r['method'] == 'initialize'),
        hasLength(1),
      );
    },
  );
  test(
    'real deltas reach the caller before completion, with separate reasoning and usage',
    () async {
      server.gate = Completer<void>();
      final deltas = <AiChatDelta>[];
      final firstText = Completer<void>();
      final done = transport
          .stream(
            settings: settings,
            messages: messages,
            cancellation: AiChatCancellation(),
          )
          .forEach((delta) {
            deltas.add(delta);
            if (delta.content == '你' && !firstText.isCompleted) {
              firstText.complete();
            }
          });
      await firstText.future.timeout(const Duration(seconds: 3));
      expect(deltas.map((delta) => delta.content).join(), '你');
      expect(deltas.map((delta) => delta.reasoning).join(), '核对字幕依据。');
      server.gate!.complete();
      await done;
      expect(deltas.map((delta) => delta.content).join(), '你好');
      expect(deltas.map((delta) => delta.reasoning).join(), '核对字幕依据。');
      expect(deltas.first.stage, contains('启动 Codex'));
      expect(
        deltas
            .where((delta) => delta.usage != null)
            .last
            .usage?['prompt_cache_hit_tokens'],
        80,
      );
      expect(launches.single.arguments.take(3), [
        'app-server',
        '--listen',
        'stdio://',
      ]);
      expect(
        launches.single.arguments,
        containsAll(['features.apps=false', 'features.shell_tool=false']),
      );
      expect(launches.single.arguments.toString(), isNot(contains('解释视频')));
      expect(
        server.requests.firstWhere(
          (request) => request['method'] == 'thread/start',
        )['params']['ephemeral'],
        isTrue,
      );
    },
  );
  test(
    'Codex retries failed network turns with fresh threads and replaces the partial answer',
    () async {
      server.networkFailures = 1;
      final content = StringBuffer();
      await transport
          .stream(
            settings: settings,
            messages: messages,
            cancellation: AiChatCancellation(),
          )
          .forEach((delta) {
            if (delta.contentSnapshot != null) content.clear();
            content.write(delta.contentSnapshot ?? delta.content);
          });
      expect(content.toString(), '你好');
      expect(server.threads, 2);
      expect(launches, hasLength(1));
      final starts = server.requests
          .where((r) => r['method'] == 'turn/start')
          .toList();
      expect(starts[1]['params']['input'], starts[0]['params']['input']);
    },
  );

  test(
    'subsequent requests reuse the process with isolated threads and model changes',
    () async {
      await transport
          .stream(
            settings: settings,
            messages: messages,
            cancellation: AiChatCancellation(),
          )
          .toList();
      await transport
          .stream(
            settings: settings.copyWith(model: 'other-model'),
            messages: messages,
            cancellation: AiChatCancellation(),
          )
          .toList();
      expect(launches.length, 1);
      expect(server.threads, 2);
      final starts = server.requests
          .where((request) => request['method'] == 'thread/start')
          .toList();
      expect(starts.last['params']['model'], 'other-model');
      expect(
        server.requests
            .where((request) => request['method'] == 'initialize')
            .length,
        1,
      );
    },
  );
  test(
    'stop interrupts immediately and the healthy connection can be reused',
    () async {
      server.gate = Completer<void>();
      final cancellation = AiChatCancellation();
      final first = Completer<void>();
      final done = transport
          .stream(
            settings: settings,
            messages: messages,
            cancellation: cancellation,
          )
          .forEach((delta) {
            if (delta.content.isNotEmpty && !first.isCompleted) {
              first.complete();
            }
          });
      await first.future.timeout(const Duration(seconds: 3));
      cancellation.cancel();
      await done.timeout(const Duration(seconds: 3));
      expect(
        server.requests.any((request) => request['method'] == 'turn/interrupt'),
        isTrue,
      );
      server.gate!.complete();
      server.gate = null;
      await transport
          .stream(
            settings: settings,
            messages: messages,
            cancellation: AiChatCancellation(),
          )
          .toList();
      expect(launches.length, 1);
    },
  );
  test(
    'final authoritative correction replaces rather than duplicates streaming text',
    () async {
      server.correction = true;
      final deltas = await transport
          .stream(
            settings: settings,
            messages: messages,
            cancellation: AiChatCancellation(),
          )
          .toList();
      expect(
        deltas
            .where((delta) => delta.contentSnapshot != null)
            .single
            .contentSnapshot,
        '修正后的答案',
      );
    },
  );
  test(
    'failed turns report their actual failure rather than successful empty answers',
    () async {
      server.fail = true;
      await expectLater(
        transport
            .stream(
              settings: settings,
              messages: messages,
              cancellation: AiChatCancellation(),
            )
            .toList(),
        throwsA(
          isA<AiChatException>().having(
            (error) => error.message,
            'message',
            contains('模型请求失败'),
          ),
        ),
      );
    },
  );

  test(
    'cancelled process startup returns promptly and terminates a late child',
    () async {
      final launched = Completer<void>(), pendingProcess = Completer<Process>();
      final slow = AiChatTransport(
        processLauncher: (_) {
          launched.complete();
          return pendingProcess.future;
        },
        processTreeRunner: (_, _) async => ProcessResult(0, 0, '', ''),
      );
      addTearDown(slow.dispose);
      final cancellation = AiChatCancellation();
      final pending = slow
          .stream(
            settings: settings,
            messages: messages,
            cancellation: cancellation,
          )
          .toList();
      await launched.future.timeout(const Duration(seconds: 2));
      cancellation.cancel();
      await pending.timeout(const Duration(seconds: 2));
      pendingProcess.complete(server);
      for (var i = 0; i < 20 && server.kills == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.kills, greaterThan(0));
    },
  );
}
