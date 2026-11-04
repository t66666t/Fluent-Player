// Read-only native MCP discovery check. No model request or user credentials.
// dart --packages=.dart_tool/package_config.json tool/external_ai_codex_probe.dart <codex-executable>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:video_player_app/features/external_ai/external_ai_clients.dart';
import 'package:video_player_app/features/external_ai/external_ai_server.dart';

class _ProbeSource implements ExternalAiDataSource {
  @override
  List<Map<String, dynamic>> get tools => [
    {
      'name': 'get_library_overview',
      'description': 'Read a synthetic library fixture; no user media is read.',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
      'annotations': {'readOnlyHint': true},
    },
  ];

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async => {
    'folders': [
      {'id': 'fixture-folder', 'name': '测试课程'},
    ],
  };
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: external_ai_codex_probe.dart <native-codex-executable>',
    );
    exitCode = 64;
    return;
  }
  final artifact = Directory('.artifacts/external-ai-codex-probe');
  await artifact.create(recursive: true);
  final isolated = await artifact.createTemp('run-');
  const token = 'synthetic-local-probe-not-a-user-credential';
  final server = ExternalAiServer(dataSource: _ProbeSource(), token: token);
  Process? process;
  StreamSubscription<String>? outputSubscription;
  StreamSubscription<String>? errorSubscription;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  final errors = <String>[];
  var nextId = 0;
  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = ++nextId;
    final completion = Completer<Map<String, dynamic>>();
    pending[id] = completion;
    process!.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'params': params}),
    );
    return completion.future.timeout(const Duration(seconds: 55));
  }

  try {
    final endpoint = await server.start();
    await File('${isolated.path}/config.toml').writeAsString(
      externalAiClientConfiguration(
        ExternalAiClient.codex,
        endpoint: endpoint,
        token: token,
      ),
    );
    process = await Process.start(
      arguments.single,
      ['app-server'],
      environment: {
        'CODEX_HOME': isolated.absolute.path,
        'HTTP_PROXY': '',
        'HTTPS_PROXY': '',
        'ALL_PROXY': '',
        'NO_PROXY': '127.0.0.1,localhost,::1',
      },
      workingDirectory: isolated.absolute.path,
    );
    outputSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final event = jsonDecode(line) as Map<String, dynamic>;
            if (event['id'] is int) {
              pending.remove(event['id'])?.complete(event);
            }
          } catch (_) {
            /* app-server should emit only JSON; ignore non-RPC lines */
          }
        });
    errorSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          // Keep only a bounded diagnostic; fixture config contains no user secrets.
          if (errors.length < 6) errors.add(line);
        });
    final initialized = await rpc('initialize', {
      'clientInfo': {'name': 'fluent_player_mcp_probe', 'version': '1.0.0'},
      'capabilities': {'experimentalApi': true},
    });
    if (initialized['error'] != null) throw StateError('initialize failed');
    process.stdin.writeln(jsonEncode({'method': 'initialized'}));
    var status = await rpc('mcpServerStatus/list', <String, dynamic>{});
    // Some versions start MCP connections only when a thread is created.
    if (server.requestCount == 0) {
      final thread = await rpc('thread/start', {
        'ephemeral': true,
        'approvalPolicy': 'never',
        'sandbox': 'read-only',
      });
      if (thread['error'] != null) {
        throw StateError('thread/start failed: ${thread['error']}');
      }
      for (var attempt = 0; attempt < 10; attempt++) {
        status = await rpc('mcpServerStatus/list', <String, dynamic>{});
        if (jsonEncode(status).contains('get_library_overview')) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    final discovered = jsonEncode(status).contains('get_library_overview');
    final report = {
      'platform': Platform.operatingSystem,
      'initialize': initialized['error'] == null,
      'syntheticToolDiscovered': discovered,
      'serverRequests': server.requestCount,
      'modelInferencePerformed': false,
      'userConfigChanged': false,
      'status': status,
      if (!discovered) 'diagnostics': errors,
    };
    await File(
      '${artifact.path}/result.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln(jsonEncode(report));
    if (!discovered) exitCode = 1;
  } finally {
    if (process != null) {
      await process.stdin.close();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
        } else {
          process.kill();
        }
      }
    }
    await outputSubscription?.cancel();
    await errorSubscription?.cancel();
    await server.stop();
  }
}
