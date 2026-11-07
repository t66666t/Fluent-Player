// Synthetic, time-limited fixture for native desktop Agent connection checks.
// No user media, chat history or credentials are read.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:video_player_app/features/external_ai/external_ai_clients.dart';
import 'package:video_player_app/features/external_ai/external_ai_server.dart';

class _Source implements ExternalAiDataSource {
  final calls = <String, int>{};
  @override
  List<Map<String, dynamic>> get tools => [
    for (final entry in {
      'player_overview':
          'Read the synthetic Fluent Player test library overview.',
      'library_browse':
          'List synthetic folder and media names in the test library.',
      'documents_list': 'List available synthetic transcript documents.',
      'document_read':
          'Read the complete synthetic transcript, with timestamps.',
    }.entries)
      {
        'name': entry.key,
        'description': entry.value,
        'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
        'annotations': {
          'readOnlyHint': true,
          'destructiveHint': false,
          'openWorldHint': false,
        },
      },
  ];
  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    calls.update(name, (count) => count + 1, ifAbsent: () => 1);
    return switch (name) {
      'player_overview' => {
        'name': 'Fluent Player synthetic fixture',
        'readOnly': true,
        'testOnly': true,
      },
      'library_browse' => {
        'items': [
          {'id': 'fixture-folder', 'type': 'folder', 'title': '连接测试课程'},
          {'id': 'fixture-media', 'type': 'media', 'title': '测试视频：认识媒体库'},
        ],
        'nextOffset': null,
      },
      'documents_list' => {
        'documents': [
          {'id': 'fixture-document', 'label': '中文测试文稿', 'language': 'zh'},
        ],
      },
      'document_read' => {
        'text':
            '[00:00] 这是一份连接测试文稿。\n[00:05] 媒体库按文件夹整理课程。\n[00:10] 外部 AI 可以读取资料并总结，所有接口都是只读。',
        'nextOffset': null,
        'complete': true,
        'revision': 'fixture-v1',
      },
      _ => throw ArgumentError('Unknown fixture tool'),
    };
  }
}

Future<void> main(List<String> arguments) async {
  final directory = Directory('.artifacts/external-ai-live-fixture');
  await directory.create(recursive: true);
  final source = _Source();
  final random = Random.secure();
  var token = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
  var port = 0;
  if (arguments.contains('--reuse')) {
    final previous =
        jsonDecode(
              await File('${directory.path}/connection.json').readAsString(),
            )
            as Map;
    if (previous['testOnly'] != true) {
      throw StateError('Not a synthetic connection');
    }
    final previousEndpoint = Uri.parse(previous['endpoint'] as String);
    token = previous['token'] as String;
    externalAiClientConfiguration(
      ExternalAiClient.generic,
      endpoint: previousEndpoint,
      token: token,
    );
    port = previousEndpoint.port;
  }
  final server = ExternalAiServer(dataSource: source, token: token);
  final endpoint = await server.start(port: port);
  final connection = {
    'endpoint': endpoint.toString(),
    'token': token,
    'serverName': 'fluent_player_connection_test',
    'testOnly': true,
  };
  await File(
    '${directory.path}/connection.json',
  ).writeAsString(jsonEncode(connection));
  for (final client in [
    ExternalAiClient.codex,
    ExternalAiClient.workBuddy,
    ExternalAiClient.workBuddyAi,
    ExternalAiClient.qwenWork,
  ]) {
    await File('${directory.path}/${client.name}.txt').writeAsString(
      externalAiClientConfiguration(
        client,
        endpoint: endpoint,
        token: token,
        serverName: 'fluent_player_connection_test',
      ),
    );
  }
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    unawaited(
      File('${directory.path}/activity.json').writeAsString(
        jsonEncode({
          'requests': server.requestCount,
          'toolCalls': source.calls,
          'running': server.isRunning,
        }),
      ),
    );
  });
  stdout.writeln(
    'Synthetic fixture ready. Connection files: ${directory.absolute.path}',
  );
  try {
    await Future<void>.delayed(const Duration(minutes: 15));
  } finally {
    timer.cancel();
    await server.stop();
  }
}
