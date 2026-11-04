import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_cli_locator.dart';

class _Process implements Process {
  _Process(String output, {String error = '', int code = 0}) {
    final input = StreamController<List<int>>();
    sink = IOSink(input.sink);
    input.stream.listen(
      (_) {},
      onDone: () {
        out.add(utf8.encode(output));
        err.add(utf8.encode(error));
        unawaited(out.close());
        unawaited(err.close());
        if (!exit.isCompleted) exit.complete(code);
      },
    );
  }
  late final IOSink sink;
  final out = StreamController<List<int>>();
  final err = StreamController<List<int>>();
  final exit = Completer<int>();
  @override
  IOSink get stdin => sink;
  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => err.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  int get pid => 987654321;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!exit.isCompleted) exit.complete(1);
    unawaited(out.close());
    unawaited(err.close());
    return true;
  }
}

Future<ProcessResult> _tree(String executable, List<String> args) async =>
    ProcessResult(987654321, 0, '', '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('ai_cli_support_'),
  );
  tearDown(() async => directory.delete(recursive: true));

  test(
    'accepts a quoted executable, bin directory, and parent install directory',
    () async {
      final bin = Directory(p.join(directory.path, 'Codex App', 'bin'));
      await bin.create(recursive: true);
      final file = File(
        p.join(bin.path, Platform.isWindows ? 'codex.exe' : 'codex'),
      );
      await file.writeAsString('fixture');
      final locator = AiCliLocator();
      for (final input in [bin.path, bin.parent.path, '  "${file.path}"  ']) {
        expect(
          await locator.resolve(AiBackend.codex, input),
          file.absolute.path,
        );
      }
    },
  );
  test(
    'GUI discovery finds the Codex app outside PATH and expands environment paths',
    () async {
      final local = Directory(p.join(directory.path, 'local'));
      final bin = Directory(
        p.join(local.path, 'Programs', 'OpenAI', 'Codex', 'bin'),
      );
      await bin.create(recursive: true);
      final file = File(p.join(bin.path, 'codex.exe'));
      await file.writeAsString('fixture');
      final locator = AiCliLocator(
        windows: true,
        environment: {'LOCALAPPDATA': local.path, 'PATH': ''},
      );
      expect(await locator.resolve(AiBackend.codex), file.absolute.path);
      expect(
        await locator.resolve(
          AiBackend.codex,
          r'%LOCALAPPDATA%\Programs\OpenAI\Codex\bin',
        ),
        file.absolute.path,
      );
    },
    skip: !Platform.isWindows,
  );
  test('bad explicit paths never silently launch a different tool', () async {
    final locator = AiCliLocator();
    await expectLater(
      locator.resolve(AiBackend.codex, p.join(directory.path, 'missing.exe')),
      throwsA(isA<AiCliPathException>()),
    );
    await expectLater(
      locator.resolve(AiBackend.codex, '"codex" --unsafe'),
      throwsA(isA<AiCliPathException>()),
    );
    await expectLater(
      locator.resolve(AiBackend.codex, directory.path),
      throwsA(isA<AiCliPathException>()),
    );
  });
  test(
    'Windows npm shims resolve ps1 to cmd and launch correctly with spaces and ampersands',
    () async {
      final folder = Directory(p.join(directory.path, 'space & folder'));
      await folder.create();
      final script = File(p.join(folder.path, 'opencode.cmd'));
      await script.writeAsString('@echo off\r\necho shim-ok\r\necho %~1\r\n');
      final locator = AiCliLocator();
      await File(p.join(folder.path, 'opencode.ps1')).writeAsString('fixture');
      final resolved = await locator.resolve(
        AiBackend.opencode,
        p.join(folder.path, 'opencode.ps1'),
      );
      final invocation = locator.command(resolved, ['--version']);
      final result = await Process.run(
        invocation.executable,
        invocation.arguments,
        runInShell: false,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('shim-ok'));
      expect(result.stdout, contains('--version'));
      expect(
        () => locator.command(resolved, ['unsafe&whoami']),
        throwsA(isA<AiCliPathException>()),
      );
    },
    skip: !Platform.isWindows,
  );
  test(
    'Codex catalog uses CLI model IDs, visibility, names and advertised effort levels',
    () {
      final models = AiChatTransport.parseCliModels(
        AiBackend.codex,
        jsonEncode({
          'models': [
            {
              'slug': 'account-model',
              'display_name': 'Account Model',
              'visibility': 'list',
              'context_window': 272000,
              'default_reasoning_level': 'medium',
              'supported_reasoning_levels': [
                {'effort': 'low'},
                {'effort': 'medium'},
                {'effort': 'xhigh'},
              ],
            },
            {'slug': 'hidden-model', 'visibility': 'hide'},
            {'slug': 'account-model', 'visibility': 'list'},
          ],
        }),
      );
      expect(models.single.id, 'account-model');
      expect(models.single.name, 'Account Model');
      expect(models.single.contextWindow, 272000);
      expect(models.single.reasoningEfforts, ['low', 'medium', 'xhigh']);
      expect(models.single.defaultReasoningEffort, 'medium');
    },
  );
  test(
    'OpenCode verbose catalog retains provider prefixes and model limits and variants',
    () {
      final models = AiChatTransport.parseCliModels(
        AiBackend.opencode,
        '\x1b[32mModels cache refreshed\x1b[0m\nprovider/model-a\n${jsonEncode({
          'id': 'model-a',
          'name': 'A',
          'limit': {'context': 128000, 'output': 8192},
          'variants': {'low': {}, 'high': {}},
        })}\nprovider/model-b\n',
      );
      expect(models.map((model) => model.id), [
        'provider/model-a',
        'provider/model-b',
      ]);
      expect(models.first.contextWindow, 128000);
      expect(models.first.reasoningEfforts, ['low', 'high']);
    },
  );
  test(
    'model refresh launches the CLI catalog command without sending video material',
    () async {
      AiChatCliInvocation? request;
      final transport = AiChatTransport(
        useCodexAppServer: false,
        processTreeRunner: _tree,
        processLauncher: (invocation) async {
          request = invocation;
          return _Process(
            jsonEncode({
              'models': [
                {'slug': 'model-a', 'visibility': 'list'},
              ],
            }),
          );
        },
      );
      final models = await transport.fetchModels(
        const AiChatSettings(
          backend: AiBackend.codex,
          executablePath: 'folder',
        ),
      );
      expect(models.single.id, 'model-a');
      expect(request!.arguments, ['debug', 'models']);
      expect(request!.backend, AiBackend.codex);
      expect(Directory(request!.workingDirectory).existsSync(), isFalse);
    },
  );
  test('CLI profiles persist separately from API catalog and each other', () {
    const settings = AiChatSettings(
      backend: AiBackend.codex,
      executablePath: 'codex-path',
      model: 'model-a',
      cliProfiles: {
        'codex': AiCliProfile(
          executablePath: 'codex-path',
          model: 'model-a',
          models: [
            AiModelInfo(id: 'model-a', reasoningEfforts: ['low', 'high']),
          ],
        ),
        'opencode': AiCliProfile(
          executablePath: 'opencode-path',
          model: 'provider/model-b',
        ),
      },
    );
    final restored = AiChatSettings.fromJson(settings.toJson());
    expect(restored.selectedModelInfo!.reasoningEfforts, ['low', 'high']);
    expect(restored.cliProfiles['opencode']!.model, 'provider/model-b');
    expect(restored.savedModels, isEmpty);
    expect(
      restored.copyWith(executablePath: 'other-tool').selectedModelInfo,
      isNull,
    );
  });
  test(
    'unsupported ChatGPT models explain account access rather than installation failure',
    () async {
      final error = jsonEncode({
        'type': 'error',
        'status': 400,
        'error': {
          'message':
              "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.",
        },
      });
      await expectLater(
        AiChatTransport(
          useCodexAppServer: false,
          processTreeRunner: _tree,
          processLauncher: (_) async =>
              _Process('${jsonEncode({'type': 'error', 'message': error})}\n'),
        ).testConnection(
          const AiChatSettings(backend: AiBackend.codex, model: 'gpt-6.1-sol'),
        ),
        throwsA(
          isA<AiChatException>().having(
            (error) => error.message,
            'account error',
            allOf(
              contains('当前账号'),
              contains('刷新 CLI 模型'),
              isNot(contains('{"type"')),
            ),
          ),
        ),
      );
    },
  );
  test(
    'selected CLI effort is passed only when the directory advertises support',
    () async {
      AiChatCliInvocation? request;
      const settings = AiChatSettings(
        backend: AiBackend.codex,
        executablePath: 'codex',
        model: 'model-a',
        reasoningEffort: 'high',
        cliProfiles: {
          'codex': AiCliProfile(
            executablePath: 'codex',
            models: [
              AiModelInfo(id: 'model-a', reasoningEfforts: ['low', 'high']),
            ],
          ),
        },
      );
      await AiChatTransport(
            useCodexAppServer: false,
            processTreeRunner: _tree,
            processLauncher: (invocation) async {
              request = invocation;
              return _Process(
                '${jsonEncode({
                  'type': 'item.completed',
                  'item': {'id': 'a', 'type': 'agent_message', 'text': 'OK'},
                })}\n',
              );
            },
          )
          .stream(
            settings: settings,
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            cancellation: AiChatCancellation(),
          )
          .toList();
      expect(request!.arguments, contains('model_reasoning_effort=high'));
      expect(request!.arguments, containsAll(['--model', 'model-a']));
    },
  );
}
