import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/ai_chat/ai_agent_catalog.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_cli_locator.dart';
import 'package:video_player_app/features/ai_chat/ai_token_usage.dart';

void main() {
  test('each named ACP agent resolves its own installed command', () async {
    final directory = await Directory.systemTemp.createTemp('ai_agents_path_');
    try {
      final locator = AiCliLocator(environment: {'PATH': directory.path});
      for (final preset in aiAgentPresets.where(
        (p) => p.executable.isNotEmpty,
      )) {
        final file = File(
          p.join(
            directory.path,
            '${preset.executable}${Platform.isWindows ? '.cmd' : ''}',
          ),
        );
        await file.writeAsString('fixture');
        expect(
          await locator.resolve(preset.backend),
          file.absolute.path,
          reason: preset.label,
        );
        expect(
          await locator.resolve(preset.backend, directory.path),
          file.absolute.path,
          reason: preset.label,
        );
        final command = locator.command(file.path, preset.arguments);
        if (preset.arguments.isNotEmpty) {
          expect(command.arguments, containsAllInOrder(preset.arguments));
        }
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'custom ACP requires an explicit executable and never assumes OpenCode',
    () async {
      final locator = AiCliLocator(environment: {'PATH': ''});
      await expectLater(
        locator.resolve(AiBackend.acp),
        throwsA(isA<AiCliPathException>()),
      );
      final directory = await Directory.systemTemp.createTemp(
        'ai_custom_path_',
      );
      try {
        await expectLater(
          locator.resolve(AiBackend.acp, directory.path),
          throwsA(isA<AiCliPathException>()),
        );
        final file = File(
          p.join(
            directory.path,
            'custom-agent${Platform.isWindows ? '.exe' : ''}',
          ),
        );
        await file.writeAsString('fixture');
        expect(
          await locator.resolve(AiBackend.acp, file.path),
          file.absolute.path,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'recorded ACP source takes precedence over native API usage guesses',
    () {
      for (final preset in aiAgentPresets) {
        final presentation = AiUsagePresentation.forReply(
          {'backend': preset.backend.name},
          {'cached_input_tokens': 20, 'promptTokenCount': 100},
        );
        expect(presentation.label, contains(preset.label));
        expect(presentation.cli, isTrue);
        expect(presentation.showCacheRate, isFalse);
      }
      expect(
        AiUsagePresentation.forReply({
          'backend': 'api',
          'api_protocol': 'anthropic',
        }, {}).label,
        'Claude 原生接口',
      );
    },
  );
}
