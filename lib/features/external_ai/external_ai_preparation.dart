import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../services/subtitle_discovery_service.dart';
import 'external_ai_actions.dart';
import 'external_ai_action_store.dart';
import 'external_ai_approvals.dart';
import 'external_ai_document_backend.dart';
import 'external_ai_library_source.dart';
import 'external_ai_preferences.dart';
import 'external_ai_processing_backend.dart';
import 'external_ai_server.dart';

/// Bounded background preparation, separate from both ordinary library reads
/// and transcription. Its journal contains IDs and safe results, never media.
class ExternalAiPreparation implements ExternalAiDataSource {
  ExternalAiPreparation({
    required this.library,
    required this.documents,
    required this.processing,
    required this.approvals,
    required this.store,
    required this.preferences,
    required this.generation,
  });
  final ExternalAiLibrarySource library;
  final ExternalAiDocumentBackend documents;
  final ExternalAiProcessingBackend processing;
  final ExternalAiApprovals approvals;
  final ExternalAiActionStore store;
  final ExternalAiPreferences? Function() preferences;
  final int Function() generation;
  Map<String, dynamic> _state = {'version': 1};
  final Map<String, ExternalAiDocumentWork> _work = {};
  final Map<String, Future<void>> _running = {};
  Future<void> _writes = Future.value();
  Future<void> _calls = Future.value();
  Future<void>? _loading;
  bool _disposed = false;
  Map<String, dynamic> _section(String key) =>
      _state.putIfAbsent(key, () => <String, dynamic>{})
          as Map<String, dynamic>;
  Future<void> initialize() => _loading ??= () async {
    _state = await store.load();
    for (final job in _section('jobs').values.whereType<Map>()) {
      if (['running', 'queued', 'cancelling'].contains(job['status'])) {
        job['status'] = 'interrupted';
        for (final row in (job['items'] as List).whereType<Map>()) {
          if (['queued', 'preparing'].contains(row['state'])) {
            row['state'] = 'interrupted';
          }
        }
      }
    }
  }();
  Future<void> _save() async {
    final snapshot = jsonDecode(jsonEncode(_state)) as Map<String, dynamic>;
    final next = _writes.then((_) => store.save(snapshot));
    _writes = next.catchError((Object _) {});
    await next;
  }

  Future<void> shutdown() async {
    _disposed = true;
    for (final w in _work.values) {
      w.cancel();
    }
    await Future.wait(_running.values.toList());
    await _writes;
  }

  static const _string = {'type': 'string'};
  static const _ids = {
    'type': 'array',
    'items': _string,
    'minItems': 1,
    'maxItems': 100,
    'uniqueItems': true,
  };
  static Map<String, dynamic> _tool(
    String name,
    String description,
    Map<String, dynamic> properties,
    List<String> required, {
    bool read = false,
  }) => {
    'name': name,
    'description': description,
    'inputSchema': {
      'type': 'object',
      'properties': properties,
      'required': required,
      'additionalProperties': false,
    },
    'annotations': {
      'readOnlyHint': read,
      'destructiveHint': false,
      'idempotentHint': true,
      'openWorldHint': ['documents_prepare', 'models_prepare'].contains(name),
    },
  };
  @override
  List<Map<String, dynamic>> get tools => [
    _tool(
      'documents_prepare',
      '批量按需准备最多100个媒体的现有字幕，不用打开播放页。先复用已保存/已提取的文稿，再匹配同目录字幕，缺少时提取内嵌文字软字幕或获取已有在线字幕。跳过图片字幕；绝不自动转录、生成付费字幕或下载整个远程媒体。返回jobId，documents_prepare_status查询后用documents_read_batch读取。',
      {
        'mediaIds': _ids,
        'requestId': _string,
        'includeEmbedded': {'type': 'boolean', 'default': true},
        'includeOnline': {'type': 'boolean', 'default': true},
      },
      ['mediaIds', 'requestId'],
    ),
    _tool(
      'documents_prepare_status',
      '批量文稿准备的进度和逐媒体结果；ready可读取，candidate需用户选择，unchecked/failed不等于无字幕。confirmed_none仅限明确检查过的来源。',
      {
        'jobId': _string,
        'offset': {'type': 'integer'},
        'limit': {'type': 'integer'},
      },
      ['jobId'],
      read: true,
    ),
    _tool(
      'documents_prepare_cancel',
      '取消本连接的文稿准备任务；终止自身的字幕提取进程，保留已准备好的字幕。',
      {'jobId': _string},
      ['jobId'],
    ),
    if (preferences()?.allowTaskControl == true) ...[
      _tool(
        'models_prepare',
        '独立的高级配置能力：准备固定模型清单中的模型或组件，沿用模型中心下载队列。先返回需确认的大小，用户确认或明确开启下载代办后执行；不切换当前模型。日常转录用transcription_start自动准备当前模型。',
        {'modelIds': _ids, 'requestId': _string},
        ['modelIds', 'requestId'],
      ),
      _tool(
        'models_status',
        '独立的高级配置能力：一次查询模型安装和下载进度、字节数及速度。下载可在软件模型中心暂停/继续；这里不接管用户其他下载。',
        {'modelIds': _ids},
        ['modelIds'],
        read: true,
      ),
      _tool(
        'settings_update',
        '独立的高级配置能力：修改以后新任务默认使用的已有模型/已配置服务、媒体语言、翻译模型或目标语言。无需提供或读取密钥；始终先在播放器确认具体变更，不影响已排队任务。日常转录无需调用。',
        {
          'serviceId': _string,
          'sourceLanguage': _string,
          'translationModelId': _string,
          'translationProvider': {
            'type': 'string',
            'enum': ['local', 'bing', 'ai'],
          },
          'translationMode': {
            'type': 'string',
            'enum': ['fixed', 'smart'],
          },
          'targetLanguage': _string,
          'requestId': _string,
        },
        ['requestId'],
      ),
      _tool(
        'approvals_read',
        '读取待用户确认的操作与批准/拒绝结果。只能查询，不能代替用户批准或打开权限。确认后重试原请求；拒绝后不要反复请求。',
        {},
        [],
        read: true,
      ),
    ],
  ];
  void Function() _guard({bool processing = false}) {
    final epoch = generation(), grant = approvals.grant;
    void check() {
      if (_disposed ||
          preferences()?.enabled != true ||
          generation() != epoch ||
          approvals.grant != grant ||
          (processing && preferences()?.allowTaskControl != true)) {
        throw ExternalAiActionError('授权已改变或操作未授权');
      }
    }

    check();
    return check;
  }

  static String _text(Map a, String key) {
    final v = a[key];
    if (v is! String ||
        v.isEmpty ||
        v.length > 256 ||
        RegExp(r'[\x00-\x1f]').hasMatch(v)) {
      throw ExternalAiActionError('字符串参数无效：$key');
    }
    return v;
  }

  static List<String> _idList(Map a, String key) {
    final v = a[key];
    if (v is! List ||
        v.isEmpty ||
        v.length > 100 ||
        v.toSet().length != v.length) {
      throw ExternalAiActionError('每批需要1–100个不重复的ID');
    }
    return [
      for (final id in v) _text({'id': id}, 'id'),
    ];
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> a,
  ) async {
    final tool = tools.where((t) => t['name'] == name).firstOrNull;
    if (tool == null) throw ExternalAiActionError('操作不存在或未授权');
    final schema = tool['inputSchema'] as Map,
        properties = tool['inputSchema']['properties'] as Map;
    if (a.keys.any((k) => !properties.containsKey(k)) ||
        (schema['required'] as List).any((k) => !a.containsKey(k))) {
      throw ExternalAiActionError('参数缺失或包含未知字段');
    }
    for (final e in a.entries) {
      final ok = switch (properties[e.key]['type']) {
        'string' => e.value is String,
        'array' => e.value is List,
        'boolean' => e.value is bool,
        'integer' => e.value is int,
        _ => false,
      };
      if (!ok) throw ExternalAiActionError('参数类型无效');
    }
    final guard = _guard(processing: !name.startsWith('documents_'));
    final next = _calls.then((_) async {
      try {
        await initialize();
        guard();
        if (name == 'approvals_read') return {'requests': approvals.requests};
        if (name == 'models_status') {
          final result = await processing.modelStatus(_idList(a, 'modelIds'));
          guard();
          return result;
        }
        if (name.startsWith('documents_prepare_')) {
          return _jobCommand(name, a, guard);
        }
        final request = _text(a, 'requestId');
        if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(request)) {
          throw ExternalAiActionError('requestId格式无效');
        }
        final key = '${approvals.grant}:$request';
        final sorted = {for (final k in a.keys.toList()..sort()) k: a[k]};
        final signature = jsonEncode([name, sorted]);
        final prior = _section('receipts')[key];
        if (prior is Map) {
          if (prior['signature'] != signature) {
            throw ExternalAiActionError('同一requestId不能用于不同操作');
          }
          if (prior['result'] != null) {
            final result = Map<String, dynamic>.from(prior['result'] as Map);
            if (result['jobId'] is String) {
              _authorizedJob(result['jobId'] as String, guard);
            }
            return result;
          }
        }
        if (_section('receipts').length >= 5000) {
          throw ExternalAiActionError('外部AI准备记录已满');
        }
        _section('receipts')[key] = {'signature': signature};
        await _save();
        guard();
        final Map<String, dynamic> result;
        if (name == 'documents_prepare') {
          result = await _prepare(a, guard);
        } else if (name == 'models_prepare') {
          final ids = _idList(a, 'modelIds');
          final preview = await processing.modelPreview(ids);
          guard();
          final pending = await approvals.require(
            categories: ['downloads'],
            identity: [key, ids, preview],
            preview: preview,
          );
          guard();
          if (pending != null) return pending;
          await processing.prepareModels(ids, guard);
          guard();
          result = {
            'status': 'queued',
            'modelIds': ids,
            'progressTool': 'models_status',
          };
        } else if (name == 'settings_update') {
          final changes = {...a}..remove('requestId');
          if (changes.isEmpty) throw ExternalAiActionError('请指定需要修改的设置');
          final preview = await processing.defaultsPreview(changes);
          guard();
          final pending = await approvals.require(
            categories: ['settings'],
            identity: [key, preview],
            preview: preview,
          );
          guard();
          if (pending != null) return pending;
          await processing.updateDefaults(changes, guard);
          guard();
          result = {'status': 'applied', 'changes': changes};
        } else {
          throw ExternalAiActionError('操作不存在');
        }
        _section('receipts')[key] = {'signature': signature, 'result': result};
        await _save();
        return result;
      } on ExternalAiActionError {
        rethrow;
      } catch (_) {
        throw ExternalAiActionError('操作未完成，请在软件检查字幕、模型或设置；未提供媒体文件');
      }
    });
    _calls = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Map<String, dynamic> _authorizedJob(String id, void Function() guard) {
    guard();
    final job = _section('jobs')[id];
    if (job is! Map<String, dynamic> || job['grant'] != approvals.grant) {
      throw ExternalAiActionError('任务不存在或不属于当前授权');
    }
    library.authorizedMediaNow((job['mediaIds'] as List).cast<String>());
    return job;
  }

  Map<String, dynamic> _jobCommand(String name, Map a, void Function() guard) {
    final id = _text(a, 'jobId'),
        job = _authorizedJob(_text(a, 'jobId'), guard);
    if (name.endsWith('_cancel')) {
      _work[id]?.cancel();
      if (_running.containsKey(id)) job['status'] = 'cancelling';
      return {'jobId': id, 'status': job['status']};
    }
    final offset = a['offset'] ?? 0, limit = a['limit'] ?? 20;
    if (offset is! int ||
        offset < 0 ||
        limit is! int ||
        limit < 1 ||
        limit > 100) {
      throw ExternalAiActionError('分页范围无效');
    }
    final rows = job['items'] as List;
    return {
      'jobId': id,
      'status': job['status'],
      'total': rows.length,
      'completed': rows
          .where((v) => !['queued', 'preparing'].contains(v['state']))
          .length,
      'items': rows.skip(offset).take(limit).toList(),
      'nextOffset': offset + limit < rows.length ? offset + limit : null,
      'readTool': 'documents_read_batch',
    };
  }

  Future<Map<String, dynamic>> _prepare(
    Map<String, dynamic> a,
    void Function() guard,
  ) async {
    final ids = _idList(a, 'mediaIds');
    await library.authorizedMedia(ids);
    guard();
    if (_running.length >= 2) throw ExternalAiActionError('已有两批文稿正在准备，请稍后再提交');
    if (_section('jobs').length >= 500) {
      final completed = _section('jobs').entries
          .where(
            (e) => ![
              'running',
              'queued',
              'cancelling',
            ].contains(e.value['status']),
          )
          .firstOrNull;
      if (completed != null) _section('jobs').remove(completed.key);
    }
    final id = const Uuid().v4();
    final job = <String, dynamic>{
      'grant': approvals.grant,
      'status': 'running',
      'mediaIds': ids,
      'items': [
        for (final mediaId in ids)
          <String, dynamic>{'mediaId': mediaId, 'state': 'queued'},
      ],
    };
    _section('jobs')[id] = job;
    await _save();
    guard();
    final work = ExternalAiDocumentWork();
    _work[id] = work;
    // Yield before heavy IO: the MCP call returns a small job ticket immediately.
    final running = Future<void>(() => _run(id, job, a, work, guard));
    _running[id] = running;
    unawaited(
      running.whenComplete(() {
        _running.remove(id);
        _work.remove(id);
      }),
    );
    return {
      'jobId': id,
      'status': 'running',
      'mediaCount': ids.length,
      'progressTool': 'documents_prepare_status',
    };
  }

  Future<void> _run(
    String id,
    Map<String, dynamic> job,
    Map<String, dynamic> a,
    ExternalAiDocumentWork work,
    void Function() base,
  ) async {
    final batch = SubtitleDiscoveryBatch(validateGenericFiles: false);
    try {
      for (final row in (job['items'] as List).cast<Map>()) {
        void guard() {
          work.check();
          base();
          library.authorizedMediaNow([row['mediaId'] as String]);
        }

        guard();
        final item = (await library.authorizedMedia([
          row['mediaId'] as String,
        ])).single;
        row['state'] = 'preparing';
        await _save();
        try {
          final before = await documents.identity(item);
          final result = await documents.prepare(
            item,
            batch: batch,
            work: work,
            guard: guard,
            includeEmbedded: a['includeEmbedded'] as bool? ?? true,
            includeOnline: a['includeOnline'] as bool? ?? true,
          );
          guard();
          if (await documents.identity(item) != before) {
            throw StateError('source changed');
          }
          row.addAll(result);
        } on ExternalAiPreparationCancelled {
          rethrow;
        } catch (_) {
          base();
          row['state'] = 'failed';
          row['reason'] = '检查或准备失败；请检查文件/登录状态后重新准备，不能据此认定没有字幕';
        }
        await _save();
      }
      job['status'] = 'completed';
    } catch (_) {
      job['status'] = work.cancelled ? 'cancelled' : 'interrupted';
      for (final row in (job['items'] as List).cast<Map>()) {
        if (['queued', 'preparing'].contains(row['state'])) {
          row['state'] = job['status'];
        }
      }
    } finally {
      try {
        await _save();
      } catch (_) {
        job['status'] = 'interrupted';
      }
    }
  }
}
