import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/services/network/network_http.dart';

/// Explicit opt-in: reuses the user's local CLI login and sends one tiny turn.
/// Normal CI and the verification script never make a paid model request.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('AI_LIVE_CODEX');
  test(
    'local Codex directory, login, catalog and real connection',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'ai_live_network_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => directory.path,
      );
      // Unit tests do not load the Windows proxy plugin. Exercise the real
      // application bridge with the system's DIRECT route explicitly supplied.
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.example.video_player_app/network'),
        (call) async => call.method == 'resolveProxy' ? ['DIRECT'] : null,
      );
      addTearDown(() async {
        await NetworkHttp.instance.dispose();
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/network'),
          null,
        );
        await directory.delete(recursive: true);
      });
      final transport = AiChatTransport(
        connectionTimeout: const Duration(seconds: 45),
        idleTimeout: const Duration(seconds: 60),
        processTimeout: const Duration(seconds: 90),
      );
      var settings = AiChatSettings(
        backend: AiBackend.codex,
        executablePath: Platform.environment['AI_CODEX_PATH'] ?? '',
        model: '',
      );
      final status = await transport.inspectCli(settings);
      expect(status.loggedIn, isTrue);
      expect(status.executablePath.toLowerCase(), endsWith('codex.exe'));
      settings = settings.copyWith(executablePath: status.executablePath);
      final models = await transport.fetchModels(settings);
      expect(models, isNotEmpty);
      // Prefer a catalog-listed stable Codex model for this transport smoke test.
      // Never claim all catalog entries are authorized for the account.
      final selected = models.firstWhere(
        (model) => model.id == 'gpt-5.5',
        orElse: () => models.first,
      );
      settings = settings.copyWith(
        model: selected.id,
        cliProfiles: {
          'codex': AiCliProfile(
            executablePath: status.executablePath,
            model: selected.id,
            models: models,
          ),
        },
      );
      final reply = await transport.testConnection(settings);
      expect(reply, contains('连接成功'));
      // These are non-secret verification facts; account identifiers are omitted.
      stdout.writeln(
        '${status.version}; login=ok; catalog=${models.length}; tested=${selected.id}; $reply',
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
