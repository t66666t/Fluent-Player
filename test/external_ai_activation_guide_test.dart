import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/external_ai/external_ai_clients.dart';
import 'package:video_player_app/utils/app_branding.dart';

void main() {
  final setupPath = p.join(
    Directory.systemTemp.path,
    '播放器连接资料',
    'fluent-player-setup.json',
  );

  test('WorkBuddy guide includes trust, enabling and per-chat selection', () {
    final steps = externalAiClientInfo(ExternalAiClient.workBuddy).steps;
    expect(steps, contains('信任'));
    expect(steps, contains('启用'));
    expect(steps, contains('输入框'));
    expect(steps, contains('连接器'));
  });

  test('Codex activation defers backend restart while user tasks run', () {
    final notice = externalAiClientActivationNotice(ExternalAiClient.codex);
    expect(notice, contains('重启'));
    expect(notice, contains('后端'));
    expect(notice, contains('任务'));
    expect(notice, contains('稍后'));
    expect(notice, matches(RegExp('不要|不得|不能|禁止')));
  });

  test('Gemini guide names the supported MCP-only reload command', () {
    final steps = externalAiClientInfo(ExternalAiClient.geminiCli).steps;
    expect(steps, contains('/mcp reload'));
  });

  test('QwenWork uses its own HTTP spelling and requires a new task', () {
    final steps = externalAiClientInfo(ExternalAiClient.qwenWork).steps;
    expect(steps, matches(RegExp('新(?:建)?(?:一个)?任务')));
    final configuration = jsonDecode(
      externalAiClientConfiguration(
        ExternalAiClient.qwenWork,
        endpoint: Uri.parse('http://127.0.0.1:38461/mcp'),
        token: 'fixture-only-secret-never-in-a-prompt',
      ),
    );
    expect(
      configuration['mcpServers'][kMcpServerName]['type'],
      'streamable-http',
    );
  });

  test('each setup prompt carries the selected client activation steps', () {
    for (final client in ExternalAiClient.values) {
      final info = externalAiClientInfo(client);
      final prompt = externalAiConnectionPrompt(
        client,
        setupFilePath: setupPath,
        serverName: 'fluent_player_community',
      );
      expect(prompt, contains(info.steps), reason: client.name);
      expect(
        prompt,
        contains(externalAiClientActivationNotice(client)),
        reason: client.name,
      );
      expect(prompt, contains('fluent_player_community'), reason: client.name);
      expect(prompt, isNot(contains('Bearer ')), reason: client.name);
      expect(prompt, isNot(contains('能刷新 MCP 时刷新')), reason: client.name);
    }
  });

  test(
    'setup does not silently configure a different client or grant trust',
    () {
      for (final client in ExternalAiClient.values) {
        final prompt = externalAiConnectionPrompt(
          client,
          setupFilePath: setupPath,
        );
        expect(prompt, contains('client'), reason: client.name);
        expect(prompt, contains('不一致'), reason: client.name);
        expect(prompt, contains('停止'), reason: client.name);
        expect(prompt, contains('信任'), reason: client.name);
        expect(prompt, contains('用户'), reason: client.name);
        expect(
          prompt,
          matches(RegExp('不要代|不得代|不能代|不可代|禁止代')),
          reason: client.name,
        );
      }
    },
  );

  test(
    'verification requires actual native MCP calls and returned content',
    () {
      final prompt = externalAiVerificationPrompt();
      expect(prompt, contains(kMcpServerName));
      expect(prompt, contains('player_overview'));
      expect(prompt, contains('library_browse'));
      expect(prompt, contains('原生'));
      expect(prompt, contains('HTTP'));
      expect(prompt, contains('磁盘'));
      expect(prompt, matches(RegExp('不要|不得|不能|禁止|不可')));
      expect(prompt, contains('真实'));
      expect(prompt, contains('成功'));
      expect(prompt, isNot(contains('Bearer ')));
    },
  );

  test('verification retains edition-specific server identity', () {
    final prompt = externalAiVerificationPrompt(
      serverName: 'fluent_player_community',
    );
    expect(prompt, contains('fluent_player_community'));
    expect(prompt, contains('player_overview'));
    expect(prompt, contains('library_browse'));
  });
}
