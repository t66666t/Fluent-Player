import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/services/network/network_http.dart';

/// Native subprocess verification, disabled in ordinary test runs.
/// AI_ACP_NATIVE_DART must identify the standalone Dart executable.
/// AI_ACP_QWEN only inspects an installed Qwen CLI; it never submits inference.
/// AI_ACP_QWEN_INFERENCE additionally opts in to one minimal connection prompt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dartExecutable = String.fromEnvironment('AI_ACP_NATIVE_DART');
  const qwenEnabled = bool.fromEnvironment('AI_ACP_QWEN');
  const qwenInference = bool.fromEnvironment('AI_ACP_QWEN_INFERENCE');
  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<
    ({
      Directory root,
      File audit,
      AiChatTransport transport,
      List<Process> processes,
      List<AiChatCliInvocation> invocations,
    })
  >
  setup() async {
    final root = await Directory.systemTemp.createTemp('ai_acp_native_test_');
    final audit = File('${root.path}/audit.jsonl');
    final processes = <Process>[];
    final invocations = <AiChatCliInvocation>[];
    final transport = AiChatTransport(
      processLauncher: (invocation) async {
        invocations.add(invocation);
        final process = await Process.start(
          invocation.executable,
          invocation.arguments,
          workingDirectory: invocation.workingDirectory,
          environment: invocation.environment,
          runInShell: false,
        );
        processes.add(process);
        return process;
      },
      temporaryDirectory: () =>
          Directory.systemTemp.createTemp('ai_acp_native_request_'),
      connectionTimeout: const Duration(seconds: 15),
      idleTimeout: const Duration(seconds: 10),
      processTimeout: const Duration(seconds: 20),
      networkRetryDelays: const [],
    );
    addTearDown(() async {
      await transport.dispose();
      for (final process in processes) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
      await root.delete(recursive: true);
    });
    return (
      root: root,
      audit: audit,
      transport: transport,
      processes: processes,
      invocations: invocations,
    );
  }

  AiChatSettings configuration(File audit, {bool waitForCancel = false}) =>
      AiChatSettings(
        backend: AiBackend.acp,
        executablePath: dartExecutable,
        cliArguments: [
          File('test/fixtures/ai_acp_stdio_agent.dart').absolute.path,
          audit.absolute.path,
          if (waitForCancel) '--wait-for-cancel',
        ],
        model: 'fixture-fast',
        reasoningEffort: 'high',
        thinkingEnabled: true,
        contextTokens: 32000,
        maxOutputTokens: 1024,
      );

  test(
    'native ACP JSONL streams unicode, chooses model and reuses a process with isolated sessions',
    () async {
      final fixture = await setup();
      final settings = configuration(fixture.audit);
      final status = await fixture.transport.inspectCli(settings);
      expect(status.version, contains('native-fixture 1.0.0'));
      expect(status.loggedIn, isNull);
      final models = await fixture.transport.fetchModels(settings);
      expect(models.map((item) => item.id), [
        'fixture-default',
        'fixture-fast',
      ]);
      expect(models.first.reasoningEfforts, isEmpty);
      expect(models.last.reasoningEfforts, ['low', 'high']);
      for (var run = 0; run < 2; run++) {
        final events = await fixture.transport
            .stream(
              settings: settings,
              messages: [
                {'role': 'user', 'content': '字幕问题 $run：保留中文、空格、"引号"与换行\n第二行。'},
              ],
              cancellation: AiChatCancellation(),
            )
            .toList();
        expect(events.map((item) => item.content).join(), '桌面 Agent 流式验证成功');
        expect(events.where((item) => item.content.isNotEmpty), hasLength(2));
        expect(events.map((item) => item.reasoning).join(), '正在整理字幕。');
        expect(events.last.finishReason, 'stop');
        expect(
          events.any((item) => item.usage?['acp_context_used'] == 123),
          isTrue,
        );
      }
      final records = fixture.audit
          .readAsLinesSync()
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      final completed = records
          .where((item) => item['kind'] == 'completed')
          .toList();
      expect(completed, hasLength(2));
      expect(
        completed.map((item) => item['model']),
        everyElement('fixture-fast'),
      );
      expect(completed.map((item) => item['effort']), everyElement('high'));
      expect(completed.map((item) => item['sessionId']).toSet(), hasLength(2));
      final prompts = records
          .where(
            (item) =>
                item['kind'] == 'request' && item['method'] == 'session/prompt',
          )
          .toList();
      expect(prompts, hasLength(2));
      for (var run = 0; run < prompts.length; run++) {
        final params = prompts[run]['params'] as Map<String, dynamic>;
        final text =
            ((params['prompt'] as List).single as Map)['text'] as String;
        expect(text, contains('字幕问题 $run'));
        expect(text, contains('第二行'));
        expect(
          fixture.invocations.every(
            (invocation) =>
                !invocation.arguments.any((arg) => arg.contains('字幕问题')),
          ),
          isTrue,
        );
      }
      expect(fixture.processes, hasLength(1));
      expect(records.where((r) => r['method'] == 'initialize'), hasLength(1));
      final sessionRequests = records
          .where((r) => r['method'] == 'session/new')
          .toList();
      expect(sessionRequests, hasLength(4));
      expect(
        sessionRequests.map((r) => r['params']['cwd']).toSet(),
        hasLength(4),
      );
      await fixture.transport.dispose();
      for (final process in fixture.processes) {
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
      for (final invocation in fixture.invocations) {
        expect(await Directory(invocation.workingDirectory).exists(), isFalse);
      }
      stdout.writeln(
        'Native ACP JSONL: one subprocess, one initialization, four fresh sessions; unicode streaming, model/effort, isolated sessions, process and directory cleanup passed.',
      );
    },
    skip: dartExecutable.isEmpty || !desktop,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native ACP cancellation stops its subprocess and reclaims its directory',
    () async {
      final fixture = await setup();
      final cancellation = AiChatCancellation();
      final events = <AiChatDelta>[];
      await for (final event in fixture.transport.stream(
        settings: configuration(fixture.audit, waitForCancel: true),
        messages: const [
          {'role': 'user', 'content': '本地取消测试'},
        ],
        cancellation: cancellation,
      )) {
        events.add(event);
        if (event.content.isNotEmpty) cancellation.cancel();
      }
      expect(events.any((item) => item.content.isNotEmpty), isTrue);
      expect(events.any((item) => item.finishReason != null), isFalse);
      expect(fixture.processes, hasLength(1));
      await fixture.processes.single.exitCode.timeout(
        const Duration(seconds: 5),
      );
      expect(
        await Directory(fixture.invocations.single.workingDirectory).exists(),
        isFalse,
      );
    },
    skip: dartExecutable.isEmpty || !desktop,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'installed Qwen performs ACP handshake and model discovery (optional inference)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('ai_acp_qwen_test_');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.example.video_player_app/network'),
        (call) async => call.method == 'resolveProxy' ? ['DIRECT'] : null,
      );
      final transport = AiChatTransport(
        connectionTimeout: const Duration(seconds: 30),
        idleTimeout: const Duration(seconds: 30),
        processTimeout: const Duration(seconds: 45),
        networkRetryDelays: const [],
      );
      addTearDown(() async {
        await transport.dispose();
        await NetworkHttp.instance.dispose();
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/network'),
          null,
        );
        await root.delete(recursive: true);
      });
      final settings = AiChatSettings(
        backend: AiBackend.qwenCode,
        executablePath: const String.fromEnvironment('AI_ACP_QWEN_PATH'),
        model: '',
      );
      final status = await transport.inspectCli(settings);
      expect(status.version, contains('ACP'));
      final models = await transport.fetchModels(
        settings.copyWith(executablePath: status.executablePath),
      );
      expect(models.map((item) => item.id).toSet().length, models.length);
      expect(models.every((item) => item.id.isNotEmpty), isTrue);
      stdout.writeln(
        'Qwen native ACP: ${status.version}; catalog=${models.length}; no inference submitted.',
      );
      if (qwenInference) {
        final response = await transport.testConnection(
          settings.copyWith(executablePath: status.executablePath),
        );
        expect(response, contains('连接成功：'));
        expect(response, contains('OK'));
        stdout.writeln('Qwen native ACP: minimal connection inference passed.');
      }
    },
    skip: !qwenEnabled || !desktop,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
