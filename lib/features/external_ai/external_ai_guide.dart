import 'external_ai_preferences.dart';
import 'external_ai_server.dart';
import 'external_ai_subtitle_backend.dart';

/// The short, live operating manual. Settings are app snapshots, not assumptions
/// inferred from downloaded weights or tool names. Never contains credentials.
class ExternalAiGuide implements ExternalAiDataSource {
  ExternalAiGuide({
    required this.preferences,
    required this.processingOptions,
    required this.subtitleOptions,
  });

  final ExternalAiPreferences? Function() preferences;
  final Future<Map<String, dynamic>> Function() processingOptions;
  final Future<Map<String, dynamic>> Function() subtitleOptions;

  @override
  List<Map<String, dynamic>> get tools => [
    {
      'name': 'player_guide',
      'description':
          '操作前先读：当前真实转录服务（公益/云端/本地）、语言、字幕优化定义、翻译规则、完整文件夹处理和真实任务队列用法。默认沿用软件设置，不凭已安装模型猜默认，也不让用户先选本地模型。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'topic': {
            'type': 'string',
            'enum': [
              'overview',
              'workflow',
              'optimization',
              'translation',
              'subtitles',
              'queue',
              'settings',
            ],
          },
        },
        'additionalProperties': false,
      },
      'annotations': {
        'readOnlyHint': true,
        'destructiveHint': false,
        'idempotentHint': true,
        'openWorldHint': false,
      },
    },
  ];

  static Map<String, dynamic> _fields(Object? source, List<String> keys) =>
      source is Map
      ? {
          for (final key in keys)
            if (source.containsKey(key)) key: source[key],
        }
      : {};

  Future<Map<String, dynamic>> currentSettings() async {
    final initial = preferences();
    if (initial == null || !initial.enabled || !initial.allowTaskControl) {
      return {'available': false, 'reason': '请在播放器开启任务控制以读取当前处理设置。'};
    }
    void guard() {
      final current = preferences();
      if (current?.enabled != true ||
          current?.allowTaskControl != true ||
          current?.token != initial.token ||
          current?.scopeFolderId != initial.scopeFolderId) {
        throw StateError('授权已变化，请重新读取软件使用说明');
      }
    }

    final asr = await processingOptions();
    guard();
    final subtitles = await subtitleOptions();
    guard();
    final current = subtitles['current'];
    return {
      'available': true,
      'transcription': _fields(asr['current'] ?? asr, [
        'serviceId',
        'name',
        'kind',
        'sourceLanguage',
        'requiresLocalModel',
        'uploadsAudio',
      ]),
      'optimization': _fields(current, [
        'optimizationEnabled',
        'optimizationConnectionId',
        'optimizationPrompt',
      ]),
      if (subtitles['executorPreference'] != null)
        'executorPreference': subtitles['executorPreference'],
      'translation': _fields(current, [
        'translationProvider',
        'sourceLanguage',
        'targetLanguage',
        'translationMode',
        'smartPolicy',
      ]),
      if (subtitles['translationPolicy'] != null)
        'translationPolicy': subtitles['translationPolicy'],
      if (subtitles['agentTranslation'] != null)
        'agentTranslation': subtitles['agentTranslation'],
      'defaultRule':
          '用户没有指定服务/模型/语言时沿用以上当前设置。公益/云端转录由软件处理音频，不需要本地转录模型；本机已安装模型不表示正在使用它。明确要求优化时开启该批优化，即使软件全局优化开关当前关闭。',
      'changes':
          '本批模型/语言用任务参数覆盖；只有用户要求以后都更改时才用settings_update。API Key只在播放器原生窗口填写。',
    };
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> a,
  ) async {
    if (name != 'player_guide' || a.keys.any((k) => k != 'topic')) {
      throw ArgumentError('无效的使用说明请求');
    }
    final topic = a['topic'] ?? 'overview';
    if (![
      'overview',
      'workflow',
      'optimization',
      'translation',
      'subtitles',
      'queue',
      'settings',
    ].contains(topic)) {
      throw ArgumentError('未知说明主题');
    }
    final settings = await currentSettings();
    return {
      'currentSettings': settings,
      'startHere':
          '先明确目标媒体/当前浏览文件夹。当前播放视频的目录不是当前浏览目录；activeLibraryContext未知时只需一次确认目录。',
      if (['overview', 'workflow'].contains(topic))
        'workflow': {
          'plan':
              'subtitle_plan：传folderId或targets，source=auto；批量准备已有文字字幕。已有合适字幕直接优化/翻译，确认缺字幕才用当前服务转录。failed/unchecked不是无字幕。',
          'selection':
              '优先明确指定documentId或软件当前所选主字幕；其他多版本汇总问一次，不静默随便挑。按计划返回的选择和覆盖范围执行。',
          'execute':
              'subtitle_process提交planId；优化/翻译分别选择app或agent。未指定执行方时沿用已保存偏好，没有偏好则用软件；偏好为ask才整批询问一次。原文不覆盖。两步都开启时严格先优化，再翻译该优化版本。',
          'progress':
              'subtitle_jobs查整批；app执行由软件负责全部内部步骤，不解析文案。Agent执行按nextTool调用subtitle_work_read/write分段处理并持久化。',
          'onlyTranscribe':
              '仅转录也可用transcription_start，省略模型沿用当前服务。不要先转录全部再优化全部造成重复识别。',
          'example': {
            'folderId': '<授权文件夹ID>',
            'source': 'auto',
            'optimize': 'app',
            'translate': 'off',
          },
        },
      if (['overview', 'optimization'].contains(topic))
        'optimization': {
          'meaning':
              '字幕文字纠错润色：修正识别错字、同音词、专有名词和标点。具体要求以当前optimizationPrompt及本批指令为准。',
          'invariants': [
            '保留原语言、原意、语气与有效信息',
            '不翻译、不总结、不凭背景补写，不确定保留原文',
            '每条独立保留，不合并/拆分，不改变cueId、时间轴',
          ],
          'execution':
              'app使用当前优化连接/提示词；agent按work_read的约束和背景改正文，再work_write。不是降噪、音频增强或重转录。',
        },
      if (['overview', 'translation'].contains(topic))
        'translation': {
          'mode': '沿用软件当前smart智能互译或fixed单向翻译；用户显式指定目标语言时本批改为单向。',
          'app':
              '软件用当前翻译提供商（Bing/本地/AI接口）及语言规则；不把保存的translationModelId当成当前provider。',
          'agent':
              '按work_read返回的实际软件路由translationParts处理每个part的targetLanguage；无需翻译的片段由软件保留并重组，不自行发明中英互译规则。仅返回文字，不改时间轴。',
          'order': '存在优化步骤时，翻译输入必须是本批已完成的优化结果。',
        },
      if (['overview', 'workflow', 'subtitles'].contains(topic))
        'subtitleSelection': {
          'optimizationOnly': externalAiSubtitlePresentation(
            optimize: true,
            translate: false,
          ),
          'translationOnly': externalAiSubtitlePresentation(
            optimize: false,
            translate: true,
          ),
          'optimizationAndTranslation': externalAiSubtitlePresentation(
            optimize: true,
            translate: true,
          ),
          'custom':
              '用户要译稿为主、原稿为副或仅一份字幕时，可loadSubtitles=false先保存，再用subtitle_select同时设置primaryDocumentId/secondaryDocumentId或clearSecondary。仅改一边省略另一边；不能把同一版本放两边。documentId从产物或documents_list取得，名称不是ID。',
          'completion':
              '完成后读取subtitle_jobs的subtitleSelection，告诉用户实际主稿和副稿的名称；applied=true表示已保存，loadedForCurrentMedia只表示是否刷新当前播放，不能当成选择是否成功。preserved_user_selection表示保留处理中用户的新选择，要解释结果，不静默重选。',
          'legacy':
              '旧translation_commit仍需显式loadAsSecondary=true才能选副字幕；日常优化/翻译优先统一入口。',
          'names':
              '仅优化和翻译结果把类别或语言放在最前面，如“［优化］内容名”“［英文］内容名”；智能互译为“［互译］内容名”。普通转录及原稿沿用原有命名，不添加类别前缀。重复版本用v2、v3。名字不含任务ID或文件时间戳，原稿和自定义名保留。译稿是否基于优化稿看本批链路和sourceAssetId，不凭名称猜。',
        },
      if (['overview', 'queue'].contains(topic))
        'queue': {
          'applicationQueue':
              'transcription_queue读取软件真实队列，包括用户手动创建的任务；用返回taskId调用transcription_queue_control。支持开始、暂停、继续、取消、重试；取消不删除媒体或已生成字幕。',
          'subtitleJobs':
              'subtitle_jobs/subtitle_job_control管理统一字幕作业及Agent草稿；控制某条软件转录可使用其taskId，作业会反映原生任务状态。',
          'restart': '重试失败任务沿用冻结配置与可用断点；重新转录已完成任务是独立restart操作，需要明确确认，不能当retry。',
          'legacy': 'tasks_read/control只管理旧MCP批次，不能用空结果声称软件真实队列为空。',
        },
      'authorization':
          '沿用播放器的授权范围及自动代办开关。需确认时请求用户处理待确认卡并原参数重试；Agent不能自我批准。避免为已明确的默认设置反复提问。',
      'privacy': {
        'mediaFilesProvided': false,
        'mediaPathsProvided': false,
        'apiKeysProvided': false,
      },
    };
  }
}
