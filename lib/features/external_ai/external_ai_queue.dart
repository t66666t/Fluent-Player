import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/video_item.dart';
import 'external_ai_action_store.dart';
import 'external_ai_actions.dart';
import 'external_ai_approvals.dart';
import 'external_ai_library_source.dart';
import 'external_ai_preferences.dart';
import 'external_ai_server.dart';

/// Internal adapter data. Generation/configuration fingerprints never contain
/// credentials and are not returned as native media keys or filenames.
class ExternalAiQueueTask {
  const ExternalAiQueueTask({
    required this.mediaId,
    required this.generation,
    required this.mediaIdentity,
    required this.configurationIdentity,
    required this.restartConfigurationIdentity,
    required this.status,
    required this.phase,
    required this.progress,
    required this.settings,
    required this.restartSettings,
    required this.actions,
    this.usesRemote = false,
    this.needsDownloads = false,
    this.restartUsesRemote = false,
    this.restartNeedsDownloads = false,
    this.translationProgress,
    this.optimizationCompleted,
    this.optimizationTotal,
    this.optimizationTotalIsFinal,
    this.ownedTaskId,
  });
  final String mediaId, generation, mediaIdentity;
  final String configurationIdentity, restartConfigurationIdentity;
  final String status, phase;
  final double progress;
  final double? translationProgress;
  final int? optimizationCompleted, optimizationTotal;
  final bool? optimizationTotalIsFinal;
  final bool usesRemote, needsDownloads;
  final bool restartUsesRemote, restartNeedsDownloads;
  final Map<String, dynamic> settings, restartSettings;
  final List<String> actions;
  final String? ownedTaskId;
}

abstract class ExternalAiQueueBackend {
  Future<List<ExternalAiQueueTask>> queueSnapshot();
  String mediaIdentity(VideoItem media);
  Future<bool> controlQueueTask(
    VideoItem media,
    ExternalAiQueueTask task,
    String action,
    void Function() guard,
  );
}

/// The native application queue, including tasks created manually in the UI.
/// An existing library scope and concrete operation approval still apply.
class ExternalAiQueueSource implements ExternalAiDataSource {
  ExternalAiQueueSource({
    required this.library,
    required this.backend,
    required this.store,
    required this.approvals,
    required this.preferences,
    required this.generation,
  });
  final ExternalAiLibrarySource library;
  final ExternalAiQueueBackend backend;
  final ExternalAiActionStore store;
  final ExternalAiApprovals approvals;
  final ExternalAiPreferences? Function() preferences;
  final int Function() generation;
  Map<String, dynamic> _state = {'version': 1, 'requests': <String, dynamic>{}};
  Future<void>? _loading;
  Future<void> _calls = Future.value();
  bool _closed = false;
  Map<String, dynamic> get _requests =>
      _state['requests'] as Map<String, dynamic>;

  Future<void> initialize() => _loading ??= () async {
    _state = await store.load();
    _state.putIfAbsent('requests', () => <String, dynamic>{});
    if (_state['requests'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid queue operation journal');
    }
  }();

  Future<void> shutdown() async {
    _closed = true;
    await _calls;
  }

  static const _actions = [
    'start',
    'pause',
    'resume',
    'cancel',
    'retry',
    'restart',
  ];
  static const _selection = {
    'type': 'array',
    'minItems': 1,
    'maxItems': 100,
    'items': {'type': 'string'},
  };
  static Map<String, dynamic> _tool(
    String name,
    String description,
    Map<String, dynamic> fields,
    List<String> required, {
    bool read = false,
  }) => {
    'name': name,
    'description': description,
    'inputSchema': {
      'type': 'object',
      'properties': fields,
      'required': required,
      'additionalProperties': false,
    },
    'annotations': {
      'readOnlyHint': read,
      'destructiveHint': name == 'transcription_queue_control',
      'idempotentHint': true,
      'openWorldHint': !read,
    },
  };

  @override
  List<Map<String, dynamic>> get tools =>
      preferences()?.allowTaskControl != true
      ? []
      : [
          _tool(
            'transcription_queue',
            '读取软件真实语音转录队列，包含用户手动创建及MCP创建的授权媒体任务。一次查看转录、优化、翻译阶段、进度、冻结设置和availableActions；无需逐媒体询问。不能用旧tasks_read代替整个软件队列。只返回不透明taskId，offset续页沿用revision。',
            {
              'mediaIds': _selection,
              'status': {
                'type': 'string',
                'enum': [
                  'all',
                  'active',
                  'pending',
                  'paused',
                  'running',
                  'failed',
                  'completed',
                  'cancelling',
                ],
              },
              'offset': {'type': 'integer', 'minimum': 0},
              'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
              'revision': {'type': 'string'},
            },
            [],
            read: true,
          ),
          _tool(
            'transcription_queue_control',
            '按transcription_queue返回的taskId批量管理软件真实队列（包含手工任务）。start/resume沿用已冻结配置，尚未冻结的任务沿用软件当前默认；pause暂停整条转录/优化/翻译流程；retry继续失败任务；cancel停止并移出任务、丢弃该次断点，但保留媒体和已发布字幕。restart是从头重新生成，独立确认并保留已发布文件；不要把retry当restart。需确认时原参数重试，绝不替用户批准。',
            {
              'taskIds': _selection,
              'action': {'type': 'string', 'enum': _actions},
              'requestId': {
                'type': 'string',
                'pattern': r'^[A-Za-z0-9_-]{8,128}$',
              },
            },
            ['taskIds', 'action', 'requestId'],
          ),
        ];

  void _access() {
    final p = preferences();
    if (_closed || p?.enabled != true || p?.allowTaskControl != true) {
      throw ExternalAiActionError('软件队列控制尚未授权或连接已关闭');
    }
  }

  void Function() _guard() {
    _access();
    final epoch = generation(), grant = approvals.grant;
    return () {
      _access();
      if (generation() != epoch || approvals.grant != grant) {
        throw ExternalAiActionError('授权已变化，请重新读取队列');
      }
    };
  }

  static Object? _canonical(Object? v) => v is Map
      ? {
          for (final k in v.keys.cast<String>().toList()..sort())
            k: _canonical(v[k]),
        }
      : v is List
      ? v.map(_canonical).toList()
      : v;
  static String _hash(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
  String _id(ExternalAiQueueTask task) =>
      'queue_${_hash([approvals.grant, task.mediaId, task.mediaIdentity, task.generation])}';

  Future<List<ExternalAiQueueTask>> _authorized(void Function() guard) async {
    final tasks = await backend.queueSnapshot();
    guard();
    final result = <ExternalAiQueueTask>[];
    for (final task in tasks) {
      try {
        final media = library.authorizedMediaNow([task.mediaId]).single;
        if (backend.mediaIdentity(media) == task.mediaIdentity) {
          result.add(task);
        }
      } on ArgumentError {
        // Queue entries outside the authorized visible library stay private.
      } on StateError {
        // A removed, hidden or substituted source is not an authorized task.
      }
    }
    return result;
  }

  static List<String>? _ids(Object? value) {
    if (value == null) return null;
    if (value is! List ||
        value.isEmpty ||
        value.length > 100 ||
        value.any((id) => id is! String || id.isEmpty || id.length > 256)) {
      throw ExternalAiActionError('需要1–100个有效任务或媒体ID');
    }
    final ids = value.cast<String>();
    if (ids.toSet().length != ids.length) throw ExternalAiActionError('ID不可重复');
    return ids;
  }

  static Map<String, dynamic> safeSettings(Map value) => {
    for (final key in [
      'serviceId',
      'serviceName',
      'serviceKind',
      'sourceLanguage',
      'optimizationEnabled',
      'translationEnabled',
      'translationProvider',
      'translationMode',
      'targetLanguage',
      'frozen',
    ])
      if (value[key] is bool ||
          value[key] is String && (value[key] as String).length < 512)
        key: value[key],
  };
  static double _progress(double value) =>
      value.isFinite ? value.clamp(0.0, 1.0) : 0;
  Map<String, dynamic> _safe(ExternalAiQueueTask task) {
    final media = library.authorizedMediaNow([task.mediaId]).single;
    return {
      'taskId': _id(task),
      'mediaId': media.id,
      'title': media.title,
      'status': task.status,
      'phase': task.phase,
      'progress': _progress(task.progress),
      if (task.translationProgress != null)
        'translationProgress': _progress(task.translationProgress!),
      if (task.optimizationCompleted != null)
        'optimizationCompleted': task.optimizationCompleted,
      if (task.optimizationTotal != null)
        'optimizationTotal': task.optimizationTotal,
      if (task.optimizationTotalIsFinal != null)
        'optimizationTotalIsFinal': task.optimizationTotalIsFinal,
      'settings': safeSettings(task.settings),
      'restartSettings': safeSettings(task.restartSettings),
      'availableActions': task.actions.where(_actions.contains).toList(),
      'createdBy': task.ownedTaskId == null ? 'app' : 'mcp',
      if (task.ownedTaskId != null) 'mcpTaskId': task.ownedTaskId,
    };
  }

  @override
  Future<Map<String, dynamic>> callTool(String name, Map<String, dynamic> a) {
    final guard = _guard();
    if (!tools.any((t) => t['name'] == name)) {
      return Future.error(ExternalAiActionError('队列工具不可用'));
    }
    final fields = name == 'transcription_queue'
        ? ['mediaIds', 'status', 'offset', 'limit', 'revision']
        : ['taskIds', 'action', 'requestId'];
    if (a.keys.any((k) => !fields.contains(k))) {
      return Future.error(ExternalAiActionError('不接受路径、密钥或额外参数'));
    }
    if (name == 'transcription_queue') return _read(a, guard);
    final call = _calls.then((_) async {
      guard();
      await initialize();
      guard();
      return _control(a, guard);
    });
    _calls = call.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return call;
  }

  Future<Map<String, dynamic>> _read(
    Map<String, dynamic> a,
    void Function() guard,
  ) async {
    var tasks = await _authorized(guard);
    final mediaIds = _ids(a['mediaIds']);
    final status = a['status'] ?? 'all';
    if (![
      'all',
      'active',
      'pending',
      'paused',
      'running',
      'failed',
      'completed',
      'cancelling',
    ].contains(status)) {
      throw ExternalAiActionError('任务状态无效');
    }
    tasks = tasks
        .where(
          (t) =>
              (mediaIds == null || mediaIds.contains(t.mediaId)) &&
              (status == 'all' ||
                  status == t.status ||
                  status == 'active' &&
                      !['completed', 'failed'].contains(t.status)),
        )
        .toList();
    final revision = _hash([for (final t in tasks) _id(t)]);
    if (a['revision'] != null && a['revision'] != revision) {
      throw ExternalAiActionError('队列项目或筛选结果已变化，请从第一页重新读取');
    }
    final offset = a['offset'] ?? 0, limit = a['limit'] ?? 50;
    if (offset is! int ||
        offset < 0 ||
        offset > tasks.length ||
        limit is! int ||
        limit < 1 ||
        limit > 100) {
      throw ExternalAiActionError('分页范围无效');
    }
    final end = (offset + limit).clamp(0, tasks.length);
    guard();
    return {
      'queue': 'application_transcription',
      'revision': revision,
      'totalAuthorizedTasks': tasks.length,
      'tasks': [for (final t in tasks.sublist(offset, end)) _safe(t)],
      'offset': offset,
      'nextOffset': end < tasks.length ? end : null,
      'controlTool': 'transcription_queue_control',
      'note':
          '仅包含授权媒体库范围内的原生队列任务；字幕协作草稿和软件字幕处理批次另用subtitle_jobs。phase仅供展示，以status和availableActions控制。',
    };
  }

  Future<void> _save() =>
      store.save(jsonDecode(jsonEncode(_state)) as Map<String, dynamic>);
  Future<Map<String, dynamic>> _control(
    Map<String, dynamic> a,
    void Function() guard,
  ) async {
    final ids = _ids(a['taskIds']);
    final action = a['action'], request = a['requestId'];
    if (ids == null ||
        !_actions.contains(action) ||
        request is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(request)) {
      throw ExternalAiActionError('需要有效taskIds、action及requestId');
    }
    final key = '${approvals.grant}:$request', signature = _hash(a);
    Map<String, dynamic>? prior = _requests[key] as Map<String, dynamic>?;
    if (prior != null && prior['signature'] != signature) {
      throw ExternalAiActionError('同一requestId不能重复用于不同操作');
    }
    if (prior != null) {
      for (final row in (prior['items'] as List).cast<Map>()) {
        final media = library.authorizedMediaNow([
          row['mediaId'] as String,
        ]).single;
        if (backend.mediaIdentity(media) != row['mediaIdentity']) {
          throw ExternalAiActionError('原任务媒体已变化，请重新读取队列');
        }
      }
      guard();
      if (prior['result'] is Map) {
        return Map<String, dynamic>.from(prior['result'] as Map);
      }
    }
    if (prior == null && _requests.length >= 5000) {
      throw ExternalAiActionError('队列控制记录已满，请在软件内整理后再试');
    }
    final snapshot = await _authorized(guard);
    final lookup = {for (final task in snapshot) _id(task): task};
    if (prior == null) {
      final selected = <ExternalAiQueueTask>[];
      for (final id in ids) {
        final task = lookup[id];
        if (task == null) throw ExternalAiActionError('任务已变化或不在授权范围，请重新读取队列');
        if (!task.actions.contains(action)) {
          throw ExternalAiActionError('任务当前不支持此操作，请使用availableActions');
        }
        selected.add(task);
      }
      final pending = await approvals.require(
        categories: [
          'tasks',
          if (action == 'restart') 'restart',
          if (['start', 'resume', 'retry', 'restart'].contains(action) &&
              selected.any(
                (t) => action == 'restart' ? t.restartUsesRemote : t.usesRemote,
              ))
            'remote',
          if (['start', 'resume', 'retry', 'restart'].contains(action) &&
              selected.any(
                (t) => action == 'restart'
                    ? t.restartNeedsDownloads
                    : t.needsDownloads,
              ))
            'downloads',
        ],
        identity: [
          request,
          action,
          for (final task in selected)
            [
              task.mediaId,
              task.mediaIdentity,
              task.generation,
              action == 'restart'
                  ? task.restartConfigurationIdentity
                  : task.configurationIdentity,
            ],
        ],
        preview: {
          'operation': action == 'restart' ? '从头重新生成字幕' : '管理软件转录队列',
          'action': action,
          'mediaCount': selected.length,
          'tasks': [
            for (final task in selected)
              {
                'title': library
                    .authorizedMediaNow([task.mediaId])
                    .single
                    .title,
                'settings': safeSettings(
                  action == 'restart' ? task.restartSettings : task.settings,
                ),
              },
          ],
          'note': action == 'restart'
              ? '从头重新执行，将重置本次断点；保留媒体和已发布字幕，软件原有输出位置可能更新。'
              : action == 'cancel'
              ? '停止并移出所选任务，丢弃该次断点；保留媒体和已发布字幕。'
              : '仅操作所选授权任务；不更改全局模型设置。',
        },
      );
      guard();
      for (final task in selected) {
        final current = library.authorizedMediaNow([task.mediaId]).single;
        if (backend.mediaIdentity(current) != task.mediaIdentity) {
          throw ExternalAiActionError('原任务媒体已变化，请重新读取队列');
        }
      }
      if (pending != null) return pending;
      prior = {
        'signature': signature,
        'items': [
          for (final task in selected)
            {
              'taskId': _id(task),
              'mediaId': task.mediaId,
              'mediaIdentity': task.mediaIdentity,
              'generation': task.generation,
              'configuration': action == 'restart'
                  ? task.restartConfigurationIdentity
                  : task.configurationIdentity,
              'state': 'pending',
            },
        ],
      };
      _requests[key] = prior;
      await _save();
    }
    for (final row in (prior['items'] as List).cast<Map>()) {
      if (row['state'] == 'applied' || row['state'] == 'failed') continue;
      if (row['state'] == 'applying') {
        // A previous response may have been lost after a non-idempotent restart.
        row['state'] = 'failed';
        row['error'] = 'outcome_unconfirmed';
        continue;
      }
      guard();
      final current = await _authorized(guard);
      final task = current.where((t) => _id(t) == row['taskId']).firstOrNull;
      if (task == null ||
          task.mediaIdentity != row['mediaIdentity'] ||
          task.generation != row['generation']) {
        row['state'] = 'failed';
        row['error'] = 'task_changed';
        continue;
      }
      if ((action == 'restart'
              ? task.restartConfigurationIdentity
              : task.configurationIdentity) !=
          row['configuration']) {
        row['state'] = 'failed';
        row['error'] = 'configuration_changed';
        continue;
      }
      if (!task.actions.contains(action)) {
        row['state'] = 'failed';
        row['error'] = 'state_changed';
        continue;
      }
      final media = library.authorizedMediaNow([task.mediaId]).single;
      void operationGuard() {
        guard();
        // Resolve afresh: the library may move, hide or update this same
        // VideoItem instance while an app-side consent dialog is open.
        final current = library.authorizedMediaNow([task.mediaId]).single;
        if (backend.mediaIdentity(current) != task.mediaIdentity) {
          throw ExternalAiActionError('原任务媒体已变化，请重新读取队列');
        }
      }
      row['state'] = 'applying';
      await _save();
      operationGuard();
      try {
        final applied = await backend.controlQueueTask(
          media,
          task,
          action as String,
          operationGuard,
        );
        operationGuard();
        row['state'] = applied ? 'applied' : 'failed';
        if (!applied) row['error'] = 'state_changed';
      } catch (_) {
        operationGuard();
        row['state'] = 'failed';
        row['error'] = 'operation_failed';
      }
      await _save();
    }
    guard();
    final items = (prior['items'] as List).cast<Map>();
    final result = <String, dynamic>{
      'status': items.every((r) => r['state'] == 'applied')
          ? 'completed'
          : 'completed_with_errors',
      'action': action,
      'tasks': [
        for (final row in items)
          {
            'taskId': row['taskId'],
            'mediaId': row['mediaId'],
            'status': row['state'],
            if (row['error'] != null) 'error': row['error'],
          },
      ],
      'nextTool': 'transcription_queue',
      'guidance':
          '重新读取队列查看真实进度。状态或配置改变时先检查再用新requestId操作；outcome_unconfirmed不可盲目重复收费任务。',
    };
    prior['result'] = result;
    await _save();
    guard();
    return result;
  }
}
