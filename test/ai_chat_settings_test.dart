import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';

class _MemorySecrets implements AiChatSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test(
    'legacy transcript defaults migrate while custom instructions are preserved',
    () {
      expect(
        AiChatSettings.fromJson({
          'transcriptPrompt': AiChatSettings.previousDefaultTranscriptPrompt,
        }).transcriptPrompt,
        AiChatSettings.defaultTranscriptPrompt,
      );
      expect(
        AiChatSettings.fromJson({
          'transcriptPrompt': '自定义整理方式',
        }).transcriptPrompt,
        '自定义整理方式',
      );
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'stores credentials only in secret storage and preserves prompt edits',
    () async {
      final secrets = _MemorySecrets();
      final store = AiChatSettingsStore(secretStorage: secrets);
      const settings = AiChatSettings(
        apiKey: 'private-test-secret',
        baseUrl: 'https://custom.example/v1',
        model: 'custom-chat',
        titlePrompt: 'custom title instruction',
        cliPrompt: 'custom CLI instruction',
        systemPrompt: 'custom system instruction',
        developerMode: true,
        thinkingEnabled: true,
        reasoningEffort: 'low',
        thinkingBudget: 2048,
      );
      await store.save(settings);
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(AiChatSettingsStore.preferencesKey)!;
      expect(raw, isNot(contains('private-test-secret')));
      expect(jsonDecode(raw), isNot(contains('apiKey')));
      expect(
        secrets.values[AiChatSettingsStore.apiKeyStorageKey],
        'private-test-secret',
      );
      final loaded = await store.load();
      expect(loaded.apiKey, settings.apiKey);
      expect(loaded.baseUrl, settings.baseUrl);
      expect(loaded.systemPrompt, settings.systemPrompt);
      expect(loaded.titlePrompt, settings.titlePrompt);
      expect(loaded.cliPrompt, settings.cliPrompt);
      expect(loaded.developerMode, isTrue);
      expect(loaded.thinkingEnabled, isTrue);
      expect(loaded.reasoningEffort, 'low');
      expect(loaded.thinkingBudget, 2048);
      await store.save(
        loaded.copyWith(apiKey: '', titlePrompt: '', cliPrompt: ''),
      );
      expect(secrets.values, isEmpty);
      expect((await store.load()).titlePrompt, isEmpty);
      expect((await store.load()).cliPrompt, isEmpty);
    },
  );

  test(
    'corrupt config and unknown values fall back without loading plaintext keys',
    () async {
      SharedPreferences.setMockInitialValues({
        AiChatSettingsStore.preferencesKey: '{broken',
      });
      final store = AiChatSettingsStore(secretStorage: _MemorySecrets());
      expect((await store.load()).contextTokens, 64000);
      final parsed = AiChatSettings.fromJson({
        'backend': 'unknown',
        'contextTokens': -1,
        'maxOutputTokens': 'oops',
        'temperature': double.nan,
        'apiKey': 'must-never-load',
      });
      expect(parsed.backend, AiBackend.api);
      expect(parsed.contextTokens, 64000);
      expect(parsed.maxOutputTokens, 8192);
      expect(parsed.temperature, 0.3);
      expect(parsed.apiKey, isEmpty);
      expect(parsed.titlePrompt, AiChatSettings.defaultTitlePrompt);
      expect(parsed.cliPrompt, AiChatSettings.defaultCliPrompt);
      expect(parsed.model, 'deepseek-flash');
      expect(parsed.thinkingEnabled, isTrue);
      expect(parsed.reasoningEffort, 'high');
      expect(parsed.apiProtocol, AiApiProtocol.openAiCompatible);
    },
  );

  test(
    'migrates only the complete old recommended tuple and preserves edits',
    () {
      final old = <String, dynamic>{
        'version': 1,
        'contextTokens': 16000,
        'maxOutputTokens': 4096,
        'temperature': 0.7,
        'thinkingEnabled': false,
        'model': 'my-custom-model',
        'baseUrl': 'https://custom.example/v1',
      };
      final migrated = AiChatSettings.fromJson(old);
      expect(migrated.contextTokens, 64000);
      expect(migrated.maxOutputTokens, 8192);
      expect(migrated.temperature, 0.3);
      expect(migrated.thinkingEnabled, isTrue);
      expect(migrated.model, 'my-custom-model');
      expect(migrated.baseUrl, 'https://custom.example/v1');
      for (final edit in [
        {'contextTokens': 32000},
        {'maxOutputTokens': 8192},
        {'temperature': 0.5},
        {'thinkingEnabled': true},
        {'version': 2},
      ]) {
        final configured = {...old, ...edit};
        final preserved = AiChatSettings.fromJson(configured);
        expect(preserved.contextTokens, configured['contextTokens']);
        expect(preserved.maxOutputTokens, configured['maxOutputTokens']);
        expect(preserved.temperature, configured['temperature']);
        expect(preserved.thinkingEnabled, configured['thinkingEnabled']);
      }
      expect(
        AiChatSettings.fromJson({'thinkingEnabled': false}).thinkingEnabled,
        isFalse,
      );
      expect(migrated.toJson()['version'], 3);
    },
  );

  test(
    'missing savings settings default off and explicit choices are preserved',
    () {
      final recommended = {
        'version': 2,
        'contextTokens': 64000,
        'maxOutputTokens': 16384,
        'thinkingEnabled': true,
        'reasoningEffort': 'high',
        'contextMode': 'automatic',
      };
      final migrated = AiChatSettings.fromJson(recommended);
      expect(migrated.maxOutputTokens, 8192);
      expect(migrated.optimizeTokens, isFalse);
      expect(migrated.fastSummaries, isFalse);
      expect(
        AiChatSettings.fromJson({
          'optimizeTokens': true,
          'fastSummaries': true,
        }).optimizeTokens,
        isTrue,
      );
      expect(
        AiChatSettings.fromJson({
          'optimizeTokens': true,
          'fastSummaries': true,
        }).fastSummaries,
        isTrue,
      );
      final custom = AiChatSettings.fromJson({
        ...recommended,
        'maxOutputTokens': 32768,
        'optimizeTokens': false,
      });
      expect(custom.maxOutputTokens, 32768);
      expect(custom.optimizeTokens, isFalse);
      final restored = AiChatSettings.fromJson(custom.toJson());
      expect(restored.maxOutputTokens, 32768);
      expect(restored.optimizeTokens, isFalse);
      expect(
        AiChatSettings.fromJson({...recommended, 'version': 3}).maxOutputTokens,
        16384,
      );
    },
  );

  test('each provider keeps its own key outside preferences', () async {
    final secrets = _MemorySecrets();
    final store = AiChatSettingsStore(secretStorage: secrets);
    const settings = AiChatSettings(
      apiProfileId: 'openai',
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'openai-secret',
      model: 'gpt-5.4',
      apiProfiles: {
        'deepseek': AiApiProfile(
          baseUrl: 'https://api.deepseek.com',
          model: 'deepseek-flash',
          apiKey: 'deepseek-secret',
        ),
        'openai': AiApiProfile(
          baseUrl: 'https://api.openai.com/v1',
          model: 'gpt-5.4',
          apiKey: 'openai-secret',
        ),
      },
    );
    await store.save(settings);
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(AiChatSettingsStore.preferencesKey)!;
    expect(raw, isNot(contains('openai-secret')));
    expect(raw, isNot(contains('deepseek-secret')));
    expect(raw, isNot(contains('apiKey')));
    final loaded = await store.load();
    expect(loaded.apiKey, 'openai-secret');
    expect(loaded.model, 'gpt-5.4');
    expect(loaded.apiProfiles['deepseek']!.apiKey, 'deepseek-secret');
    expect(loaded.apiProfiles['deepseek']!.model, 'deepseek-flash');
    expect(loaded.apiProfiles['openai']!.model, 'gpt-5.4');
    expect(loaded.resolvedApiProfileId, 'openai');
  });

  test(
    'a legacy single key is attached to the provider for that URL',
    () async {
      final secrets = _MemorySecrets()
        ..values[AiChatSettingsStore.apiKeyStorageKey] = 'legacy-openai';
      SharedPreferences.setMockInitialValues({
        AiChatSettingsStore.preferencesKey: jsonEncode({
          'version': 2,
          'baseUrl': 'https://api.openai.com/v1',
          'model': 'gpt-4o',
          'apiProtocol': 'openAiCompatible',
        }),
      });
      final loaded = await AiChatSettingsStore(secretStorage: secrets).load();
      expect(loaded.apiProfileId, 'openai');
      expect(loaded.apiKey, 'legacy-openai');
      expect(loaded.apiProfiles['openai']!.apiKey, 'legacy-openai');
      expect(loaded.apiProfiles['openai']!.model, 'gpt-4o');
      expect(loaded.toJson().toString(), isNot(contains('legacy-openai')));
    },
  );

  test(
    'model cache retains tri-state capabilities and scopes URL and protocol',
    () {
      const settings = AiChatSettings(
        apiProtocol: AiApiProtocol.gemini,
        baseUrl: 'https://native.example/v1beta',
        model: 'models/gemini-tested',
        modelCatalogBaseUrl: 'https://native.example/v1beta',
        modelCatalogProtocol: AiApiProtocol.gemini,
        savedModels: [
          AiModelInfo(
            id: 'gemini-tested',
            name: 'Gemini tested',
            contextWindow: 100000,
            maxOutputTokens: 20000,
            reasoningEfforts: ['low', 'high'],
            defaultReasoningEffort: 'high',
            supportsThinking: true,
            supportsReasoningEffort: true,
            supportsThinkingBudget: false,
            thinkingTypes: ['enabled'],
          ),
        ],
      );
      final loaded = AiChatSettings.fromJson(settings.toJson());
      expect(loaded.selectedModelInfo?.id, 'gemini-tested');
      expect(loaded.selectedModelInfo?.canDisableThinking, isFalse);
      expect(loaded.selectedModelInfo?.supportsThinkingBudget, isFalse);
      expect(loaded.selectedModelInfo?.reasoningEfforts, ['low', 'high']);
      expect(
        loaded.copyWith(baseUrl: 'https://other.example').selectedModelInfo,
        isNull,
      );
      expect(
        loaded.copyWith(apiProtocol: AiApiProtocol.anthropic).selectedModelInfo,
        isNull,
      );
      expect(
        loaded.copyWith(backend: AiBackend.codex).selectedModelInfo,
        isNull,
      );
      final unknown = AiModelInfo.fromJson({'id': 'custom-id'});
      expect(unknown.supportsThinking, isNull);
      expect(unknown.supportsReasoningEffort, isNull);
      expect(unknown.canDisableThinking, isNull);
      final denied = AiModelInfo.fromJson({
        'id': 'plain',
        'supports_thinking': false,
        'supports_reasoning_effort': false,
      });
      expect(denied.supportsThinking, isFalse);
      expect(denied.supportsReasoningEffort, isFalse);
    },
  );
}
