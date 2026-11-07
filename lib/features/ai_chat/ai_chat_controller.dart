import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../models/video_item.dart';
import '../../models/subtitle_model.dart';
import 'ai_chat_copy.dart';
import 'ai_chat_models.dart';
import 'ai_chat_reading_state.dart';
import 'ai_chat_settings.dart';
import 'ai_chat_transport.dart';
import 'ai_answer_continuation.dart';
import 'ai_conversation_store.dart';
import 'ai_prompt_composer.dart';
import 'ai_video_context.dart';
import 'ai_token_usage.dart';
import 'ai_transcript_preparation.dart';
import 'ai_turn_plan.dart';
import 'ai_context_compaction.dart';
import '../../services/ai_api_connection_sync.dart';

class _AiChatRun {
  bool compactionOnly = false;
  final cancellation = AiChatCancellation();
  final done = Completer<void>();
  String? preparationStatus;
  String? generationStatus;
  bool reconnecting = false;
}

class AiChatController extends ChangeNotifier {
  AiChatController({
    required this.video,
    AiChatTransport? transport,
    AiChatSettingsStore? settingsStore,
    AiConversationStore? conversationStore,
    AiVideoContextLoader? contextLoader,
    AiChatSettings? initialSettings,
  }) : _transport = transport ?? AiChatTransport(),
       _settingsStore = settingsStore ?? AiChatSettingsStore(),
       _store = conversationStore ?? AiConversationStore(),
       _loader = contextLoader ?? AiVideoContextLoader(),
       settings = initialSettings ?? const AiChatSettings(),
       _initialSettings = initialSettings {
    AiApiConnectionSync.changes.addListener(_sharedConnectionChanged);
  }

  VideoItem video;
  Future<void>? _initialization;
  final AiChatTransport _transport;

  /// A settings dialog may borrow the idle chat connection. It must not own or
  /// dispose it, and background conversations must keep their active transport.
  AiChatTransport? get settingsTransport =>
      !_disposed && _runs.isEmpty && _titleCancellations.isEmpty
      ? _transport
      : null;
  final AiChatSettingsStore _settingsStore;
  final AiConversationStore _store;
  final AiVideoContextLoader _loader;
  final AiChatSettings? _initialSettings;
  final AiPromptComposer _composer = AiPromptComposer();
  late final AiTranscriptPreparation _transcript = AiTranscriptPreparation(
    transport: _transport,
    root: _store.root,
  );
  final _runs = <String, _AiChatRun>{};
  _AiChatRun? get _activeRun => _runs[_activeId];
  String? _preparationOverride;
  String? get preparationStatus =>
      _activeRun?.preparationStatus ?? _preparationOverride;
  set preparationStatus(String? value) {
    if (_activeRun != null) {
      _activeRun!.preparationStatus = value;
    } else {
      _preparationOverride = value;
    }
  }

  String? get generationStatus => _activeRun?.generationStatus;
  bool get reconnecting => _activeRun?.reconnecting ?? false;
  static const _uuid = Uuid();
  AiChatSettings settings;
  AiVideoContext? videoContext;
  AiRequestPreview? get lastRequest => active?.lastRequest;
  bool ready = false;
  bool _mutating = false;
  bool get generating => _activeRun != null;
  bool get busy => generating || _mutating;
  bool get compacting =>
      _activeRun?.compactionOnly == true ||
      (_activeRun?.preparationStatus?.startsWith('正在压缩') ?? false);
  AiContextCheckpoint? get contextCheckpoint {
    final record = active;
    final checkpoint = record?.contextCheckpoint;
    return record != null && checkpoint?.matches(record.messages) == true
        ? checkpoint
        : null;
  }

  bool get managing => _mutating;
  bool isGenerating(String conversationId) => _runs.containsKey(conversationId);
  String? error;
  String? _draft;
  String? get draft => _draft;
  set draft(String? value) {
    _draft = value;
    if (value != null) updateDraft(value, notify: false);
  }

  bool _disposed = false;
  String? _activeId;
  final readingState = AiChatReadingState();

  /// Composer-only changes must not rebuild the rendered transcript.
  final draftRevision = ValueNotifier<int>(0);
  final List<AiConversation> _conversations = [];
  Set<String> selectedTrackIds = {};
  bool get selectionIsAutomatic => active?.selectionIsAutomatic ?? true;
  Map<String, dynamic>? get lastUsage => active?.messages.lastOrNull?.usage;
  String? get responseWarning =>
      active?.messages.lastOrNull?.finishReason == 'length' &&
          active?.messages.lastOrNull?.status == 'complete'
      ? '本次生成达到单次输出上限，已保留回答，可继续补全。思考也可能占用输出额度。'
      : null;
  final _titleCancellations = <String, AiChatCancellation>{};
  Future<void> _settingsWrites = Future<void>.value();
  Timer? _notifyTimer;
  Timer? _draftSaveTimer;
  final _dirtyDraftIds = <String>{};
  final _deletingIds = <String>{};
  int _contextRevision = 0;

  List<AiConversation> get conversations => List.unmodifiable(_conversations);
  AiConversation? get active {
    for (final conversation in _conversations) {
      if (conversation.id == _activeId) return conversation;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String? takeDraft() {
    final value = draft;
    draft = null;
    return value;
  }

  /// Keep exact text in memory immediately, without changing history order.
  void updateDraft(String text, {String? conversationId, bool notify = true}) {
    if (_disposed) return;
    final id = conversationId ?? _activeId;
    if (_deletingIds.contains(id)) return;
    final index = _conversations.indexWhere((item) => item.id == id);
    if (index < 0) return;
    // An unconsumed withdraw/edit command must not overwrite later typing
    // when a hidden view is attached again.
    if (notify && id == _activeId) _draft = null;
    if (_conversations[index].draftText == text) return;
    _conversations[index] = _conversations[index].copyWith(
      draftText: text,
      touchUpdatedAt: false,
    );
    _dirtyDraftIds.add(id!);
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(flushDrafts());
    });
    if (notify) draftRevision.value++;
  }

  /// Enqueue the latest records before a view detaches or a task changes.
  Future<void> flushDrafts() async {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = null;
    final records = _conversations
        .where(
          (item) =>
              _dirtyDraftIds.contains(item.id) &&
              !_deletingIds.contains(item.id),
        )
        .toList();
    _dirtyDraftIds.clear();
    await Future.wait(records.map(_persist));
  }

  /// True once [initialize] has been entered, including while it is still running.
  bool get initializationStarted => _initialization != null;

  /// Swap in a newer library snapshot for the same video without dropping
  /// the reply that is already streaming.
  void adoptVideo(VideoItem next) {
    if (next.id != video.id) return;
    video = next;
  }

  /// Settings saved from another surface, such as subtitle translation.
  /// The reply already in flight keeps the copy it started with.
  void adoptSettings(AiChatSettings value) {
    if (_disposed) return;
    settings = value;
    _notify();
  }

  /// Lets the visible panel refresh Bilibili and download metadata on the
  /// loader this controller kept after the previous panel was disposed.
  void bindContext(void Function(AiVideoContextLoader loader) update) {
    if (_disposed) return;
    update(_loader);
  }

  Future<void> initialize({
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) {
    if (ready || _disposed) return Future<void>.value();
    // Portrait and landscape can attach during the same hand-off. One load
    // has to win; the later view refreshes context after this future.
    return _initialization ??= _initialize(
      primarySubtitles: primarySubtitles,
      secondarySubtitles: secondarySubtitles,
      position: position,
      primaryPath: primaryPath,
      secondaryPath: secondaryPath,
    );
  }

  Future<void> _initialize({
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async {
    final initializationWarnings = <String>[];
    try {
      if (_initialSettings == null) {
        try {
          settings = await _settingsStore.load();
        } catch (_) {
          initializationWarnings.add('无法读取安全存储中的 API 密钥，请打开设置重新填写。');
        }
      }
      final loaded = await _store.load(video.id);
      if (_disposed) return;
      _conversations.addAll(loaded);
      initializationWarnings.addAll(_store.warnings);
      await refreshContext(
        primarySubtitles: primarySubtitles,
        secondarySubtitles: secondarySubtitles,
        position: position,
        primaryPath: primaryPath,
        secondaryPath: secondaryPath,
      );
      if (_disposed) return;
      if (_conversations.isEmpty) {
        await createConversation();
      } else {
        await selectConversation(_conversations.first.id);
      }
      if (initializationWarnings.isNotEmpty) {
        error = initializationWarnings.join('\n');
      }
    } catch (_) {
      error = 'AI 对话初始化失败，请关闭边栏后重试。';
    } finally {
      ready = true;
      _notify();
    }
  }

  Future<void> refreshContext({
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
    bool retryOnlineSources = false,
  }) async {
    final revision = ++_contextRevision;
    if (retryOnlineSources) _loader.invalidateFailures();
    try {
      final result = await _loader.load(
        video: video,
        primarySubtitles: primarySubtitles,
        secondarySubtitles: secondarySubtitles,
        position: position,
        primaryPath: primaryPath,
        secondaryPath: secondaryPath,
      );
      await _composer.contextBuilder.prepare(result);
      if (_disposed || revision != _contextRevision) return;
      videoContext = result;
      if (selectionIsAutomatic || active?.selectedTrackIds == null) {
        final recommended = _defaultTracks();
        selectedTrackIds = recommended;
        final current = active;
        if (current != null &&
            !setEquals(current.selectedTrackIds, recommended)) {
          final updated = current.copyWith(selectedTrackIds: recommended);
          _replace(updated);
          unawaited(_persist(updated));
        }
      } else {
        final migrated = selectedTrackIds.map((id) {
          for (final track in result.tracks) {
            if (track.id == id || track.aliases.contains(id)) return track.id;
          }
          return id;
        }).toSet();
        if (!setEquals(migrated, selectedTrackIds)) {
          selectedTrackIds = migrated;
          final updated = active!.copyWith(selectedTrackIds: migrated);
          _replace(updated);
          unawaited(_persist(updated));
        }
      }
    } catch (_) {
      if (!_disposed) error = AiChatMediaCopy.of(video).sourcesFailed;
    }
    _notify();
  }

  Set<String> _defaultTracks() {
    final context = videoContext;
    return context == null ? {} : recommendAiSubtitleTracks(context);
  }

  Future<void> createConversation() async {
    if (_mutating || _disposed) return;
    await _mutate(_createConversation);
  }

  Future<void> _mutate(Future<void> Function() action) async {
    _mutating = true;
    _notify();
    try {
      await action();
    } finally {
      _mutating = false;
      _notify();
    }
  }

  Future<void> _createConversation() async {
    unawaited(flushDrafts());
    // Source choices apply immediately, including before the first message.
    final automatic = selectionIsAutomatic;
    final tracks = automatic
        ? _defaultTracks()
        : Set<String>.of(selectedTrackIds);
    final empty = _conversations
        .where(
          (item) =>
              item.messages.isEmpty &&
              !item.hasDraft &&
              !item.titleEdited &&
              item.parentConversationId == null &&
              !isGenerating(item.id) &&
              // Keep other blank tasks with different manual source choices.
              (item.selectionIsAutomatic ||
                  (!automatic && setEquals(item.selectedTrackIds, tracks))),
        )
        .firstOrNull;
    if (empty != null) {
      AiConversation? updated;
      if (empty.selectionIsAutomatic != automatic ||
          !setEquals(empty.selectedTrackIds, tracks)) {
        updated = empty.copyWith(
          selectedTrackIds: tracks,
          selectionIsAutomatic: automatic,
        );
        _replace(updated);
      }
      _selectConversation(empty.id);
      if (updated != null) await _persist(updated);
      return;
    }
    final conversation = AiConversation(
      id: _uuid.v4(),
      videoId: video.id,
      title: '新对话',
      selectedTrackIds: tracks,
      selectionIsAutomatic: automatic,
    );
    _conversations.insert(0, conversation);
    _activeId = conversation.id;
    readingState.openConversation(conversation.id);
    selectedTrackIds = Set.from(conversation.selectedTrackIds!);
    draft = null;
    error = null;
    _notify();
    await _persist(conversation);
  }

  Future<void> selectConversation(String id) async {
    if (_mutating ||
        _disposed ||
        !_conversations.any((conversation) => conversation.id == id)) {
      return;
    }
    _selectConversation(id);
  }

  void _selectConversation(String id) {
    unawaited(flushDrafts());
    _activeId = id;
    readingState.openConversation(id);
    selectedTrackIds = Set.from(
      selectionIsAutomatic
          ? _defaultTracks()
          : active?.selectedTrackIds ?? _defaultTracks(),
    );
    draft = null;
    error = null;
    _notify();
  }

  Future<void> deleteConversation(String id) async {
    if (_mutating || _disposed) return;
    await _mutate(() async {
      _deletingIds.add(id);
      _dirtyDraftIds.remove(id);
      try {
        await _stopConversation(id);
        _titleCancellations.remove(id)?.cancel();
        await _store.delete(video.id, id);
        _conversations.removeWhere((conversation) => conversation.id == id);
        if (_activeId == id) {
          if (_conversations.isEmpty) {
            await _createConversation();
          } else {
            _selectConversation(_conversations.first.id);
          }
        }
      } catch (_) {
        error = '删除对话失败，请重试。';
      } finally {
        _deletingIds.remove(id);
      }
    });
  }

  Future<void> renameConversation(String id, String title) async {
    if (_mutating || _disposed || title.trim().isEmpty) return;
    final index = _conversations.indexWhere(
      (conversation) => conversation.id == id,
    );
    if (index < 0) return;
    final updated = _conversations[index].copyWith(
      title: title.trim(),
      titleEdited: true,
    );
    _replace(updated);
    await _persist(updated);
    _notify();
  }

  void setSelectedTracks(Set<String> ids, {bool automatic = false}) {
    if (_mutating || _disposed) return;
    selectedTrackIds = Set.from(ids);
    final current = active;
    if (current != null) {
      final updated = current.copyWith(
        selectedTrackIds: ids,
        selectionIsAutomatic: automatic,
      );
      _replace(updated);
      unawaited(_persist(updated));
    }
    _notify();
  }

  Future<void> flushPreferencesForTrial() async {
    await _initialization;
    await _settingsWrites;
  }

  Future<void> refreshApiConnections() async {
    await _initialization;
    await _settingsWrites;
    if (_disposed) return;
    final updated = await _settingsStore.withSharedApiConnections(settings);
    if (_disposed) return;
    settings = updated;
    _notify();
  }

  bool _refreshingSharedConnections = false,
      _sharedConnectionsChangedAgain = false;
  void _sharedConnectionChanged() {
    if (_disposed || !ready) return;
    _sharedConnectionsChangedAgain = true;
    if (_refreshingSharedConnections) return;
    _refreshingSharedConnections = true;
    unawaited(() async {
      try {
        do {
          _sharedConnectionsChangedAgain = false;
          await refreshApiConnections();
        } while (_sharedConnectionsChangedAgain && !_disposed);
      } catch (_) {
        if (!_disposed) {
          error = '共享接口未能读取，请检查安全存储后重试。';
          _notify();
        }
      } finally {
        _refreshingSharedConnections = false;
      }
    }());
  }

  Future<void> saveSettings(AiChatSettings value) async {
    if (_disposed) return;
    final write = _settingsWrites.then((_) async {
      try {
        await _settingsStore.save(value);
        if (_disposed) return;
        settings = value;
        error = null;
      } catch (_) {
        error = '设置未保存成功，请检查安全存储后重试。';
        throw StateError(error!);
      }
    });
    _settingsWrites = write.catchError((Object _) {});
    await write;
    _notify();
  }

  AiRequestPreview preview(String question, {String requestTurnId = ''}) {
    final result = _composer.build(
      settings: settings,
      video:
          videoContext ?? AiVideoContext(videoId: video.id, title: video.title),
      question: question,
      selectedTrackIds: selectedTrackIds,
      history: active?.messages ?? [],
      checkpoint: contextCheckpoint,
      previousRequest: active?.lastRequest,
      requestTurnId: requestTurnId,
    );
    return result;
  }

  Future<AiCompactionResult?> _compactRecord(
    AiConversation record,
    AiChatSettings config,
    AiRequestPreview request,
    _AiChatRun run, {
    bool force = false,
    bool manual = false,
    bool overflow = false,
    String focus = '',
  }) async {
    final plan = AiContextCompaction.plan(
      history: record.messages,
      checkpoint: record.contextCheckpoint,
      settings: config,
      request: request,
      force: force,
      overflow: overflow,
    );
    if (plan == null) return null;
    if (!manual &&
        record.compactionInfo?['attempt_key'] == plan.key &&
        record.compactionInfo?['status'] != 'completed') {
      return null;
    }
    final source = <String, dynamic>{
      'video_id': record.videoId,
      'tracks': [
        for (final chunk in request.selectedChunks)
          {'id': chunk.trackId, 'label': chunk.label},
      ],
      'context_hash': sha256
          .convert(utf8.encode(request.contextText))
          .toString(),
      'provider_host': Uri.tryParse(config.baseUrl)?.host,
      'protocol': config.apiProtocol.name,
      'model': config.model,
    };
    run.preparationStatus = '正在压缩对话上下文…';
    _notify();
    final result = await AiContextCompaction(_transport).compact(
      plan: plan,
      history: record.messages,
      settings: config,
      cancellation: run.cancellation,
      focus: focus,
      source: source,
      onProgress: (calls) {
        run.preparationStatus = '正在压缩对话上下文 · 第 $calls/8 次请求';
        _notify();
      },
    );
    run.preparationStatus = null;
    final latest = _currentRecord(record);
    if (_disposed ||
        _deletingIds.contains(record.id) ||
        _runs[record.id] != run ||
        !_conversations.any((item) => item.id == record.id)) {
      return AiCompactionResult({
        ...result.info,
        'status': 'cancelled',
        'message': '原对话已关闭或压缩已停止，未提交摘要。',
      });
    }
    final checkpoint =
        !run.cancellation.isCancelled &&
            result.checkpoint?.matches(latest.messages) == true
        ? result.checkpoint
        : null;
    final info = result.checkpoint != null && checkpoint == null
        ? {
            ...result.info,
            'status': 'cancelled',
            'message': '历史已改变或压缩已停止，原摘要保持不变。',
          }
        : result.info;
    final updated = latest.copyWith(
      contextCheckpoint: checkpoint,
      clearLastRequest: checkpoint != null,
      compactionInfo: info,
    );
    _replace(updated);
    await _persist(updated);
    _notify();
    return AiCompactionResult(info, checkpoint: checkpoint);
  }

  /// Runs without adding a synthetic user/assistant turn. Its cancellation and
  /// persistence belong to the originating conversation even after navigation.
  Future<void> compactContext({String focus = ''}) async {
    if (!ready || busy || _disposed || active == null) return;
    final record = active!;
    final config = settings;
    final run = _AiChatRun()..compactionOnly = true;
    _runs[record.id] = run;
    _notify();
    try {
      AiRequestPreview request;
      try {
        request = preview(record.draftText.isEmpty ? '继续' : record.draftText);
      } on StateError {
        request = _composer.build(
          settings: config,
          video:
              videoContext ??
              AiVideoContext(videoId: record.videoId, title: video.title),
          question: record.draftText.isEmpty ? '继续' : record.draftText,
          selectedTrackIds: selectedTrackIds,
        );
      }
      final result = await _compactRecord(
        record,
        config,
        request,
        run,
        force: true,
        manual: true,
        focus: focus,
      );
      if (result == null && !_disposed) {
        final updated = _currentRecord(record).copyWith(
          compactionInfo: {
            'status': 'skipped',
            'message': '没有可压缩的较早完整轮次，或当前固定资料已占满预算。',
            'calls': 0,
            'time': DateTime.now().toIso8601String(),
          },
        );
        _replace(updated);
        await _persist(updated);
      }
    } catch (e) {
      if (!_disposed) {
        final updated = _currentRecord(record).copyWith(
          compactionInfo: {
            'status': 'failed',
            'message': e.toString(),
            'calls': 0,
            'time': DateTime.now().toIso8601String(),
          },
        );
        _replace(updated);
        await _persist(updated);
      }
    } finally {
      if (_runs[record.id] == run) _runs.remove(record.id);
      run.done.complete();
      _notify();
    }
  }

  Future<void> send(
    String text, {
    String? submittedDraft,
    VoidCallback? onAccepted,
  }) => _send(text, submittedDraft: submittedDraft, onAccepted: onAccepted);

  Future<void> _send(
    String text, {
    String? submittedDraft,
    VoidCallback? onAccepted,
  }) async {
    if (generating || _mutating || !ready || text.trim().isEmpty || _disposed) {
      return;
    }
    final settings = this.settings;
    if (active == null) await _createConversation();
    final current = active!;
    final sourceVideo = videoContext;
    final sourceTrackIds = Set<String>.from(selectedTrackIds);
    final hasTranscript =
        sourceVideo?.tracks.any(
          (track) => sourceTrackIds.contains(track.id) && track.hasText,
        ) ??
        false;
    final question = text.trim();
    final user = AiChatMessage(id: _uuid.v4(), role: 'user', content: question);
    AiRequestPreview request;
    try {
      // Before semantic selection, validate only the current input. A full-mode
      // transcript must not block ordinary feedback that needs no transcript.
      request = _composer.build(
        settings: settings.copyWith(contextMode: AiContextMode.automatic),
        video:
            sourceVideo ??
            AiVideoContext(videoId: current.videoId, title: video.title),
        question: question,
        selectedTrackIds: const {},
        requestTurnId: user.id,
      );
    } catch (exception) {
      error = exception.toString().replaceFirst('Bad state: ', '');
      _notify();
      return;
    }
    final run = _AiChatRun();
    _runs[current.id] = run;
    final answer = AiChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '',
      status: 'streaming',
      responseInfo: {
        'backend': settings.backend.name,
        if (settings.backend == AiBackend.api)
          'api_protocol': settings.apiProtocol.name,
        if (settings.backend == AiBackend.api)
          'provider_host': Uri.tryParse(settings.baseUrl)?.host.toLowerCase(),
        'supports_thinking': settings.selectedModelInfo?.supportsThinking,
        ...aiCachePrefixTrace(current.lastRequest?.messages, request.messages),
        'model': settings.model,
        'model_window': settings.selectedModelInfo?.contextWindow,
        'context_budget': request.contextLimit,
        'configured_context_budget': settings.contextTokens,
        'fast_summary':
            settings.fastSummaries &&
            AiTranscriptPreparation.isSummaryTask(question),
        'estimated_input': request.estimatedTokens,
        'reserved_output': request.outputReserve > 0
            ? request.outputReserve
            : settings.maxOutputTokens,
        'configured_output_limit': settings.maxOutputTokens,
        'reused_request_prefix': request.reusedRequestPrefix,
        'session_reset_reason': request.sessionResetReason,
        'context_mode': !hasTranscript
            ? AiChatMediaCopy.of(video).metadataMode
            : request.contextComplete
            ? '完整原文'
            : '相关原文检索',
      },
    );
    var updated = current.copyWith(
      messages: [...current.messages, user, answer],
      lastRequest: request,
      title: current.messages.isEmpty && !current.titleEdited
          ? _fallbackTitle(question)
          : null,
      // Direct sends (retry/edit/suggestions) must preserve unrelated drafts.
      draftText: submittedDraft != null && current.draftText == submittedDraft
          ? ''
          : null,
    );
    _replace(updated);
    error = null;
    draft = null;
    final cancellation = run.cancellation;
    _notify();
    // The message is now in the conversation; do not wait for the response.
    onAccepted?.call();
    await _persist(updated);
    final content = StringBuffer(), reasoning = StringBuffer();
    var lastSave = DateTime.now();
    var status = 'complete';
    String? failure;
    Map<String, dynamic>? usage;
    AiTurnPlan? turnPlan;
    var responseInfo = Map<String, dynamic>.from(answer.responseInfo!);
    String? finishReason;
    String? transcriptDigest;
    var autoAttempted = false;
    Future<AiRequestPreview> compose({bool auto = true}) async {
      final record = _currentRecord(current);
      AiRequestPreview build({bool bare = false}) => _composer.build(
        settings: settings,
        video:
            sourceVideo ??
            AiVideoContext(videoId: current.videoId, title: video.title),
        question: question,
        selectedTrackIds: sourceTrackIds,
        history: bare ? const [] : current.messages,
        checkpoint: bare ? null : record.contextCheckpoint,
        previousRequest: bare ? null : current.lastRequest,
        requestTurnId: user.id,
        turnPlan: turnPlan,
        transcriptDigest: transcriptDigest,
      );
      AiRequestPreview candidate;
      Object? compositionError;
      try {
        candidate = build();
      } on StateError catch (e) {
        compositionError = e;
        candidate = build(bare: true);
      }
      if (auto && settings.autoCompact && !autoAttempted) {
        final result = await _compactRecord(
          record,
          settings,
          candidate,
          run,
          force: compositionError != null || candidate.omittedMessages > 0,
        );
        if (result != null) {
          autoAttempted = true;
          responseInfo['compaction'] = result.info;
          if (result.checkpoint != null) {
            final latest = _currentRecord(current);
            return _composer.build(
              settings: settings,
              video:
                  sourceVideo ??
                  AiVideoContext(videoId: current.videoId, title: video.title),
              question: question,
              selectedTrackIds: sourceTrackIds,
              history: current.messages,
              checkpoint: latest.contextCheckpoint,
              requestTurnId: user.id,
              turnPlan: turnPlan,
              transcriptDigest: transcriptDigest,
            );
          }
        }
      }
      if (compositionError != null) throw compositionError;
      return candidate;
    }

    try {
      if (settings.backend == AiBackend.api) {
        run.preparationStatus = '正在理解本轮问题…';
        _notify();
        final planning = await AiTurnPlanner(transport: _transport).plan(
          settings: settings,
          question: question,
          title: sourceVideo?.title ?? video.title,
          hasTranscript: hasTranscript,
          history: current.messages,
          checkpoint: _currentRecord(current).contextCheckpoint,
          cancellation: cancellation,
        );
        turnPlan = planning.plan;
        if (planning.usage != null) {
          responseInfo['planning_usage'] = planning.usage;
        }
        if (planning.warning != null) {
          responseInfo['planning_warning'] = planning.warning;
        }
        request = await compose();
        responseInfo.addAll({
          'turn_plan': turnPlan?.toJson(),
          'estimated_input': request.estimatedTokens,
          'reserved_output': request.outputReserve,
          'reused_request_prefix': request.reusedRequestPrefix,
          'session_reset_reason': request.sessionResetReason,
          'context_budget': request.contextLimit,
          'context_mode': turnPlan?.source == 'none'
              ? '对话'
              : !hasTranscript
              ? AiChatMediaCopy.of(video).metadataMode
              : request.contextComplete
              ? '完整原文'
              : '相关原文检索',
          ...aiCachePrefixTrace(
            current.lastRequest?.messages,
            request.messages,
          ),
        });
        updated = _currentRecord(updated).copyWith(lastRequest: request);
        _replace(updated);
      }
      if (settings.backend != AiBackend.api) {
        request = await compose();
        updated = _currentRecord(updated).copyWith(lastRequest: request);
        _replace(updated);
      }
      if (sourceVideo != null &&
          hasTranscript &&
          settings.contextMode != AiContextMode.economical &&
          settings.contextMode != AiContextMode.full &&
          (!request.contextComplete ||
              settings.contextMode == AiContextMode.segmented) &&
          (turnPlan?.needsVideoBackground ??
              AiTranscriptPreparation.needsWholeVideo(question))) {
        responseInfo['context_mode'] = '全文分段处理中';
        final detailReserve = AiPromptComposer.detailBudget(
          request.contextBudget,
          request.contextPrefix,
          turnPlan,
        );
        final prepared = await _transcript.prepare(
          video: sourceVideo,
          selectedTrackIds: sourceTrackIds,
          settings: settings,
          question: turnPlan?.query.isNotEmpty == true
              ? turnPlan!.query
              : question,
          targetTokens:
              request.contextBudget -
              AiTokenEstimate.text(request.contextPrefix) -
              detailReserve -
              (detailReserve > 0 ? 240 : 0) -
              80,
          cancellation: cancellation,
          onUsage: (value) {
            responseInfo['preparation_usage'] = value;
          },
          exhaustiveTask: turnPlan == null
              ? null
              : turnPlan.task == 'exhaustive',
          onRecovery: (status) {
            run.preparationStatus = status;
            _notify();
          },
          onProgress: (done, total, reused) {
            run.preparationStatus = done == total
                ? '正在汇总全文记录…'
                : '正在处理全文 $done/$total 段${reused > 0 ? ' · 已复用 $reused 段' : ''}';
            responseInfo.addAll({
              'processed_segments': done,
              'total_segments': total,
              'reused_segments': reused,
            });
            _notify();
          },
        );
        if (cancellation.isCancelled || _disposed) {
          throw const AiChatException('全文处理已停止。');
        }
        transcriptDigest = prepared.text;
        request = await compose();
        responseInfo.addAll({
          'context_mode':
              (turnPlan?.task == 'exhaustive' ||
                  (turnPlan == null &&
                      AiTranscriptPreparation.exhaustive(question)))
              ? '全文逐段核查'
              : turnPlan?.usesPlayback == true || turnPlan?.source == 'time'
              ? '全文背景与当前原文'
              : '全文分段摘要',
          'estimated_input': request.estimatedTokens,
          'reused_request_prefix': request.reusedRequestPrefix,
          'session_reset_reason': request.sessionResetReason,
          'processed_segments': prepared.segments,
          'total_segments': prepared.segments,
          'reused_segments': prepared.reused,
          'preparation_usage': prepared.usage,
        });
        responseInfo.addAll(
          aiCachePrefixTrace(current.lastRequest?.messages, request.messages),
        );
        updated = _currentRecord(updated).copyWith(lastRequest: request);
        _replace(updated);
      }
      run.preparationStatus = null;
      _notify();
      for (var recovery = 0; recovery < 2; recovery++) {
        try {
          await for (final delta in AiAnswerContinuation(_transport).stream(
            settings: settings.forRequest(
              summaryTask:
                  turnPlan?.task == 'summary' ||
                  (turnPlan == null &&
                      AiTranscriptPreparation.isSummaryTask(question)),
              contextLimit: request.contextLimit,
              estimatedInputTokens: request.estimatedTokens,
              question: question,
            ),
            messages: request.messages,
            cancellation: cancellation,
            onUsage: (value) {
              responseInfo['generation_usage'] = value;
            },
          )) {
            if (_disposed ||
                cancellation.isCancelled ||
                _runs[current.id] != run) {
              break;
            }
            if (delta.contentSnapshot != null) content.clear();
            if (delta.reasoningSnapshot != null) reasoning.clear();
            content.write(delta.contentSnapshot ?? delta.content);
            reasoning.write(delta.reasoningSnapshot ?? delta.reasoning);
            run.generationStatus = delta.stage ?? run.generationStatus;
            run.reconnecting = delta.reconnecting ?? run.reconnecting;
            usage =
                delta.usageSnapshot ?? AiTokenUsage.merge(usage, delta.usage);
            finishReason = delta.finishReason ?? finishReason;
            updated = _updateAnswer(
              updated,
              answer.id,
              content.toString(),
              reasoning.toString(),
              'streaming',
            );
            _replace(updated);
            _scheduleNotify();
            if (DateTime.now().difference(lastSave) >=
                const Duration(seconds: 1)) {
              lastSave = DateTime.now();
              unawaited(_persist(updated));
            }
          }
          break;
        } on AiChatException catch (e) {
          if (recovery != 0 ||
              !settings.autoCompact ||
              !e.contextOverflow ||
              content.isNotEmpty ||
              cancellation.isCancelled ||
              _disposed) {
            rethrow;
          }
          responseInfo['overflow_attempt_usage'] =
              responseInfo['generation_usage'];
          final result = await _compactRecord(
            _currentRecord(current),
            settings,
            request,
            run,
            force: true,
            overflow: true,
          );
          if (result?.checkpoint == null) rethrow;
          responseInfo['overflow_recovery'] = result!.info;
          reasoning.clear();
          usage = null;
          request = await compose(auto: false);
          responseInfo['estimated_input'] = request.estimatedTokens;
          responseInfo['overflow_retries'] = 1;
          updated = _currentRecord(updated).copyWith(lastRequest: request);
          _replace(updated);
          run.preparationStatus = null;
        }
      }
      if (cancellation.isCancelled || _disposed) {
        status = 'cancelled';
      } else if (const {
        'aborted',
        'insufficient_system_resource',
        'content_filter',
        'tool_calls',
      }.contains(finishReason)) {
        status = 'error';
        failure = switch (finishReason) {
          'content_filter' => '服务的内容过滤中止了回答，已保留收到的内容。',
          'tool_calls' => '模型请求了当前聊天不支持的工具调用，请选择普通对话模型后重试。',
          _ => '服务中断了回答，已保留收到的内容，可重新生成。',
        };
      } else if (content.isEmpty) {
        status = 'error';
        failure = finishReason == 'length' && reasoning.isNotEmpty
            ? '生成在思考阶段达到单次输出上限，尚未产生正文。可以降低思考等级或提高单次生成上限后重试。'
            : '服务返回了空回答，请检查模型设置后重试。';
      }
    } catch (exception) {
      if (cancellation.isCancelled) {
        status = 'cancelled';
      } else {
        status = 'error';
        failure = exception.toString();
      }
    } finally {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      run.preparationStatus = null;
      run.generationStatus = null;
      if (usage?['model_context_window'] is num) {
        responseInfo['model_window'] = (usage!['model_context_window'] as num)
            .toInt();
      }
      responseInfo['estimated_output'] = AiTokenEstimate.text(
        '${content.toString()}${reasoning.toString()}',
      );
      updated = _updateAnswer(
        updated,
        answer.id,
        content.toString(),
        reasoning.toString(),
        status,
        failure,
      );
      updated = updated.copyWith(
        messages: updated.messages
            .map(
              (message) => message.id == answer.id
                  ? message.copyWith(
                      usage: usage,
                      finishReason: finishReason,
                      responseInfo: responseInfo,
                    )
                  : message,
            )
            .toList(),
      );
      _replace(updated);
      if (!_disposed && _activeId == current.id) error = failure;
      await _persist(updated);
      if (_runs[current.id] == run) _runs.remove(current.id);
      run.done.complete();
      _notify();
      if (!_disposed &&
          status == 'complete' &&
          current.messages.isEmpty &&
          !updated.titleEdited) {
        unawaited(
          _summarizeTitle(
            updated.id,
            question,
            content.toString(),
            requestSettings: settings,
          ),
        );
      }
    }
  }

  AiConversation _updateAnswer(
    AiConversation conversation,
    String id,
    String content,
    String reasoning,
    String status, [
    String? error,
  ]) {
    final latest = _currentRecord(conversation);
    return latest.copyWith(
      messages: latest.messages
          .map(
            (message) => message.id == id
                ? message.copyWith(
                    content: content,
                    reasoning: reasoning,
                    status: status,
                    error: error,
                  )
                : message,
          )
          .toList(),
    );
  }

  void _scheduleNotify() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 70), () {
      _notifyTimer = null;
      _notify();
    });
  }

  void stop() {
    _activeRun?.cancellation.cancel();
  }

  Future<void> _stopConversation(String id) async {
    final run = _runs[id];
    if (run == null) return;
    run.cancellation.cancel();
    await run.done.future;
  }

  AiConversation _currentRecord(AiConversation fallback) => _conversations
      .firstWhere((item) => item.id == fallback.id, orElse: () => fallback);

  Future<void> forkAt(String messageId) async {
    if (_mutating || _disposed) return;
    final current = active;
    if (current == null) return;
    final index = current.messages.indexWhere(
      (message) => message.id == messageId,
    );
    if (index < 0) return;
    await _mutate(() async {
      final message = current.messages[index];
      await _fork(
        current,
        message.role == 'user' ? index : index + 1,
        messageId,
      );
      if (message.role == 'user') draft = message.content;
    });
  }

  Future<void> _fork(AiConversation source, int end, String fromId) async {
    unawaited(flushDrafts());
    final branch = AiConversation(
      id: _uuid.v4(),
      videoId: video.id,
      title: '${source.title} · 分支',
      messages: source.messages
          .take(end)
          .map(
            (message) => message.status == 'streaming'
                ? message.copyWith(status: 'cancelled')
                : message,
          )
          .toList(),
      contextCheckpoint:
          source.contextCheckpoint?.matches(
                source.messages.take(end).toList(),
              ) ==
              true
          ? source.contextCheckpoint
          : null,
      parentConversationId: source.id,
      parentMessageId: fromId,
      selectedTrackIds: source.selectedTrackIds,
      selectionIsAutomatic: source.selectionIsAutomatic,
      titleEdited: true,
    );
    _conversations.insert(0, branch);
    _activeId = branch.id;
    draft = null;
    error = null;
    _notify();
    await _persist(branch);
  }

  /// Rewind the current record rather than manufacturing another conversation.
  /// Discarded turns must not remain in the cached provider request prefix.
  Future<void> _rewind(
    AiConversation source,
    int end, {
    String? restoredDraft,
  }) async {
    if (end == 0) _titleCancellations.remove(source.id)?.cancel();
    final updated = source.copyWith(
      messages: source.messages.take(end).toList(),
      clearLastRequest: true,
      clearCheckpoint:
          source.contextCheckpoint?.matches(
            source.messages.take(end).toList(),
          ) !=
          true,
      draftText: restoredDraft,
    );
    _replace(updated);
    draft = restoredDraft;
    error = null;
    _notify();
    await _persist(updated);
  }

  Future<void> withdraw(String userMessageId) async {
    if (_mutating || _disposed) return;
    final source = active;
    if (source == null) return;
    final index = source.messages.indexWhere(
      (message) => message.id == userMessageId && message.role == 'user',
    );
    if (index < 0) return;
    final text = source.messages[index].content;
    await _mutate(() async {
      await _stopConversation(source.id);
      await _rewind(_currentRecord(source), index, restoredDraft: text);
    });
  }

  Future<void> editMessage(String id, String text) async {
    if (text.trim().isEmpty || _mutating || _disposed) return;
    final source = active;
    if (source == null) return;
    final index = source.messages.indexWhere(
      (message) => message.id == id && message.role == 'user',
    );
    if (index < 0) return;
    await _mutate(() async {
      await _stopConversation(source.id);
      await _rewind(_currentRecord(source), index);
    });
    await _send(text);
  }

  Future<void> regenerate(String assistantId) async {
    if (_mutating || _disposed) return;
    final source = active;
    if (source == null) return;
    final index = source.messages.indexWhere(
      (message) => message.id == assistantId && message.role == 'assistant',
    );
    if (index < 1 || source.messages[index - 1].role != 'user') return;
    final question = source.messages[index - 1].content;
    await _mutate(() async {
      await _stopConversation(source.id);
      await _rewind(_currentRecord(source), index - 1);
    });
    await _send(question);
  }

  Future<void> _summarizeTitle(
    String id,
    String question,
    String answer, {
    AiChatSettings? requestSettings,
  }) async {
    final settings = requestSettings ?? this.settings;
    // This small optional request never includes the video transcript or key in
    // content. A deterministic title is already saved if it fails or is stopped.
    if (settings.backend != AiBackend.api ||
        settings.titlePrompt.trim().isEmpty) {
      return;
    }
    _titleCancellations.remove(id)?.cancel();
    final cancellation = AiChatCancellation();
    _titleCancellations[id] = cancellation;
    final firstAnswerId = _conversations
        .where((conversation) => conversation.id == id)
        .firstOrNull
        ?.messages
        .where((message) => message.role == 'assistant')
        .firstOrNull
        ?.id;
    Map<String, dynamic>? titleUsage;
    try {
      final result = StringBuffer();
      final info = settings.selectedModelInfo;
      final mayRequireThinking =
          info?.supportsThinking != false &&
          info?.canDisableThinking != true &&
          (settings.apiProtocol != AiApiProtocol.openAiCompatible ||
              info?.supportsThinking == true);
      final titleLimit = mayRequireThinking ? 4096 : 80;
      final maximum = info?.maxOutputTokens;
      await for (final delta in _transport.stream(
        settings: settings.copyWith(
          maxOutputTokens: maximum == null
              ? titleLimit
              : titleLimit.clamp(1, maximum).toInt(),
          thinkingEnabled: false,
          thinkingBudget: 0,
          reasoningEffort: info?.lowestReasoningEffort ?? '',
        ),
        messages: [
          {'role': 'system', 'content': settings.titlePrompt},
          {
            'role': 'user',
            'content':
                '问题：${AiPromptComposer.truncateBytes(question, 900)}\n回答：${AiPromptComposer.truncateBytes(answer, 1200)}',
          },
        ],
        cancellation: cancellation,
      )) {
        if (_disposed || cancellation.isCancelled) return;
        if (delta.contentSnapshot != null) result.clear();
        result.write(delta.contentSnapshot ?? delta.content);
        titleUsage = AiTokenUsage.merge(titleUsage, delta.usage);
      }
      final index = _conversations.indexWhere(
        (conversation) => conversation.id == id,
      );
      if (index < 0 ||
          cancellation.isCancelled ||
          _conversations[index].messages
                  .where((message) => message.role == 'assistant')
                  .firstOrNull
                  ?.id !=
              firstAnswerId ||
          _conversations[index].titleEdited ||
          result.isEmpty ||
          _disposed) {
        return;
      }
      final title = _fallbackTitle(
        result.toString().replaceAll(RegExp(r'[\n\r"“”]'), ' '),
      );
      final updated = _conversations[index].copyWith(title: title);
      _replace(updated);
      await _persist(updated);
      _notify();
    } catch (_) {
      /* Title generation is optional and must not replace chat errors. */
    } finally {
      if (_titleCancellations[id] == cancellation) {
        _titleCancellations.remove(id);
      }
      if (!_disposed) {
        final index = _conversations.indexWhere(
          (conversation) => conversation.id == id,
        );
        if (index >= 0) {
          final conversation = _conversations[index];
          final firstAnswer = conversation.messages
              .where((message) => message.role == 'assistant')
              .firstOrNull;
          if (firstAnswer != null && firstAnswer.id == firstAnswerId) {
            final updated = conversation.copyWith(
              messages: conversation.messages
                  .map(
                    (message) => message.id == firstAnswer.id
                        ? message.copyWith(
                            responseInfo: {
                              ...?message.responseInfo,
                              'title_requested': true,
                              'title_usage': titleUsage,
                            },
                          )
                        : message,
                  )
                  .toList(),
            );
            _replace(updated);
            await _persist(updated);
            _notify();
          }
        }
      }
    }
  }

  String _fallbackTitle(String text) {
    final value = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = value.runes.take(24).toList();
    return String.fromCharCodes(runes) + (value.runes.length > 24 ? '…' : '');
  }

  void _replace(AiConversation conversation) {
    final index = _conversations.indexWhere(
      (item) => item.id == conversation.id,
    );
    if (index >= 0) _conversations[index] = conversation;
    _conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> _persist(AiConversation conversation) async {
    if (_deletingIds.contains(conversation.id)) return;
    try {
      await _store.save(_currentRecord(conversation));
    } catch (_) {
      if (!_disposed) {
        _dirtyDraftIds.add(conversation.id);
        error = '对话尚未成功保存到磁盘，请导出备份后重试。';
        _notify();
      }
    }
  }

  String exportMarkdown({String? conversationId}) {
    AiConversation? conversation = active;
    if (conversationId != null) {
      conversation = null;
      for (final candidate in _conversations) {
        if (candidate.id == conversationId) conversation = candidate;
      }
    }
    if (conversation == null) return '';
    final output = StringBuffer(
      '# ${conversation.title}\n\n${AiChatMediaCopy.of(video).exportHeading}${video.title}\n\n',
    );
    if (conversation.parentConversationId != null) {
      output.writeln('分支来源：${conversation.parentConversationId}\n');
    }
    for (final message in conversation.messages) {
      output.writeln(
        '## ${message.role == 'user' ? '你' : 'AI'}\n\n${message.content}\n',
      );
      if (message.reasoning.isNotEmpty) {
        output.writeln(
          '<details><summary>思考过程</summary>\n\n${message.reasoning}\n\n</details>\n',
        );
      }
      if (message.status != 'complete') {
        output.writeln('状态：${message.status}\n');
      }
      if (message.error != null) output.writeln('错误：${message.error}\n');
    }
    return output.toString();
  }

  String exportRequestJson() =>
      const JsonEncoder.withIndent('  ').convert(lastRequest?.messages ?? []);

  @override
  void dispose() {
    AiApiConnectionSync.changes.removeListener(_sharedConnectionChanged);
    unawaited(flushDrafts());
    _disposed = true;
    _contextRevision++;
    for (final run in _runs.values) {
      run.cancellation.cancel();
    }
    for (final cancellation in _titleCancellations.values) {
      cancellation.cancel();
    }
    _notifyTimer?.cancel();
    draftRevision.dispose();
    unawaited(_transport.dispose());
    super.dispose();
  }
}
