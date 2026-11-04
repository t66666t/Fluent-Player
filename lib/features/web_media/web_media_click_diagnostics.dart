/// Bounded, shareable trace of what happened to a webpage download click.
///
/// The trace never stores URLs, query strings, cookies, page titles or file
/// paths. Only stage names, anonymous ids, byte counts and error codes leave
/// the app, which keeps the existing "copy diagnostics" behaviour safe.
library;

enum WebMediaClickStage {
  clickReceived,
  bridgeReceived,
  pageValidated,
  targetResolved,
  taskCreated,
  taskReused,
  resourceBound,
  manifestReady,
  transferStarted,
  transferFinished,
  saved,
  rejected,
  failed,
}

String webMediaClickStageLabel(WebMediaClickStage stage) => switch (stage) {
  WebMediaClickStage.clickReceived => '收到点击',
  WebMediaClickStage.bridgeReceived => '收到网页命令',
  WebMediaClickStage.pageValidated => '页面校验通过',
  WebMediaClickStage.targetResolved => '定位播放器',
  WebMediaClickStage.taskCreated => '创建任务',
  WebMediaClickStage.taskReused => '复用已有任务',
  WebMediaClickStage.resourceBound => '绑定下载资源',
  WebMediaClickStage.manifestReady => '解析播放清单',
  WebMediaClickStage.transferStarted => '开始传输',
  WebMediaClickStage.transferFinished => '传输完成',
  WebMediaClickStage.saved => '已加入媒体库',
  WebMediaClickStage.rejected => '请求被拒绝',
  WebMediaClickStage.failed => '下载失败',
};

class WebMediaClickEvent {
  const WebMediaClickEvent(this.stage, this.at, {this.detail});

  final WebMediaClickStage stage;
  final Duration at;
  final String? detail;

  String get label {
    final suffix = detail == null || detail!.isEmpty ? '' : '（$detail）';
    return '+${at.inMilliseconds}ms ${webMediaClickStageLabel(stage)}$suffix';
  }
}

class WebMediaClickDiagnostics {
  WebMediaClickDiagnostics({
    required this.requestId,
    this.generation,
    this.playerId,
  });

  /// Bounded so a page that keeps retrying cannot grow the trace forever.
  static const maxEvents = 24;

  final String requestId;
  final int? generation;
  final String? playerId;
  final DateTime startedAt = DateTime.now();
  final List<WebMediaClickEvent> events = [];
  final Stopwatch _watch = Stopwatch()..start();

  String? taskId;
  String? errorCode;
  int? sizeBytes;
  bool sizeEstimated = false;
  bool saved = false;

  bool get rejected => errorCode != null;
  String? get lastStage =>
      events.isEmpty ? null : webMediaClickStageLabel(events.last.stage);

  void mark(WebMediaClickStage stage, {String? detail}) {
    if (events.length >= maxEvents) return;
    if (events.isNotEmpty && events.last.stage == stage) return;
    events.add(WebMediaClickEvent(stage, _watch.elapsed, detail: detail));
  }

  void reject(String code) {
    errorCode = code;
    mark(WebMediaClickStage.rejected, detail: code);
  }

  void fail(String code) {
    errorCode = code;
    mark(WebMediaClickStage.failed, detail: code);
  }

  void attachTask(String id, {bool reused = false}) {
    taskId = id;
    mark(
      reused ? WebMediaClickStage.taskReused : WebMediaClickStage.taskCreated,
      detail: 'task $id',
    );
  }

  void noteSize({int? bytes, required bool estimated}) {
    sizeBytes = bytes;
    sizeEstimated = estimated;
  }

  String get sizeLabel {
    if (sizeBytes == null || sizeBytes! <= 0) return '大小未知';
    final mb = (sizeBytes! / (1024 * 1024)).toStringAsFixed(1);
    return '${sizeEstimated ? '约 ' : ''}$mb MB';
  }

  String get summary {
    final lines = [
      '点击诊断：$requestId',
      '页面 generation：${generation ?? '未知'} · 播放器：${playerId ?? '整页'}',
      '阶段：${lastStage ?? '未收到'}${rejected ? ' · 错误 $errorCode' : ''}',
      '任务：${taskId ?? '尚未创建'} · 大小来源：${sizeBytes == null ? '未知' : sizeLabel}',
      ...events.map((event) => event.label),
    ];
    return lines.join('\n');
  }
}

/// Keeps only a few recent clicks so the browser menu can explain a failure
/// even when no task was created.
class WebMediaClickDiagnosticsLog {
  static const maxEntries = 8;

  final List<WebMediaClickDiagnostics> _entries = [];

  List<WebMediaClickDiagnostics> get entries => List.unmodifiable(_entries);

  WebMediaClickDiagnostics start({
    required String requestId,
    int? generation,
    String? playerId,
  }) {
    final existing = _entries
        .where((entry) => entry.requestId == requestId)
        .firstOrNull;
    if (existing != null) return existing;
    final entry = WebMediaClickDiagnostics(
      requestId: requestId,
      generation: generation,
      playerId: playerId,
    );
    entry.mark(WebMediaClickStage.clickReceived);
    entry.mark(WebMediaClickStage.bridgeReceived);
    _entries.insert(0, entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    return entry;
  }

  WebMediaClickDiagnostics? byTaskId(String id) =>
      _entries.where((entry) => entry.taskId == id).firstOrNull;

  void clear() => _entries.clear();

  String get summary {
    if (_entries.isEmpty) return '还没有收到网页下载点击。';
    return [
      '最近 ${_entries.length} 次网页下载点击（${DateTime.now().toIso8601String()}）',
      '',
      for (var index = 0; index < _entries.length; index++)
        '【${index + 1}】${_entries[index].summary}',
    ].join('\n');
  }
}
