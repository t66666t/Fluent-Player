import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'installed Codex streams an actual answer and reuses its server',
    () async {
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final dataDirectory = await Directory.systemTemp.createTemp(
        'codex_live_data_',
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => dataDirectory.path,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.example.video_player_app/network'),
        (call) async => call.method == 'resolveProxy' ? ['DIRECT'] : null,
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/network'),
          null,
        );
        await dataDirectory.delete(recursive: true);
      });
      final transport = AiChatTransport(
        connectionTimeout: const Duration(seconds: 15),
        idleTimeout: const Duration(seconds: 40),
        processTimeout: const Duration(seconds: 75),
      );
      addTearDown(transport.dispose);
      const base = AiChatSettings(
        backend: AiBackend.codex,
        contextTokens: 12000,
        maxOutputTokens: 1000,
      );
      final models = await transport.fetchModels(base);
      final requestedModel = Platform.environment['AI_CODEX_MODEL'];
      final requestedEffort = Platform.environment['AI_CODEX_EFFORT'];
      final probePrompt = Platform.environment['AI_CODEX_LATENCY_PROMPT'];
      final model = models.firstWhere(
        (item) => item.id == (requestedModel ?? 'gpt-5.5'),
        orElse: () => models.first,
      );
      if (requestedModel != null) expect(model.id, requestedModel);
      if (requestedEffort != null) {
        expect(model.reasoningEfforts, contains(requestedEffort));
      }
      final settings = base.copyWith(
        model: model.id,
        reasoningEffort: requestedEffort ?? model.lowestReasoningEffort ?? '',
        cliProfiles: {
          'codex': AiCliProfile(
            executablePath: '',
            model: model.id,
            models: models,
          ),
        },
      );
      for (var run = 0; run < 2; run++) {
        final clock = Stopwatch()..start();
        int? firstText;
        var textEvents = 0, reasoningEvents = 0;
        final stages = <String>[];
        final text = StringBuffer();
        Map<String, dynamic>? usage;
        await for (final delta in transport.stream(
          settings: settings,
          messages: [
            {
              'role': 'user',
              'content':
                  probePrompt ??
                  (run == 0
                      ? '用中文写六条简短的视频学习建议，每条一行。只使用对话，不使用任何工具。'
                      : '用中文写四条简短的笔记建议，每条一行。只使用对话，不使用任何工具。'),
            },
          ],
          cancellation: AiChatCancellation(),
        )) {
          if (delta.stage != null) {
            stages.add(delta.stage!);
            stdout.writeln(
              'run=$run elapsed_ms=${clock.elapsedMilliseconds} ${delta.stage}',
            );
          }
          if (delta.content.isNotEmpty) {
            firstText ??= clock.elapsedMilliseconds;
            textEvents++;
            text.write(delta.content);
          }
          if (delta.contentSnapshot != null) {
            text.clear();
            text.write(delta.contentSnapshot);
          }
          if (delta.reasoning.isNotEmpty) reasoningEvents++;
          usage = delta.usage ?? usage;
        }
        expect(text.toString().trim(), isNotEmpty);
        expect(
          textEvents,
          greaterThan(probePrompt == null ? 1 : 0),
          reason: 'real incremental events must arrive',
        );
        expect(usage?['prompt_tokens'], isNotNull);
        if (run == 1) {
          expect(stages.any((stage) => stage.contains('启动')), isFalse);
        }
        stdout.writeln(
          'Codex live run=$run model=${model.id} effort=${settings.reasoningEffort} first_text_ms=$firstText elapsed_ms=${clock.elapsedMilliseconds} text_events=$textEvents reasoning_events=$reasoningEvents input=${usage?['prompt_tokens']} output=${usage?['completion_tokens']}',
        );
      }
    },
    skip: Platform.environment['RUN_AI_CODEX_APP_SERVER_LIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
