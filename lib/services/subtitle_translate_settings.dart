import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_subtitle_api_settings.dart';
import 'ai_subtitle_translator.dart';
import 'subtitle_translation_service.dart';
export 'subtitle_translation_policy.dart';
import '../features/model_center/model_catalog.dart';
import '../features/model_center/model_center_service.dart';
import '../features/model_center/local_subtitle_translator.dart';

/// Reads the shared settings when the app has provided them.
///
/// Widget tests that pump a screen alone do not register this store.
SubtitleTranslateSettings? lookupSubtitleTranslateSettings(
  BuildContext context, {
  bool listen = true,
}) {
  try {
    return Provider.of<SubtitleTranslateSettings>(context, listen: listen);
  } on ProviderNotFoundException {
    return null;
  }
}

/// Where a transcript should be translated. Kept off the batch toolbar so the
/// switch row stays one line on a phone.
enum TranscriptTranslateDirection {
  auto,
  toChinese,
  toEnglish;

  static TranscriptTranslateDirection fromStorage(String? raw) {
    for (final value in TranscriptTranslateDirection.values) {
      if (value.name == raw) return value;
    }
    return TranscriptTranslateDirection.auto;
  }

  String get label => switch (this) {
    TranscriptTranslateDirection.auto => '自动',
    TranscriptTranslateDirection.toChinese => '译为中文',
    TranscriptTranslateDirection.toEnglish => '译为英文',
  };
}

/// Languages chosen for one transcript. [assumedSimplifiedChinese] is true
/// when automatic detection could not tell Chinese from English.
class TranscriptTranslationPlan {
  const TranscriptTranslationPlan({
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.assumedSimplifiedChinese,
  });

  final String sourceLanguage;
  final String targetLanguage;
  final bool assumedSimplifiedChinese;
}

/// Chinese-dominant text becomes English. English-dominant text becomes
/// simplified Chinese. Anything unclear becomes simplified Chinese, and the
/// caller says so in the task status.
TranscriptTranslationPlan resolveTranscriptTranslation({
  required TranscriptTranslateDirection direction,
  required String subtitleText,
  String? sourceLanguage,
  String? targetLanguage,
}) {
  if (targetLanguage != null) {
    return TranscriptTranslationPlan(
      sourceLanguage: sourceLanguage ?? 'auto',
      targetLanguage: targetLanguage,
      assumedSimplifiedChinese: false,
    );
  }
  if (direction == TranscriptTranslateDirection.toChinese) {
    return const TranscriptTranslationPlan(
      sourceLanguage: 'auto',
      targetLanguage: 'zh-CN',
      assumedSimplifiedChinese: false,
    );
  }
  if (direction == TranscriptTranslateDirection.toEnglish) {
    return const TranscriptTranslationPlan(
      sourceLanguage: 'auto',
      targetLanguage: 'en',
      assumedSimplifiedChinese: false,
    );
  }
  final sample = subtitleText.length > 8000
      ? subtitleText.substring(0, 8000)
      : subtitleText;
  final chinese = RegExp(r'[\u4E00-\u9FFF]').allMatches(sample).length;
  final latin = RegExp(r'[A-Za-z]').allMatches(sample).length;
  if (chinese >= 8 && chinese >= latin) {
    return const TranscriptTranslationPlan(
      sourceLanguage: 'zh-CN',
      targetLanguage: 'en',
      assumedSimplifiedChinese: false,
    );
  }
  if (latin >= 12 && latin > chinese) {
    return const TranscriptTranslationPlan(
      sourceLanguage: 'en',
      targetLanguage: 'zh-CN',
      assumedSimplifiedChinese: false,
    );
  }
  return const TranscriptTranslationPlan(
    sourceLanguage: 'auto',
    targetLanguage: 'zh-CN',
    assumedSimplifiedChinese: true,
  );
}

const Map<SubtitleTranslateProvider, String> subtitleTranslateProviderLabels =
    <SubtitleTranslateProvider, String>{
      SubtitleTranslateProvider.bing: '必应翻译',
      SubtitleTranslateProvider.ai: 'AI 翻译',
      SubtitleTranslateProvider.local: '本地模型翻译',
    };

SubtitleTranslateProvider subtitleTranslateProviderFromName(String? name) {
  for (final provider in SubtitleTranslateProvider.values) {
    if (provider.name == name) return provider;
  }
  return SubtitleTranslateProvider.bing;
}

/// Snapshot taken when a transcription actually starts.
///
/// Continuing a task keeps this snapshot. Restarting captures current settings.
class TranscriptTranslateChoice {
  const TranscriptTranslateChoice({
    required this.enabled,
    required this.direction,
    required this.provider,
    required this.aiOptions,
    this.apiProviderId = '',
    this.localSpecification,
    this.sourceLanguage,
    this.targetLanguage,
    this.apiEndpoint,
    this.bindingKey = '',
    this.smartPolicy,
  });

  const TranscriptTranslateChoice.off()
    : enabled = false,
      direction = TranscriptTranslateDirection.auto,
      provider = SubtitleTranslateProvider.bing,
      aiOptions = AiSubtitleTranslationSettings.defaults,
      apiProviderId = '',
      localSpecification = null,
      sourceLanguage = 'auto',
      targetLanguage = 'zh-CN',
      apiEndpoint = null,
      smartPolicy = null,
      bindingKey = 'bing';
  final ModelJobSpec? localSpecification;

  /// Used when the shared settings object is not in the tree yet.
  const TranscriptTranslateChoice.automatic()
    : enabled = true,
      direction = TranscriptTranslateDirection.auto,
      provider = SubtitleTranslateProvider.bing,
      aiOptions = AiSubtitleTranslationSettings.defaults,
      apiProviderId = '',
      localSpecification = null,
      sourceLanguage = 'auto',
      targetLanguage = 'zh-CN',
      apiEndpoint = null,
      smartPolicy = null,
      bindingKey = 'bing';

  final bool enabled;
  final TranscriptTranslateDirection direction;
  final SubtitleTranslateProvider provider;
  final AiSubtitleTranslationSettings aiOptions;
  final String? sourceLanguage, targetLanguage;
  final String bindingKey;
  final AiSubtitleApiSettings? apiEndpoint;
  final SmartTranslationPolicy? smartPolicy;

  /// Connection service selected for AI translation, such as `deepseek`.
  /// Empty unless [provider] is AI. The key itself stays in the API store.
  final String apiProviderId;

  /// Describes settings only; it does not validate credentials or load models.
  factory TranscriptTranslateChoice.current(
    SubtitleTranslateSettings settings,
  ) {
    final provider = settings.providerEnZh;
    final smart = settings.mode == SubtitleTranslationMode.smart
        ? settings.smartPolicy.copyWith()
        : null;
    return TranscriptTranslateChoice(
      enabled: true,
      direction: settings.direction,
      provider: provider,
      aiOptions: settings.aiOptions,
      apiProviderId: settings.binding.api?.providerId ?? '',
      apiEndpoint: settings.binding.api?.copyWith(
        apiKey: '',
        profiles: const {},
      ),
      sourceLanguage: smart == null ? settings.sourceLanguage : 'auto',
      targetLanguage: smart == null ? settings.targetLanguage : 'mul',
      smartPolicy: smart,
      localSpecification: provider == SubtitleTranslateProvider.local
          ? localTranslationConfiguration(settings._center)
          : null,
    );
  }

  /// Credentials and unused provider settings do not change generated text.
  String get configurationFingerprint => jsonEncode({
    'enabled': enabled,
    if (enabled) ...{
      'direction': direction.name,
      'provider': provider.name,
      'source': sourceLanguage,
      'target': targetLanguage,
      'smart': smartPolicy?.toJson(),
      if (provider == SubtitleTranslateProvider.local)
        'local': localSpecification?.toJson(),
      if (provider == SubtitleTranslateProvider.ai) ...{
        'apiProvider': apiProviderId,
        'endpoint': apiEndpoint?.baseUrl.trim().replaceFirst(
          RegExp(r'/+$'),
          '',
        ),
        'model': apiEndpoint?.model,
        'options': aiOptions.toJson(),
      },
    },
  });

  static Future<TranscriptTranslateChoice> capture(
    SubtitleTranslateSettings settings, {
    required bool enabled,
  }) async {
    await settings.ensureLoaded();
    if (!enabled) return const TranscriptTranslateChoice.off();
    await settings.refreshBinding();
    if (settings.providerEnZh == SubtitleTranslateProvider.ai &&
        settings.binding.api?.ready != true) {
      await AiSubtitleApiSettingsStore().load();
      await settings.refreshBinding();
      if (settings.binding.api?.ready != true) {
        throw StateError('请先配置翻译接口并选择 AI 模型');
      }
    }
    final binding = settings.binding,
        source = settings.sourceLanguage,
        target = settings.targetLanguage;
    final provider = settings.providerEnZh;
    final smart = settings.mode == SubtitleTranslationMode.smart
        ? settings.smartPolicy.copyWith()
        : null;
    final local = provider == SubtitleTranslateProvider.local
        ? await captureLocalTranslation(settings._center)
        : null;
    if (local != null && binding.key != 'local:${local.profile.model}') {
      throw StateError('翻译模型已切换，请重新开始以使用当前设置');
    }
    return TranscriptTranslateChoice(
      enabled: true,
      direction: settings.direction,
      provider: provider,
      aiOptions: settings.aiOptions,
      apiProviderId: binding.api?.providerId ?? '',
      apiEndpoint: binding.api?.copyWith(apiKey: '', profiles: const {}),
      sourceLanguage: smart == null ? source : 'auto',
      targetLanguage: smart == null ? target : 'mul',
      smartPolicy: smart,
      bindingKey: binding.key,
      localSpecification: local,
    );
  }
}

class SubtitleTranslationPair {
  const SubtitleTranslationPair({
    this.source = 'auto',
    this.target = 'zh-CN',
    this.mode = SubtitleTranslationMode.smart,
    this.smart = const SmartTranslationPolicy(),
  });
  final String source, target;
  final SubtitleTranslationMode mode;
  final SmartTranslationPolicy smart;
  SubtitleTranslationPair copyWith({
    String? source,
    String? target,
    SubtitleTranslationMode? mode,
    SmartTranslationPolicy? smart,
  }) => SubtitleTranslationPair(
    source: source ?? this.source,
    target: target ?? this.target,
    mode: mode ?? this.mode,
    smart: smart ?? this.smart,
  );
  Map<String, dynamic> toJson() => {
    'source': source,
    'target': target,
    'mode': mode.name,
    'smart': smart.toJson(),
  };
  factory SubtitleTranslationPair.fromJson(Map value) =>
      SubtitleTranslationPair(
        source: normalizeSubtitleLanguage(
          value['source'] is String ? value['source'] as String : 'auto',
        ),
        target: normalizeSubtitleLanguage(
          value['target'] is String ? value['target'] as String : 'zh-CN',
        ),
        mode: value['mode'] == 'fixed'
            ? SubtitleTranslationMode.fixed
            : SubtitleTranslationMode.smart,
        smart: value['smart'] is Map
            ? SmartTranslationPolicy.fromJson(value['smart'] as Map)
            : const SmartTranslationPolicy(),
      );
}

/// Identifies the translator that will receive the selected languages.
/// Keys contain no API credentials and distinguish endpoint + model pairs.
class SubtitleTranslationBinding {
  const SubtitleTranslationBinding({
    required this.key,
    required this.label,
    this.languages = subtitleTranslationLanguages,
    this.api,
  });
  const SubtitleTranslationBinding.bing()
    : key = 'bing',
      label = '必应翻译',
      languages = subtitleTranslationLanguages,
      api = null;
  final String key, label;
  final List<SubtitleTranslationLanguage> languages;
  final AiSubtitleApiSettings? api;
}

/// Source and target are remembered for each actual translator/model, shared
/// by single-file translation, transcription and batch transcription.
class SubtitleTranslateSettings extends ChangeNotifier {
  SubtitleTranslateSettings({
    Future<SharedPreferences> Function()? preferences,
    Future<AiSubtitleApiSettings> Function()? readApiSettings,
    ModelCenterService? modelCenter,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _readApiSettings =
           readApiSettings ?? AiSubtitleApiSettingsStore().loadMetadata,
       _center = modelCenter ?? ModelCenterService.instance {
    _center.addListener(_onCenterChanged);
    AiSubtitleApiSettingsStore.changes.addListener(_onApiChanged);
  }

  static const providerEnZhKey = 'subtitle_translate_provider_enzh';
  static const directionKey = 'subtitle_transcript_translate_direction';
  static const languageProfilesKey = 'subtitle_translation_languages_v1';
  final Future<SharedPreferences> Function() _preferences;
  final Future<AiSubtitleApiSettings> Function() _readApiSettings;
  ModelCenterService _center;
  final Map<String, SubtitleTranslationPair> _pairs = {};
  SubtitleTranslationBinding _binding = const SubtitleTranslationBinding.bing();
  SubtitleTranslationPair _pair = const SubtitleTranslationPair();
  SubtitleTranslateProvider providerEnZh = SubtitleTranslateProvider.bing;
  AiSubtitleTranslationSettings aiOptions =
      AiSubtitleTranslationSettings.defaults;
  TranscriptTranslateDirection direction = TranscriptTranslateDirection.auto;
  bool _loaded = false, _disposed = false;
  int _bindingEpoch = 0;
  Future<void>? _loadInFlight;
  Future<void> _writes = Future.value();
  String _observedLocalId = '';

  SubtitleTranslationBinding get binding => _binding;
  String get sourceLanguage => _pair.source;
  String get targetLanguage => _pair.target;
  SubtitleTranslationMode get mode => _pair.mode;
  SmartTranslationPolicy get smartPolicy => _pair.smart;
  List<SubtitleTranslationLanguage> get availableLanguages =>
      _binding.languages;
  String get providerLabel => subtitleTranslateProviderLabels[providerEnZh]!;
  String get languageSummary => mode == SubtitleTranslationMode.smart
      ? smartPolicy.summary
      : '${subtitleLanguageLabel(sourceLanguage)} → ${subtitleLanguageLabel(targetLanguage)}';
  String get summary => '${_binding.label} · $languageSummary';

  /// Language and batching preferences, including inactive configurations.
  /// Provider/model selection and endpoint credentials are intentionally absent.
  Map<String, dynamic>? exportSettingsSnapshot() => !_loaded
      ? null
      : {
          'direction': direction.name,
          'languageProfiles': {
            'bing': const SubtitleTranslationPair().toJson(),
            for (final entry in _pairs.entries) entry.key: entry.value.toJson(),
            _binding.key: _pair.toJson(),
          },
          'aiOptions': aiOptions.toJson(),
        };

  void useModelCenter(ModelCenterService center) {
    if (identical(_center, center)) return;
    _center.removeListener(_onCenterChanged);
    _center = center;
    _center.addListener(_onCenterChanged);
    if (_loaded) unawaited(refreshBinding());
  }

  void _onCenterChanged() {
    if (_loaded &&
        providerEnZh == SubtitleTranslateProvider.local &&
        (_observedLocalId != _center.translationModelId ||
            _binding.label !=
                (_center.artifact(_center.translationModelId)?.name ??
                    '本地模型 · ${_center.translationModelId}'))) {
      unawaited(refreshBinding());
    }
  }

  void _onApiChanged() {
    if (_loaded && providerEnZh == SubtitleTranslateProvider.ai) {
      unawaited(refreshBinding());
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadInFlight ??= _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await _preferences();
      providerEnZh = subtitleTranslateProviderFromName(
        prefs.getString(providerEnZhKey),
      );
      direction = TranscriptTranslateDirection.fromStorage(
        prefs.getString(directionKey),
      );
      final raw = prefs.getString(languageProfilesKey);
      if (raw != null) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              if (entry.key is String && entry.value is Map) {
                _pairs[entry.key as String] = SubtitleTranslationPair.fromJson(
                  entry.value as Map,
                );
              }
            }
          }
        } on FormatException {
          /* Keep usable defaults when old data is damaged. */
        }
      }
      aiOptions = await AiSubtitleTranslationSettings.load(
        preferences: _preferences,
      );
      await refreshBinding(legacyDirection: direction);
      await _persist();
    } catch (error) {
      debugPrint('[translate-settings] 读取翻译设置失败：$error');
    } finally {
      _loaded = true;
      _notify();
    }
  }

  Future<SubtitleTranslationBinding> _readBinding(
    SubtitleTranslateProvider provider,
  ) async {
    if (provider == SubtitleTranslateProvider.bing) {
      return const SubtitleTranslationBinding.bing();
    }
    if (provider == SubtitleTranslateProvider.local) {
      final id = _center.translationModelId;
      final model = _center.artifact(id);
      return SubtitleTranslationBinding(
        key: 'local:$id',
        label: model?.name ?? '本地模型 · $id',
        languages: subtitleLanguagesForModel(model?.languages ?? const []),
      );
    }
    final api = await _readApiSettings();
    final endpoint = api.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final identity = jsonEncode([api.providerId, endpoint, api.model.trim()]);
    final preset = AiSubtitleApiPreset.byId(api.providerId);
    final host = Uri.tryParse(endpoint)?.host ?? '';
    final name = preset.id == 'custom'
        ? (host.isEmpty ? '自定义接口' : host)
        : preset.label;
    return SubtitleTranslationBinding(
      key: 'ai:${sha256.convert(utf8.encode(identity))}',
      label: api.model.trim().isEmpty
          ? '$name · 未选择模型'
          : '$name · ${api.model.trim()}',
      api: api,
    );
  }

  Future<void> refreshBinding({
    TranscriptTranslateDirection? legacyDirection,
  }) async {
    final provider = providerEnZh, epoch = ++_bindingEpoch;
    try {
      final next = await _readBinding(provider);
      if (_disposed || epoch != _bindingEpoch || provider != providerEnZh) {
        return;
      }
      _binding = next;
      _observedLocalId = _center.translationModelId;
      final fallback = SubtitleTranslationPair(
        target: legacyDirection == TranscriptTranslateDirection.toEnglish
            ? 'en'
            : 'zh-CN',
      );
      final saved = _pairs[next.key] ?? fallback;
      final allowed = next.languages.map((language) => language.code).toSet();
      _pair = SubtitleTranslationPair(
        mode: saved.mode,
        smart: saved.smart.forLanguages(next.languages),
        source: saved.source == 'auto' || allowed.contains(saved.source)
            ? saved.source
            : 'auto',
        target: allowed.contains(saved.target)
            ? saved.target
            : allowed.contains('zh-CN')
            ? 'zh-CN'
            : allowed.contains('en')
            ? 'en'
            : next.languages.first.code,
      );
      _pairs[next.key] = _pair;
      _notify();
    } catch (error) {
      debugPrint('[translate-settings] 读取当前翻译服务失败：$error');
      if (!_disposed && epoch == _bindingEpoch) rethrow;
    }
  }

  Future<void> setProviderEnZh(SubtitleTranslateProvider value) async {
    await ensureLoaded();
    providerEnZh = value;
    await refreshBinding();
    await _persist();
  }

  Future<void> setLanguages({
    String? source,
    String? target,
    String? bindingKey,
  }) async {
    await ensureLoaded();
    final key = bindingKey ?? _binding.key;
    final previous = _pairs[key] ?? const SubtitleTranslationPair();
    final next = previous.copyWith(
      source: source == null
          ? previous.source
          : normalizeSubtitleLanguage(source),
      target: target == null
          ? previous.target
          : normalizeSubtitleLanguage(target),
    );
    if (next.target == 'auto') throw ArgumentError('请选择明确的目标语言');
    _pairs[key] = next;
    if (key == _binding.key) {
      _pair = next;
      direction = next.target == 'zh-CN'
          ? TranscriptTranslateDirection.toChinese
          : next.target == 'en'
          ? TranscriptTranslateDirection.toEnglish
          : TranscriptTranslateDirection.auto;
      _notify();
    }
    await _persist();
  }

  Future<void> setMode(
    SubtitleTranslationMode value, {
    String? bindingKey,
  }) async {
    await ensureLoaded();
    final key = bindingKey ?? _binding.key;
    final next = (_pairs[key] ?? const SubtitleTranslationPair()).copyWith(
      mode: value,
    );
    _pairs[key] = next;
    if (key == _binding.key) {
      _pair = next;
      _notify();
    }
    await _persist();
  }

  Future<void> setSmartPolicy(
    SmartTranslationPolicy policy, {
    String? bindingKey,
  }) async {
    await ensureLoaded();
    final key = bindingKey ?? _binding.key;
    if (key == _binding.key) policy.validate(availableLanguages);
    final next = (_pairs[key] ?? const SubtitleTranslationPair()).copyWith(
      smart: policy.copyWith(),
    );
    _pairs[key] = next;
    if (key == _binding.key) {
      _pair = next;
      _notify();
    }
    await _persist();
  }

  /// Compatibility for saved settings and older callers; new UI uses language pairs.
  Future<void> setDirection(TranscriptTranslateDirection value) async {
    await setMode(
      value == TranscriptTranslateDirection.auto
          ? SubtitleTranslationMode.smart
          : SubtitleTranslationMode.fixed,
    );
    await setLanguages(
      source: 'auto',
      target: value == TranscriptTranslateDirection.toEnglish ? 'en' : 'zh-CN',
    );
    direction = value;
    await _persist();
  }

  Future<void> _persist() {
    final raw = jsonEncode({
      for (final entry in _pairs.entries) entry.key: entry.value.toJson(),
    });
    final provider = providerEnZh.name, savedDirection = direction.name;
    final save = _writes.then((_) async {
      final prefs = await _preferences();
      await prefs.setString(languageProfilesKey, raw);
      await prefs.setString(providerEnZhKey, provider);
      await prefs.setString(directionKey, savedDirection);
    });
    _writes = save.catchError((Object error) {
      debugPrint('[translate-settings] 保存翻译设置失败：$error');
    });
    return _writes;
  }

  Future<void> setAiOptions(AiSubtitleTranslationSettings value) async {
    aiOptions = value.normalized();
    _notify();
    await aiOptions.save(preferences: _preferences);
  }

  Future<void> flushPreferencesForTrial() async {
    await _loadInFlight;
    await _writes;
  }

  Future<void> reloadPreferencesForTrial() async {
    if (!_loaded) return;
    await _writes;
    final prefs = await _preferences();
    final data =
        jsonDecode(prefs.getString(languageProfilesKey) ?? '{}') as Map;
    _pairs.clear();
    for (final entry in data.entries) {
      _pairs[entry.key as String] = SubtitleTranslationPair.fromJson(
        entry.value as Map,
      );
    }
    direction = TranscriptTranslateDirection.fromStorage(
      prefs.getString(directionKey),
    );
    aiOptions = await AiSubtitleTranslationSettings.load(
      preferences: _preferences,
    );
    await refreshBinding(legacyDirection: direction);
    _notify();
  }

  void notifyApiChanged() => _onApiChanged();

  @override
  void dispose() {
    _disposed = true;
    _center.removeListener(_onCenterChanged);
    AiSubtitleApiSettingsStore.changes.removeListener(_onApiChanged);
    super.dispose();
  }
}
