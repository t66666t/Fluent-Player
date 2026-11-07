part of 'external_ai_subtitle_processing.dart';

/// Planning reads app state, prepares existing text and freezes a reviewable
/// generation. It never runs ASR, optimization, translation or model downloads.
extension _SubtitleWorkflowPlanning on ExternalAiSubtitleProcessing {
  static String _text(Map a, String key) =>
      ExternalAiSubtitleProcessing._text(a, key);
  static String _digest(Object? value) =>
      ExternalAiSubtitleProcessing._hash(value);
  static const _settingsKeys = [
    'source',
    'optimize',
    'translate',
    'optimizationConnectionId',
    'optimizationInstruction',
    'translationConnectionId',
    'translationProvider',
    'translationModelId',
    'translationMode',
    'smartRules',
    'otherTarget',
    'keepUncertain',
    'sourceLanguage',
    'targetLanguage',
    'transcriptionServiceId',
    'loadSubtitles',
  ];

  Future<Map<String, dynamic>> _previewSubtitlePlan(
    Map<String, dynamic> a,
    void Function() guard,
  ) async {
    Map<String, dynamic> plan;
    String id;
    if (a['planId'] != null) {
      id = _text(a, 'planId');
      final found = _section('plans')[id];
      if (found is! Map<String, dynamic> || found['grant'] != _grant) {
        throw ExternalAiActionError('字幕规划不存在或未授权，请重新规划');
      }
      plan = found;
      if (DateTime.parse(
        plan['expiresAt'] as String,
      ).isBefore(DateTime.now())) {
        throw ExternalAiActionError('字幕规划已过期，请重新规划');
      }
      await library.authorizedMedia((plan['mediaIds'] as List).cast<String>());
      guard();
      if (plan['jobId'] != null &&
          (a['targets'] != null ||
              _settingsKeys.any(
                (key) =>
                    a.containsKey(key) &&
                    _digest(a[key]) != _digest(plan['request'][key]),
              ))) {
        throw ExternalAiActionError('规划已提交，不能修改已排队任务');
      }
      var changed = false;
      for (final key in _settingsKeys) {
        if (a.containsKey(key) &&
            _digest(a[key]) != _digest(plan['request'][key])) {
          plan['request'][key] = a[key];
          changed = true;
        }
      }
      if (a['targets'] is List) {
        final choices = a['targets'] as List;
        for (final choice in choices) {
          if (choice is! Map || choice['documentId'] is! String) {
            throw ExternalAiActionError('选择字幕时需要mediaId及documentId');
          }
          final row = (plan['items'] as List).cast<Map>().firstWhere(
            (row) => row['mediaId'] == choice['mediaId'],
            orElse: () => throw ExternalAiActionError('字幕选择不属于此规划'),
          );
          row['explicitDocumentId'] = _text(choice, 'documentId');
          if (choice['documentRevision'] != null) {
            row['explicitDocumentRevision'] = _text(choice, 'documentRevision');
          } else {
            row.remove('explicitDocumentRevision');
          }
          changed = true;
        }
      }
      if (changed) {
        if (plan['jobId'] != null) {
          throw ExternalAiActionError('规划已提交，不能修改已排队任务');
        }
        plan['status'] = 'preparing_documents';
        plan.remove('configuration');
        plan.remove('settingsFingerprint');
      }
    } else {
      final requestId = _text(a, 'requestId');
      if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(requestId)) {
        throw ExternalAiActionError('新规划需要8–128位requestId');
      }
      final key = '$_grant:$requestId';
      final signature = _digest({
        for (final e in a.entries)
          if (!['offset', 'limit'].contains(e.key)) e.key: e.value,
      });
      final previous = _section('planRequests')[key] as Map?;
      if (previous != null) {
        if (previous['signature'] != signature) {
          throw ExternalAiActionError('同一requestId不能改变规划参数');
        }
        return _previewSubtitlePlan({
          'planId': previous['planId'],
          if (a['offset'] != null) 'offset': a['offset'],
          if (a['limit'] != null) 'limit': a['limit'],
        }, guard);
      }
      List<VideoItem> media;
      String? folderId;
      final explicit = a['targets'];
      if (explicit != null) {
        if (explicit is! List ||
            explicit.isEmpty ||
            explicit.length > 1000 ||
            explicit.any(
              (t) =>
                  t is! Map ||
                  t.keys.any(
                    (k) => ![
                      'mediaId',
                      'documentId',
                      'source',
                      'documentRevision',
                    ].contains(k),
                  ),
            )) {
          throw ExternalAiActionError('规划targets需要1–1000个媒体ID及可选字幕ID');
        }
        final ids = [for (final t in explicit) _text(t as Map, 'mediaId')];
        if (ids.toSet().length != ids.length) {
          throw ExternalAiActionError('媒体ID不可重复');
        }
        media = await library.authorizedMedia(ids);
      } else {
        folderId = a['folderId'] as String?;
        if (folderId == null && a['scope'] != 'library') {
          final context = library.currentLibraryContext();
          if (context['available'] != true) {
            return {
              'status': 'needs_folder_choice',
              'nextTool': 'library_browse',
              'question': '播放器当前没有可确认的媒体库文件夹，请指定folderId或明确选择整个授权媒体库。',
            };
          }
          folderId = context['folderId'] as String?;
        }
        media = library.authorizedMediaInFolder(
          folderId: folderId,
          recursive: a['recursive'] as bool? ?? true,
        );
      }
      guard();
      if (media.isEmpty) throw ExternalAiActionError('当前范围没有可处理且已授权的媒体');
      if (media.length > 1000) {
        return {
          'status': 'scope_too_large',
          'totalMedia': media.length,
          'maximumPerPlan': 1000,
          'completeScope': false,
          'nextStep': '按子文件夹或每批最多1000个明确媒体ID分批规划；没有启动或省略其余媒体。',
        };
      }
      final expired = _section('plans').entries
          .where(
            (e) => DateTime.parse(
              e.value['expiresAt'] as String,
            ).isBefore(DateTime.now()),
          )
          .map((e) => e.key)
          .toList();
      for (final old in expired) {
        _section('plans').remove(old);
      }
      if (_section('plans').length >= 100) {
        throw ExternalAiActionError('待用字幕规划已满，请稍后重试');
      }
      id = _uuid.v4();
      final request = <String, dynamic>{
        'source': 'auto',
        'optimize': a['translate'] != null && a['translate'] != 'off'
            ? 'off'
            : 'app',
        'translate': 'off',
        for (final key in _settingsKeys)
          if (a.containsKey(key)) key: a[key],
      };
      plan = {
        'id': id,
        'grant': _grant,
        'status': 'preparing_documents',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'request': request,
        'mediaIds': [for (final item in media) item.id],
        'folderScope': explicit == null,
        'folderId': folderId,
        'recursive': a['recursive'] as bool? ?? true,
        'items': [
          for (var i = 0; i < media.length; i++)
            {
              'mediaId': media[i].id,
              'title': media[i].title,
              'identity': backend.mediaIdentity(media[i]),
              'source': explicit is List
                  ? explicit[i]['source'] ?? request['source']
                  : request['source'],
              if (explicit is List && explicit[i]['source'] != null)
                'sourceOverride': explicit[i]['source'],
              'explicitDocumentRevision': explicit is List
                  ? explicit[i]['documentRevision']
                  : null,
              'explicitDocumentId': explicit is List
                  ? explicit[i]['documentId']
                  : null,
              'state': 'unchecked',
            },
        ],
      };
      _section('plans')[id] = plan;
      _section('planRequests')[key] = {'signature': signature, 'planId': id};
      await _save();
    }
    if (plan['status'] != 'ready' && plan['jobId'] == null) {
      await _advanceSubtitlePlan(plan, guard);
    }
    guard();
    return _subtitlePlanSummary(plan, a);
  }

  Future<void> _advanceSubtitlePlan(
    Map<String, dynamic> plan,
    void Function() guard,
  ) async {
    final rows = (plan['items'] as List).cast<Map>();
    final preparing = plan['preparationJobId'];
    if (preparing is String) {
      final status = await documents!.callTool('documents_prepare_status', {
        'jobId': preparing,
        'limit': 100,
      });
      guard();
      if (['running', 'queued', 'cancelling'].contains(status['status'])) {
        plan['status'] = 'preparing_documents';
        return;
      }
      for (final value in (status['items'] as List? ?? []).whereType<Map>()) {
        final row = rows
            .where((r) => r['mediaId'] == value['mediaId'])
            .firstOrNull;
        if (row != null) row['discoveryState'] = value['state'];
      }
      plan.remove('preparationJobId');
    }
    final needsPreparation = <String>[];
    var needsChoice = false, blocked = false;
    final selected = await library.authorizedMedia(
      (plan['mediaIds'] as List).cast<String>(),
    );
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      guard();
      if (backend.mediaIdentity(selected[i]) != row['identity']) {
        throw ExternalAiActionError('规划期间媒体来源已变化，请重新规划');
      }
      final mode =
          row['sourceOverride'] as String? ??
          plan['request']['source'] as String;
      row['source'] = mode;
      if (!['auto', 'existing', 'transcribe'].contains(mode)) {
        throw ExternalAiActionError('字幕来源模式无效');
      }
      if (mode == 'transcribe') {
        row['resolvedSource'] = 'transcribe';
        row['state'] = 'ready';
        row.remove('documentId');
        row.remove('documentRevision');
        continue;
      }
      final listing = await library.callTool('documents_list', {
        'mediaId': row['mediaId'],
      });
      guard();
      final candidates = (listing['documents'] as List)
          .whereType<Map>()
          .where((d) => d['available'] == true)
          .toList();
      row['candidates'] = [
        for (final d in candidates)
          {
            'documentId': d['id'],
            'label': d['label'],
            'selected': d['selected'] == true,
            if (d['language'] != null) 'language': d['language'],
            if (d['kind'] != null) 'kind': d['kind'],
          },
      ];
      Map? chosen;
      if (row['explicitDocumentId'] != null) {
        chosen = candidates
            .where((d) => d['id'] == row['explicitDocumentId'])
            .firstOrNull;
        if (chosen == null) {
          throw ExternalAiActionError('指定字幕已不可用或不属于此媒体，请重新选择');
        }
      } else {
        chosen = candidates.where((d) => d['selected'] == true).firstOrNull;
        if (chosen == null && candidates.length == 1) {
          chosen = candidates.single;
        }
      }
      if (chosen != null) {
        final document = await library.authorizedSubtitle(
          row['mediaId'] as String,
          chosen['id'] as String,
        );
        guard();
        ExternalAiSubtitleProcessing._validateSource(document);
        if (row['explicitDocumentRevision'] != null &&
            row['explicitDocumentRevision'] != document.revision) {
          throw ExternalAiActionError('指定字幕的版本已变化，请重新读取后规划');
        }
        row['documentId'] = document.documentId;
        row['documentRevision'] = document.revision;
        row['resolvedSource'] = 'existing';
        row['state'] = 'ready';
      } else if (candidates.length > 1) {
        row['state'] = 'needs_subtitle_choice';
        needsChoice = true;
      } else if (row['discoveryState'] == null && documents != null) {
        needsPreparation.add(row['mediaId'] as String);
        row['state'] = 'preparing_documents';
      } else if (mode == 'auto' && row['discoveryState'] == 'confirmed_none') {
        row['resolvedSource'] = 'transcribe';
        row['state'] = 'ready';
      } else {
        row['state'] = 'needs_subtitle_preparation';
        blocked = true;
      }
    }
    if (needsPreparation.isNotEmpty) {
      final ids = needsPreparation.take(100).toList();
      final started = await documents!.callTool('documents_prepare', {
        'mediaIds': ids,
        'requestId':
            'plan-discovery-${plan['id']}-${_digest(ids).substring(0, 12)}',
      });
      guard();
      plan['preparationJobId'] = started['jobId'];
      plan['status'] = 'preparing_documents';
      await _save();
      return;
    }
    if (needsChoice || blocked) {
      plan['status'] = needsChoice
          ? 'needs_subtitle_choice'
          : 'needs_subtitle_preparation';
      await _save();
      return;
    }
    final request = Map<String, dynamic>.from(plan['request'] as Map);
    request['optimize'] = _executorValue(request['optimize'], 'optimization');
    request['translate'] = _executorValue(request['translate'], 'translation');
    if ([request['optimize'], request['translate']].contains('ask')) {
      plan['status'] = 'needs_execution_choice';
      await _save();
      return;
    }
    if (request['optimize'] == 'off' && request['translate'] == 'off') {
      throw ExternalAiActionError('字幕处理至少需要优化或翻译；仅转录使用transcription_start');
    }
    final configuration = await backend.captureSubtitlePlan({
      ...request,
      '_requiresRecognition': rows.any(
        (r) => r['resolvedSource'] == 'transcribe',
      ),
      '_authorizedMedia': selected,
    });
    guard();
    plan['effectiveRequest'] = request;
    plan['configuration'] = configuration;
    plan['settingsFingerprint'] = _configurationFingerprint(configuration);
    plan['status'] = 'ready';
    await _save();
  }

  String _configurationFingerprint(Map configuration) => _digest({
    'recognition': configuration['recognition'] is Map
        ? {
            for (final key in [
              'asr',
              'translation',
              'remoteTranslation',
              'localTranslationPolicy',
              'targetLanguage',
            ])
              key: configuration['recognition'][key],
          }
        : null,
    for (final key in [
      'optimization',
      'optimizationPrompt',
      'translation',
      'sourceLanguage',
      'targetLanguage',
      'agentTranslationPolicy',
      'backgrounds',
    ])
      key: configuration[key],
  });

  Map<String, dynamic> _subtitlePlanSummary(Map plan, Map a) {
    final rows = (plan['items'] as List).cast<Map>();
    final offset = ExternalAiSubtitleProcessing._number(a, 'offset'),
        limit = ExternalAiSubtitleProcessing._number(
          a,
          'limit',
          fallback: 20,
          maximum: 100,
        );
    if (limit == 0 || offset > rows.length) {
      throw ExternalAiActionError('规划分页范围无效');
    }
    final end = (offset + limit).clamp(0, rows.length);
    return {
      'planId': plan['id'],
      'status': plan['jobId'] != null ? 'submitted' : plan['status'],
      'jobId': plan['jobId'],
      'expiresAt': plan['expiresAt'],
      'completeScope': true,
      'totalMedia': rows.length,
      'scope': {
        'folderId': plan['folderId'],
        'recursive': plan['recursive'],
        'explicitMediaSelection': plan['folderScope'] != true,
      },
      'existingSubtitleMedia': rows
          .where((r) => r['resolvedSource'] == 'existing')
          .length,
      'needsTranscriptionMedia': rows
          .where((r) => r['resolvedSource'] == 'transcribe')
          .length,
      'ambiguousSubtitleMedia': rows
          .where((r) => r['state'] == 'needs_subtitle_choice')
          .length,
      'blockedMedia': rows
          .where((r) => r['state'] == 'needs_subtitle_preparation')
          .length,
      'settings': (plan['configuration'] as Map?)?['summary'],
      'subtitlePresentation': externalAiSubtitlePresentation(
        optimize:
            (plan['effectiveRequest'] ?? plan['request'])['optimize'] != 'off',
        translate:
            (plan['effectiveRequest'] ?? plan['request'])['translate'] != 'off',
        loadSubtitles:
            (plan['effectiveRequest'] ?? plan['request'])['loadSubtitles'] !=
            false,
      ),
      'settingsFingerprint': plan['settingsFingerprint'],
      if (plan['status'] == 'needs_execution_choice')
        'executionChoices': {
          'optimization': ['app', 'agent'],
          'translation': ['app', 'agent'],
        },
      'costBoundary': {
        'generationStarted': plan['jobId'] != null,
        'uploadsAudio':
            (plan['configuration'] as Map?)?['summary']?['uploadsAudio'] ==
            true,
        'uploadsText':
            (plan['configuration'] as Map?)?['summary']?['uploadsText'] == true,
        'modelDownloadBytes':
            (plan['configuration'] as Map?)?['summary']?['downloadBytes'],
        'note': '此预览仅检查和准备已有字幕；开始后才按所列范围调用软件服务/Agent，实际额度由所选服务计费。',
      },
      'items': [
        for (final row in rows.sublist(offset, end))
          {
            'mediaId': row['mediaId'],
            'title': row['title'],
            'state': row['state'],
            'source': row['resolvedSource'],
            'documentId': row['documentId'],
            'documentRevision': row['documentRevision'],
            if (row['state'] == 'needs_subtitle_choice')
              'candidates': row['candidates'],
            if (row['state'] == 'needs_subtitle_preparation')
              'note': '字幕来源尚未可靠确认；失败/未检查不等于无字幕，不会自动重转录。',
          },
      ],
      'nextOffset': end < rows.length ? end : null,
      'pollAfterMs': plan['status'] == 'preparing_documents' ? 1500 : null,
      'nextTool': plan['jobId'] != null
          ? 'subtitle_jobs'
          : plan['status'] == 'ready'
          ? 'subtitle_process'
          : 'subtitle_plan',
      'nextStep': plan['status'] == 'needs_subtitle_choice'
          ? '请用户选一个源字幕，或按其明确授权的选择偏好决定；subtitle_plan({planId,targets:[{mediaId,documentId}]})更新，其他媒体保留。'
          : '同planId继续检查；ready后以subtitle_process({planId,requestId})开始整批。默认沿用当前软件服务，不猜本地模型。',
    };
  }

  Future<Map<String, dynamic>> _resolveSubtitlePlan(
    Map<String, dynamic> a,
    void Function() guard,
  ) async {
    final preview = await _previewSubtitlePlan(a, guard);
    if (preview['planId'] == null) return preview;
    final plan = _section('plans')[preview['planId']] as Map<String, dynamic>;
    if (plan['jobId'] is String) {
      final job = _job(plan['jobId'] as String);
      return {
        'jobId': job['id'],
        'status': job['status'],
        'nextTool': 'subtitle_jobs',
      };
    }
    if (plan['status'] != 'ready') return preview;
    final ids = (plan['mediaIds'] as List).cast<String>();
    final media = await library.authorizedMedia(ids);
    if (plan['folderScope'] == true) {
      final now = library.authorizedMediaInFolder(
        folderId: plan['folderId'] as String?,
        recursive: plan['recursive'] == true,
      );
      if (_digest(now.map((m) => m.id).toList()) != _digest(ids)) {
        throw ExternalAiActionError('文件夹内容已变化，请重新规划；没有启动旧范围');
      }
    }
    final rows = (plan['items'] as List).cast<Map>();
    for (var i = 0; i < rows.length; i++) {
      guard();
      final row = rows[i];
      if (backend.mediaIdentity(media[i]) != row['identity']) {
        throw ExternalAiActionError('媒体来源已变化，请重新规划');
      }
      if (row['documentId'] != null) {
        final document = await library.authorizedSubtitle(
          row['mediaId'] as String,
          row['documentId'] as String,
        );
        if (document.revision != row['documentRevision']) {
          throw ExternalAiActionError('规划后的字幕已变化，请重新规划');
        }
      } else if (row['source'] != 'transcribe') {
        final listing = await library.callTool('documents_list', {
          'mediaId': row['mediaId'],
        });
        if ((listing['documents'] as List).any((d) => d['available'] == true)) {
          throw ExternalAiActionError('规划后已出现字幕，请重新规划以避免重复转录');
        }
      }
    }
    final request = Map<String, dynamic>.from(plan['effectiveRequest'] as Map);
    final current = await backend.captureSubtitlePlan({
      ...request,
      '_authorizedMedia': media,
      '_requiresRecognition': rows.any(
        (r) => r['resolvedSource'] == 'transcribe',
      ),
    });
    guard();
    if (_configurationFingerprint(current) != plan['settingsFingerprint']) {
      throw ExternalAiActionError('软件默认服务、模型或语言设置在规划后已改变，请重新规划确认；未启动任务');
    }
    return {
      'planId': plan['id'],
      'configuration': plan['configuration'],
      'request': {
        ...request,
        'source': 'auto',
        'requestId': a['requestId'],
        'targets': [
          for (final row in rows)
            {
              'mediaId': row['mediaId'],
              'source': row['resolvedSource'],
              if (row['documentId'] != null) 'documentId': row['documentId'],
              if (row['documentRevision'] != null)
                'documentRevision': row['documentRevision'],
            },
        ],
      },
    };
  }
}
