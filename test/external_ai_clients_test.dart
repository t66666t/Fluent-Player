import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/external_ai/external_ai_clients.dart';

void main() {
  final endpoint = Uri.parse('http://127.0.0.1:39241/mcp');
  const token = 'local-test-token-"-\\-中文';

  test(
    'copyable prompts instruct the current client without embedding credentials',
    () {
      final setupFile = p.join(
        Directory.systemTemp.path,
        '播放器资料',
        'connect "quoted".json',
      );
      for (final client in ExternalAiClient.values) {
        final prompt = externalAiConnectionPrompt(
          client,
          setupFilePath: setupFile,
          serverName: 'fluent_player_community',
        );
        expect(prompt, contains(externalAiClientInfo(client).label));
        expect(prompt, contains(jsonEncode(setupFile)));
        expect(prompt, contains('fluent_player_community'));
        expect(prompt, contains('备份'));
        expect(prompt, contains('保留其他连接'));
        expect(prompt, contains('player_overview'));
        expect(prompt, contains('library_browse'));
        expect(prompt, contains('仅写入配置'));
        expect(prompt, contains('原生 MCP'));
        expect(prompt, isNot(contains(token)));
        expect(prompt, isNot(contains('Bearer ')));
        expect(prompt, contains('不要把令牌放进地址、命令行、对话输出或日志'));
      }
      expect(
        externalAiConnectionPrompt(
          ExternalAiClient.codex,
          setupFilePath: setupFile,
        ),
        contains('CODEX_HOME'),
      );
      expect(
        externalAiConnectionPrompt(
          ExternalAiClient.workBuddy,
          setupFilePath: setupFile,
        ),
        contains('.workbuddy/mcp.json'),
      );
      expect(
        externalAiConnectionPrompt(
          ExternalAiClient.workBuddyAi,
          setupFilePath: setupFile,
        ),
        contains('.workbuddy-ai/connectors/default/mcp.json'),
      );
      expect(
        externalAiConnectionPrompt(
          ExternalAiClient.qwenWork,
          setupFilePath: setupFile,
        ),
        contains('普通千问客户端能否添加 MCP 尚未确认'),
      );
      expect(
        externalAiConnectionPrompt(
          ExternalAiClient.claudeDesktop,
          setupFilePath: setupFile,
        ),
        contains('未提供 Claude Desktop 桌面扩展或 stdio 桥'),
      );
    },
  );

  test('connection prompt rejects relative paths and newline instructions', () {
    expect(
      () => externalAiConnectionPrompt(
        ExternalAiClient.codex,
        setupFilePath: 'relative.json',
      ),
      throwsArgumentError,
    );
    expect(
      () => externalAiConnectionPrompt(
        ExternalAiClient.codex,
        setupFilePath: '${Directory.systemTemp.path}\ninjected',
      ),
      throwsArgumentError,
    );
    expect(
      () => externalAiConnectionPrompt(
        ExternalAiClient.codex,
        setupFilePath: Directory.systemTemp.path,
        serverName: 'bad]\n[table',
      ),
      throwsArgumentError,
    );
  });

  test('all client configurations carry auth in headers, never the URL', () {
    for (final client in ExternalAiClient.values) {
      final configuration = externalAiClientConfiguration(
        client,
        endpoint: endpoint,
        token: token,
      );
      if (client == ExternalAiClient.codex) {
        expect(configuration, contains('http_headers = { Authorization = '));
        expect(configuration, contains(jsonEncode('Bearer $token')));
        continue;
      }
      final root = jsonDecode(configuration) as Map<String, dynamic>;
      final servers =
          root[client == ExternalAiClient.vsCode ? 'servers' : 'mcpServers']
              as Map;
      final server = servers['fluent_player'] as Map;
      expect(
        server[client == ExternalAiClient.geminiCli ? 'httpUrl' : 'url'],
        endpoint.toString(),
      );
      expect(server['headers'], {'Authorization': 'Bearer $token'});
    }
    final workBuddy = jsonDecode(
      externalAiClientConfiguration(
        ExternalAiClient.workBuddy,
        endpoint: endpoint,
        token: token,
      ),
    );
    expect(workBuddy['mcpServers']['fluent_player']['type'], 'streamableHttp');
  });

  test('remote, query, credential and header injection inputs fail closed', () {
    for (final url in [
      'https://127.0.0.1:39241/mcp',
      'http://example.com/mcp',
      'http://127.0.0.1:39241/mcp?token=secret',
      'http://user:pass@127.0.0.1:39241/mcp',
      'http://127.0.0.1:39241/mcp#secret',
      'http://127.0.0.1:39241/not-mcp',
    ]) {
      expect(
        () => externalAiClientConfiguration(
          ExternalAiClient.codex,
          endpoint: Uri.parse(url),
          token: token,
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => externalAiClientConfiguration(
        ExternalAiClient.generic,
        endpoint: endpoint,
        token: 'bad\nheader',
      ),
      throwsArgumentError,
    );
    expect(
      () => externalAiClientConfiguration(
        ExternalAiClient.codex,
        endpoint: endpoint,
        token: token,
        serverName: 'bad]\n[table',
      ),
      throwsArgumentError,
    );
  });

  group('explicit connection installation', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'external-ai-client-test-',
      );
    });
    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test(
      'JSON merge preserves siblings, backup and repeated installation',
      () async {
        final file = File(p.join(directory.path, 'mcp.json'));
        final existing = jsonEncode({
          'otherSetting': {'enabled': false},
          'mcpServers': {
            'other-server': {
              'command': r'C:\Program Files\工具\server.exe',
              'args': ['--safe'],
            },
          },
        });
        await file.writeAsString(existing);
        final result = await installExternalAiClient(
          ExternalAiClient.workBuddy,
          endpoint: endpoint,
          token: token,
          targetFile: file,
        );
        expect(result.changed, isTrue);
        expect(await File(result.backupPath!).readAsString(), existing);
        final updated = jsonDecode(await file.readAsString());
        expect(updated['otherSetting'], {'enabled': false});
        expect(
          updated['mcpServers']['other-server']['command'],
          r'C:\Program Files\工具\server.exe',
        );
        final repeated = await installExternalAiClient(
          ExternalAiClient.workBuddy,
          endpoint: endpoint,
          token: token,
          targetFile: file,
        );
        expect(repeated.changed, isFalse);
        expect(repeated.backupPath, isNull);
      },
    );

    test('malformed JSON and a named conflict never overwrite data', () async {
      final file = File(p.join(directory.path, 'mcp.json'));
      for (final original in [
        'not JSON',
        '[]',
        '{"mcpServers": []}',
        '{"mcpServers":{"fluent_player":{"command":"other"}}}',
      ]) {
        await file.writeAsString(original);
        await expectLater(
          installExternalAiClient(
            ExternalAiClient.workBuddy,
            endpoint: endpoint,
            token: token,
            targetFile: file,
          ),
          throwsFormatException,
        );
        expect(await file.readAsString(), original);
      }
      expect(await directory.list().length, 1);
    });

    test(
      'explicit replacement updates only the selected JSON connection',
      () async {
        final file = File(p.join(directory.path, 'mcp.json'));
        await file.writeAsString(
          '{"mcpServers":{"fluent_player":{"url":"old"},"keep":{"command":"keep"}}}',
        );
        await installExternalAiClient(
          ExternalAiClient.cursor,
          endpoint: endpoint,
          token: token,
          targetFile: file,
          replaceExisting: true,
        );
        final updated = jsonDecode(await file.readAsString());
        expect(updated['mcpServers']['keep'], {'command': 'keep'});
        expect(
          updated['mcpServers']['fluent_player']['url'],
          endpoint.toString(),
        );
      },
    );

    test(
      'Codex managed block preserves comments, tables, and can rotate token',
      () async {
        final file = File(p.join(directory.path, 'config.toml'));
        const original =
            '# 用户配置\r\nmodel = "test"\r\n[mcp_servers.keep]\r\ncommand = "keep"\r\n';
        await file.writeAsString(original);
        final result = await installExternalAiClient(
          ExternalAiClient.codex,
          endpoint: endpoint,
          token: token,
          targetFile: file,
        );
        final first = await file.readAsString();
        expect(first, startsWith(original));
        expect(await File(result.backupPath!).readAsString(), original);
        await installExternalAiClient(
          ExternalAiClient.codex,
          endpoint: endpoint,
          token: 'rotated',
          targetFile: file,
        );
        final rotated = await file.readAsString();
        expect(rotated, startsWith(original));
        expect('BEGIN FLUENT PLAYER'.allMatches(rotated).length, 1);
        expect(rotated, contains('Bearer rotated'));
        expect(rotated, isNot(contains(jsonEncode('Bearer $token'))));
        final unchanged = await installExternalAiClient(
          ExternalAiClient.codex,
          endpoint: endpoint,
          token: 'rotated',
          targetFile: file,
        );
        expect(unchanged.changed, isFalse);
      },
    );

    test(
      'Codex refuses unmarked names, alternate quoting and broken markers',
      () async {
        final file = File(p.join(directory.path, 'config.toml'));
        for (final original in [
          '[mcp_servers.fluent_player]\ncommand="keep"\n',
          '[mcp_servers."fluent_player"]\ncommand="keep"\n',
          "[mcp_servers.'fluent_player']\ncommand='keep'\n",
          '[mcp_servers]\nfluent_player = { command="keep" }\n',
          '# BEGIN FLUENT PLAYER MCP fluent_player\nbroken',
        ]) {
          await file.writeAsString(original);
          await expectLater(
            installExternalAiClient(
              ExternalAiClient.codex,
              endpoint: endpoint,
              token: token,
              targetFile: file,
            ),
            throwsFormatException,
          );
          expect(await file.readAsString(), original);
        }
      },
    );

    test(
      'Codex custom home honored; ambiguous Qianwen uses copy fallback',
      () async {
        final file = await externalAiClientConfigFile(
          ExternalAiClient.codex,
          environment: {
            'USERPROFILE': directory.path,
            'CODEX_HOME': p.join(directory.path, 'isolated-codex'),
          },
        );
        expect(
          file!.path,
          p.join(directory.path, 'isolated-codex', 'config.toml'),
        );
        expect(
          await externalAiClientConfigFile(
            ExternalAiClient.qwenWork,
            environment: {'USERPROFILE': directory.path},
          ),
          isNull,
        );
        expect(
          await externalAiClientConfigFile(
            ExternalAiClient.workBuddy,
            environment: {'USERPROFILE': directory.path},
          ),
          isNull,
        );
      },
    );
    test(
      'WorkBuddy variants resolve only their own existing profile',
      () async {
        final mainDirectory = Directory(p.join(directory.path, '.workbuddy'));
        final aiDirectory = Directory(
          p.join(directory.path, '.workbuddy-ai', 'connectors', 'default'),
        );
        await mainDirectory.create(recursive: true);
        await aiDirectory.create(recursive: true);
        final environment = {'USERPROFILE': directory.path};
        final main = await externalAiClientConfigFile(
          ExternalAiClient.workBuddy,
          environment: environment,
        );
        final ai = await externalAiClientConfigFile(
          ExternalAiClient.workBuddyAi,
          environment: environment,
        );
        expect(main!.path, p.join(mainDirectory.path, 'mcp.json'));
        expect(ai!.path, p.join(aiDirectory.path, 'mcp.json'));
        expect(main.path, isNot(ai.path));
        await installExternalAiClient(
          ExternalAiClient.workBuddyAi,
          endpoint: endpoint,
          token: token,
          targetFile: ai,
        );
        expect(await main.exists(), isFalse);
        final parsed = jsonDecode(await ai.readAsString());
        expect(parsed['mcpServers']['fluent_player']['type'], 'streamableHttp');
      },
    );
    test(
      'WorkBuddy respects the active profile environment override',
      () async {
        final override = Directory(p.join(directory.path, 'workbuddy-custom'));
        final legacy = Directory(p.join(directory.path, 'codebuddy-custom'));
        await override.create();
        await legacy.create();
        final active = await externalAiClientConfigFile(
          ExternalAiClient.workBuddy,
          environment: {
            'USERPROFILE': directory.path,
            'WORKBUDDY_CONFIG_DIR': override.path,
            'CODEBUDDY_CONFIG_DIR': legacy.path,
          },
        );
        expect(active!.path, p.join(override.path, 'mcp.json'));
        final fallback = await externalAiClientConfigFile(
          ExternalAiClient.workBuddy,
          environment: {
            'USERPROFILE': directory.path,
            'WORKBUDDY_CONFIG_DIR': '  ',
            'CODEBUDDY_CONFIG_DIR': legacy.path,
          },
        );
        expect(fallback!.path, p.join(legacy.path, 'mcp.json'));
        expect(
          await externalAiClientConfigFile(
            ExternalAiClient.workBuddy,
            environment: {
              'USERPROFILE': directory.path,
              'WORKBUDDY_CONFIG_DIR': 'relative-profile',
            },
          ),
          isNull,
        );
      },
    );
  });
}
