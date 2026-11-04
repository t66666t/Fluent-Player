import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/ai_chat/ai_chat_settings.dart';

/// One translation provider. Picking it fills the endpoint; the key and model
/// stay whatever the user last saved for this screen.
class AiSubtitleApiPreset {
  const AiSubtitleApiPreset(
    this.id,
    this.label,
    this.baseUrl, {
    this.protocol = AiApiProtocol.openAiCompatible,
  });

  final String id;
  final String label;
  final String baseUrl;
  final AiApiProtocol protocol;

  static const deepseek = AiSubtitleApiPreset(
    'deepseek',
    'DeepSeek',
    'https://api.deepseek.com',
  );
  static const openai = AiSubtitleApiPreset(
    'openai',
    'OpenAI',
    'https://api.openai.com/v1',
  );
  static const siliconflow = AiSubtitleApiPreset(
    'siliconflow',
    '硅基流动',
    'https://api.siliconflow.cn/v1',
  );
  static const ollama = AiSubtitleApiPreset(
    'ollama',
    'Ollama 本地',
    'http://localhost:11434/v1',
  );
  static const gemini = AiSubtitleApiPreset(
    'gemini',
    'Gemini',
    'https://generativelanguage.googleapis.com/v1beta',
    protocol: AiApiProtocol.gemini,
  );
  static const custom = AiSubtitleApiPreset('custom', '自定义', '');

  static const all = <AiSubtitleApiPreset>[
    deepseek,
    openai,
    siliconflow,
    ollama,
    gemini,
    custom,
  ];

  static AiSubtitleApiPreset byId(String id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return custom;
  }
}

/// Address, key and model remembered for one connection service.
///
/// Switching DeepSeek to OpenAI must not erase what was typed for DeepSeek.
/// The key stays out of [toJson] and is stored per provider.
class AiSubtitleApiProfile {
  const AiSubtitleApiProfile({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.models = const [],
  });

  final String baseUrl;
  final String apiKey;
  final String model;
  final List<String> models;

  AiSubtitleApiProfile copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    List<String>? models,
  }) => AiSubtitleApiProfile(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    models: models ?? this.models,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'baseUrl': baseUrl,
    'model': model,
    'models': models,
  };

  factory AiSubtitleApiProfile.fromJson(Map<String, dynamic> json) {
    final models = <String>[];
    if (json['models'] is List) {
      for (final value in json['models'] as List) {
        if (value is String && value.trim().isNotEmpty) models.add(value);
      }
    }
    return AiSubtitleApiProfile(
      baseUrl: json['baseUrl'] is String ? json['baseUrl'] as String : '',
      model: json['model'] is String ? json['model'] as String : '',
      models: models,
    );
  }
}

/// Endpoint used only by subtitle translation.
///
/// Chat keeps its own profiles. Saving here must not change that store, so a
/// translation model can differ from the conversation model.
///
/// [profiles] holds every connection service the user has filled in. The
/// top-level fields are the service currently selected.
class AiSubtitleApiSettings {
  const AiSubtitleApiSettings({
    this.providerId = 'custom',
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.models = const [],
    this.profiles = const {},
  });

  static const preferencesKey = 'subtitle_ai_api_v1';
  static const apiKeyStorageKey = 'subtitle_ai_api_key_v1';

  final String providerId;
  final String baseUrl;
  final String apiKey;
  final String model;

  /// Model ids last returned by a connection check. Not a second source of truth
  /// for the selected model; [model] is what translation actually calls.
  final List<String> models;

  /// Saved input for each connection service, including the active one.
  /// Keys are [AiSubtitleApiPreset.id].
  final Map<String, AiSubtitleApiProfile> profiles;

  static String profileKeyStorageKey(String providerId) =>
      '$apiKeyStorageKey:$providerId';

  bool get ready {
    final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    return model.trim().isNotEmpty && host.isNotEmpty;
  }

  AiApiProtocol get protocol {
    final preset = AiSubtitleApiPreset.byId(providerId);
    if (preset.id != AiSubtitleApiPreset.custom.id) return preset.protocol;
    final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    if (host == 'generativelanguage.googleapis.com') {
      return AiApiProtocol.gemini;
    }
    return AiApiProtocol.openAiCompatible;
  }

  /// Applies a provider and, for a known service, replaces the endpoint.
  /// Custom keeps the address the user typed.
  AiSubtitleApiSettings withProvider(String id) {
    final preset = AiSubtitleApiPreset.byId(id);
    if (preset.id == AiSubtitleApiPreset.custom.id) {
      return copyWith(providerId: preset.id);
    }
    return copyWith(providerId: preset.id, baseUrl: preset.baseUrl);
  }

  /// Returns this store with [providerId] active, restoring that service's
  /// saved address, key and model. A service that was never saved does not
  /// inherit the key currently on screen.
  AiSubtitleApiSettings selecting(String providerId) {
    final profile = profiles[providerId];
    if (profile != null) {
      return copyWith(
        providerId: providerId,
        baseUrl: profile.baseUrl,
        apiKey: profile.apiKey,
        model: profile.model,
        models: profile.models,
      );
    }
    final preset = withProvider(providerId);
    return preset.copyWith(apiKey: '', model: '', models: const []);
  }

  AiSubtitleApiSettings copyWith({
    String? providerId,
    String? baseUrl,
    String? apiKey,
    String? model,
    List<String>? models,
    Map<String, AiSubtitleApiProfile>? profiles,
  }) => AiSubtitleApiSettings(
    providerId: providerId ?? this.providerId,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    models: models ?? this.models,
    profiles: profiles ?? this.profiles,
  );

  AiSubtitleApiSettings normalized() {
    final url = _normalizeBaseUrl(baseUrl);
    final ids = <String>[];
    for (final id in models) {
      final trimmed = id.trim();
      if (trimmed.isEmpty || ids.contains(trimmed)) continue;
      ids.add(trimmed);
    }
    final selected = model.trim();
    if (selected.isNotEmpty && !ids.contains(selected)) {
      ids.insert(0, selected);
    }
    final resolvedId = _providerFor(url, protocol);
    final stored = <String, AiSubtitleApiProfile>{
      for (final entry in profiles.entries) entry.key: entry.value,
    };
    stored[resolvedId] = AiSubtitleApiProfile(
      baseUrl: url,
      apiKey: apiKey.trim(),
      model: selected,
      models: List.unmodifiable(ids),
    );
    return AiSubtitleApiSettings(
      providerId: resolvedId,
      baseUrl: url,
      apiKey: apiKey.trim(),
      model: selected,
      models: List.unmodifiable(ids),
      profiles: Map.unmodifiable(stored),
    );
  }

  /// Chat transport already knows how to call these protocols. Translation
  /// never inherits the chat backend, profile or prompts.
  AiChatSettings toChatSettings() {
    final current = normalized();
    return AiChatSettings(
      backend: AiBackend.api,
      apiProtocol: current.protocol,
      baseUrl: current.baseUrl,
      apiKey: current.apiKey,
      model: current.model,
      temperature: 0.2,
      thinkingEnabled: false,
      reasoningEffort: '',
      thinkingBudget: 0,
      savedModels: [for (final id in current.models) AiModelInfo(id: id)],
      modelCatalogBaseUrl: current.baseUrl,
      modelCatalogProtocol: current.protocol,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'providerId': providerId,
    'baseUrl': baseUrl,
    'model': model,
    'models': models,
    if (profiles.isNotEmpty)
      'profiles': <String, dynamic>{
        for (final entry in profiles.entries) entry.key: entry.value.toJson(),
      },
  };

  factory AiSubtitleApiSettings.fromJson(Map<String, dynamic> json) {
    final models = <String>[];
    if (json['models'] is List) {
      for (final value in json['models'] as List) {
        if (value is String && value.trim().isNotEmpty) models.add(value);
      }
    }
    final profiles = <String, AiSubtitleApiProfile>{};
    final rawProfiles = json['profiles'];
    if (rawProfiles is Map) {
      for (final entry in rawProfiles.entries) {
        final id = entry.key?.toString() ?? '';
        if (id.isEmpty || entry.value is! Map) continue;
        profiles[id] = AiSubtitleApiProfile.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
    }
    return AiSubtitleApiSettings(
      providerId: json['providerId'] is String
          ? json['providerId'] as String
          : AiSubtitleApiPreset.custom.id,
      baseUrl: json['baseUrl'] is String ? json['baseUrl'] as String : '',
      model: json['model'] is String ? json['model'] as String : '',
      models: models,
      profiles: profiles,
    ).normalized();
  }

  static String _normalizeBaseUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    if (!text.contains('://')) text = 'https://$text';
    return text.replaceFirst(RegExp(r'/+$'), '');
  }

  static String _providerFor(String baseUrl, AiApiProtocol protocol) {
    final url = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    for (final preset in AiSubtitleApiPreset.all) {
      if (preset.baseUrl.isEmpty) continue;
      final presetUrl = preset.baseUrl.replaceFirst(RegExp(r'/+$'), '');
      if (preset.protocol == protocol && url == presetUrl) return preset.id;
    }
    return AiSubtitleApiPreset.custom.id;
  }
}

class AiSubtitleApiSettingsStore {
  static final changes = ValueNotifier<int>(0);
  AiSubtitleApiSettingsStore({
    AiChatSecretStorage? secretStorage,
    Future<SharedPreferences> Function()? preferences,
    this.operationTimeout = const Duration(seconds: 8),
    Future<AiChatSettings> Function()? readChatSettings,
  }) : _secrets = secretStorage ?? PlatformAiChatSecretStorage(),
       _preferences = preferences ?? SharedPreferences.getInstance,
       _readChatSettings = readChatSettings;

  final AiChatSecretStorage _secrets;
  final Future<SharedPreferences> Function() _preferences;
  final Duration operationTimeout;

  /// Only used the first time translation has no saved endpoint, so an existing
  /// chat key can be copied once and then diverge.
  final Future<AiChatSettings> Function()? _readChatSettings;

  /// Identity shown beside language settings does not need credential access.
  Future<AiSubtitleApiSettings> loadMetadata() async {
    final preferences = await _preferences();
    final raw = preferences.getString(AiSubtitleApiSettings.preferencesKey);
    try {
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return AiSubtitleApiSettings.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      }
    } on FormatException {
      /* Empty metadata is an unconfigured interface. */
    }
    return const AiSubtitleApiSettings();
  }

  Future<AiSubtitleApiSettings> loadForSnapshot(
    AiSubtitleApiSettings snapshot,
  ) async {
    final saved = await load();
    final active = saved.selecting(snapshot.providerId);
    String address(String value) =>
        value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (address(active.baseUrl) != address(snapshot.baseUrl)) {
      throw StateError('翻译接口地址已更改，请重新开始以使用当前接口与语言设置');
    }
    return snapshot.copyWith(apiKey: active.apiKey);
  }

  Future<AiSubtitleApiSettings> load() async {
    final preferences = await _preferences();
    final raw = preferences.getString(AiSubtitleApiSettings.preferencesKey);
    if (raw == null || raw.isEmpty) {
      final seeded = await _seedFromChat(preferences);
      try {
        await save(seeded, notifyChanges: false);
      } catch (error) {
        debugPrint('[ai-subtitle-api] 初次保存翻译接口失败：$error');
      }
      return seeded;
    }
    AiSubtitleApiSettings settings = const AiSubtitleApiSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        settings = AiSubtitleApiSettings.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    } on FormatException {
      debugPrint('[ai-subtitle-api] 已忽略损坏的翻译接口');
    }
    final legacy = await _secrets
        .read(AiSubtitleApiSettings.apiKeyStorageKey)
        .timeout(operationTimeout);
    return _attachProfileKeys(settings, legacy);
  }

  Future<void> save(
    AiSubtitleApiSettings settings, {
    bool notifyChanges = true,
  }) async {
    final current = settings.normalized();
    for (final entry in current.profiles.entries) {
      await _writeSecret(
        AiSubtitleApiSettings.profileKeyStorageKey(entry.key),
        entry.value.apiKey,
      );
    }
    await _writeSecret(AiSubtitleApiSettings.apiKeyStorageKey, current.apiKey);
    final preferences = await _preferences();
    await preferences.setString(
      AiSubtitleApiSettings.preferencesKey,
      jsonEncode(current.copyWith(apiKey: '').toJson()),
    );
    if (notifyChanges) changes.value++;
  }

  /// Fills each saved service from its own secret. Older installs stored one
  /// key for whichever service was active; that key is used only when the
  /// per-service secret is still empty.
  Future<AiSubtitleApiSettings> _attachProfileKeys(
    AiSubtitleApiSettings settings,
    String? legacyKey,
  ) async {
    final loaded = <String, AiSubtitleApiProfile>{};
    for (final entry in settings.profiles.entries) {
      final stored = await _secrets
          .read(AiSubtitleApiSettings.profileKeyStorageKey(entry.key))
          .timeout(operationTimeout);
      final key = (stored != null && stored.isNotEmpty)
          ? stored
          : (entry.key == settings.providerId ? (legacyKey ?? '') : '');
      loaded[entry.key] = entry.value.copyWith(apiKey: key);
    }
    final active = loaded[settings.providerId]?.apiKey ?? legacyKey ?? '';
    return settings.copyWith(
      apiKey: active,
      profiles: Map<String, AiSubtitleApiProfile>.unmodifiable(loaded),
    );
  }

  Future<void> _writeSecret(String storageKey, String key) async {
    if (key.isEmpty) {
      await _secrets.delete(storageKey).timeout(operationTimeout);
      return;
    }
    await _secrets.write(storageKey, key).timeout(operationTimeout);
    final verified = await _secrets.read(storageKey).timeout(operationTimeout);
    if (verified != key) {
      throw StateError('翻译接口密钥未能安全保存，请重试。');
    }
  }

  Future<AiSubtitleApiSettings> _seedFromChat(
    SharedPreferences preferences,
  ) async {
    final chatRaw = preferences.getString(AiChatSettingsStore.preferencesKey);
    if (chatRaw == null || chatRaw.isEmpty) {
      return const AiSubtitleApiSettings();
    }
    try {
      final chat =
          await (_readChatSettings ??
              AiChatSettingsStore(
                secretStorage: _secrets,
                preferences: _preferences,
                operationTimeout: operationTimeout,
              ).load)();
      if (chat.backend != AiBackend.api) return const AiSubtitleApiSettings();
      final key = chat.apiKey.trim();
      final host = Uri.tryParse(chat.baseUrl.trim())?.host ?? '';
      final local = host == 'localhost' || host == '127.0.0.1';
      // Constructor defaults look configured but were never chosen for translation.
      if (key.isEmpty && !local) return const AiSubtitleApiSettings();
      if (chat.model.trim().isEmpty || host.isEmpty) {
        return const AiSubtitleApiSettings();
      }
      debugPrint('[ai-subtitle-api] 首次从已配置的对话接口复制翻译接口');
      return AiSubtitleApiSettings(
        baseUrl: chat.baseUrl,
        apiKey: key,
        model: chat.model,
        models: [for (final info in chat.savedModels) info.id],
      ).normalized();
    } catch (error) {
      debugPrint('[ai-subtitle-api] 未能读取对话接口，翻译接口保持空白：$error');
      return const AiSubtitleApiSettings();
    }
  }
}
