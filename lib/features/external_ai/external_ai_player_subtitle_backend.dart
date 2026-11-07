import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../models/video_item.dart';
import '../../services/ai_subtitle_api_settings.dart';
import '../../services/ai_subtitle_translator.dart';
import '../../services/subtitle_optimization.dart';
import '../../services/subtitle_optimization_background.dart';
import '../../services/subtitle_translate_settings.dart';
import '../../services/subtitle_translation_service.dart';
import '../../services/task_subtitle_storage_service.dart';
import '../../utils/subtitle_parser.dart';
import '../model_center/model_catalog.dart';
import 'external_ai_action_backend.dart';
import 'external_ai_actions.dart';
import 'external_ai_library_source.dart';
import 'external_ai_subtitle_backend.dart';

/// Application adapter, shared by the three desktop platforms and local-only
/// edition. A change to app batching/progress stays here, never in Agent logic.
class ExternalAiPlayerSubtitleBackend implements ExternalAiSubtitleBackend {
  ExternalAiPlayerSubtitleBackend(
    this.native, {
    SubtitleTranslationService? service,
    AiSubtitleApiSettingsStore? apiSettings,
    SubtitleAiConnectionStore? connections,
    this.optimizer,
  }) : service = service ?? SubtitleTranslationService.instance,
       apiSettings = apiSettings ?? AiSubtitleApiSettingsStore(),
       connections = connections ?? SubtitleAiConnectionStore();
  final ExternalAiPlayerBackend native;
  final SubtitleTranslationService service;
  final AiSubtitleApiSettingsStore apiSettings;
  final SubtitleAiConnectionStore connections;
  final SubtitleOptimizer? optimizer;
  final _recognitionResults =
      <
        String,
        ({String mediaId, String identity, String assetId, String stamp})
      >{};
  static String _subtitleStamp(String path) {
    final stat = File(path).statSync();
    if (stat.type != FileSystemEntityType.file) return '';
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  }

  @override
  String mediaIdentity(VideoItem item) => native.mediaIdentity(item);
  @override
  List<ExternalAiNativeTask> tasks() {
    final tasks = native.tasks();
    for (final task in tasks) {
      if (task.status != 'completed' || task.taskId == null) continue;
      final item = native.library.getVideo(task.mediaId);
      if (item == null) continue;
      final path = native.manager.getGeneratedSrtPathForVideo(
        item.path,
        videoId: item.id,
      );
      final asset = path == null
          ? null
          : native.library.managedSubtitleAssetForPath(item.id, path);
      if (asset != null && !_recognitionResults.containsKey(task.taskId)) {
        try {
          final stamp = _subtitleStamp(asset.path);
          if (stamp.isNotEmpty) {
            _recognitionResults[task.taskId!] = (
              mediaId: item.id,
              identity: mediaIdentity(item),
              assetId: asset.assetId,
              stamp: stamp,
            );
          }
        } on FileSystemException {
          /* A later completion notification can retry missing output metadata. */
        }
      }
    }
    return tasks;
  }

  @override
  void addTaskListener(void Function() listener) =>
      native.addTaskListener(listener);
  @override
  void removeTaskListener(void Function() listener) =>
      native.removeTaskListener(listener);
  static bool _isLocal(AiSubtitleApiSettings endpoint) => [
    'localhost',
    '127.0.0.1',
    '::1',
  ].contains(Uri.tryParse(endpoint.baseUrl)?.host);
  static AiSubtitleApiSettings _safeEndpoint(AiSubtitleApiSettings endpoint) {
    final uri = Uri.tryParse(endpoint.baseUrl);
    if (!endpoint.ready ||
        uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !(uri.scheme == 'https' ||
            uri.scheme == 'http' && _isLocal(endpoint))) {
      throw ExternalAiActionError('请在软件内检查接口地址：使用HTTPS或本机HTTP，不要把密钥放进地址');
    }
    return endpoint.copyWith(apiKey: '', profiles: const {});
  }

  static String _language(Object? value, String fallback) {
    final v = value ?? fallback;
    if (v is! String ||
        !(RegExp(r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$').hasMatch(v) ||
            ['auto', 'mul'].contains(v))) {
      throw ExternalAiActionError('语言代码无效');
    }
    return v;
  }

  static SmartTranslationRule _smartRule(Object? value) {
    if (value is! Map ||
        value.keys.any((key) => !['source', 'target'].contains(key))) {
      throw ExternalAiActionError('智能规则只接受source和target语言代码');
    }
    final source = _language(value['source'], 'auto');
    if (['auto', 'mul'].contains(source) || value['target'] is! String) {
      throw ExternalAiActionError('智能规则需要明确源语言和目标语言');
    }
    return SmartTranslationRule(
      source: source,
      target: value['target'] == keepOriginal
          ? keepOriginal
          : _language(value['target'], 'zh-CN'),
    );
  }

  @override
  Future<Map<String, dynamic>> subtitleOptions() async {
    await native.center.initialize();
    await native.translationSettings?.ensureLoaded();
    await native.translationSettings?.refreshBinding();
    final optimization = await SubtitleOptimizationSettings.load();
    final savedConnections = await connections.load();
    final inherited = await apiSettings.loadMetadata();
    final transcription = await native.options();
    var optimizationEndpoint = inherited;
    if (optimization.connectionId.isNotEmpty) {
      try {
        optimizationEndpoint = await connections.endpoint(
          optimization.connectionId,
          withKey: false,
        );
      } catch (_) {
        optimizationEndpoint = const AiSubtitleApiSettings();
      }
    }
    return {
      'executors': ['app', 'agent'],
      'defaultExecutor': 'app',
      'sourceModes': ['auto', 'existing', 'transcribe'],
      'transcription': transcription['current'],
      'configuredTranscriptionServices': transcription['services'],
      'translationPolicy':
          native.translationSettings?.mode == SubtitleTranslationMode.fixed
          ? {
              'mode': 'fixed',
              'sourceLanguage': native.translationSettings!.sourceLanguage,
              'targetLanguage': native.translationSettings!.targetLanguage,
            }
          : {
              'mode': 'smart',
              ...(native.translationSettings?.smartPolicy ??
                      const SmartTranslationPolicy())
                  .toJson(),
            },
      'agentTranslation': {
        'contractVersion': 2,
        'readTool': 'subtitle_work_read',
        'writeTool': 'subtitle_work_write',
        'routing':
            '与软件同一个SmartSubtitleTranslator路由器。按片段返回实际目标语言；保留原文/不确定片段由软件保留，Agent只翻译translationParts并返回partId/text/targetLanguage。',
        'fixed': '所有需要翻译的条目使用选定的目标语言；显式targetLanguage切换本批为单向翻译。',
      },
      'current': {
        'transcription': transcription['current'],
        'optimizationEnabled': optimization.enabled,
        'optimizationConnectionId': optimization.connectionId.isEmpty
            ? inherited.connectionId
            : optimization.connectionId,
        'optimizationPrompt': optimization.prompt,
        'optimization': {
          'enabledByDefault': optimization.enabled,
          'configured': optimizationEndpoint.ready,
          'connectionId': optimizationEndpoint.connectionId,
          'model': optimizationEndpoint.model,
          'definition':
              '修正识别错字、术语和标点，结合视频标题与有限背景；保持原语言、原意、信息量和时间轴，不是总结或翻译。明确要求优化时可单独开启，不受全局开关关闭影响。',
        },
        'translationProvider':
            native.translationSettings?.providerEnZh.name ?? 'bing',
        'sourceLanguage': native.translationSettings?.sourceLanguage ?? 'auto',
        'targetLanguage': native.translationSettings?.targetLanguage ?? 'zh-CN',
        'translationMode': native.translationSettings?.mode.name ?? 'smart',
        'translationPolicy':
            native.translationSettings?.mode == SubtitleTranslationMode.fixed
            ? {
                'mode': 'fixed',
                'sourceLanguage': native.translationSettings!.sourceLanguage,
                'targetLanguage': native.translationSettings!.targetLanguage,
              }
            : {
                'mode': 'smart',
                ...?native.translationSettings?.smartPolicy.toJson(),
              },
      },
      'services': [
        {
          'id': 'bing',
          'provider': 'bing',
          'name': '必应翻译',
          'supportsOptimization': false,
          'supportsTranslation': true,
        },
        for (final entry in savedConnections)
          {
            'id': entry.id,
            'connectionId': entry.id,
            'provider': 'ai',
            'name': entry.name,
            'model': entry.endpoint.model,
            'configured': entry.endpoint.ready,
            'supportsOptimization': true,
            'supportsTranslation': true,
            'isLocalEndpoint': _isLocal(entry.endpoint),
            'credentialStatus': 'managed_in_app',
            'connectionTest': 'not_tested',
          },
      ],
      'localTranslationModels': [
        for (final model in native.center.catalog.where(
          (m) => !m.retired && m.purpose == ModelPurpose.translation,
        ))
          {
            'id': model.id,
            'name': model.name,
            'installed': native.center.installed(model.id),
            'supportsTranslation': true,
            'supportsOptimization': false,
            'languages': model.languages,
          },
      ],
      'setupTool': 'subtitle_service_configure',
      'note':
          '默认沿用软件当前配置，不询问是否改用本地模型；公益/云端语音服务不需要本地转录权重。优化使用支持指令的字幕AI接口（含本机兼容服务），不是总结或翻译。未指定执行方沿用已保存偏好，无偏好用软件；明确让Agent处理用agent，其本身模型不需要软件API Key。',
    };
  }

  @override
  Future<Map<String, dynamic>> captureSubtitlePlan(
    Map<String, dynamic> request,
  ) async {
    await native.center.initialize();
    final settings = native.translationSettings;
    await settings?.ensureLoaded();
    await settings?.refreshBinding();
    final optSettings = await SubtitleOptimizationSettings.load();
    final optimize = request['optimize'] as String,
        translate = request['translate'] as String;
    final prompt =
        request['optimizationInstruction'] as String? ?? optSettings.prompt;
    if (prompt.length > 6000 || prompt.contains('\x00')) {
      throw ExternalAiActionError('优化要求最多6000字');
    }
    SubtitleOptimizationChoice opt = const SubtitleOptimizationChoice.off();
    if (optimize == 'app') {
      final connectionId =
          request['optimizationConnectionId'] as String? ??
          optSettings.connectionId;
      final endpoint = connectionId.isEmpty
          ? await apiSettings.loadMetadata()
          : await connections.endpoint(connectionId, withKey: false);
      if (!endpoint.ready) {
        throw ExternalAiActionError('请先在软件内配置优化AI接口，或让Agent处理');
      }
      opt = SubtitleOptimizationChoice(
        endpoint: _safeEndpoint(endpoint),
        prompt: prompt,
      );
    }
    // Agent text processing must not require installed local weights or an API.
    // Capture metadata only; local specification is built for app translation.
    final current = settings == null
        ? const TranscriptTranslateChoice.automatic()
        : TranscriptTranslateChoice(
            enabled: true,
            direction: settings.direction,
            provider: settings.providerEnZh,
            aiOptions: settings.aiOptions,
            apiEndpoint: settings.binding.api?.copyWith(
              apiKey: '',
              profiles: const {},
            ),
            sourceLanguage: settings.mode == SubtitleTranslationMode.smart
                ? 'auto'
                : settings.sourceLanguage,
            targetLanguage: settings.mode == SubtitleTranslationMode.smart
                ? 'mul'
                : settings.targetLanguage,
            smartPolicy: settings.mode == SubtitleTranslationMode.smart
                ? settings.smartPolicy.copyWith()
                : null,
          );
    var source = _language(
      request['sourceLanguage'],
      current.sourceLanguage ?? 'auto',
    );
    var target = _language(
      request['targetLanguage'],
      current.targetLanguage ?? 'zh-CN',
    );
    if (request['targetLanguage'] != null && ['auto', 'mul'].contains(target)) {
      throw ExternalAiActionError('指定目标语言时请选择明确语言；省略则沿用软件的智能规则');
    }
    final requestedMode = request['translationMode'] ?? 'current';
    if (!['current', 'smart', 'fixed'].contains(requestedMode)) {
      throw ExternalAiActionError('翻译模式需要current、smart或fixed');
    }
    if (requestedMode == 'smart' && request['targetLanguage'] != null) {
      throw ExternalAiActionError(
        '智能互译请使用规则及otherTarget；targetLanguage用于本批单向翻译',
      );
    }
    final hasRuleOverride =
        request['smartRules'] != null ||
        request['otherTarget'] != null ||
        request['keepUncertain'] != null;
    if (hasRuleOverride &&
        (requestedMode == 'fixed' || request['targetLanguage'] != null)) {
      throw ExternalAiActionError('智能规则不能与单向翻译混用');
    }
    SmartTranslationPolicy? smart =
        request['targetLanguage'] != null || requestedMode == 'fixed'
        ? null
        : requestedMode == 'smart' || hasRuleOverride
        ? settings?.smartPolicy.copyWith() ?? const SmartTranslationPolicy()
        : current.smartPolicy;
    if (smart != null && hasRuleOverride) {
      final values = request['smartRules'];
      if (values != null && (values is! List || values.length > 32)) {
        throw ExternalAiActionError('智能互译最多32条规则');
      }
      final rules = values == null
          ? smart.rules
          : <SmartTranslationRule>[
              for (final value in values as List) _smartRule(value),
            ];
      final other = request['otherTarget'];
      smart = smart.copyWith(
        rules: rules,
        otherTarget: other == null
            ? null
            : other == keepOriginal
            ? keepOriginal
            : _language(other, 'zh-CN'),
        keepUncertain: request['keepUncertain'] as bool?,
      );
      smart.validate(subtitleTranslationLanguages);
    }
    if (requestedMode == 'fixed' && request['targetLanguage'] == null) {
      source = _language(
        request['sourceLanguage'],
        settings?.sourceLanguage ?? 'auto',
      );
      target = settings?.targetLanguage ?? 'zh-CN';
    }
    if (smart != null) {
      source = 'auto';
      target = 'mul';
    }
    TranscriptTranslateChoice choice = const TranscriptTranslateChoice.off();
    ModelJobSpec? local;
    if (translate == 'app') {
      final connection = request['translationConnectionId'] as String?;
      final requestedProvider =
          request['translationProvider'] as String? ?? 'current';
      final provider = requestedProvider != 'current'
          ? SubtitleTranslateProvider.values.byName(requestedProvider)
          : connection != null
          ? SubtitleTranslateProvider.ai
          : request['translationModelId'] != null
          ? SubtitleTranslateProvider.local
          : current.provider;
      final endpoint = provider != SubtitleTranslateProvider.ai
          ? null
          : connection != null
          ? await connections.endpoint(connection, withKey: false)
          : current.apiEndpoint ?? await apiSettings.loadMetadata();
      if (provider == SubtitleTranslateProvider.ai && endpoint?.ready != true) {
        throw ExternalAiActionError('请先在软件内配置翻译AI接口，或让Agent处理');
      }
      if (provider == SubtitleTranslateProvider.local) {
        final model = native.center.artifact(
          request['translationModelId'] as String? ??
              native.center.translationModelId,
        );
        if (model?.retired != false ||
            model?.purpose != ModelPurpose.translation) {
          throw ExternalAiActionError('当前本地翻译模型不可用');
        }
        local = ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'local:${model!.id}',
            name: model.name,
            kind: TranscriptionServiceKind.local,
            model: model.id,
          ),
          artifactIdentity: model.identity,
          threads: native.center.threads,
          translation: native.center.translationOptionsFor(model.id),
          allowModelDownload: false,
        );
        if (smart != null) {
          smart.validate(subtitleLanguagesForModel(model.languages));
        } else if (!subtitleLanguagesForModel(
          model.languages,
        ).any((l) => l.code == normalizeSubtitleLanguage(target))) {
          throw ExternalAiActionError('当前本地翻译模型未声明支持目标语言');
        }
      }
      choice = TranscriptTranslateChoice(
        enabled: true,
        direction: current.direction,
        provider: provider,
        aiOptions: current.aiOptions,
        apiEndpoint: endpoint == null ? null : _safeEndpoint(endpoint),
        apiProviderId: endpoint?.providerId ?? '',
        localSpecification: local,
        sourceLanguage: source,
        targetLanguage: target,
        smartPolicy: smart,
      );
    }
    final recognition =
        request['source'] == 'transcribe' ||
            request['_requiresRecognition'] == true
        ? await native.captureConfiguration({
            'mode': 'transcribe',
            if (request['transcriptionServiceId'] != null)
              'modelId': request['transcriptionServiceId'],
            if (request['sourceLanguage'] != null)
              'sourceLanguage': request['sourceLanguage'],
          })
        : null;
    final requiredModels = <String>{
      ...((recognition?['missingModelIds'] as List?) ?? []).cast<String>(),
      if (local != null && !native.center.installed(local.profile.model))
        local.profile.model,
    }.toList();
    final backgrounds = <String, String>{};
    for (final item
        in (request['_authorizedMedia'] as List<VideoItem>? ?? <VideoItem>[])) {
      backgrounds[item.id] = await SubtitleOptimizationBackground.capture(
        item,
        item.title,
      );
    }
    return {
      'recognition': recognition,
      'optimization': opt.toJson(),
      'optimizationPrompt': prompt,
      'backgrounds': backgrounds,
      'subtitleSelectionRevision': native.playback.subtitleSelectionRevision,
      'subtitleSelections': {
        for (final item
            in (request['_authorizedMedia'] as List<VideoItem>? ??
                <VideoItem>[]))
          item.id: [item.subtitlePath, item.secondarySubtitlePath],
      },
      'translation': _encodeTranslation(choice),
      'sourceLanguage': source,
      'targetLanguage': target,
      'agentTranslationPolicy': smart?.toJson(),
      'agentTranslationContract': 2,
      'translationMode': smart == null ? 'fixed' : 'smart',
      'usesRemote':
          recognition?['usesRemote'] == true ||
          (opt.enabled && !_isLocal(opt.endpoint!)) ||
          (choice.enabled &&
              choice.provider != SubtitleTranslateProvider.local &&
              (choice.apiEndpoint == null || !_isLocal(choice.apiEndpoint!))),
      'missingModelIds': requiredModels,
      'summary': {
        'transcriptionService':
            recognition?['summary']?['service'] ??
            native.center.asrProfile.name,
        'transcriptionKind':
            recognition?['asr']?['profile']?['kind'] ??
            native.center.asrProfile.kind.name,
        'transcriptionLanguage':
            recognition?['summary']?['sourceLanguage'] ??
            native.center.effectiveAsrLanguage,
        'optimizationService':
            opt.endpoint?.model ?? (optimize == 'agent' ? 'Agent自身模型' : null),
        'translationService': choice.enabled
            ? choice.apiEndpoint?.model ?? choice.provider.name
            : translate == 'agent'
            ? 'Agent自身模型'
            : null,
        'sourceLanguage': source,
        'targetLanguage': target,
        'translationMode': smart == null ? 'fixed' : 'smart',
        if (smart != null) 'translationRules': smart.summary,
        'uploadsAudio': recognition?['summary']?['uploadsAudio'] == true,
        'uploadsText':
            (opt.enabled && !_isLocal(opt.endpoint!)) ||
            (choice.enabled &&
                choice.provider != SubtitleTranslateProvider.local),
        'agentProcessesText': optimize == 'agent' || translate == 'agent',
        'downloadBytes': requiredModels.fold<int>(
          0,
          (n, id) => n + (native.center.artifact(id)?.bytes ?? 0),
        ),
      },
    };
  }

  static Map<String, dynamic> _encodeTranslation(
    TranscriptTranslateChoice value,
  ) => {
    'enabled': value.enabled,
    'provider': value.provider.name,
    'direction': value.direction.name,
    'sourceLanguage': value.sourceLanguage,
    'targetLanguage': value.targetLanguage,
    'aiOptions': value.aiOptions.toJson(),
    'endpoint': value.apiEndpoint?.toJson(),
    'local': value.localSpecification?.toJson(),
    'smart': value.smartPolicy?.toJson(),
  };
  static TranscriptTranslateChoice _decodeTranslation(
    Map value, {
    required bool downloads,
  }) => TranscriptTranslateChoice(
    enabled: value['enabled'] == true,
    provider: SubtitleTranslateProvider.values.byName(
      value['provider'] as String,
    ),
    direction: TranscriptTranslateDirection.fromStorage(
      value['direction'] as String?,
    ),
    aiOptions: AiSubtitleTranslationSettings.fromJson(
      Map<String, dynamic>.from(value['aiOptions'] as Map),
    ),
    sourceLanguage: value['sourceLanguage'] as String?,
    targetLanguage: value['targetLanguage'] as String?,
    apiEndpoint: value['endpoint'] is Map
        ? AiSubtitleApiSettings.fromJson(
            Map<String, dynamic>.from(value['endpoint'] as Map),
          )
        : null,
    localSpecification: value['local'] is Map
        ? ModelJobSpec.fromJson({
            ...Map<String, dynamic>.from(value['local'] as Map),
            'allowModelDownload': downloads,
          })
        : null,
    smartPolicy: value['smart'] is Map
        ? SmartTranslationPolicy.fromJson(value['smart'] as Map)
        : null,
  );

  @override
  Future<void> startSubtitleRecognition(
    VideoItem media,
    String taskId,
    Map<String, dynamic> plan,
    void Function() guard,
  ) async {
    if (_recognitionResults.containsKey(taskId)) {
      if (await recognitionAssetId(media, taskId) == null) {
        throw ExternalAiSubtitleWorkflowError(
          'recognition_result_unavailable',
          '已完成的识别结果暂不可用，请检查软件字幕；不会重新转录收费',
          'subtitle_plan',
        );
      }
      return;
    }
    final config = plan['recognition'];
    if (config is! Map) throw ExternalAiActionError('未明确选择转录');
    final frozen = <String, dynamic>{
      ...Map<String, dynamic>.from(config),
      'remoteAuthorized': plan['remoteAuthorized'] == true,
      'downloadAuthorized': plan['downloadAuthorized'] == true,
    };
    final task = native.tasks().where((t) => t.taskId == taskId).firstOrNull;
    if (task?.status == 'completed') return;
    final result = await native.enqueue(media, taskId, frozen, guard);
    if (result == 'conflict') {
      throw ExternalAiSubtitleWorkflowError(
        'native_task_conflict',
        '此媒体已有软件原生转录任务，请查看真实队列并操作既有任务，不要重复入队',
        'transcription_queue',
      );
    }
    await native.control(
      media,
      taskId,
      task?.status == 'error' ? 'retry' : 'start',
      guard,
    );
  }

  @override
  Future<void> pauseSubtitleRecognition(VideoItem media, String taskId) async {
    // Owner matching remains enforced in the native adapter, even on revoke.
    await native.control(media, taskId, 'pause', () {});
  }

  @override
  Future<void> cancelSubtitleRecognition(VideoItem media, String taskId) async {
    await native.control(media, taskId, 'cancel', () {});
  }

  @override
  Future<String?> recognitionAssetId(VideoItem media, String taskId) async {
    final cached = _recognitionResults[taskId];
    if (cached != null &&
        cached.mediaId == media.id &&
        cached.identity == mediaIdentity(media)) {
      final asset = native.library
          .getVideo(media.id)
          ?.managedSubtitleAssets
          .where((a) => a.assetId == cached.assetId)
          .firstOrNull;
      if (asset == null || _subtitleStamp(asset.path) != cached.stamp) {
        throw ExternalAiSubtitleWorkflowError(
          'recognition_result_changed',
          '原识别任务完成后的文稿已被改变，不能把后来结果冒充旧任务；请重新规划',
          'subtitle_plan',
        );
      }
      return cached.assetId;
    }
    final key = native.manager.mediaKeyForVideo(media.path, videoId: media.id);
    if (native.manager.externalTaskIdFor(key) != taskId) return null;
    final path = native.manager.getGeneratedSrtPathForVideo(
      media.path,
      videoId: media.id,
    );
    return path == null
        ? null
        : native.library.managedSubtitleAssetForPath(media.id, path)?.assetId;
  }

  @override
  Future<ExternalAiSubtitleOutput> runSubtitleWorkflow(
    ExternalAiSubtitleDocument source, {
    required String workId,
    required bool optimize,
    required bool translate,
    bool completedOnly = false,
    required Map<String, dynamic> plan,
    required Future<void> cancelSignal,
    required void Function(double, Map<String, dynamic>) onProgress,
    required void Function() guard,
  }) async {
    guard();
    var opt = optimize
        ? SubtitleOptimizationChoice.fromJson(plan['optimization'] as Map)
        : const SubtitleOptimizationChoice.off();
    if (opt.enabled) {
      opt = SubtitleOptimizationChoice(
        endpoint: opt.endpoint,
        prompt: opt.prompt,
        background:
            (plan['backgrounds'] as Map?)?[source.media.id] as String? ?? '',
      );
    }
    final translation = _decodeTranslation(
      plan['translation'] as Map,
      downloads: plan['downloadAuthorized'] == true,
    );
    if ((opt.enabled && !_isLocal(opt.endpoint!) ||
            translate &&
                translation.provider != SubtitleTranslateProvider.local) &&
        plan['remoteAuthorized'] != true) {
      throw ExternalAiActionError('此软件处理流程尚未取得在线授权');
    }
    final storage = TaskSubtitleStorageService(
      dataRootOverride: native.library.dataRootDirOrNull,
    );
    final root = await storage.taskDirectory(source.media.id, create: true);
    final output = Directory(p.join(root.path, '.mcp-processing', workId));
    await output.create(recursive: true);
    guard();
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              source.revision,
              optimize,
              translate,
              plan['optimization'],
              plan['translation'],
              (plan['backgrounds'] as Map?)?[source.media.id],
            ]),
          ),
        )
        .toString();
    final receipt = File(p.join(output.path, 'completed-workflow.json'));
    Future<List<String>> texts(String path) async => [
      for (final cue in SubtitleParser.parse(
        SubtitleParser.decodeBytes(
          await File(path).readAsBytes(),
          sourcePath: path,
        ),
        sourcePath: path,
      ))
        cue.text,
    ];
    Future<String?> cachedPath(Object? value) async {
      if (value == null) return null;
      if (value is! String ||
          !p.isWithin(output.absolute.path, File(value).absolute.path) ||
          p.extension(value).toLowerCase() != '.srt' ||
          !await File(value).exists()) {
        throw ExternalAiActionError('软件处理缓存已变化，请检查或建立新任务');
      }
      return value;
    }

    if (await receipt.exists()) {
      if (await receipt.length() > 16384) {
        throw ExternalAiActionError('软件处理记录无效，原文件保留');
      }
      final saved = jsonDecode(await receipt.readAsString()) as Map;
      if (saved['fingerprint'] != fingerprint) {
        throw ExternalAiActionError('软件处理配置或源版本已变化，请建立新任务');
      }
      final primary = await cachedPath(saved['optimized']);
      final secondary = await cachedPath(saved['translated']);
      guard();
      onProgress(1, {
        'completed': source.cues.length,
        'total': source.cues.length,
      });
      return ExternalAiSubtitleOutput(
        optimized: primary == null ? null : await texts(primary),
        translated: secondary == null ? null : await texts(secondary),
        warning: saved['warning'] as String?,
      );
    }
    if (completedOnly) {
      throw ExternalAiSubtitleWorkflowError(
        'software_result_unavailable',
        '软件此前已完成计算，但结果缓存暂不可确认；已生成字幕保留，不会自动重复调用收费服务。请在软件检查或明确新建处理任务。',
        'subtitle_plan',
      );
    }
    // This is the same application start interface used by subtitle management.
    // No batching, provider calls or processing-step ordering is copied into MCP.
    final cancellation = Completer<void>();
    var finished = false;
    cancelSignal.then((_) {
      if (!finished && !cancellation.isCompleted) cancellation.complete();
    });
    try {
      final result = await service.processSubtitleFile(
        inputPath: source.path,
        sourceText: SubtitleParser.decodeBytes(
          await File(source.path).readAsBytes(),
          sourcePath: source.path,
        ),
        optimization: opt,
        optimizationEndpoint: opt.enabled
            ? await apiSettings.loadForSnapshot(opt.endpoint!)
            : null,
        optimizer: optimizer,
        translationEnabled: translate,
        provider: translation.provider,
        sourceLanguage: translation.sourceLanguage ?? 'auto',
        targetLanguage: translation.targetLanguage ?? 'zh-CN',
        aiOptions: translation.aiOptions,
        aiEndpoint:
            translate && translation.provider == SubtitleTranslateProvider.ai
            ? await apiSettings.loadForSnapshot(translation.apiEndpoint!)
            : null,
        localSpecification: translation.localSpecification,
        smartPolicy: translation.smartPolicy,
        outputDirectory: output.path,
        outputFilePrefix: 'result',
        videoPath: source.media.path,
        checkpointScope: workId,
        cancelSignal: cancellation.future,
        onProgress: (value) {
          try {
            guard();
          } catch (_) {
            if (!cancellation.isCompleted) cancellation.complete();
            return;
          }
          final progress = service.optimizationProgress;
          onProgress(value, {
            if (progress != null) ...{
              'optimizationCompleted': progress.processed,
              'optimizationTotal': progress.total,
            },
          });
        },
      );
      guard();
      // A completed native result is durable before MCP publication. A lost
      // acknowledgement or restart reuses it rather than invoking the model again.
      final temporary = File('${receipt.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'fingerprint': fingerprint,
          'optimized': optimize ? result.optimizedPath : null,
          'translated': translate ? result.outputPath : null,
          'warning': result.optimizationWarning,
        }),
        flush: true,
      );
      guard();
      await temporary.rename(receipt.path);
      return ExternalAiSubtitleOutput(
        optimized: optimize && result.optimizedPath != null
            ? await texts(result.optimizedPath!)
            : null,
        translated: translate ? await texts(result.outputPath) : null,
        warning: result.optimizationWarning,
      );
    } finally {
      finished = true;
    }
  }

  @override
  Future<Map<String, dynamic>> publishProcessedSubtitle(
    ExternalAiSubtitleDocument source, {
    required String workId,
    required String operation,
    required String executor,
    required String language,
    required List<String> texts,
    required void Function() guard,
  }) => native.publishProcessedSubtitle(
    source,
    workId: workId,
    operation: operation,
    executor: executor,
    language: language,
    texts: texts,
    guard: guard,
  );
  @override
  Future<Map<String, dynamic>> selectProcessedSubtitles(
    ExternalAiSubtitleDocument source, {
    String? primaryAssetId,
    String? secondaryAssetId,
    required Map<String, dynamic> plan,
    required void Function() guard,
  }) async {
    guard();
    if (native.playback.currentItem?.id == source.media.id &&
        native.playback.subtitleSelectionRevision !=
            plan['subtitleSelectionRevision']) {
      return _preservedSelection(source.media.id);
    }
    final item = native.library.getVideo(source.media.id);
    final selected =
        (plan['subtitleSelections'] as Map?)?[source.media.id] as List?;
    if (item != null &&
        selected != null &&
        ((item.subtitlePath != selected[0] &&
                !(plan['recognition'] != null &&
                    item.subtitlePath == source.path)) ||
            item.secondarySubtitlePath != selected[1])) {
      return _preservedSelection(source.media.id);
    }
    return native.selectProcessedSubtitles(
      source,
      primaryAssetId: primaryAssetId,
      secondaryAssetId: secondaryAssetId,
      guard: guard,
    );
  }

  static Map<String, dynamic> _preservedSelection(String mediaId) => {
    'status': 'preserved_user_selection',
    'applied': false,
    'selectionSaved': false,
    'loadedForCurrentMedia': false,
    'nextTool': 'documents_list',
    'arguments': {'mediaId': mediaId},
    'selectionTool': 'subtitle_select',
    'note':
        '处理期间主副字幕选择发生变化，已保留用户选择。新稿已保存，请说明结果；用户要求切换时再用subtitle_select，不要静默覆盖。',
  };
}
