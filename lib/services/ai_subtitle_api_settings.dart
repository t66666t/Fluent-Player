import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/ai_chat/ai_chat_settings.dart';
import 'ai_api_connection_sync.dart';

AiApiConnectionSync _sharedConnections(
  AiChatSecretStorage secrets,
  Future<SharedPreferences> Function() preferences,
  Duration timeout,
) => AiApiConnectionSync(
  chatProfileId: (url, protocol) => aiApiProfileId(
    url,
    AiApiProtocol.values.firstWhere(
      (p) => p.name == protocol,
      orElse: () => AiApiProtocol.openAiCompatible,
    ),
  ),
  preferences: preferences,
  readSecret: (key) => secrets.read(key).timeout(timeout),
  writeSecret: (key, value) => secrets.write(key, value).timeout(timeout),
  deleteSecret: (key) => secrets.delete(key).timeout(timeout),
);

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
/// Equal API connections share credentials with chat. Model selection and
/// prompts remain specific to each workflow.
///
/// [profiles] holds every connection service the user has filled in. The
/// top-level fields are the service currently selected.
class AiSubtitleApiSettings {
  const AiSubtitleApiSettings({
    this.connectionId = '',
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
  final String connectionId;
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
    String? connectionId,
    String? providerId,
    String? baseUrl,
    String? apiKey,
    String? model,
    List<String>? models,
    Map<String, AiSubtitleApiProfile>? profiles,
  }) => AiSubtitleApiSettings(
    connectionId: connectionId ?? this.connectionId,
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
      connectionId: connectionId,
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
    if (connectionId.isNotEmpty) 'connectionId': connectionId,
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
      connectionId: json['connectionId'] as String? ?? '',
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

  AiApiConnectionSync get _connections =>
      _sharedConnections(_secrets, _preferences, operationTimeout);

  Future<AiSubtitleApiSettings?> sharedConnectionFor(
    AiSubtitleApiSettings draft,
  ) async {
    final value = await _connections.findUnique(
      draft.baseUrl,
      draft.protocol.name,
    );
    if (value == null) return null;
    return draft.copyWith(
      apiKey: value.apiKey,
      model: draft.model.isEmpty ? value.model : draft.model,
      models: draft.models.isEmpty ? value.models : draft.models,
    );
  }

  Future<AiSubtitleApiSettings> _withSharedConnections(
    AiSubtitleApiSettings settings,
  ) async {
    final sync = _connections;
    await sync.prepare();
    final current = settings.normalized();
    final profiles = {...current.profiles};
    for (final id in profiles.keys.toList()) {
      final profile = profiles[id]!;
      final endpoint = AiSubtitleApiSettings(
        providerId: id,
        baseUrl: profile.baseUrl,
      );
      final shared = await sync.resolve(
        owner: 'subtitle-profile:$id',
        baseUrl: profile.baseUrl,
        protocol: endpoint.protocol.name,
        apiKey: profile.apiKey,
        model: profile.model,
        models: profile.models,
      );
      if (shared != null) {
        profiles[id] = profile.copyWith(
          apiKey: shared.apiKey,
          model: profile.model.isEmpty ? shared.model : profile.model,
          models: profile.models.isEmpty ? shared.models : profile.models,
        );
      }
    }
    final available = await sync.metadata();
    for (final row in available) {
      final endpoint = AiSubtitleApiSettings(
        baseUrl: row.baseUrl,
        model: row.model,
        models: row.models,
      ).normalized();
      if (endpoint.protocol.name != row.protocol ||
          profiles.containsKey(endpoint.providerId)) {
        continue;
      }
      if (available.where((r) => r.identity == row.identity).length != 1) {
        continue;
      }
      if (endpoint.providerId == 'custom' &&
          available
                  .where(
                    (r) =>
                        AiSubtitleApiSettings(
                          baseUrl: r.baseUrl,
                        ).normalized().providerId ==
                        'custom',
                  )
                  .map((r) => r.identity)
                  .toSet()
                  .length !=
              1) {
        continue;
      }
      final shared = await sync.resolve(
        owner: 'subtitle-profile:${endpoint.providerId}',
        baseUrl: row.baseUrl,
        protocol: row.protocol,
        apiKey: '',
      );
      if (shared != null) {
        profiles[endpoint.providerId] = AiSubtitleApiProfile(
          baseUrl: row.baseUrl,
          apiKey: shared.apiKey,
          model: shared.model,
          models: shared.models,
        );
      }
    }
    final active = profiles[current.providerId]!;
    return current.copyWith(
      apiKey: active.apiKey,
      model: active.model,
      models: active.models,
      profiles: Map.unmodifiable(profiles),
    );
  }

  /// Seeds the initial subtitle endpoint from chat. Subsequent credential edits
  /// use the shared connection store while model choices stay independent.
  final Future<AiChatSettings> Function()? _readChatSettings;

  /// Identity shown beside language settings does not need credential access.
  Future<AiSubtitleApiSettings> loadMetadata() async {
    final preferences = await _preferences();
    final raw = preferences.getString(AiSubtitleApiSettings.preferencesKey);
    try {
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final saved = AiSubtitleApiSettings.fromJson(
            Map<String, dynamic>.from(decoded),
          );
          if (saved.connectionId.isEmpty) return saved;
          return SubtitleAiConnectionStore(
            secretStorage: _secrets,
            preferences: _preferences,
          ).endpoint(saved.connectionId, withKey: false);
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
    if (snapshot.connectionId.isNotEmpty) {
      return SubtitleAiConnectionStore(
        secretStorage: _secrets,
        preferences: _preferences,
      ).resolve(snapshot);
    }
    final prefs = await _preferences();
    if (prefs.containsKey(SubtitleAiConnectionStore.preferencesKey)) {
      final registry = SubtitleAiConnectionStore(
        secretStorage: _secrets,
        preferences: _preferences,
      );
      final legacyId = 'legacy-${snapshot.providerId}';
      final candidates = await registry.load();
      if (candidates.any(
        (item) =>
            item.id == legacyId && item.endpoint.baseUrl == snapshot.baseUrl,
      )) {
        final original = await registry.endpoint(legacyId);
        return snapshot.copyWith(apiKey: original.apiKey);
      }
    }
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
      return _withSharedConnections(seeded);
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
    if (settings.connectionId.isNotEmpty) {
      return SubtitleAiConnectionStore(
        secretStorage: _secrets,
        preferences: _preferences,
      ).endpoint(settings.connectionId);
    }
    final legacy = await _secrets
        .read(AiSubtitleApiSettings.apiKeyStorageKey)
        .timeout(operationTimeout);
    return _withSharedConnections(await _attachProfileKeys(settings, legacy));
  }

  Future<void> save(
    AiSubtitleApiSettings settings, {
    bool notifyChanges = true,
  }) async {
    await _connections.prepare();
    // Keep pre-registry profiles/keys for queued jobs with legacy snapshots.
    final previous = settings.connectionId.isEmpty ? null : await load();
    var current = settings
        .copyWith(
          profiles: {
            if (previous != null) ...previous.profiles,
            ...settings.profiles,
          },
        )
        .normalized();
    if (current.connectionId.isEmpty) {
      final profiles = {...current.profiles};
      final prefs = await _preferences();
      AiSubtitleApiSettings? native;
      try {
        final raw = prefs.getString(AiSubtitleApiSettings.preferencesKey);
        if (raw != null) {
          native = AiSubtitleApiSettings.fromJson(
            Map<String, dynamic>.from(jsonDecode(raw) as Map),
          );
        }
      } on FormatException {
        /* Native save repairs the malformed value. */
      }
      for (final entry in profiles.entries.toList()) {
        final value = entry.value;
        if (entry.key == current.providerId || value.apiKey.isEmpty) continue;
        final old = native?.profiles[entry.key];
        final oldKey =
            await _secrets
                .read(AiSubtitleApiSettings.profileKeyStorageKey(entry.key))
                .timeout(operationTimeout) ??
            (entry.key == native?.providerId
                ? await _secrets
                      .read(AiSubtitleApiSettings.apiKeyStorageKey)
                      .timeout(operationTimeout)
                : '') ??
            '';
        final endpoint = AiSubtitleApiSettings(
          providerId: entry.key,
          baseUrl: value.baseUrl,
        );
        final identity = aiApiConnectionIdentity(
          value.baseUrl,
          endpoint.protocol.name,
        );
        if (value.apiKey == oldKey &&
            identity != null &&
            identity ==
                aiApiConnectionIdentity(
                  old?.baseUrl ?? '',
                  endpoint.protocol.name,
                )) {
          final shared = await _connections.resolve(
            owner: 'subtitle-profile:${entry.key}',
            baseUrl: value.baseUrl,
            protocol: endpoint.protocol.name,
            apiKey: value.apiKey,
          );
          if (shared != null) {
            profiles[entry.key] = value.copyWith(apiKey: shared.apiKey);
          }
        }
      }
      current = current.copyWith(
        profiles: profiles,
        apiKey: profiles[current.providerId]!.apiKey,
      );
    }
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
    if (current.connectionId.isEmpty) {
      for (final entry in current.profiles.entries) {
        final value = entry.value;
        await _connections.publish(
          owner: 'subtitle-profile:${entry.key}',
          baseUrl: value.baseUrl,
          protocol: AiSubtitleApiSettings(
            providerId: entry.key,
            baseUrl: value.baseUrl,
          ).protocol.name,
          apiKey: value.apiKey,
          model: value.model,
          models: value.models,
        );
      }
    }
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

/// Named connections shared by subtitle optimization and translation. Bindings
/// carry an ID and a credential-free snapshot; keys stay in secure storage.
class SubtitleAiConnection {
  const SubtitleAiConnection(this.id, this.name, this.endpoint);
  final String id, name;
  final AiSubtitleApiSettings endpoint;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'endpoint': endpoint.copyWith(apiKey: '', profiles: const {}).toJson(),
  };
}

class SubtitleAiConnectionStore {
  SubtitleAiConnectionStore({
    AiChatSecretStorage? secretStorage,
    Future<SharedPreferences> Function()? preferences,
  }) : _secrets = secretStorage ?? PlatformAiChatSecretStorage(),
       _preferences = preferences ?? SharedPreferences.getInstance;

  static const preferencesKey = 'subtitle_ai_connections_v1';
  static final changes = ValueNotifier<int>(0);
  final AiChatSecretStorage _secrets;
  final Future<SharedPreferences> Function() _preferences;
  static String secretKey(String id) => 'subtitle_ai_connection_key_v1:$id';
  static Future<void> _writes = Future<void>.value();
  AiApiConnectionSync get _connections =>
      _sharedConnections(_secrets, _preferences, const Duration(seconds: 8));

  Future<List<SubtitleAiConnection>> load() async {
    final prefs = await _preferences();
    final raw = prefs.getString(preferencesKey);
    if (raw == null) {
      final legacy = await AiSubtitleApiSettingsStore(
        secretStorage: _secrets,
        preferences: _preferences,
      ).load();
      final migrated = <SubtitleAiConnection>[
        for (final entry in legacy.profiles.entries)
          if (entry.value.baseUrl.isNotEmpty && entry.value.model.isNotEmpty)
            SubtitleAiConnection(
              'legacy-${entry.key}',
              AiSubtitleApiPreset.byId(entry.key).label,
              AiSubtitleApiSettings(
                connectionId: 'legacy-${entry.key}',
                providerId: entry.key,
                baseUrl: entry.value.baseUrl,
                model: entry.value.model,
                models: entry.value.models,
                apiKey: entry.value.apiKey,
              ),
            ),
      ];
      // Migration is serialized with edits and rechecks the persisted marker.
      await _serial(() async {
        if (prefs.containsKey(preferencesKey)) return;
        for (final item in migrated) {
          await _saveKey(item.id, item.endpoint.apiKey);
        }
        await prefs.setString(
          preferencesKey,
          jsonEncode(migrated.map((item) => item.toJson()).toList()),
        );
      });
      return load();
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('字幕接口列表损坏');
    final entries = [
      for (final item in decoded.whereType<Map>())
        SubtitleAiConnection(
          item['id'] as String,
          item['name'] as String,
          AiSubtitleApiSettings.fromJson(
            Map<String, dynamic>.from(item['endpoint'] as Map),
          ).copyWith(connectionId: item['id'] as String, profiles: const {}),
        ),
    ];
    for (final row in await _connections.metadata()) {
      if (!row.owners.any((owner) => owner.startsWith('chat:'))) continue;
      final endpoint = AiSubtitleApiSettings(
        baseUrl: row.baseUrl,
        model: row.model,
        models: row.models,
      ).normalized();
      if (!endpoint.ready || endpoint.protocol.name != row.protocol) continue;
      if (entries.any(
        (entry) =>
            row.owners.contains('subtitle:${entry.id}') ||
            entry.id == 'legacy-${entry.endpoint.providerId}' &&
                row.owners.contains(
                  'subtitle-profile:${entry.endpoint.providerId}',
                ),
      )) {
        continue;
      }
      final id = 'shared-${row.id}';
      if (entries.any((entry) => entry.id == id)) continue;
      entries.add(
        SubtitleAiConnection(
          id,
          '${row.model} · ${Uri.tryParse(row.baseUrl)?.host ?? ''}（AI 对话）',
          endpoint.copyWith(connectionId: id, profiles: const {}),
        ),
      );
    }
    return entries;
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> save(
    SubtitleAiConnection connection, {
    AiSubtitleApiSettings? previousEndpoint,
  }) async {
    await _connections.prepare();
    if (previousEndpoint != null &&
        aiApiConnectionIdentity(
              previousEndpoint.baseUrl,
              previousEndpoint.protocol.name,
            ) ==
            aiApiConnectionIdentity(
              connection.endpoint.baseUrl,
              connection.endpoint.protocol.name,
            )) {
      await _connections.resolve(
        owner: 'subtitle:${connection.id}',
        baseUrl: previousEndpoint.baseUrl,
        protocol: previousEndpoint.protocol.name,
        apiKey: previousEndpoint.apiKey,
        model: previousEndpoint.model,
        models: previousEndpoint.models,
      );
    }
    await load();
    await _serial(() async {
      final entries = await load();
      final updated = SubtitleAiConnection(
        connection.id,
        connection.name.trim().isEmpty
            ? connection.endpoint.model
            : connection.name.trim(),
        connection.endpoint.normalized().copyWith(
          connectionId: connection.id,
          profiles: const {},
        ),
      );
      await _saveKey(updated.id, updated.endpoint.apiKey);
      final index = entries.indexWhere((item) => item.id == updated.id);
      if (index < 0) {
        entries.add(updated);
      } else {
        entries[index] = updated;
      }
      final prefs = await _preferences();
      await prefs.setString(
        preferencesKey,
        jsonEncode(entries.map((item) => item.toJson()).toList()),
      );
      await _connections.publish(
        owner: 'subtitle:${updated.id}',
        baseUrl: updated.endpoint.baseUrl,
        protocol: updated.endpoint.protocol.name,
        apiKey: updated.endpoint.apiKey,
        model: updated.endpoint.model,
        models: updated.endpoint.models,
      );
      changes.value++;
      AiSubtitleApiSettingsStore.changes.value++;
    });
  }

  Future<void> _saveKey(String id, String key) async {
    // An empty key is valid for a local endpoint and explicitly clears its key.
    if (key.isEmpty) {
      await _secrets.delete(secretKey(id)).timeout(const Duration(seconds: 8));
    } else {
      await _secrets
          .write(secretKey(id), key)
          .timeout(const Duration(seconds: 8));
      if (await _secrets
              .read(secretKey(id))
              .timeout(const Duration(seconds: 8)) !=
          key) {
        throw StateError('字幕接口密钥未能安全保存');
      }
    }
  }

  Future<AiSubtitleApiSettings> endpoint(
    String id, {
    bool withKey = true,
  }) async {
    final items = await load();
    final item = items.where((item) => item.id == id).firstOrNull;
    if (item == null) throw StateError('字幕接口已不存在，请重新选择接口');
    var key = withKey
        ? await _secrets
                  .read(secretKey(id))
                  .timeout(const Duration(seconds: 8)) ??
              ''
        : '';
    if (withKey) {
      final shared = await _connections.resolve(
        owner: 'subtitle:$id',
        baseUrl: item.endpoint.baseUrl,
        protocol: item.endpoint.protocol.name,
        apiKey: key,
        model: item.endpoint.model,
        models: item.endpoint.models,
        sourceId: id.startsWith('shared-')
            ? id.substring('shared-'.length)
            : null,
      );
      key = shared?.apiKey ?? key;
    }
    return item.endpoint.copyWith(apiKey: key, profiles: const {});
  }

  Future<AiSubtitleApiSettings> resolve(AiSubtitleApiSettings snapshot) async {
    final current = await endpoint(snapshot.connectionId);
    if (current.baseUrl != snapshot.baseUrl ||
        current.protocol != snapshot.protocol) {
      throw StateError('字幕接口地址已更改，请重新开始以使用当前接口');
    }
    return snapshot.copyWith(apiKey: current.apiKey, profiles: const {});
  }
}
