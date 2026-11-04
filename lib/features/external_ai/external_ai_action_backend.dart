import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../models/managed_subtitle_asset.dart';
import '../../models/transcription_status.dart';
import '../../models/video_item.dart';
import '../../services/ai_subtitle_translator.dart';
import '../../services/ai_subtitle_api_settings.dart';
import '../../services/internal_media_picker_source.dart';
import '../../services/library_service.dart';
import '../../services/media_playback_service.dart';
import '../../services/subtitle_discovery_service.dart';
import '../../services/subtitle_translate_settings.dart';
import '../../services/subtitle_translation_service.dart';
import '../../services/task_subtitle_storage_service.dart';
import '../../services/transcription_manager.dart';
import '../../utils/app_data_paths.dart';
import '../model_center/model_catalog.dart';
import '../model_center/asr_language_options.dart';
import '../model_center/model_center_service.dart';
import 'external_ai_actions.dart';
import 'external_ai_library_source.dart';
import 'external_ai_processing_backend.dart';

/// Reuses the application's single native queue and model/resource owners on
/// Windows, macOS and Linux. No shell, download endpoint or media data leaves it.
class ExternalAiPlayerBackend
    implements ExternalAiActionBackend, ExternalAiProcessingBackend {
  ExternalAiPlayerBackend({
    required this.library,
    required this.manager,
    MediaPlaybackService? playback,
    this.translationSettings,
    this.mediaProcessingConsent,
  }) : playback = playback ?? MediaPlaybackService();
  final LibraryService library;
  final TranscriptionManager manager;
  final MediaPlaybackService playback;
  final SubtitleTranslateSettings? translationSettings;
  final Future<void> Function(VideoItem)? mediaProcessingConsent;

  Future<void> _checkProcessingConsent(
    VideoItem item,
    void Function() guard,
  ) async {
    guard();
    // Retired source metadata in the standalone edition does not turn an
    // existing local file back into an online media acquisition entry point.
    if (kAppDataFolderName.endsWith('Community')) {
      if (SubtitleDiscoveryService.localVideoPath(item.path) == null) {
        throw ExternalAiActionError('社区版仅允许本地媒体');
      }
      return;
    }
    if (item.sourceRef?.cloudDrive != null ||
        item.sourceRef?.podcast != null ||
        item.sourceRef?.kind.name == 'bilibiliStream' ||
        SubtitleDiscoveryService.localVideoPath(item.path) == null) {
      final check = mediaProcessingConsent;
      if (check == null) {
        throw ExternalAiActionError('此来源的处理授权尚未初始化，请在应用内检查个人使用声明后重试');
      }
      await check(item);
      guard();
    }
  }

  ModelCenterService get center => manager.modelCenter;

  @override
  void addTaskListener(void Function() listener) =>
      manager.addListener(listener);
  @override
  void removeTaskListener(void Function() listener) =>
      manager.removeListener(listener);

  @override
  Future<Map<String, dynamic>> options() async {
    await center.initialize();
    await translationSettings?.ensureLoaded();
    final services = <Map<String, dynamic>>[];
    for (final profile in center.profiles.values.where((p) => !p.local)) {
      final languages = center.languageOptionsFor(profile);
      final configured =
          profile.kind == TranscriptionServiceKind.gongyi ||
          (await center.readSecret(profile.id)).trim().isNotEmpty;
      services.add({
        'id': profile.id,
        'name': profile.name,
        'kind': profile.kind.name,
        'selected': center.asrProfileId == profile.id,
        'configured': configured,
        'requiresLocalModel': false,
        'uploadsAudio': true,
        'languages': [
          for (final code in languages.codes)
            {'code': code, 'label': languages.label(code)},
        ],
      });
    }
    return {
      'current': {
        'serviceId': center.asrProfile.id,
        'name': center.asrProfile.name,
        'kind': center.asrProfile.kind.name,
        'sourceLanguage': center.effectiveAsrLanguage,
        'requiresLocalModel': center.asrProfile.local,
        'translationModelId': center.translationModelId,
        if (translationSettings != null)
          'translation': {
            'provider': translationSettings!.providerEnZh.name,
            'sourceLanguage': translationSettings!.sourceLanguage,
            'targetLanguage': translationSettings!.targetLanguage,
            'mode': translationSettings!.mode.name,
          },
      },
      'services': services,
      'models': [
        for (final m in center.catalog.where(
          (m) =>
              !m.retired &&
              [
                ModelPurpose.transcription,
                ModelPurpose.translation,
                ModelPurpose.enhancement,
              ].contains(m.purpose),
        ))
          {
            'id': m.id,
            'name': m.name,
            'purpose': m.purpose.name,
            'installed': center.installed(m.id),
            'ready':
                center.installed(m.id) &&
                (m.purpose != ModelPurpose.transcription ||
                    center
                        .asrDownloadComponents(m)
                        .every((d) => center.installed(d.id))),
            'bytes': m.bytes,
            'suggestedRamGb': m.suggestedRamGb,
            'languages': _modelLanguages(m),
          },
      ],
      'modes': ['transcribe', 'transcribe_translate'],
      'localOnly': false,
      'modelDownloadAllowed': true,
      'mediaFilesProvided': false,
      'note':
          '日常用 transcription_start，只选媒体和模式，沿用当前模型、语言和翻译设置。processing_options/models_prepare/settings_update 属于独立的高级配置能力。云端/公益服务由播放器上传音频，不需要安装本地转录模型；不会向 Agent 提供音频。',
    };
  }

  Object _modelLanguages(ModelArtifact model) {
    if (model.purpose != ModelPurpose.transcription) return model.languages;
    final languages = center.languageOptionsFor(
      ModelServiceProfile(
        id: 'local:${model.id}',
        name: model.name,
        kind: TranscriptionServiceKind.local,
        model: model.id,
      ),
    );
    return [
      for (final code in languages.codes)
        {'code': code, 'label': languages.label(code)},
    ];
  }

  @override
  Future<Map<String, dynamic>> captureConfiguration(
    Map<String, dynamic> selection,
  ) async {
    await center.initialize();
    final asr = await center.captureExternalTranscription(
      selection['modelId'] as String? ?? 'current',
      selection['sourceLanguage'] as String? ?? center.effectiveAsrLanguage,
    );
    if (!asr.profile.local &&
        asr.profile.kind != TranscriptionServiceKind.gongyi &&
        (await center.readSecret(asr.profile.id)).trim().isEmpty) {
      throw ExternalAiActionError('所选云端服务尚未配置密钥，请先在软件服务管理中配置；Agent 不读取密钥');
    }
    ModelJobSpec? translation;
    TranscriptTranslateChoice? remoteChoice, currentChoice;
    SmartTranslationPolicy? localSmart;
    String? target = selection['targetLanguage'] as String?;
    if (selection['mode'] == 'transcribe_translate') {
      final chosen = selection['translationModelId'] as String?;
      if (chosen == null && translationSettings != null) {
        await translationSettings!.ensureLoaded();
        await translationSettings!.refreshBinding();
        final current = TranscriptTranslateChoice.current(translationSettings!);
        currentChoice = current;
        if (current.provider != SubtitleTranslateProvider.local) {
          if (current.provider == SubtitleTranslateProvider.ai) {
            final metadata = await AiSubtitleApiSettingsStore().load();
            if (!metadata.ready) {
              throw ExternalAiActionError('当前 AI 翻译接口未配置完整，请先在软件中配置');
            }
          }
          remoteChoice = current;
        }
        target ??= current.targetLanguage;
      }
      if (remoteChoice == null) {
        final model = center.artifact(chosen ?? center.translationModelId);
        if (model == null ||
            model.retired ||
            model.purpose != ModelPurpose.translation) {
          throw ExternalAiActionError('当前本地翻译模型不可用，请选择清单中的翻译模型');
        }
        target ??= 'zh-CN';
        localSmart = selection['targetLanguage'] == null
            ? currentChoice?.smartPolicy
            : null;
        if (localSmart != null) {
          localSmart.validate(subtitleLanguagesForModel(model.languages));
        }
        final base = target.toLowerCase().split('-').first;
        if (localSmart == null &&
            model.languages.isNotEmpty &&
            !model.languages.any(
              (l) =>
                  l.toLowerCase().split('-').first == base ||
                  l == 'multilingual',
            )) {
          throw ExternalAiActionError('当前本地翻译模型未声明支持目标语言');
        }
        translation = ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'local:${model.id}',
            name: model.name,
            kind: TranscriptionServiceKind.local,
            model: model.id,
          ),
          artifactIdentity: model.identity,
          threads: center.threads,
          translation: center.translationOptionsFor(model.id),
          allowModelDownload: false,
        );
      }
    }
    final required = <String>{
      if (asr.profile.local) asr.profile.model,
      ...asr.enhancementModels.keys,
      if (translation != null) translation.profile.model,
    };
    // The community queue's independent VAD is part of its installed contract.
    if (asr.profile.local && kAppDataFolderName.endsWith('Community')) {
      for (final model in center.catalog.where(
        (m) => m.id == 'silero-vad-16k',
      )) {
        required.add(model.id);
      }
    }
    final missing = required.where((id) => !center.installed(id)).toList();
    final usesRemote = !asr.profile.local || remoteChoice != null;
    return {
      'asr': asr.toJson(),
      if (translation != null) 'translation': translation.toJson(),
      if (translation != null)
        'localTranslationPolicy': {
          'source': currentChoice?.sourceLanguage ?? asr.profile.language,
          'direction': currentChoice?.direction.name ?? 'auto',
          if (localSmart != null) 'smart': localSmart.toJson(),
        },
      'targetLanguage': ?target,
      if (remoteChoice != null)
        'remoteTranslation': {
          'provider': remoteChoice.provider.name,
          'source': remoteChoice.sourceLanguage,
          'target': target ?? remoteChoice.targetLanguage,
          'direction': remoteChoice.direction.name,
          'aiOptions': remoteChoice.aiOptions.toJson(),
          'apiProviderId': remoteChoice.apiProviderId,
          if (remoteChoice.apiEndpoint != null)
            'endpoint': remoteChoice.apiEndpoint!.toJson(),
          if (remoteChoice.smartPolicy != null &&
              selection['targetLanguage'] == null)
            'smart': remoteChoice.smartPolicy!.toJson(),
        },
      'usesRemote': usesRemote,
      'missingModelIds': missing,
      'downloadBytes': missing.fold<int>(
        0,
        (sum, id) => sum + (center.artifact(id)?.bytes ?? 0),
      ),
      'summary': {
        'service': asr.profile.name,
        'sourceLanguage': asr.profile.language,
        'mode': selection['mode'],
        'translation': translation?.profile.name ?? remoteChoice?.provider.name,
        'targetLanguage':
            localSmart?.summary ??
            (selection['targetLanguage'] == null
                ? remoteChoice?.smartPolicy?.summary
                : null) ??
            target,
        'uploadsAudio': !asr.profile.local,
        'uploadsText': remoteChoice != null,
      },
    };
  }

  @override
  Future<void> validateConfiguration(Map<String, dynamic> configuration) async {
    await center.initialize();
    for (final key in ['asr', 'translation']) {
      if (configuration[key] is! Map) continue;
      final spec = ModelJobSpec.fromJson(
        Map<String, dynamic>.from(configuration[key] as Map),
      );
      if (spec.profile.local) {
        final model = center.artifact(spec.profile.model);
        if (model?.retired != false ||
            model?.identity != spec.artifactIdentity ||
            spec.enhancementModels.entries.any(
              (e) => center.artifact(e.key)?.identity != e.value,
            )) {
          throw ExternalAiActionError('任务模型版本已变化，请重新准备计划');
        }
        if (configuration['downloadAuthorized'] != true) {
          center.requirePreparedModels(spec);
        }
      } else {
        final profile = center.profiles[spec.profile.id];
        if (profile == null ||
            profile.local ||
            jsonEncode(_profileIdentity(profile)) !=
                jsonEncode(_profileIdentity(spec.profile))) {
          throw ExternalAiActionError('云端服务配置已变化，请重新准备计划');
        }
      }
    }
    if (configuration['remoteTranslation'] case final Map remote) {
      if (remote['provider'] == 'ai') {
        final current = await AiSubtitleApiSettingsStore().loadMetadata();
        final frozen = remote['endpoint'] as Map?;
        if (frozen == null ||
            current.providerId != frozen['providerId'] ||
            current.baseUrl != frozen['baseUrl'] ||
            current.model != frozen['model']) {
          throw ExternalAiActionError('AI 翻译服务已变化，请重新准备任务');
        }
      }
    }
  }

  List<Object?> _profileIdentity(ModelServiceProfile p) => [
    p.id,
    p.kind.name,
    p.endpoint,
    p.model,
    p.appId,
    p.cloudProvider == null
        ? null
        : (p.cloudOptions ?? const CloudAsrOptions()).toJson(),
    p.cloudProvider == null
        ? null
        : (p.cloudCapabilities ??
                  cloudAsrCapabilities(p.cloudProvider!, p.model))
              .toJson(),
  ];

  @override
  Future<Map<String, dynamic>> modelStatus(List<String> ids) async {
    await center.initialize();
    return {
      'models': [
        for (final id in ids)
          if (center.artifact(id) case final m?)
            {
              'id': id, 'name': m.name, 'installed': center.installed(id),
              'status': center.downloads[id]?.phase.name ?? 'not_installed',
              'receivedBytes': center.downloads[id]?.received ?? 0,
              'totalBytes': m.bytes,
              'bytesPerSecond': center.downloads[id]?.bytesPerSecond ?? 0,
              // Native download messages contain URLs and local paths; never serialize.
              if (center.downloads[id]?.phase == ModelDownloadPhase.failed)
                'error': '下载失败，可在模型中心检查或用 models_prepare 重试',
            },
      ],
    };
  }

  List<String> _validModels(List<String> ids) {
    if (ids.any(
      (id) =>
          center.artifact(id)?.retired != false ||
          ![
            ModelPurpose.transcription,
            ModelPurpose.translation,
            ModelPurpose.enhancement,
          ].contains(center.artifact(id)?.purpose),
    )) {
      throw ExternalAiActionError('只允许准备模型清单中的现有转录、翻译或依赖组件');
    }
    return ids;
  }

  List<String> _expandedModels(List<String> ids) {
    _validModels(ids);
    return {
      for (final id in ids) ...[
        id,
        if (center.artifact(id)?.purpose == ModelPurpose.transcription)
          ...center
              .asrDownloadComponents(center.artifact(id)!)
              .map((m) => m.id),
      ],
    }.toList();
  }

  @override
  Future<Map<String, dynamic>> modelPreview(List<String> ids) async {
    await center.initialize();
    ids = _expandedModels(ids);
    return {
      'modelIds': ids,
      'downloadBytes': ids
          .where((id) => !center.installed(id))
          .fold<int>(0, (n, id) => n + center.artifact(id)!.bytes),
      'note': '只下载固定清单中的模型；沿用模型中心选源、校验和断点，不改当前默认模型。',
    };
  }

  @override
  Future<void> prepareModels(List<String> ids, void Function() guard) async {
    await center.initialize();
    ids = _expandedModels(ids);
    for (final id in ids) {
      guard();
      if (!center.installed(id)) await center.enqueue(id);
    }
  }

  @override
  Future<Map<String, dynamic>> defaultsPreview(
    Map<String, dynamic> changes,
  ) async {
    await center.initialize();
    await translationSettings?.ensureLoaded();
    if (changes['translationProvider'] != null &&
        !['local', 'bing', 'ai'].contains(changes['translationProvider'])) {
      throw ExternalAiActionError('请选择已适配的翻译方式');
    }
    if (changes['translationMode'] != null &&
        !['smart', 'fixed'].contains(changes['translationMode'])) {
      throw ExternalAiActionError('翻译模式需要 smart 或 fixed');
    }
    if (changes['translationMode'] == 'smart' &&
        changes['targetLanguage'] != null) {
      throw ExternalAiActionError('智能互译使用软件中的现有规则；指定目标语言请使用 fixed 模式');
    }
    final service = changes['serviceId'] as String?;
    if (service != null || changes['sourceLanguage'] != null) {
      await center.captureExternalTranscription(
        service ?? 'current',
        changes['sourceLanguage'] as String? ?? 'auto',
      );
    }
    final tr = changes['translationModelId'] as String?;
    if (tr != null &&
        (center.artifact(tr)?.purpose != ModelPurpose.translation ||
            center.artifact(tr)?.retired != false)) {
      throw ExternalAiActionError('翻译模型不在可用清单中');
    }
    if (changes['targetLanguage'] != null &&
        !RegExp(
          r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$',
        ).hasMatch(changes['targetLanguage'] as String)) {
      throw ExternalAiActionError('目标语言无效');
    }
    return {
      'changes': changes,
      'before': {
        'serviceId': center.asrProfileId,
        'sourceLanguage': center.effectiveAsrLanguage,
        'translationModelId': center.translationModelId,
        'targetLanguage': translationSettings?.targetLanguage,
        'translationProvider': translationSettings?.providerEnZh.name,
      },
      'note': '修改以后新任务的默认设置；已排队任务保持原配置。此操作始终需要在播放器确认。',
    };
  }

  @override
  Future<void> updateDefaults(
    Map<String, dynamic> changes,
    void Function() guard,
  ) async {
    await defaultsPreview(changes);
    guard();
    final oldId = center.asrProfileId,
        oldTranslation = center.translationModelId;
    final oldProfiles = {...center.profiles},
        oldLanguages = {...center.asrLanguagePreferences};
    final oldSelected = center.selectedLanguage;
    final oldProvider = translationSettings?.providerEnZh;
    final oldMode = translationSettings?.mode;
    final oldSource = translationSettings?.sourceLanguage,
        oldTarget = translationSettings?.targetLanguage;
    final spec = await center.captureExternalTranscription(
      changes['serviceId'] as String? ?? 'current',
      changes['sourceLanguage'] as String? ??
          (changes['serviceId'] != null ? 'auto' : center.effectiveAsrLanguage),
    );
    guard();
    try {
      if (changes['serviceId'] != null || changes['sourceLanguage'] != null) {
        center.profiles[spec.profile.id] = spec.profile;
        center.asrProfileId = spec.profile.id;
        center.selectedLanguage = spec.profile.language;
        center.asrLanguagePreferences[asrLanguagePreferenceKey(spec.profile)] =
            spec.profile.language;
      }
      if (changes['translationModelId'] is String) {
        center.translationModelId = changes['translationModelId'] as String;
      }
      await center.settingsChanged();
      guard();
      if (changes['translationProvider'] != null ||
          changes['translationModelId'] != null) {
        if (translationSettings == null) {
          throw ExternalAiActionError('翻译设置尚未初始化');
        }
        await translationSettings!.setProviderEnZh(
          changes['translationProvider'] != null
              ? SubtitleTranslateProvider.values.byName(
                  changes['translationProvider'] as String,
                )
              : SubtitleTranslateProvider.local,
        );
        guard();
      }
      if (changes['translationMode'] != null ||
          changes['targetLanguage'] != null) {
        if (translationSettings == null) {
          throw ExternalAiActionError('翻译设置尚未初始化');
        }
        await translationSettings!.setMode(
          changes['translationMode'] == 'smart'
              ? SubtitleTranslationMode.smart
              : SubtitleTranslationMode.fixed,
        );
        guard();
      }
      if (changes['targetLanguage'] is String) {
        if (translationSettings == null) {
          throw ExternalAiActionError('翻译设置尚未初始化');
        }
        await translationSettings!.setLanguages(
          target: changes['targetLanguage'] as String,
        );
        guard();
      }
    } catch (_) {
      // Restore only this operation's unchanged values. Never replace the whole
      // profile/language maps: the user may edit another profile during IO.
      if (center.asrProfileId == spec.profile.id) center.asrProfileId = oldId;
      if (center.translationModelId == changes['translationModelId']) {
        center.translationModelId = oldTranslation;
      }
      if (identical(center.profiles[spec.profile.id], spec.profile)) {
        if (oldProfiles.containsKey(spec.profile.id)) {
          center.profiles[spec.profile.id] = oldProfiles[spec.profile.id]!;
        } else {
          center.profiles.remove(spec.profile.id);
        }
      }
      final key = asrLanguagePreferenceKey(spec.profile);
      if (center.asrLanguagePreferences[key] == spec.profile.language) {
        if (oldLanguages.containsKey(key)) {
          center.asrLanguagePreferences[key] = oldLanguages[key]!;
        } else {
          center.asrLanguagePreferences.remove(key);
        }
      }
      if (center.selectedLanguage == spec.profile.language) {
        center.selectedLanguage = oldSelected;
      }
      await center.settingsChanged();
      if (oldProvider != null) {
        await translationSettings!.setProviderEnZh(oldProvider);
        if (oldMode != null) await translationSettings!.setMode(oldMode);
        await translationSettings!.setLanguages(
          source: oldSource,
          target: oldTarget,
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> validateMedia(VideoItem media) async {
    final local = SubtitleDiscoveryService.localVideoPath(media.path);
    if (kAppDataFolderName.endsWith('Community') && local == null) {
      throw ExternalAiActionError('社区版仅允许本地媒体');
    }
    if (local != null) {
      if (!await File(local).exists()) {
        throw ExternalAiActionError('本地媒体不可用，请在播放器检查文件');
      }
    } else if (media.sourceRef == null) {
      throw ExternalAiActionError('该媒体缺少可处理的来源，请先在播放器导入');
    }
    if (library.getVideo(media.id) == null &&
        media.sourceRef?.podcast == null &&
        media.sourceRef?.cloudDrive == null &&
        media.sourceRef?.kind.name != 'bilibiliStream') {
      throw ExternalAiActionError('请先将此临时媒体加入媒体库，再提交转录或译文');
    }
  }

  @override
  String mediaIdentity(VideoItem media) {
    final ref = media.sourceRef;
    // Cached media paths may legitimately change during materialization.
    final source = ref?.podcast != null
        ? ['podcast', ref!.podcast!.episodeId]
        : ref?.cloudDrive != null
        ? ['cloud', ref!.cloudDrive!.sourceKey]
        : ref?.bvid != null || ref?.aid != null
        ? ['bilibili', ref?.bvid, ref?.aid, ref?.cid, ref?.page]
        : ['local-or-url', media.path];
    return sha256
        .convert(utf8.encode(jsonEncode([media.id, source])))
        .toString();
  }

  Future<VideoItem> prepareDocumentMedia(
    VideoItem media,
    void Function() guard,
  ) => _prepareMedia(media, guard);

  Future<VideoItem> _prepareMedia(
    VideoItem media,
    void Function() guard,
  ) async {
    guard();
    if (library.getVideo(media.id) == null) {
      final source = InternalMediaPickerSource(
        library: library,
        manager: manager,
      );
      await source.prepareSelection([source.nodeFor(media)]);
      guard();
    }
    final stored = library.getVideo(media.id);
    if (stored == null ||
        stored.isRecycled ||
        mediaIdentity(stored) != mediaIdentity(media)) {
      throw ExternalAiActionError('媒体已变化或不能加入处理队列，请在播放器重新选择');
    }
    return stored;
  }

  @override
  Future<String> enqueue(
    VideoItem media,
    String taskId,
    Map<String, dynamic> configuration,
    void Function() guard,
  ) async {
    await _checkProcessingConsent(media, guard);
    await validateConfiguration(configuration);
    guard();
    final item = await _prepareMedia(media, guard);
    final key = manager.mediaKeyForVideo(item.path, videoId: item.id);
    final existing = manager
        .getQueueSnapshot()
        .where((row) => row.mediaKey == key)
        .firstOrNull;
    if (existing != null) {
      if (manager.externalTaskIdFor(key) != taskId ||
          !manager.externalTaskIsControlled(key)) {
        return 'conflict';
      }
      await manager.flushExternalTasks();
      return 'queued';
    }
    final asr = ModelJobSpec.fromJson({
      ...Map<String, dynamic>.from(configuration['asr'] as Map),
      'allowModelDownload': configuration['downloadAuthorized'] == true,
    });
    final translationJson = configuration['translation'];
    final remote = configuration['remoteTranslation'];
    final choice = remote is Map
        ? TranscriptTranslateChoice(
            enabled: true,
            direction: TranscriptTranslateDirection.fromStorage(
              remote['direction'] as String?,
            ),
            provider: SubtitleTranslateProvider.values.byName(
              remote['provider'] as String,
            ),
            aiOptions: AiSubtitleTranslationSettings.fromJson(
              Map<String, dynamic>.from(remote['aiOptions'] as Map),
            ),
            apiProviderId: remote['apiProviderId'] as String? ?? '',
            apiEndpoint: remote['endpoint'] is Map
                ? AiSubtitleApiSettings.fromJson(
                    Map<String, dynamic>.from(remote['endpoint'] as Map),
                  )
                : null,
            smartPolicy: remote['smart'] is Map
                ? SmartTranslationPolicy.fromJson(remote['smart'] as Map)
                : null,
            sourceLanguage: remote['source'] as String?,
            targetLanguage: remote['target'] as String?,
          )
        : translationJson is Map
        ? TranscriptTranslateChoice(
            enabled: true,
            direction: TranscriptTranslateDirection.fromStorage(
              (configuration['localTranslationPolicy'] as Map?)?['direction']
                  as String?,
            ),
            provider: SubtitleTranslateProvider.local,
            aiOptions: AiSubtitleTranslationSettings.defaults,
            localSpecification: ModelJobSpec.fromJson({
              ...Map<String, dynamic>.from(translationJson),
              'allowModelDownload': configuration['downloadAuthorized'] == true,
            }),
            sourceLanguage:
                (configuration['localTranslationPolicy'] as Map?)?['source']
                    as String? ??
                asr.profile.language,
            smartPolicy:
                (configuration['localTranslationPolicy'] as Map?)?['smart']
                    is Map
                ? SmartTranslationPolicy.fromJson(
                    (configuration['localTranslationPolicy'] as Map)['smart']
                        as Map,
                  )
                : null,
            targetLanguage: configuration['targetLanguage'] as String,
          )
        : const TranscriptTranslateChoice.off();
    guard();
    final result = await manager.startTranscription(
      item.path,
      videoId: item.id,
      videoTitle: item.title,
      libraryService: library,
      sourceItem: item,
      autoStart: false,
      preparedSpecification: asr,
      translateChoice: choice,
      externalTaskId: taskId,
      externalRemoteAuthorized: configuration['remoteAuthorized'] == true,
      externalDownloadAuthorized: configuration['downloadAuthorized'] == true,
    );
    await manager.flushExternalTasks();
    return result == TranscriptionEnqueueResult.added ? 'queued' : 'conflict';
  }

  @override
  List<ExternalAiNativeTask> tasks() => [
    for (final row in manager.getQueueSnapshot())
      if (row.videoId != null)
        ExternalAiNativeTask(
          mediaId: row.videoId!,
          taskId: manager.externalTaskIdFor(row.mediaKey),
          status: row.status == TranscriptionStatus.idle
              ? (row.isStarted ? 'queued' : 'paused')
              : row.status.name,
          progress: row.progress,
          translationProgress: row.translationProgress,
          failure: row.status != TranscriptionStatus.error
              ? null
              : row.statusMessage.contains('内存不足')
              ? ExternalAiTaskFailure.resourceLimited
              : row.statusMessage.contains('模型') &&
                    (row.statusMessage.contains('缺失') ||
                        row.statusMessage.contains('未准备') ||
                        row.statusMessage.contains('版本已'))
              ? ExternalAiTaskFailure.modelUnavailable
              : row.statusMessage.contains('文件不存在') ||
                    row.statusMessage.contains('来源不可用')
              ? ExternalAiTaskFailure.sourceUnavailable
              : ExternalAiTaskFailure.processingFailed,
        ),
  ];

  @override
  Future<bool> control(
    VideoItem media,
    String taskId,
    String action,
    void Function() guard,
  ) async {
    final item = library.getVideo(media.id);
    if (item == null || mediaIdentity(item) != mediaIdentity(media)) {
      return false;
    }
    final key = manager.mediaKeyForVideo(item.path, videoId: item.id);
    if (manager.externalTaskIdFor(key) != taskId ||
        !manager.externalTaskIsControlled(key)) {
      return false;
    }
    final task = manager
        .getQueueSnapshot()
        .where((t) => t.mediaKey == key)
        .firstOrNull;
    if (task == null || task.status == TranscriptionStatus.completed) {
      return false;
    }
    if (action != 'pause') await _checkProcessingConsent(item, guard);
    guard();
    final bool applied;
    switch (action) {
      case 'pause':
        applied = manager.pauseTask(key);
      case 'retry':
        applied =
            task.status == TranscriptionStatus.error && manager.retryTask(key);
      case 'start':
      case 'resume':
        manager.startTask(key);
        applied = true;
      default:
        return false;
    }
    await manager.flushExternalTasks();
    return applied;
  }

  @override
  Future<Map<String, dynamic>> publishTranslation(
    ExternalAiSubtitleDocument source,
    String draftId,
    String language,
    List<String> texts,
    void Function() guard,
  ) async {
    final item = await _prepareMedia(source.media, guard);
    Future<void> verifySource() async {
      if (sha256.convert(await File(source.path).readAsBytes()).toString() !=
          source.revision) {
        throw ExternalAiActionError('源字幕已变化，译文草稿保留，请重新创建草稿');
      }
      guard();
    }

    final storage = TaskSubtitleStorageService(
      dataRootOverride: library.dataRootDirOrNull,
    );
    final directory = await storage.taskDirectory(item.id, create: true);
    guard();
    // File name and timings are entirely app-generated, never Agent supplied.
    final file = File(p.join(directory.path, 'agent-translation-$draftId.srt'));
    final buffer = StringBuffer();
    for (var i = 0; i < source.cues.length; i++) {
      final cue = source.cues[i];
      buffer.writeln(i + 1);
      buffer.writeln(
        '${_timestamp(cue.startTime)} --> ${_timestamp(cue.endTime)}',
      );
      buffer.writeln(texts[i]);
      buffer.writeln();
    }
    final content = buffer.toString(),
        hash = sha256.convert(utf8.encode(content)).toString();
    if (await file.exists()) {
      if (sha256.convert(await file.readAsBytes()).toString() != hash) {
        throw ExternalAiActionError('同一草稿已有不同结果，保留现存字幕；请新建草稿');
      }
    } else {
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      await verifySource();
      guard();
      await temporary.rename(file.path);
    }
    await verifySource();
    guard();
    final sourceAsset = library.managedSubtitleAssetForPath(
      item.id,
      source.path,
    );
    final asset = await library.registerManagedSubtitleAsset(
      item.id,
      path: file.path,
      kind: ManagedSubtitleAssetKind.translated,
      displayName: 'Agent 译文 · $language',
      language: language,
      sourceAssetId: sourceAsset?.assetId,
      contentHash: hash,
      sourceLabel: '外部 Agent 译文',
      machineGenerated: true,
      shareWithBilibiliPart: false,
      authorize: guard,
    );
    if (asset == null) throw ExternalAiActionError('媒体不可用，译文未登记');
    return {
      'mediaId': item.id,
      'assetId': asset.assetId,
      'displayName': asset.displayName,
      'language': asset.language,
      'kind': 'translated',
    };
  }

  static String _timestamp(Duration time) {
    final ms = time.inMilliseconds;
    String pad(int n, int width) => n.toString().padLeft(width, '0');
    return '${pad(ms ~/ 3600000, 2)}:${pad(ms ~/ 60000 % 60, 2)}:${pad(ms ~/ 1000 % 60, 2)},${pad(ms % 1000, 3)}';
  }

  @override
  Future<bool> selectSecondary(
    VideoItem media,
    String assetId,
    void Function() guard, {
    ExternalAiSubtitleDocument? source,
  }) async {
    final item = library.getVideo(media.id);
    if (item == null ||
        item.isRecycled ||
        mediaIdentity(item) != mediaIdentity(media)) {
      throw ExternalAiActionError('媒体已不可用');
    }
    final asset = item.managedSubtitleAssets
        .where((a) => a.assetId == assetId)
        .firstOrNull;
    if (asset == null ||
        asset.kind != ManagedSubtitleAssetKind.translated ||
        !await File(asset.path).exists()) {
      throw ExternalAiActionError('译文字幕不存在或不属于此媒体');
    }
    final primary =
        item.subtitlePath ??
        (source?.media.id == item.id ? source?.path : null);
    final previousPrimary = item.subtitlePath;
    if (primary == null ||
        primary == asset.path ||
        !await File(primary).exists()) {
      throw ExternalAiActionError('请先在播放器选择原文主字幕；译文已保存在字幕管理区');
    }
    guard();
    final intent = playback.subtitleSelectionRevision;
    await library.updateVideoSubtitles(
      item.id,
      primary,
      false,
      secondarySubtitlePath: asset.path,
      shouldApply: () {
        guard();
        if (item.subtitlePath != previousPrimary &&
            item.subtitlePath != primary) {
          throw ExternalAiActionError('主字幕选择已变化，请重新选择副字幕');
        }
        if (playback.currentItem?.id == item.id &&
            playback.subtitleSelectionRevision != intent) {
          throw ExternalAiActionError('实时字幕选择已变化，请重新选择副字幕');
        }
        return true;
      },
    );
    guard();
    if (playback.subtitleSelectionRevision != intent) return false;
    return playback.loadSubtitlePathsForCurrentItem(
      itemId: item.id,
      paths: [primary, asset.path],
      shouldApply: () {
        guard();
        return true;
      },
    );
  }
}
