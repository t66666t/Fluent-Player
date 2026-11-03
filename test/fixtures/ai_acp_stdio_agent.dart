// A real stdio ACP v1 process for opt-in desktop transport tests.
// Run with the standalone Dart executable, never flutter_tester.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final audit = File(arguments.first);
  final waitForCancel = arguments.contains('--wait-for-cancel');
  var sessionId = '';
  var sessionCount = 0;
  var model = 'fixture-default', effort = 'low';

  void record(String kind, Map<String, dynamic> fields) {
    audit.writeAsStringSync(
      '${jsonEncode({'kind': kind, 'pid': pid, 'cwd': Directory.current.path, ...fields})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  List<Map<String, dynamic>> options() => [
    {
      'id': 'model',
      'name': 'Model',
      'category': 'model',
      'type': 'select',
      'currentValue': model,
      'options': [
        {'value': 'fixture-default', 'name': 'Fixture Default'},
        {'value': 'fixture-fast', 'name': 'Fixture Fast'},
      ],
    },
    {
      'id': 'reasoning_effort',
      'name': 'Reasoning',
      'category': 'thought_level',
      'type': 'select',
      'currentValue': effort,
      'options': [
        {'value': 'low', 'name': 'Low'},
        {'value': 'high', 'name': 'High'},
      ],
    },
  ];

  Future<void> send(Map<String, dynamic> value, {bool fragment = false}) async {
    final bytes = utf8.encode('${jsonEncode({'jsonrpc': '2.0', ...value})}\n');
    if (fragment) {
      final unicode = bytes.indexWhere((value) => value >= 128);
      final split = unicode < 0 ? bytes.length ~/ 2 : unicode + 1;
      stdout.add(bytes.sublist(0, split));
      await stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      stdout.add(bytes.sublist(split));
    } else {
      stdout.add(bytes);
    }
    await stdout.flush();
  }

  Future<void> chunk(String kind, String text) => send({
    'method': 'session/update',
    'params': {
      'sessionId': sessionId,
      'update': {
        'sessionUpdate': kind,
        'content': {'type': 'text', 'text': text},
      },
    },
  }, fragment: true);

  record('started', {});
  stdout.writeln('ACP native fixture');
  await stdout.flush();
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    final message = jsonDecode(line) as Map<String, dynamic>;
    final method = message['method'];
    final params = message['params'] as Map<String, dynamic>? ?? {};
    record('request', {'method': method, 'params': params});
    switch (method) {
      case 'initialize':
        await send({
          'id': message['id'],
          'result': {
            'protocolVersion': 1,
            'agentCapabilities': {},
            'agentInfo': {'name': 'native-fixture', 'version': '1.0.0'},
          },
        });
      case 'session/new':
        sessionId = 'fixture-session-$pid-${++sessionCount}';
        model = 'fixture-default';
        effort = 'low';
        await send({
          'id': message['id'],
          'result': {'sessionId': sessionId, 'configOptions': options()},
        });
      case 'session/set_config_option':
        if (params['configId'] == 'model') model = params['value'] as String;
        if (params['configId'] == 'reasoning_effort') {
          effort = params['value'] as String;
        }
        await send({
          'id': message['id'],
          'result': {'configOptions': options()},
        });
      case 'session/prompt':
        await chunk('agent_thought_chunk', '正在整理字幕。');
        await chunk('agent_message_chunk', '桌面 Agent ');
        if (waitForCancel) continue;
        await Future<void>.delayed(const Duration(milliseconds: 15));
        await chunk('agent_message_chunk', '流式验证成功');
        await send({
          'method': 'session/update',
          'params': {
            'sessionId': sessionId,
            'update': {
              'sessionUpdate': 'usage_update',
              'size': 32000,
              'used': 123,
            },
          },
        });
        record('completed', {
          'sessionId': sessionId,
          'model': model,
          'effort': effort,
        });
        await send({
          'id': message['id'],
          'result': {'stopReason': 'end_turn'},
        });
      case 'session/cancel':
        record('cancelled', {'sessionId': sessionId});
      default:
        if (message['id'] != null) {
          await send({
            'id': message['id'],
            'error': {'code': -32601, 'message': 'Unsupported fixture method'},
          });
        }
    }
  }
}
