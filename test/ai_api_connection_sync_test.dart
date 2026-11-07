import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/ai_api_connection_sync.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Secrets secrets;
  late AiChatSettingsStore chat;
  late AiSubtitleApiSettingsStore subtitles;
  late SubtitleAiConnectionStore registry;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = _Secrets();
    chat = AiChatSettingsStore(secretStorage: secrets);
    subtitles = AiSubtitleApiSettingsStore(secretStorage: secrets);
    registry = SubtitleAiConnectionStore(secretStorage: secrets);
  });

  test(
    'a subtitle connection fills the matching chat provider without changing chat prompts or model',
    () async {
      await registry.save(
        const SubtitleAiConnection('proofreader', '校对', deepseek),
      );
      final value = await chat.load();
      expect(value.apiKey, 'account-key');
      expect(value.apiProfiles['deepseek']!.apiKey, 'account-key');
      expect(value.model, const AiChatSettings().model);
      expect(value.systemPrompt, const AiChatSettings().systemPrompt);
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect(prefs.get(key).toString(), isNot(contains('account-key')));
      }
    },
  );

  test(
    'a chat provider saved before any key was entered receives its first shared key',
    () async {
      await chat.save(const AiChatSettings(model: 'chat-model'));
      await registry.save(
        const SubtitleAiConnection('proofreader', '校对', deepseek),
      );
      expect((await chat.load()).apiKey, 'account-key');
      expect((await chat.load()).model, 'chat-model');
    },
  );

  test(
    'chat connections appear in the subtitle picker with their credentials',
    () async {
      await chat.save(
        const AiChatSettings(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'account-key',
          model: 'chat-model',
        ),
      );
      final entries = await registry.load();
      final entry = entries.firstWhere(
        (e) => e.endpoint.baseUrl == deepseek.baseUrl,
      );
      expect((await registry.endpoint(entry.id)).apiKey, 'account-key');
      expect(
        (await registry.endpoint(entry.id, withKey: false)).apiKey,
        isEmpty,
      );
      expect((await chat.load()).model, 'chat-model');
    },
  );

  test(
    'linked keys rotate in either direction while models and prompts stay independent',
    () async {
      await subtitles.save(deepseek.copyWith(model: 'translation-model'));
      await chat.save(
        const AiChatSettings(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'account-key',
          model: 'chat-model',
          systemPrompt: '保留对话提示词',
        ),
      );
      await chat.save((await chat.load()).copyWith(apiKey: 'rotated-chat'));
      expect((await subtitles.load()).apiKey, 'rotated-chat');
      expect((await subtitles.load()).model, 'translation-model');
      await subtitles.save(
        (await subtitles.load()).copyWith(apiKey: 'rotated-subtitles'),
      );
      final value = await chat.load();
      expect(value.apiKey, 'rotated-subtitles');
      expect(value.model, 'chat-model');
      expect(value.systemPrompt, '保留对话提示词');
    },
  );

  test(
    'clearing a linked key does not resurrect an old key on reload',
    () async {
      await subtitles.save(deepseek);
      final loaded = await chat.load();
      await chat.save(loaded.copyWith(apiKey: ''));
      expect((await subtitles.load()).apiKey, isEmpty);
      expect((await chat.load()).apiKey, isEmpty);
      expect((await subtitles.load()).apiKey, isEmpty);
    },
  );

  test(
    'different accounts on the same endpoint are not overwritten or guessed',
    () async {
      await chat.save(
        const AiChatSettings(apiKey: 'chat-account', model: 'chat-model'),
      );
      await registry.save(
        SubtitleAiConnection(
          'other-account',
          '另一个账号',
          deepseek.copyWith(apiKey: 'subtitle-account'),
        ),
      );
      expect((await chat.load()).apiKey, 'chat-account');
      expect(
        (await registry.endpoint('other-account')).apiKey,
        'subtitle-account',
      );
      expect(
        await subtitles.sharedConnectionFor(deepseek.copyWith(apiKey: '')),
        isNull,
      );
    },
  );

  test(
    'selecting another named account does not rotate the original chat account',
    () async {
      await chat.save(
        const AiChatSettings(apiKey: 'chat-account', model: 'chat-model'),
      );
      await registry.save(
        SubtitleAiConnection(
          'other-account',
          '另一个账号',
          deepseek.copyWith(apiKey: 'subtitle-account'),
        ),
      );
      await subtitles.save(await registry.endpoint('other-account'));
      expect((await subtitles.load()).apiKey, 'subtitle-account');
      expect((await chat.load()).apiKey, 'chat-account');
    },
  );

  test(
    'different custom endpoints keep independent credentials and active selections',
    () async {
      await subtitles.save(
        deepseek.copyWith(
          baseUrl: 'https://subtitles.example/v1',
          apiKey: 'subtitle-key',
        ),
      );
      await chat.save(
        const AiChatSettings(
          baseUrl: 'https://chat.example/v1',
          apiKey: 'chat-key',
          model: 'chat-model',
        ),
      );
      expect((await chat.load()).baseUrl, 'https://chat.example/v1');
      expect((await chat.load()).apiKey, 'chat-key');
      expect((await subtitles.load()).baseUrl, 'https://subtitles.example/v1');
      expect((await subtitles.load()).apiKey, 'subtitle-key');
    },
  );

  test(
    'sharing an inactive provider never switches the current chat provider',
    () async {
      await chat.save(
        const AiChatSettings(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'openai-key',
          model: 'conversation-model',
        ),
      );
      await registry.save(
        const SubtitleAiConnection('proofreader', '校对', deepseek),
      );
      final value = await chat.load();
      expect(value.resolvedApiProfileId, 'openai');
      expect(value.apiKey, 'openai-key');
      expect(value.model, 'conversation-model');
      expect(value.apiProfiles['deepseek']!.apiKey, 'account-key');
    },
  );

  test(
    'a copied optimization configuration rotates the same linked key without changing model selections',
    () async {
      await chat.save(
        const AiChatSettings(apiKey: 'account-key', model: 'chat-model'),
      );
      await registry.save(const SubtitleAiConnection('old', '旧优化', deepseek));
      final previous = await registry.endpoint('old');
      await registry.save(
        SubtitleAiConnection(
          'new',
          '新优化',
          previous.copyWith(apiKey: 'rotated-key', model: 'new-model'),
        ),
        previousEndpoint: previous,
      );
      expect((await chat.load()).apiKey, 'rotated-key');
      expect((await chat.load()).model, 'chat-model');
      expect((await registry.endpoint('old')).model, 'proofreader');
      expect((await registry.endpoint('new')).model, 'new-model');
    },
  );

  for (final equalKeys in [false, true]) {
    test(
      'legacy stores migrate once without joining different accounts; equal=$equalKeys',
      () async {
        SharedPreferences.setMockInitialValues({
          AiChatSettingsStore.preferencesKey: jsonEncode(
            const AiChatSettings(
              apiProfileId: 'deepseek',
              model: 'chat-model',
              apiProfiles: {
                'deepseek': AiApiProfile(
                  baseUrl: 'https://api.deepseek.com',
                  model: 'chat-model',
                ),
              },
            ).toJson(),
          ),
          SubtitleAiConnectionStore.preferencesKey: jsonEncode([
            const SubtitleAiConnection('legacy', '旧接口', deepseek).toJson(),
          ]),
        });
        secrets.values[AiChatSettingsStore.apiKeyStorageKey] = 'account-key';
        secrets.values[AiChatSettingsStore.apiKeysStorageKey] = jsonEncode({
          'deepseek': 'account-key',
        });
        secrets.values[SubtitleAiConnectionStore.secretKey('legacy')] =
            equalKeys ? 'account-key' : 'another-key';
        await chat.save((await chat.load()).copyWith(apiKey: 'new-key'));
        expect(
          (await registry.endpoint('legacy')).apiKey,
          equalKeys ? 'new-key' : 'another-key',
        );
      },
    );
  }

  test(
    'pre-profile chat credentials share a rotation initiated by subtitles',
    () async {
      final oldChat = const AiChatSettings(model: 'chat-model').toJson()
        ..remove('apiProfileId')
        ..remove('apiProfiles');
      SharedPreferences.setMockInitialValues({
        AiChatSettingsStore.preferencesKey: jsonEncode(oldChat),
        SubtitleAiConnectionStore.preferencesKey: jsonEncode([
          const SubtitleAiConnection('legacy', '旧接口', deepseek).toJson(),
        ]),
      });
      secrets.values[AiChatSettingsStore.apiKeyStorageKey] = 'account-key';
      secrets.values[SubtitleAiConnectionStore.secretKey('legacy')] =
          'account-key';
      await registry.save(
        SubtitleAiConnection(
          'legacy',
          '旧接口',
          deepseek.copyWith(apiKey: 'new-key'),
        ),
      );
      expect((await chat.load()).apiKey, 'new-key');
      expect((await chat.load()).model, 'chat-model');
    },
  );

  test(
    'a virtual chat entry resolves the selected account even when endpoint keys are ambiguous',
    () async {
      SharedPreferences.setMockInitialValues({
        SubtitleAiConnectionStore.preferencesKey: '[]',
      });
      await chat.save(
        const AiChatSettings(apiKey: 'chat-key', model: 'chat-model'),
      );
      await registry.save(
        SubtitleAiConnection(
          'other',
          '其他账号',
          deepseek.copyWith(apiKey: 'other-key'),
        ),
      );
      final entries = await registry.load();
      final fromChat = entries.firstWhere(
        (entry) => entry.id.startsWith('shared-'),
      );
      expect((await registry.endpoint(fromChat.id)).apiKey, 'chat-key');
      expect((await registry.endpoint('other')).apiKey, 'other-key');
    },
  );

  test(
    'endpoint identity is strict about path, port, scheme and protocol',
    () async {
      final sync = AiApiConnectionSync(
        preferences: SharedPreferences.getInstance,
        readSecret: secrets.read,
        writeSecret: secrets.write,
        deleteSecret: secrets.delete,
      );
      await sync.publish(
        owner: 'test',
        baseUrl: 'https://service.example/v1',
        protocol: 'openAiCompatible',
        apiKey: 'protected-key',
        model: 'model',
        models: [],
      );
      expect(
        (await sync.findUnique(
          'https://SERVICE.example/v1/',
          'openAiCompatible',
        ))!.apiKey,
        'protected-key',
      );
      for (final url in [
        'http://service.example/v1',
        'https://service.example:8443/v1',
        'https://service.example/v2',
        'https://service.example/v1/other',
        'https://other.example/v1',
        'https://service.example/v1?tenant=other',
        'https://user@service.example/v1',
      ]) {
        expect(
          await sync.findUnique(url, 'openAiCompatible'),
          isNull,
          reason: url,
        );
      }
      expect(
        await sync.findUnique('https://service.example/v1', 'gemini'),
        isNull,
      );
      expect(
        await sync.findUnique('https://service.example/v1', 'anthropic'),
        isNull,
      );
    },
  );

  test(
    'an already-open chat refreshes matching connection credentials without changing its model',
    () async {
      await chat.save(
        const AiChatSettings(apiKey: 'account-key', model: 'chat-model'),
      );
      await registry.save(
        const SubtitleAiConnection('proofreader', '校对', deepseek),
      );
      final controller = AiChatController(
        video: VideoItem(
          id: 'local',
          path: 'local.mp4',
          title: '本地视频',
          durationMs: 0,
          lastUpdated: 0,
        ),
        settingsStore: chat,
        initialSettings: await chat.load(),
      );
      addTearDown(controller.dispose);
      controller.ready = true;
      final updated = Completer<void>();
      controller.addListener(() {
        if (controller.settings.apiKey == 'live-key' && !updated.isCompleted) {
          updated.complete();
        }
      });
      await registry.save(
        SubtitleAiConnection(
          'proofreader',
          '校对',
          deepseek.copyWith(apiKey: 'live-key'),
        ),
      );
      await updated.future.timeout(const Duration(seconds: 3));
      expect(controller.settings.model, 'chat-model');
      await controller.refreshApiConnections();
    },
  );
}
