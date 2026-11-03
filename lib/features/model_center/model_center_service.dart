import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../features/ai_chat/ai_chat_settings.dart';
import '../../services/app_storage_service.dart';
import '../../services/app_default_settings_trial.dart';
import '../../models/recommended_app_defaults.dart';
import '../../services/network/network_http.dart';
import '../../models/subtitle_punctuation.dart';
import 'model_catalog.dart';
import 'model_adapters.dart';
import 'asr_language_options.dart';
import 'asr_enhancement_options.dart';
import 'subtitle_segmentation.dart';
import 'model_background_tasks.dart';
import 'ios_model_download.dart';
import 'model_download_sources.dart';
import 'model_file_transfer.dart';
import 'translation_performance.dart';
import 'asr_acceleration.dart';

typedef ModelDioFactory = Dio Function();

/// Application-owned state. Routes only observe this service; closing a route
/// never cancels a transfer. File identities and validators survive restarts.
class ModelCenterService extends ChangeNotifier {
  ModelCenterService({
    AppStorageService? storage,
    Future<List<ModelArtifact>> Function()? catalogLoader,
    ModelDioFactory? createDio,
    AiChatSecretStorage? secrets,
  }) : storage = storage ?? AppStorageService.instance,
       _catalogLoader =
           catalogLoader ?? (() => loadModelCatalog(includeRetired: true)),
       _createDio =
           createDio ??
           (() => NetworkHttp.instance.createDio(
             scope: NetworkScope.modelDownloads,
           )),
       _secrets = secrets ?? PlatformAiChatSecretStorage();

  static final instance = ModelCenterService();
  static const legacyProfile = ModelServiceProfile(
    id: 'gongyi',
    name: '公益接口',
    kind: TranscriptionServiceKind.gongyi,
  );
  final AppStorageService storage;
  final Future<List<ModelArtifact>> Function() _catalogLoader;
  final ModelDioFactory _createDio;
  late final _downloadSources = ModelDownloadSources(
    createDio: _createDio,
    cacheContext: () {
      final settings = NetworkHttp.instance.settings;
      return '${settings.imageGeneration(NetworkScope.modelDownloads)}:${settings.deviceGeneration}';
    },
  );
  final AiChatSecretStorage _secrets;
  List<ModelArtifact> catalog = const [];
  final Map<String, ModelArtifact> _retiredCatalog = {};
  final Map<String, ModelDownload> downloads = {};
  final Map<String, ModelServiceProfile> profiles = {
    legacyProfile.id: legacyProfile,
  };
  final Map<String, int> _leases = {};
  final Map<String, String> diagnostics = {};
  final Set<String> checking = {};
  String asrProfileId = legacyProfile.id;
  String translationModelId = 'hy-mt2-1.8b-q4';
  String sourcePreference = 'auto';
  String ocrSourcePreference = 'auto';
  bool ocrLegacyMigrationComplete = false;
  final Map<String, List<ModelSourceProbeResult>> sourceChecks = {};
  final Map<String, Map<String, dynamic>> ocrPerformance = {};
  String selectedLanguage = 'auto';
  final Map<String, String> asrLanguagePreferences = {};
  int _languageChangeVersion = 0;
  AsrLanguageOptions languageOptionsFor(ModelServiceProfile profile) =>
      asrLanguageOptions(
        profile,
        model: profile.local ? artifact(profile.model) : null,
      );
  AsrLanguageOptions get currentAsrLanguageOptions =>
      languageOptionsFor(asrProfile);
  String? get fixedAsrLanguage => currentAsrLanguageOptions.fixedLanguage;
  String languageForProfile(ModelServiceProfile profile) =>
      languageOptionsFor(profile).resolve(
        asrLanguagePreferences[asrLanguagePreferenceKey(profile)] ??
            (profile.cloudProvider != null ? profile.language : selectedLanguage),
      );
  String languageForModel(ModelArtifact model) {
    final profile = ModelServiceProfile(
      id: 'local:${model.id}',
      name: model.name,
      kind: TranscriptionServiceKind.local,
      model: model.id,
    );
    return asrLanguageOptions(profile, model: model).resolve(
      asrLanguagePreferences[asrLanguagePreferenceKey(profile)] ??
          selectedLanguage,
    );
  }

  String get effectiveAsrLanguage => languageForProfile(asrProfile);

  void _restoreAsrLanguagePreferences(Object? value) {
    asrLanguagePreferences.clear();
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is String && entry.value is String) {
          asrLanguagePreferences[entry.key as String] = entry.value as String;
        }
      }
    }
  }

  Future<void> selectAsrLanguage(
    String value, {
    ModelServiceProfile? profile,
  }) async {
    final target = profile ?? asrProfile;
    final options = languageOptionsFor(target);
    final language = options.normalize(value);
    if (!options.codes.contains(language)) {
      throw ArgumentError('当前转录模型不支持此语言');
    }
    final key = asrLanguagePreferenceKey(target);
    final previous = asrLanguagePreferences[key];
    final previousGlobal = selectedLanguage;
    final version = ++_languageChangeVersion;
    asrLanguagePreferences[key] = language;
    if (asrLanguagePreferenceKey(asrProfile) == key) {
      selectedLanguage = language;
    }
    try {
      await settingsChanged();
    } catch (_) {
      if (_languageChangeVersion == version) {
        if (previous == null) {
          asrLanguagePreferences.remove(key);
        } else {
          asrLanguagePreferences[key] = previous;
        }
        selectedLanguage = previousGlobal;
        _publish();
      }
      rethrow;
    }
  }

  final Map<String, Map<String, dynamic>> inferenceTuning = {};
  int threads = 2;
  int asrCpuThreads = 0;
  AsrExecutionMode asrExecution = AsrExecutionMode.auto;
  final Map<String, AsrAcceleration> asrAccelerationOptions = {};
  final Map<String, AsrPerformanceProfile> asrPerformance = {};
  final Map<String, String> asrBackendStatus = {};
  AsrAcceleration asrAccelerationFor(String modelId) =>
      asrAccelerationOptions[modelId] ?? AsrAcceleration.auto;
  void clearAsrPerformance(String modelId) =>
      asrPerformance.removeWhere((key, _) => key.startsWith('$modelId:'));
  Future<void> recordAsrState(
    String modelId,
    Map<String, dynamic> state,
  ) async {
    asrBackendStatus[modelId] = '${state['backend']} · ${state['reason']}';
    final cleared = state['clearProfileSignature'];
    final removed =
        cleared is String && asrPerformance.remove('$modelId:$cleared') != null;
    final profile = AsrPerformanceProfile.fromJson(state['profile']);
    if (profile != null) {
      asrPerformance['$modelId:${profile.signature}'] = profile;
      final entries =
          asrPerformance.entries
              .where((e) => e.key.startsWith('$modelId:'))
              .toList()
            ..sort((a, b) => b.value.testedAt.compareTo(a.value.testedAt));
      for (final entry in entries.skip(16)) {
        asrPerformance.remove(entry.key);
      }
      await save();
    } else if (removed) {
      await save();
    }
    _publish();
  }

  AsrEnhancementOptions asrEnhancements = AsrEnhancementOptions.recommended;
  // Keep the established global preference for existing models. This new
  // Japanese recognizer performed better on original audio in device checks.
  bool parakeetJapaneseDenoise = false;
  AsrEnhancementOptions asrEnhancementsFor(ModelArtifact? model) =>
      model?.engine == 'parakeet-ja'
      ? asrEnhancements.copyWith(denoise: parakeetJapaneseDenoise)
      : asrEnhancements;
  AsrEnhancementOptions get currentAsrEnhancements =>
      asrEnhancementsFor(asrProfile.local ? artifact(asrProfile.model) : null);
  void updateAsrEnhancements(
    AsrEnhancementOptions options, {
    ModelArtifact? model,
  }) {
    model ??= asrProfile.local ? artifact(asrProfile.model) : null;
    if (model?.engine == 'parakeet-ja') {
      parakeetJapaneseDenoise = options.denoise;
      asrEnhancements = options.copyWith(denoise: asrEnhancements.denoise);
    } else {
      asrEnhancements = options;
    }
  }

  SubtitlePunctuation subtitlePunctuation = SubtitlePunctuation.defaultValue;
  LocalTranslationOptions _translationDefaults =
      const LocalTranslationOptions();
  final Map<String, LocalTranslationOptions> translationModelOptions = {};
  LocalTranslationOptions get translationOptions =>
      translationOptionsFor(translationModelId);
  LocalTranslationOptions get defaultTranslationOptions => _translationDefaults;
  LocalTranslationOptions translationOptionsFor(String modelId) =>
      translationModelOptions[modelId] ?? _translationDefaults;
  set translationOptions(LocalTranslationOptions value) =>
      translationModelOptions[translationModelId] = value;
  final Map<String, TranslationPerformanceProfile> translationPerformance = {};
  void clearTranslationPerformance(String modelId) => translationPerformance
      .removeWhere((key, _) => key == modelId || key.startsWith('$modelId:'));
  SubtitleSegmentationOptions subtitleSegmentation =
      SubtitleSegmentationOptions.natural;
  int selectedTab = 0;
  String search = '';
  String filter = 'all';
  String? selectedModelId;
  final Map<String, double> scrollPositions = {};
  final Set<String> expandedPerformanceSections = {};
  bool loaded = false;
  String? initializationError;
  bool _pumping = false;
  bool _suspended = false;
  final bool _closed = false;
  Future<void>? _initialization;
  String? _backupExcludedPath;
  Future<void> _writes = Future<void>.value();
  Future<void>? _pumpFuture;
  static const maxConcurrentDownloads = 3;
  final _transfers = <String, CancelToken>{};
  Completer<void>? _pumpWake;

  bool get busy => _pumping || _leases.isNotEmpty;
  bool get started =>
      _initialization != null || loaded || initializationError != null;
  bool get hasModelLeases => _leases.isNotEmpty || checking.isNotEmpty;
  int get activeDownloads => downloads.values
      .where(
        (d) => const [
          ModelDownloadPhase.queued,
          ModelDownloadPhase.downloading,
          ModelDownloadPhase.verifying,
        ].contains(d.phase),
      )
      .length;
  ModelServiceProfile get asrProfile => profiles[asrProfileId] ?? legacyProfile;
  String get summary => '转录：${asrProfile.name} · $activeDownloads 个下载';
  ModelArtifact? artifact(String id) =>
      catalog.where((m) => m.id == id).firstOrNull ?? _retiredCatalog[id];
  bool installed(String id) =>
      downloads[id]?.phase == ModelDownloadPhase.installed;
  bool inUse(String id) => (_leases[id] ?? 0) > 0;
  Future<Directory> modelRoot() async {
    final directory = await storage.featureDirectory('local_models');
    if (Platform.isIOS && _backupExcludedPath != directory.path) {
      await const MethodChannel(
        'com.example.video_player_app/storage_paths',
      ).invokeMethod<void>('excludeFromBackup', {'path': directory.path});
      _backupExcludedPath = directory.path;
    }
    return directory;
  }

  Future<Directory> modelDirectory(ModelArtifact model) async => Directory(
    p.join(
      (await modelRoot()).path,
      '${model.id}-${model.revision.substring(0, 12)}',
    ),
  );

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      final allModels = await _catalogLoader();
      _retiredCatalog.addEntries(
        allModels.where((m) => m.retired).map((m) => MapEntry(m.id, m)),
      );
      catalog = allModels
          .where((m) => !m.retired && !retiredAsrModelIds.contains(m.id))
          .toList();
      final raw = await readStorageJson(
        await storage.dataRecord('model_center.json'),
      );
      var retiredDownloadsChanged = false;
      if (raw is Map) {
        if (raw['inferenceTuning'] is Map) {
          for (final entry in (raw['inferenceTuning'] as Map).entries) {
            if (entry.key is String && entry.value is Map) {
              inferenceTuning[entry.key as String] = Map<String, dynamic>.from(
                entry.value as Map,
              );
            }
          }
        }
        asrProfileId = raw['asrProfileId'] as String? ?? legacyProfile.id;
        translationModelId =
            raw['translationModelId'] as String? ?? translationModelId;
        sourcePreference = raw['sourcePreference'] as String? ?? 'auto';
        ocrSourcePreference = raw['ocrSourcePreference'] as String? ?? 'auto';
        ocrLegacyMigrationComplete = raw['ocrLegacyMigrationComplete'] == true;
        if (raw['ocrPerformance'] is Map) {
          for (final entry in (raw['ocrPerformance'] as Map).entries) {
            if (entry.key is String && entry.value is Map) {
              ocrPerformance[entry.key as String] = Map<String, dynamic>.from(
                entry.value as Map,
              );
            }
          }
        }
        selectedLanguage = raw['language'] as String? ?? 'auto';
        _restoreAsrLanguagePreferences(raw['asrLanguagePreferences']);
        threads = ((raw['threads'] as num?)?.toInt() ?? 2).clamp(1, 4);
        asrCpuThreads = raw['asrCpuThreads'] is num
            ? (raw['asrCpuThreads'] as num).toInt().clamp(0, 12)
            : threads == 2
            ? 0
            : threads;
        asrExecution = AsrExecutionMode.values.firstWhere(
          (v) => v.name == raw['asrExecution'],
          orElse: () => AsrExecutionMode.auto,
        );
        asrEnhancements = AsrEnhancementOptions.fromJson(
          raw['asrEnhancements'],
        );
        parakeetJapaneseDenoise = raw['parakeetJapaneseDenoise'] == true;
        subtitlePunctuation = SubtitlePunctuation.fromStorage(
          raw['subtitlePunctuation'],
        );
        if (raw['asrAccelerationOptions'] is Map) {
          for (final entry in (raw['asrAccelerationOptions'] as Map).entries) {
            if (entry.key is String) {
              asrAccelerationOptions[entry.key as String] = AsrAcceleration
                  .values
                  .firstWhere(
                    (v) => v.name == entry.value,
                    orElse: () => AsrAcceleration.auto,
                  );
            }
          }
        }
        if (raw['asrPerformance'] is Map) {
          for (final entry in (raw['asrPerformance'] as Map).entries) {
            final profile = AsrPerformanceProfile.fromJson(entry.value);
            if (entry.key is String && profile != null) {
              asrPerformance[entry.key as String] = profile;
            }
          }
        }
        _translationDefaults = LocalTranslationOptions.fromJson(
          raw['translationOptions'] is Map
              ? Map<String, dynamic>.from(raw['translationOptions'] as Map)
              : const {},
        );
        if (raw['translationModelOptions'] is Map) {
          for (final entry in (raw['translationModelOptions'] as Map).entries) {
            if (entry.key is String && entry.value is Map) {
              translationModelOptions[entry.key
                  as String] = LocalTranslationOptions.fromJson(
                Map<String, dynamic>.from(entry.value as Map),
              );
            }
          }
        }
        if (raw['translationPerformance'] is Map) {
          for (final entry in (raw['translationPerformance'] as Map).entries) {
            final profile = TranslationPerformanceProfile.fromJson(entry.value);
            if (entry.key is String && profile != null) {
              translationPerformance[entry.key as String] = profile;
            }
          }
        }
        subtitleSegmentation = SubtitleSegmentationOptions.fromJson(
          raw['subtitleSegmentation'],
          migrateDefaults: true,
        );
        selectedTab = ((raw['tab'] as num?)?.toInt() ?? 0).clamp(0, 3);
        search = raw['search'] as String? ?? '';
        filter = raw['filter'] as String? ?? 'all';
        selectedModelId = raw['selectedModelId'] as String?;
        if (raw['expandedPerformanceSections'] is List) {
          expandedPerformanceSections.addAll(
            (raw['expandedPerformanceSections'] as List)
                .whereType<String>()
                .where((value) => value == 'asr' || value == 'translation'),
          );
        }
        if (raw['scrollPositions'] is Map) {
          for (final entry in (raw['scrollPositions'] as Map).entries) {
            if (entry.value is num) {
              scrollPositions['${entry.key}'] = (entry.value as num).toDouble();
            }
          }
        }
        for (final value in raw['profiles'] as List? ?? const []) {
          final profile = ModelServiceProfile.fromJson(
            Map<String, dynamic>.from(value as Map),
          );
          profiles[profile.id] = profile.id == legacyProfile.id
              ? legacyProfile
              : profile;
        }
        for (final value in raw['downloads'] as List? ?? const []) {
          final download = ModelDownload.fromJson(
            Map<String, dynamic>.from(value as Map),
          );
          if (retiredAsrModelIds.contains(download.artifactId)) {
            if (Platform.isIOS &&
                download.phase != ModelDownloadPhase.installed) {
              await IosModelDownload.pauseRetiredSpeakerDownload(
                download.artifactId,
              );
            }
            continue;
          }
          final model = artifact(download.artifactId);
          if (model == null) continue;
          if (model.retired && download.phase != ModelDownloadPhase.installed) {
            if (Platform.isIOS) {
              await IosModelDownload.pauseRetiredModelDownload(
                model.identity,
                model.files.map((file) => file.name),
              );
            }
            retiredDownloadsChanged = true;
            download.phase = ModelDownloadPhase.paused;
            download.bytesPerSecond = 0;
            download.message = '模型已下架，已保留下载断点；新任务请选择其他模型';
          }
          if (download.phase == ModelDownloadPhase.installed) {
            final dir = await modelDirectory(model);
            final receipt = await readStorageJson(
              File(p.join(dir.path, 'installed.json')),
            );
            var valid = receipt is Map && receipt['identity'] == model.identity;
            for (final file in model.files) {
              final stat = await File(p.join(dir.path, file.name)).stat();
              valid =
                  valid &&
                  stat.type == FileSystemEntityType.file &&
                  stat.size == file.bytes;
            }
            if (!valid) {
              download.phase = ModelDownloadPhase.failed;
              download.message = '模型文件缺失或版本不一致，请重新下载或导入';
            }
          } else if (download.phase != ModelDownloadPhase.paused &&
              download.phase != ModelDownloadPhase.failed) {
            download.phase = ModelDownloadPhase.queued;
            download.message = '恢复未完成的下载';
          }
          downloads[download.artifactId] = download;
        }
        if (raw['diagnostics'] is Map) {
          diagnostics.addAll(
            Map<String, String>.from(raw['diagnostics'] as Map),
          );
          diagnostics.removeWhere((id, _) => retiredAsrModelIds.contains(id));
        }
      }
      if (!profiles.containsKey(asrProfileId)) {
        asrProfileId = legacyProfile.id;
      }
      final retiredDefault =
          asrProfile.local && artifact(asrProfile.model)?.retired == true;
      if (retiredDefault) {
        final replacement =
            catalog.where((m) => m.id == 'sensevoice-small-int8').firstOrNull ??
            catalog
                .where((m) => m.purpose == ModelPurpose.transcription)
                .firstOrNull;
        if (replacement != null) {
          final profile = ModelServiceProfile(
            id: 'local:${replacement.id}',
            name: replacement.name,
            kind: TranscriptionServiceKind.local,
            model: replacement.id,
          );
          profiles[profile.id] = profile;
          asrProfileId = profile.id;
        }
      }
      if (artifact(translationModelId)?.purpose != ModelPurpose.translation) {
        translationModelId =
            catalog
                .where((model) => model.purpose == ModelPurpose.translation)
                .firstOrNull
                ?.id ??
            '';
      }
      loaded = true;
      initializationError = null;
      if (retiredDefault || retiredDownloadsChanged) await save();
      _publish();
      _kick();
    } catch (error) {
      initializationError = '$error';
      _initialization = null;
      _publish();
      rethrow;
    }
  }

  Future<void> save() {
    final value = jsonDecode(
      jsonEncode({
        'version': 1,
        'asrProfileId': asrProfileId,
        'translationModelId': translationModelId,
        'sourcePreference': sourcePreference,
        'ocrSourcePreference': ocrSourcePreference,
        'ocrLegacyMigrationComplete': ocrLegacyMigrationComplete,
        'ocrPerformance': ocrPerformance,
        'language': selectedLanguage,
        if (asrLanguagePreferences.isNotEmpty)
          'asrLanguagePreferences': asrLanguagePreferences,
        'threads': threads,
        'asrCpuThreads': asrCpuThreads,
        'inferenceTuning': inferenceTuning,
        'asrExecution': asrExecution.name,
        'asrEnhancements': asrEnhancements.toJson(),
        if (parakeetJapaneseDenoise) 'parakeetJapaneseDenoise': true,
        'subtitlePunctuation': subtitlePunctuation.name,
        'asrAccelerationOptions': {
          for (final entry in asrAccelerationOptions.entries)
            entry.key: entry.value.name,
        },
        'asrPerformance': {
          for (final entry in asrPerformance.entries)
            entry.key: entry.value.toJson(),
        },
        'translationOptions': _translationDefaults.toJson(),
        'translationModelOptions': {
          for (final entry in translationModelOptions.entries)
            entry.key: entry.value.toJson(),
        },
        'translationPerformance': {
          for (final entry in translationPerformance.entries)
            entry.key: entry.value.toJson(),
        },
        'subtitleSegmentation': subtitleSegmentation.toJson(),
        'tab': selectedTab,
        'search': search,
        'filter': filter,
        'selectedModelId': selectedModelId,
        'scrollPositions': scrollPositions,
        'expandedPerformanceSections': expandedPerformanceSections.toList(),
        'profiles': profiles.values.map((v) => v.toJson()).toList(),
        'downloads': downloads.values.map((v) => v.toJson()).toList(),
        'diagnostics': diagnostics,
      }),
    );
    final write = _writes.then((_) async {
      await writeStorageJson(
        await storage.dataRecord('model_center.json'),
        value,
      );
    });
    _writes = write.catchError((Object error) {
      initializationError = '模型中心状态保存失败：$error';
      _publish();
    });
    return write;
  }

  Future<void> settingsChanged() async {
    _publish();
    await save();
  }

  Future<void> flushPreferencesForTrial() async {
    await _initialization;
    await _writes;
  }

  Future<void> reloadPreferencesForTrial() async {
    if (!loaded) return;
    await _writes;
    final raw = Map<String, dynamic>.from(
      await readStorageJson(await storage.dataRecord('model_center.json'))
              as Map? ??
          {},
    );
    _adoptTrialPreferences(raw);
    _publish();
  }

  Future<bool> patchPreferencesForTrial(
    Map<String, dynamic> fields,
    bool restoring,
  ) async {
    if (!loaded) return false;
    await _writes;
    final raw = Map<String, dynamic>.from(
      await readStorageJson(await storage.dataRecord('model_center.json'))
              as Map? ??
          {},
    );
    _adoptTrialPreferences(
      restoring
          ? TrialFieldMask.restore(
              raw,
              fields,
              RecommendedAppDefaults.modelFields,
            )
          : TrialFieldMask.apply(raw, fields),
    );
    await save();
    _publish();
    return true;
  }

  void _adoptTrialPreferences(Map<String, dynamic> raw) {
    sourcePreference = raw['sourcePreference'] as String? ?? 'auto';
    ocrSourcePreference = raw['ocrSourcePreference'] as String? ?? 'auto';
    selectedLanguage = raw['language'] as String? ?? 'auto';
    _restoreAsrLanguagePreferences(raw['asrLanguagePreferences']);
    threads = ((raw['threads'] as num?)?.toInt() ?? 2).clamp(1, 4);
    asrCpuThreads = raw['asrCpuThreads'] is num
        ? (raw['asrCpuThreads'] as num).toInt().clamp(0, 12)
        : threads == 2
        ? 0
        : threads;
    asrExecution = AsrExecutionMode.values.firstWhere(
      (value) => value.name == raw['asrExecution'],
      orElse: () => AsrExecutionMode.auto,
    );
    asrEnhancements = AsrEnhancementOptions.fromJson(raw['asrEnhancements']);
    parakeetJapaneseDenoise = raw['parakeetJapaneseDenoise'] == true;
    subtitlePunctuation = SubtitlePunctuation.fromStorage(
      raw['subtitlePunctuation'],
    );
    asrAccelerationOptions.clear();
    for (final entry
        in (raw['asrAccelerationOptions'] is Map
                ? raw['asrAccelerationOptions'] as Map
                : const {})
            .entries) {
      if (entry.key is String) {
        asrAccelerationOptions[entry.key as String] = AsrAcceleration.values
            .firstWhere(
              (value) => value.name == entry.value,
              orElse: () => AsrAcceleration.auto,
            );
      }
    }
    _translationDefaults = LocalTranslationOptions.fromJson(
      Map<String, dynamic>.from(raw['translationOptions'] as Map? ?? {}),
    );
    translationModelOptions.clear();
    for (final entry
        in (raw['translationModelOptions'] is Map
                ? raw['translationModelOptions'] as Map
                : const {})
            .entries) {
      if (entry.key is String && entry.value is Map) {
        translationModelOptions[entry.key
            as String] = LocalTranslationOptions.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
    }
    subtitleSegmentation = SubtitleSegmentationOptions.fromJson(
      raw['subtitleSegmentation'],
      migrateDefaults: true,
    );
  }

  void updateDiagnostic(String id, String message) {
    diagnostics[id] = message;
    _publish();
  }

  void rememberView() {
    if (!loaded) return;
    unawaited(save().catchError((Object _) {}));
  }

  Future<void> saveProfile(
    ModelServiceProfile profile, {
    String? secret,
  }) async {
    await initialize();
    if (secret != null) {
      if (secret.isEmpty) {
        await _secrets.delete('model-center:${profile.id}');
      } else {
        await _secrets.write('model-center:${profile.id}', secret);
        if (await _secrets.read('model-center:${profile.id}') != secret) {
          throw StateError('密钥未能安全保存');
        }
      }
    }
    profiles[profile.id] = profile;
    if (profile.cloudProvider != null) {
      asrLanguagePreferences[asrLanguagePreferenceKey(profile)] =
          languageOptionsFor(profile).resolve(profile.language);
    }
    await settingsChanged();
  }

  Future<String> readSecret(String profileId) async =>
      await _secrets.read('model-center:$profileId') ?? '';

  Future<ModelJobSpec> captureTranscription() async {
    await initialize();
    final profile = asrProfile;
    final model = profile.local ? artifact(profile.model) : null;
    if (model?.retired == true) throw StateError('此模型已下架，请重新选择转录模型');
    if (profile.local && (model == null || !installed(model.id))) {
      throw StateError('请先在模型中心下载转录模型');
    }
    return transcriptionConfiguration;
  }

  /// Current settings without loading models or validating an installation.
  /// Used to explain how a saved task differs from the next new task.
  ModelJobSpec get transcriptionConfiguration {
    final profile = asrProfile;
    final model = profile.local ? artifact(profile.model) : null;
    final enhancements = asrEnhancementsFor(model);
    final language = languageForProfile(profile);
    return ModelJobSpec(
      profile: ModelServiceProfile(
        id: profile.id,
        name: profile.name,
        kind: profile.kind,
        endpoint: profile.endpoint,
        model: profile.model,
        appId: profile.appId,
        language: language,
        cloudOptions: profile.cloudProvider == null ? null :
            CloudAsrOptions.fromJson((profile.cloudOptions ?? const CloudAsrOptions()).toJson()),
        cloudCapabilities: profile.cloudProvider == null ? null :
            CloudAsrCapabilities.fromJson((profile.cloudCapabilities ??
              cloudAsrCapabilities(profile.cloudProvider!, profile.model)).toJson()),
      ),
      artifactIdentity: model?.identity ?? '',
      asrTokenTiming: model == null
          ? null
          : asrTokenTimingOverride(model.id, model.engine),
      asrTextProcessingVersion: model != null
          ? currentAsrTextProcessingVersion
          : null,
      threads: threads,
      asrCpuThreads: profile.local ? asrCpuThreads : null,
      asrExecution: asrExecution,
      asrAcceleration: profile.local ? asrAccelerationFor(profile.model) : null,
      asrAccelerationModels: {
        if (model != null)
          if (artifact(asrAccelerationPackId(model.id)) case final pack?)
            pack.id: pack.identity,
      },
      subtitleSegmentation: profile.local ? subtitleSegmentation : null,
      asrEnhancements: profile.local
          ? localAsrAdapters[model?.engine]?.supportsHotwords == true
                ? enhancements.copyWith(hotwords: '')
                : enhancements
          : null,
      enhancementModels: {
        if (model != null)
          for (final id in enhancements.requiredModels(
            model.languages,
            language,
            textProcessingVersion: currentAsrTextProcessingVersion,
            recognitionEngine: model.engine,
          ))
            if (artifact(id) case final dependency?) id: dependency.identity,
      },
    );
  }

  Future<void> selectAsr(ModelArtifact model) async {
    if (model.retired) throw StateError('此模型已下架，请选择其他转录模型');
    if (model.purpose != ModelPurpose.transcription) {
      throw ArgumentError.value(model.id, 'model', '请选择转录模型');
    }
    // Binding may precede installation; captureTranscription guards execution.
    final profile = ModelServiceProfile(
      id: 'local:${model.id}',
      name: model.name,
      kind: TranscriptionServiceKind.local,
      model: model.id,
    );
    await saveProfile(profile);
    asrProfileId = profile.id;
    await settingsChanged();
    await queueAsrEnhancements(model);
  }

  List<ModelArtifact> asrEnhancementArtifacts(ModelArtifact model) {
    if (model.purpose != ModelPurpose.transcription) return const [];
    return [
      for (final id in asrEnhancementsFor(model).requiredModels(
        model.languages,
        languageForModel(model),
        textProcessingVersion: currentAsrTextProcessingVersion,
        recognitionEngine: model.engine,
      ))
        ?artifact(id),
    ];
  }

  List<ModelArtifact> asrDownloadComponents(ModelArtifact model) => [
    model,
    ...asrEnhancementArtifacts(model),
  ];

  /// An explicit download action queues the disclosed combination together.
  /// Shared installed/active components keep their existing files and progress.
  Future<void> queueAsrDownload(ModelArtifact model) async {
    await initialize();
    if (model.retired) throw StateError('此模型已下架，不能开始新的下载');
    if (model.purpose != ModelPurpose.transcription) {
      throw ArgumentError.value(model.id, 'model', '请选择转录模型');
    }
    final components = asrDownloadComponents(model);
    for (final component in components) {
      if (!installed(component.id) &&
          !const [
            ModelDownloadPhase.queued,
            ModelDownloadPhase.downloading,
            ModelDownloadPhase.verifying,
          ].contains(downloads[component.id]?.phase)) {
        await enqueue(component.id);
      }
    }
  }

  Future<void> queueAsrEnhancements(ModelArtifact model) async {
    for (final dependency in asrEnhancementArtifacts(model)) {
      if (!installed(dependency.id)) await enqueue(dependency.id);
    }
  }

  /// Download waiting happens before acquiring the shared inference slot.
  Future<void> prepareAsrEnhancements(
    ModelJobSpec spec, {
    Future<void>? cancelSignal,
    void Function(String)? onProgress,
  }) async {
    if (spec.asrEnhancements?.enabled != true) return;
    await initialize();
    var cancelled = false;
    var finished = false;
    cancelSignal?.then((_) {
      if (!finished) cancelled = true;
    });
    try {
      final primary = artifact(spec.profile.model);
      final expected = spec.asrEnhancements!.requiredModels(
        primary?.languages ?? const [],
        spec.profile.language,
        textProcessingVersion: spec.asrTextProcessingVersion,
        recognitionEngine: primary?.engine ?? '',
      );
      for (final id in expected) {
        if (artifact(id) == null ||
            artifact(id)!.identity != spec.enhancementModels[id]) {
          throw StateError('增强模型 $id 的版本已变更或清单缺失，请重新创建任务');
        }
        if (!installed(id)) await enqueue(id);
      }
      while (expected.any((id) => !installed(id))) {
        if (cancelled) throw StateError('转录已取消');
        for (final id in expected.where((id) => !installed(id))) {
          final state = downloads[id];
          if (state?.phase == ModelDownloadPhase.failed ||
              state?.phase == ModelDownloadPhase.paused) {
            throw StateError(
              '${artifact(id)?.name}：${state?.message ?? '下载已暂停'}；可在转录增强中调整或继续下载',
            );
          }
        }
        final waiting = expected.where((id) => !installed(id)).first;
        final state = downloads[waiting];
        onProgress?.call(
          '正在准备增强模型 · ${artifact(waiting)?.name} · ${modelBytes(state?.received ?? 0)} / ${modelBytes(artifact(waiting)!.bytes)}',
        );
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 300)),
          ?cancelSignal,
        ]);
      }
      if (cancelled) throw StateError('转录已取消');
    } finally {
      finished = true;
    }
  }

  Future<T> usingAsrModels<T>(
    ModelJobSpec spec,
    Future<T> Function(ModelArtifact, Directory, Map<String, String>) action,
  ) => usingModel(spec.profile.model, (primary, dir) async {
    final directories = <String, String>{};
    final ids = spec.asrEnhancements?.enabled == true
        ? spec.enhancementModels.keys
              .where((id) => !retiredAsrModelIds.contains(id))
              .toList()
        : <String>[];
    for (final entry in spec.asrAccelerationModels.entries) {
      if (spec.asrAcceleration != null &&
          spec.asrAcceleration != AsrAcceleration.cpu &&
          installed(entry.key) &&
          artifact(entry.key)?.identity == entry.value) {
        ids.add(entry.key);
      }
    }
    Future<T> lease(int index) async {
      if (index == ids.length) return action(primary, dir, directories);
      final id = ids[index];
      return usingModel(id, (model, dependencyDir) async {
        final expected =
            spec.enhancementModels[id] ?? spec.asrAccelerationModels[id];
        if (model.identity != expected) {
          throw StateError('任务所需模型组件版本已变更：${model.name}');
        }
        directories[id] = dependencyDir.path;
        return lease(index + 1);
      });
    }

    return lease(0);
  });

  Future<void> enqueue(String id) async {
    await initialize();
    if (inUse(id)) throw StateError('模型正在检查或使用，请稍后重试');
    if (artifact(id) == null) throw ArgumentError.value(id);
    if (artifact(id)!.retired) throw StateError('此模型已下架，不能开始新的下载');
    if (installed(id) || _transfers.containsKey(id)) return;
    final state = downloads.putIfAbsent(
      id,
      () => ModelDownload(artifactId: id),
    );
    state.phase = ModelDownloadPhase.queued;
    if (artifact(id)?.purpose == ModelPurpose.ocr) {
      state.sourcePreference = ocrSourcePreference;
    }
    state.message = '';
    _suspended = false;
    await settingsChanged();
    _kick();
  }

  Future<void> pause(String id) async {
    final state = downloads[id];
    if (state == null || state.phase == ModelDownloadPhase.installed) return;
    state.phase = ModelDownloadPhase.paused;
    state.message = '再次打开页面后可继续';
    _transfers[id]?.cancel('已暂停');
    await settingsChanged();
  }

  Future<void> pauseAll() async {
    _suspended = true;
    for (final state in downloads.values) {
      if (const [
        ModelDownloadPhase.queued,
        ModelDownloadPhase.downloading,
        ModelDownloadPhase.verifying,
      ].contains(state.phase)) {
        state.phase = ModelDownloadPhase.paused;
      }
    }
    for (final transfer in _transfers.values) {
      transfer.cancel('保存下载断点');
    }
    await _pumpFuture;
    await save();
  }

  Future<void> shutdown() async {
    final resumable = downloads.values
        .where(
          (state) => const [
            ModelDownloadPhase.queued,
            ModelDownloadPhase.downloading,
            ModelDownloadPhase.verifying,
          ].contains(state.phase),
        )
        .map((state) => state.artifactId)
        .toSet();
    await pauseAll();
    for (final id in resumable) {
      if (downloads[id]?.phase == ModelDownloadPhase.paused) {
        downloads[id]!.phase = ModelDownloadPhase.queued;
      }
    }
    await save();
    await _writes;
  }

  void _kick() {
    if (_suspended || _closed) return;
    if (_pumping) {
      if (_pumpWake?.isCompleted == false) _pumpWake!.complete();
      return;
    }
    _pumpFuture = _pump();
    unawaited(
      _pumpFuture!.catchError((Object error) {
        initializationError = '$error';
        _publish();
      }),
    );
  }

  Future<void> _pump() async {
    _pumping = true;
    final active = <String, Future<void>>{};
    Future<void> run(ModelDownload state, CancelToken cancel) async {
      try {
        await _download(artifact(state.artifactId)!, state, cancel);
      } catch (error) {
        if (state.phase != ModelDownloadPhase.paused) {
          state.phase = ModelDownloadPhase.failed;
          state.message = '下载失败：$error';
        }
      } finally {
        state.bytesPerSecond = 0;
        _transfers.remove(state.artifactId);
        try {
          await settingsChanged();
        } catch (error) {
          initializationError = '模型中心状态保存失败：$error';
        } finally {
          active.remove(state.artifactId);
        }
      }
    }

    try {
      while (true) {
        _pumpWake = Completer<void>();
        while (!_suspended &&
            !_closed &&
            active.length < maxConcurrentDownloads) {
          final state = downloads.values
              .where(
                (d) =>
                    d.phase == ModelDownloadPhase.queued &&
                    !active.containsKey(d.artifactId),
              )
              .firstOrNull;
          if (state == null) break;
          final cancel = CancelToken();
          _transfers[state.artifactId] = cancel;
          active[state.artifactId] = run(state, cancel);
        }
        if (active.isEmpty) break;
        await Future.any([...active.values, _pumpWake!.future]);
      }
    } finally {
      _pumpWake = null;
      _pumping = false;
      _publish();
    }
  }

  Future<void> _download(
    ModelArtifact model,
    ModelDownload state,
    CancelToken cancel,
  ) async {
    final preference = state.sourcePreference ?? sourcePreference;
    final dir = await modelDirectory(model);
    await dir.create(recursive: true);
    var complete = 0;
    for (final file in model.files) {
      cancel.throwIfCancellationRequested();
      final target = File(p.join(dir.path, file.name));
      final manuallyRejected =
          (state.fileState[file.name] as Map?)?['invalid'] == true;
      if (!manuallyRejected &&
          await target.exists() &&
          await target.length() == file.bytes) {
        complete += file.bytes;
        state.received = complete;
        continue;
      }
      if (await target.exists()) await target.delete();
      final partial = File('${target.path}.part');
      if (!manuallyRejected &&
          await partial.exists() &&
          await partial.length() == file.bytes) {
        await partial.rename(target.path);
        complete += file.bytes;
        state.received = complete;
        await save();
        continue;
      }
      state.phase = ModelDownloadPhase.downloading;
      state.bytesPerSecond = 0;
      state.message = '${file.name} · 正在连接下载源';
      _publish();
      final sources = await _downloadSources.rank(
        file,
        preference: preference,
        cancel: cancel,
        onProbing: () {
          state.message = '${file.name} · 正在测速，自动选择下载源';
          _publish();
        },
        onProbed: (results) {
          sourceChecks[model.id] = results;
          _publish();
        },
      );
      if (Platform.isIOS) {
        final mode = await IosModelDownload.networkMode();
        if (mode != NetworkMode.custom) {
          await _downloadIosFile(
            model,
            file,
            state,
            target,
            complete,
            cancel,
            mode,
            sources,
          );
          complete += file.bytes;
          state.received = complete;
          await save();
          continue;
        }
      }
      Object? lastError;
      var success = false;
      final candidates = [...sources, if (sources.length > 1) sources.first];
      for (var index = 0; index < candidates.length; index++) {
        if (success) break;
        final source = candidates[index];
        final monitorSlow = sources.length > 1 && index < sources.length;
        final attempts = sources.length == 1 ? 3 : 1;
        var restartedAfterInvalidRange = false;
        for (var attempt = 0; attempt < attempts && !success; attempt++) {
          cancel.throwIfCancellationRequested();
          final metadata = Map<String, dynamic>.from(
            state.fileState[file.name] as Map? ?? {},
          );
          var offset = await partial.exists() ? await partial.length() : 0;
          final sameSource = metadata['url'] == source.value;
          if (offset > file.bytes || (sameSource && metadata['etag'] == null)) {
            offset = 0;
            if (await partial.exists()) await partial.delete();
          }
          final dio = _createDio();
          dio.options.connectTimeout = const Duration(seconds: 15);
          try {
            state.phase = ModelDownloadPhase.downloading;
            state.message = '${file.name} · ${modelSourceLabel(source.key)}';
            _publish();
            var lastBytes = offset;
            var clock = DateTime.now();
            var previousBytes = offset;
            final health = ModelDownloadHealth(
              referenceBytesPerSecond: preference == 'auto'
                  ? sourceChecks[model.id]
                            ?.where((check) => check.key == source.key)
                            .firstOrNull
                            ?.bytesPerSecond ??
                        0
                  : 0,
            );
            await ModelFileTransfer(dio: dio).download(
              url: source.value,
              total: file.bytes,
              partial: partial,
              offset: offset,
              ifRange: sameSource ? metadata['etag'] as String? : null,
              cancel: cancel,
              onValidator: (etag) async {
                state.fileState = {
                  ...state.fileState,
                  file.name: {'url': source.value, 'etag': etag},
                };
                await save();
              },
              onBytes: (received) {
                if (monitorSlow) {
                  health.add((received - previousBytes).clamp(0, file.bytes));
                }
                previousBytes = received;
                state.received = complete + received;
                final now = DateTime.now();
                final elapsed = now.difference(clock).inMilliseconds;
                if (elapsed >= 500) {
                  state.bytesPerSecond =
                      (received - lastBytes).clamp(0, file.bytes) *
                      1000 /
                      elapsed;
                  clock = now;
                  lastBytes = received;
                  _publish();
                }
              },
            );
            cancel.throwIfCancellationRequested();
            await partial.rename(target.path);
            if (preference == 'auto') {
              _downloadSources.succeeded(file, source.key);
            }
            success = true;
          } catch (error) {
            lastError = error;
            cancel.throwIfCancellationRequested();
            if (preference == 'auto') {
              _downloadSources.failed(file, source.key);
            }
            // Retry a rejected resume range once from the start.
            if (offset > 0 &&
                error is FormatException &&
                !restartedAfterInvalidRange) {
              restartedAfterInvalidRange = true;
              if (await partial.exists()) await partial.delete();
              attempt--;
              continue;
            }
            state.bytesPerSecond = 0;
            state.message = '${modelSourceLabel(source.key)} 下载失败或过慢，正在尝试其他来源';
            _publish();
            // Keep the measured fallback order. A brief speed test must not
            // immediately promote the source that just stalled.
            if (attempt < attempts - 1) {
              await Future<void>.delayed(
                Duration(milliseconds: 400 * (attempt + 1)),
              );
            }
          } finally {
            dio.close(force: true);
          }
        }
      }
      if (!success) {
        _downloadSources.forget(file);
        throw lastError ?? StateError('没有可用的下载源');
      }
      complete += file.bytes;
      state.received = complete;
      await save();
    }
    cancel.throwIfCancellationRequested();
    await _finishInstallation(model, dir, state, '下载完成，可直接使用');
  }

  Future<void> _downloadIosFile(
    ModelArtifact model,
    ModelFile file,
    ModelDownload state,
    File target,
    int complete,
    CancelToken cancel,
    NetworkMode mode,
    List<MapEntry<String, String>> sources,
  ) async {
    final staging = File('${target.path}.part');
    Object? lastError;
    final candidates = [...sources, if (sources.length > 1) sources.first];
    for (var index = 0; index < candidates.length; index++) {
      final source = candidates[index];
      final monitorSlow = sources.length > 1 && index < sources.length;
      cancel.throwIfCancellationRequested();
      try {
        state.phase = ModelDownloadPhase.downloading;
        state.message =
            '${file.name} · ${modelSourceLabel(source.key)} · iOS 后台下载';
        _publish();
        if (!await staging.exists() || await staging.length() != file.bytes) {
          var last = 0;
          var time = DateTime.now();
          final sourceCancel = CancelToken();
          var finished = false;
          unawaited(
            cancel.whenCancel.then((_) {
              if (!finished) sourceCancel.cancel('已暂停');
            }),
          );
          final health = ModelDownloadHealth(
            referenceBytesPerSecond:
                (state.sourcePreference ?? sourcePreference) == 'auto'
                ? sourceChecks[model.id]
                          ?.where((check) => check.key == source.key)
                          .firstOrNull
                          ?.bytesPerSecond ??
                      0
                : 0,
          );
          ModelSourceTooSlow? slow;
          var observed = false;
          final watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
            try {
              health.check();
            } on ModelSourceTooSlow catch (error) {
              slow = error;
              sourceCancel.cancel('$error');
            }
          });
          try {
            await IosModelDownload.download(
              key: '${model.identity}:${file.name}',
              url: source.value,
              destination: staging.path,
              direct: mode == NetworkMode.direct,
              cancel: sourceCancel,
              onProgress: (received) {
                if (!observed) {
                  observed = true;
                  last = received;
                  time = DateTime.now();
                }
                try {
                  health.observeTotal(received, allowSlow: !monitorSlow);
                } on ModelSourceTooSlow catch (error) {
                  slow = error;
                  sourceCancel.cancel('$error');
                }
                final elapsed = DateTime.now().difference(time).inMilliseconds;
                if (elapsed >= 500) {
                  state.bytesPerSecond =
                      ((received - last).clamp(0, file.bytes)) * 1000 / elapsed;
                  last = received;
                  time = DateTime.now();
                  state.received = complete + received.clamp(0, file.bytes);
                  _publish();
                }
              },
            );
          } catch (_) {
            if (slow != null) throw slow!;
            rethrow;
          } finally {
            finished = true;
            watchdog.cancel();
          }
        }
        cancel.throwIfCancellationRequested();
        if (!await staging.exists() || await staging.length() != file.bytes) {
          if (await staging.exists()) await staging.delete();
          throw const FormatException('模型文件未下载完整');
        }
        cancel.throwIfCancellationRequested();
        await staging.rename(target.path);
        if ((state.sourcePreference ?? sourcePreference) == 'auto') {
          _downloadSources.succeeded(file, source.key);
        }
        return;
      } catch (error) {
        lastError = error;
        cancel.throwIfCancellationRequested();
        if ((state.sourcePreference ?? sourcePreference) == 'auto') {
          _downloadSources.failed(file, source.key);
        }
      }
    }
    _downloadSources.forget(file);
    throw lastError ?? StateError('iOS 模型下载失败');
  }

  Future<List<ModelSourceProbeResult>> probeDownloadSources(
    String id,
    ModelFile file,
    CancelToken cancel,
  ) async {
    List<ModelSourceProbeResult> results = [];
    await _downloadSources.rank(
      file,
      preference: 'auto',
      cancel: cancel,
      forceProbe: true,
      onProbed: (checks) {
        results = sourceChecks[id] = checks;
        _publish();
      },
    );
    return results;
  }

  Future<void> verify(String id) async {
    await initialize();
    final model = artifact(id)!;
    if (inUse(id) || _transfers.containsKey(id)) {
      throw StateError('请等待模型任务完成后检查');
    }
    final state = downloads.putIfAbsent(
      id,
      () => ModelDownload(artifactId: id),
    );
    state.phase = ModelDownloadPhase.verifying;
    _leases[id] = 1;
    _publish();
    try {
      final dir = await modelDirectory(model);
      for (final file in model.files) {
        final target = File(p.join(dir.path, file.name));
        if (!await target.exists() ||
            await target.length() != file.bytes ||
            await modelFileHash(target.path) != file.sha256) {
          state.fileState = {
            ...state.fileState,
            file.name: {'invalid': true},
          };
          throw StateError('${file.name} 缺失或校验失败');
        }
      }
      await writeStorageJson(File(p.join(dir.path, 'installed.json')), {
        'identity': model.identity,
        'files': {for (final file in model.files) file.name: file.sha256},
      });
      state.phase = ModelDownloadPhase.installed;
      state.checkedAt = DateTime.now();
      state.message = 'SHA-256 校验通过';
    } catch (error) {
      state.phase = ModelDownloadPhase.failed;
      state.message = '$error';
      rethrow;
    } finally {
      _leases.remove(id);
      await settingsChanged();
    }
  }

  Future<void> importFiles(String id, Directory source) async {
    await initialize();
    final model = artifact(id)!;
    if (inUse(id) || _transfers.containsKey(id)) throw StateError('模型正在使用或下载');
    if (downloads[id]?.phase == ModelDownloadPhase.queued) await pause(id);
    final dir = await modelDirectory(model);
    _leases[id] = 1;
    try {
      // Check directory entries only; importing does not scan model contents.
      for (final file in model.files) {
        final input = File(p.join(source.path, file.name));
        if (!await input.exists() || await input.length() != file.bytes) {
          throw StateError('${file.name} 缺失或文件大小不匹配');
        }
      }
      if (AppStorageService.samePath(source.path, dir.path)) {
        final state = downloads.putIfAbsent(
          id,
          () => ModelDownload(artifactId: id),
        );
        await _finishInstallation(model, dir, state, '模型已就绪，可直接使用');
        return;
      }
      await dir.create(recursive: true);
      for (final file in model.files) {
        final staging = await File(
          p.join(source.path, file.name),
        ).copy(p.join(dir.path, '${file.name}.import'));
        if (await staging.length() != file.bytes) {
          throw StateError('${file.name} 未复制完整，已保留原安装文件');
        }
      }
      for (final file in model.files) {
        final target = File(p.join(dir.path, file.name));
        final staging = File('${target.path}.import');
        if (await target.exists()) await target.delete();
        await staging.rename(target.path);
      }
      final state = downloads[id] = ModelDownload(artifactId: id);
      await _finishInstallation(model, dir, state, '离线导入完成，可直接使用');
    } finally {
      _leases.remove(id);
      await settingsChanged();
    }
  }

  Future<void> _finishInstallation(
    ModelArtifact model,
    Directory dir,
    ModelDownload state,
    String message,
  ) async {
    await writeStorageJson(File(p.join(dir.path, 'installed.json')), {
      'identity': model.identity,
      'files': {for (final file in model.files) file.name: file.sha256},
    });
    state.phase = ModelDownloadPhase.installed;
    state.received = model.bytes;
    state.checkedAt = null;
    state.message = message;
  }

  /// Retained streaming weights keep their files leased between batches.
  void Function() retainModel(String id) {
    _leases[id] = (_leases[id] ?? 0) + 1;
    var released = false;
    return () {
      if (released) return;
      released = true;
      final left = (_leases[id] ?? 1) - 1;
      if (left <= 0) {
        _leases.remove(id);
      } else {
        _leases[id] = left;
      }
      _publish();
    };
  }

  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) async {
    await initialize();
    final model = artifact(id);
    if (model?.retired == true && !installed(id)) {
      throw StateError('任务使用的模型已下架且未安装，断点已保留；请用其他模型重新创建任务');
    }
    if (model == null || !installed(id)) throw StateError('请先下载模型 $id');
    _leases[id] = (_leases[id] ?? 0) + 1;
    _publish();
    try {
      return await action(model, await modelDirectory(model));
    } finally {
      final remaining = (_leases[id] ?? 1) - 1;
      if (remaining <= 0) {
        _leases.remove(id);
      } else {
        _leases[id] = remaining;
      }
      _publish();
    }
  }

  Future<void> remove(String id) async {
    await initialize();
    if (inUse(id) || _transfers.containsKey(id)) {
      throw StateError('模型正在使用，请先停止任务');
    }
    final model = artifact(id)!;
    final root = (await modelRoot()).absolute.path;
    final dir = await modelDirectory(model);
    if (!p.isWithin(root, dir.absolute.path)) throw StateError('模型目录无效');
    if (await dir.exists()) await dir.delete(recursive: true);
    downloads.remove(id);
    diagnostics.remove(id);
    // Keep bindings so a pending task never silently switches to an online service.
    await settingsChanged();
  }

  void _publish() {
    if (_closed) return;
    ModelBackgroundTasks.downloads(activeDownloads);
    notifyListeners();
  }
}

Future<String> modelFileHash(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);

extension ModelCancellationCheck on CancelToken {
  void throwIfCancellationRequested() {
    if (isCancelled) throw cancelError ?? StateError('任务已取消');
  }
}
