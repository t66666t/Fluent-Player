// Install/remove one synthetic test connector after explicit testing approval.
// Existing client settings and their backups remain in the client directory.
import 'dart:convert';
import 'dart:io';

import 'package:video_player_app/features/external_ai/external_ai_clients.dart';

const _name = 'fluent_player_probe';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 ||
      !['install', 'remove'].contains(arguments.single)) {
    throw ArgumentError(
      'Usage: external_ai_workbuddy_probe.dart install|remove',
    );
  }
  final connectionFile = File(
    '.artifacts/external-ai-live-fixture/connection.json',
  );
  final connection = jsonDecode(await connectionFile.readAsString()) as Map;
  final endpoint = Uri.parse(connection['endpoint'] as String);
  final token = connection['token'] as String;
  final target = await externalAiClientConfigFile(ExternalAiClient.workBuddy);
  if (target == null) throw StateError('WorkBuddy profile was not found.');
  if (arguments.single == 'install') {
    final result = await installExternalAiClient(
      ExternalAiClient.workBuddy,
      endpoint: endpoint,
      token: token,
      serverName: _name,
      targetFile: target,
    );
    final report = {
      'configPath': result.configPath,
      'backupPath': result.backupPath,
      'changed': result.changed,
      'serverName': _name,
      'syntheticDataOnly': true,
    };
    await File(
      '.artifacts/external-ai-live-fixture/workbuddy-install-result.json',
    ).writeAsString(jsonEncode(report));
    stdout.writeln(jsonEncode(report));
    return;
  }
  final original = await target.readAsString();
  final parsed = jsonDecode(original) as Map<String, dynamic>;
  final servers = Map<String, dynamic>.from(parsed['mcpServers'] as Map);
  final record = servers[_name];
  if (record == null) {
    stdout.writeln('Synthetic connector already absent.');
    return;
  }
  if (record is! Map ||
      record['url'] != endpoint.toString() ||
      record['headers'] is! Map ||
      record['headers']['Authorization'] != 'Bearer $token') {
    throw StateError(
      'The named connection changed; no client settings were removed.',
    );
  }
  servers.remove(_name);
  parsed['mcpServers'] = servers;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final backup = File('${target.path}.fluent-player-cleanup-$stamp.bak');
  final temporary = File('${target.path}.fluent-player-cleanup-$stamp.tmp');
  try {
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(parsed)}\n',
      flush: true,
    );
    if (await target.readAsString() != original) {
      throw StateError(
        'Client settings changed concurrently; please retry cleanup.',
      );
    }
    await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
    } catch (_) {
      if (!await target.exists()) await backup.copy(target.path);
      rethrow;
    }
    final report = {
      'configPath': target.path,
      'backupPath': backup.path,
      'removedServer': _name,
    };
    await File(
      '.artifacts/external-ai-live-fixture/workbuddy-cleanup-result.json',
    ).writeAsString(jsonEncode(report));
    stdout.writeln(jsonEncode(report));
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
