import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_settings_dialog.dart';
import 'package:video_player_app/widgets/ai_subtitle_api_dialog.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';

class _Secrets implements AiChatSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

const deepseek = AiSubtitleApiSettings(
  baseUrl: 'https://api.deepseek.com',
  apiKey: 'account-key',
  model: 'proofreader',
);

class _Transport extends AiChatTransport {
  @override
  Future<List<AiModelInfo>> fetchModels(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async => [const AiModelInfo(id: 'proofreader')];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Secrets secrets;
  late AiChatSettingsStore chat;
  late SubtitleAiConnectionStore registry;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = _Secrets();
    chat = AiChatSettingsStore(secretStorage: secrets);
    registry = SubtitleAiConnectionStore(secretStorage: secrets);
  });

  testWidgets(
    'the subtitle form fills only an exact saved endpoint and clears its autofill when the address changes',
    (tester) async {
      await tester.runAsync(
        () => chat.save(
          const AiChatSettings(apiKey: 'account-key', model: 'chat-model'),
        ),
      );
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final key = args['key'] as String;
            switch (call.method) {
              case 'read':
                return secrets.values[key];
              case 'write':
                secrets.values[key] = args['value'] as String;
                return null;
              case 'delete':
                secrets.values.remove(key);
                return null;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: AiSubtitleApiDialog(
            settings: AiSubtitleApiSettings(
              baseUrl: 'https://api.deepseek.com',
            ),
          ),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      final key = find.byKey(const ValueKey('subtitle-api-key'));
      expect(tester.widget<TextField>(key).controller!.text, 'account-key');
      await tester.enterText(
        find.byKey(const ValueKey('subtitle-api-url')),
        'https://other.example/v1',
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(key).controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a late shared-key read does not replace manual input or a manual clear',
    (tester) async {
      await tester.runAsync(
        () => chat.save(
          const AiChatSettings(apiKey: 'account-key', model: 'chat-model'),
        ),
      );
      final pending = Completer<String>();
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'read') return pending.future;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: AiSubtitleApiDialog(
            settings: AiSubtitleApiSettings(
              baseUrl: 'https://api.deepseek.com',
            ),
          ),
        ),
      );
      final key = find.byKey(const ValueKey('subtitle-api-key'));
      await tester.enterText(key, 'typed-key');
      await tester.enterText(key, '');
      pending.complete('account-key');
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(key).controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'chat provider selection displays the matching shared key and does not carry it to another provider',
    (tester) async {
      final settings = await tester.runAsync(() async {
        await chat.save(
          const AiChatSettings(
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'openai-key',
            model: 'chat-model',
          ),
        );
        await registry.save(
          const SubtitleAiConnection('proofreader', '校对', deepseek),
        );
        return chat.load();
      });
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: AiSettingsDialog(
            settings: settings!,
            transport: _Transport(),
            onSave: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('provider-openai')));
      await tester.tap(find.byKey(const ValueKey('provider-openai')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DeepSeek').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('ai-settings-key')),
            )
            .controller!
            .text,
        'account-key',
      );
      await tester.tap(find.byKey(const ValueKey('provider-deepseek')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('硅基流动').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('ai-settings-key')),
            )
            .controller!
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
