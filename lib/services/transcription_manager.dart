import 'community_media_input.dart';
import 'app_wakelock_coordinator.dart';
import 'app_storage_service.dart';
import '../features/model_center/model_catalog.dart';
import '../features/model_center/asr_enhancement_options.dart';
import '../features/model_center/model_center_service.dart';
import '../features/model_center/model_adapters.dart';
import 'transcription_hotword_store.dart';
import '../features/model_center/model_transcription.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:universal_platform/universal_platform.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../utils/app_data_paths.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/subtitle_output_path_strategy.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/local_asr_progress.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/transcription_reliability.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import '../features/podcasts/podcast_playback_hooks.dart';
import '../features/model_center/local_subtitle_translator.dart';
import '../features/model_center/translation_memory.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';
import 'package:video_player_app/services/task_subtitle_storage_service.dart';
import 'subtitle_word_timing_store.dart';
import 'subtitle_output_preparer.dart';
import 'gongyi_audio_preparation.dart';
import 'transcription_audio_prefetcher.dart';
import '../models/subtitle_stream.dart';
import '../models/subtitle_punctuation.dart';
import '../models/transcription_task_configuration.dart';
import '../utils/media_duration_label.dart';
import '../utils/serial_task_queue.dart';
import 'streaming_subtitle_store.dart';
import 'subtitle_stream_source.dart';
import 'local_transcription_stream.dart';
import 'cloud_translation_batches.dart';
import '../utils/subtitle_parser.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player_app/utils/linux_audio_device.dart';

Future<List<SubtitleItem>> _readCompletedTranscript(String path) =>
    Isolate.run(() async {
      final text = SubtitleParser.decodeBytes(
        await File(path).readAsBytes(),
        sourcePath: path,
      );
      return SubtitleWordTimingStore.attach(
        path,
        text,
        SubtitleParser.parse(text),
      );
    });

// Task inputs must survive a queue change without relying on a library row.
// Do not persist decoder URLs or unrelated mutable playback/subtitle state.
Map<String, dynamic> _transcriptionSourceJson(VideoItem item) => {
  'id': item.id,
  'path': item.path,
  'title': item.title,
  'durationMs': item.durationMs,
  'lastUpdated': item.lastUpdated,
  'type': item.type.name,
  'sourceFingerprint': item.sourceFingerprint,
  'sourceRef': item.sourceRef?.toJson(),
};

VideoItem? _transcriptionSourceSnapshot(
  VideoItem? item,
  String path,
  String? id,
) {
  if (item == null || item.path != path || (id != null && item.id != id)) {
    return null;
  }
  return VideoItem.fromJson(_transcriptionSourceJson(item));
}

bool _hasTranscriptionSource(VideoItem? item) {
  if (item == null) return false;
  if (item.path.startsWith('podcast:')) return item.sourceRef?.podcast != null;
  if (isCloudDriveMedia(source: item.sourceRef, path: item.path)) {
    return item.sourceRef?.cloudDrive != null;
  }
  return true;
}

/// A duplicate request must not be reported as a newly added task.
enum TranscriptionEnqueueResult { added, alreadyQueued }

class TranscriptionManager extends ChangeNotifier
    implements SubtitleStreamSource {
  final _streamEvents = StreamController<SubtitleStreamUpdate>.broadcast(
    sync: true,
  );
  @override
  Stream<SubtitleStreamUpdate> get subtitleUpdates => _streamEvents.stream;
  final _streamStarts = StreamController<SubtitleGenerationStart>.broadcast(
    sync: true,
  );
  final Future<Map<String, dynamic>?> Function(String)? _mediaProbe;
  @override
  Stream<SubtitleGenerationStart> get subtitleGenerationStarts =>
      _streamStarts.stream;
  @override
  final ValueNotifier<int> subtitleFilesRevision = ValueNotifier(0);
  final Map<String, StreamingSubtitleStore> _streamStores = {};
  final Map<String, SubtitleStreamUpdate> _streamStates = {};
  @override
  Iterable<SubtitleStreamUpdate> get subtitleStreams => _streamStates.values;
  @override
  bool Function(String mediaKey)? shouldSelectGeneratedSubtitles;

  /// Explicit changes belong to the generation, including across stop/resume
  /// and process restarts. Generated files keep growing without reclaiming UI.
  @override
  void preserveSubtitleSelection(String path, {String? videoId}) {
    final job = _jobForKey(_mediaKey(path, videoId: videoId));
    if (job == null || _completedJobs.containsKey(job.mediaKey)) return;
    job.subtitleSelectionOverridden = true;
    _scheduleSave();
  }

  @override
  bool subtitleSelectionOverridden(String mediaKey) =>
      _jobForKey(mediaKey)?.subtitleSelectionOverridden ?? false;
  Completer<void>? _currentFinished;

  @override
  SubtitleStreamUpdate? streamForVideo(String path, {String? videoId}) =>
      _streamStates[_mediaKey(path, videoId: videoId)];
  @override
  bool hasSubtitleStreamForVideo(String path, {String? videoId}) {
    final key = _mediaKey(path, videoId: videoId);
    return streamForVideo(path, videoId: videoId) != null ||
        _jobForKey(key)?.streamJournal != null;
  }

  @override
  SubtitleStreamUpdate? streamForPath(String path) {
    for (final value in _streamStates.values) {
      if (value.primaryPath == path || value.secondaryPath == path) {
        return value;
      }
    }
    return null;
  }

  @override
  Future<void> stopStreamForPath(String path) async {
    final stream = streamForPath(path);
    if (stream == null) return;
    final done = _currentJob?.mediaKey == stream.mediaKey
        ? _currentFinished?.future
        : null;
    pauseTask(stream.mediaKey);
    await done;
  }

  @override
  void resumeStreamForPath(String path) {
    final stream = streamForPath(path);
    if (stream == null ||
        stream.complete ||
        isVideoCancelling(stream.videoPath, videoId: stream.videoId) ||
        isVideoStopping(stream.videoPath, videoId: stream.videoId)) {
      return;
    }
    if (_jobForKey(stream.mediaKey) == null) {
      final store = _streamStores[stream.mediaKey]!;
      final job = _TranscriptionJob.fromJson(
        Map<String, dynamic>.from(store.header['job'] as Map),
      );
      job.streamJournal = store.journal.path;
      _insertQueuedByTaskOrder(job);
    }
    if (_failedJobs.containsKey(stream.mediaKey)) {
      retryTask(stream.mediaKey);
    } else {
      startTask(stream.mediaKey);
    }
  }

  @override
  void forgetStreamForPath(String path) {
    final stream = streamForPath(path);
    if (stream == null) return;
    _streamStates.remove(stream.mediaKey);
    _streamStores.remove(stream.mediaKey);
    _removeTaskRecords(stream.mediaKey);
    _scheduleSave();
    if (!_disposed) subtitleFilesRevision.value++;
  }

  static const String _managedTempAudioDirName = 'ai_transcription_temp_audio';
  static const String _managedTempAudioPrefix = 'temp_audio_';
  static const String _persistenceFileName = 'transcription_queue_cache.json';
  final GongyiAsrService _asrService;
  final SubtitleTranslationService _translationService;
  final SettingsService _settings;
  final ModelCenterService _modelCenter;
  final ModelTranscriptionRunner _modelRunner;
  final SubtitleOutputPreparer _outputPreparer;
  final List<_TranscriptionJob> _queue = <_TranscriptionJob>[];
  final Set<String> _queuedMediaKeys = <String>{};
  final Map<String, _TranscriptionJob> _cancellingJobs = {};
  final Map<String, String> _resultSrtByMediaKey = <String, String>{};
  bool _translatingCurrent = false;
  final Set<String> _consumedResultMediaKeys = <String>{};
  final Map<String, _TranscriptionJob> _failedJobs =
      <String, _TranscriptionJob>{};
  final Map<String, _TranscriptionJob> _completedJobs =
      <String, _TranscriptionJob>{};
  final Set<String> _startedMediaKeys = <String>{};
  final List<String> _taskOrder = <String>[];
  final Map<String, String> _statusMessagesByMediaKey = <String, String>{};

  // State
  TranscriptionStatus _status = TranscriptionStatus.idle;
  String _statusMessage = "";
  double _progress = 0.0;
  double? _translationProgress;
  LocalAsrProgress? _localAsrProgress;
  LocalAsrProgress? get localAsrProgress => _localAsrProgress;
  Duration _audioDuration = Duration.zero, _committedAudio = Duration.zero;
  TranscriptionAudioProgress? get localAudioProgress =>
      _currentJob?.streamsRecognition == true
      ? TranscriptionAudioProgress(
          completed: _committedAudio,
          total: _localAsrProgress?.total ?? _audioDuration,
        )
      : null;
  TranscriptionProgressPlan get _progressPlan => TranscriptionProgressPlan(
    translate: _currentJob?.translateEnabled ?? false,
  );
  String? _currentVideoPath;
  String? _lastGeneratedSrtPath;
  bool _isQueueProcessing = false;

  String? _currentVideoId;
  LibraryService? _libraryService;
  bool _autoCache = false;
  bool _initialized = false;
  bool _disposed = false;
  bool _preparingMedia = false;
  _TranscriptionJob? _currentJob;
  _JobCancellation? _currentCancellation;
  bool _currentTaskRemoved = false;
  bool _currentPauseRequested = false;
  int _consecutiveRiskControlFailures = 0;
  DateTime? _nextRemoteRequestAt;
  bool _hitRiskControlThisJob = false;
  TranscriptionCheckpointBook? _checkpointBook;

  /// 单次任务内部已经按风控退避重试过。只要整段仍然被拦住，就先停下后面的
  /// 任务，避免继续把访问频率打高。
  static const int _riskControlStopThreshold = 1;
  static const Duration _normalInterTaskDelay = Duration(seconds: 8);
  static const Duration _riskControlCooldown =
      TranscriptionRetryPolicy.batchCooldown;
  static const String _checkpointFileName =
      'transcription_slice_checkpoints.json';

  // ── 持久化 ──
  Timer? _saveDebounceTimer;
  String? _persistenceDirPath;
  static const Duration _saveDebounce = Duration(milliseconds: 500);
  bool _savePending = false;
  final _stateWrites = SerialTaskQueue();

  TranscriptionManager({
    SettingsService? settings,
    GongyiAsrService? asrService,
    SubtitleTranslationService? translationService,
    ModelCenterService? modelCenter,
    TranscriptionHotwordStore? hotwordStore,
    ModelTranscriptionRunner? modelRunner,
    @visibleForTesting SubtitleOutputPreparer? outputPreparer,
    @visibleForTesting
    Future<Map<String, dynamic>?> Function(String)? mediaProbe,
  }) : _settings = settings ?? SettingsService(),
       _mediaProbe = mediaProbe,
       _modelCenter = modelCenter ?? ModelCenterService.instance,
       _hotwordStore = hotwordStore ?? TranscriptionHotwordStore(),
       _ownsHotwordStore = hotwordStore == null,
       _outputPreparer = outputPreparer ?? const SubtitleOutputPreparer(),
       _modelRunner =
           modelRunner ?? ModelTranscriptionRunner(center: modelCenter),
       _translationService =
           translationService ?? SubtitleTranslationService.instance,
       _asrService = asrService ?? GongyiAsrService() {
    addListener(_syncCompletedRemovals);
    _settings.addListener(_syncCompletedRemovals);
    addListener(_syncProcessingKeepAwake);
    _settings.addListener(_syncProcessingKeepAwake);
  }

  bool _processingKeepAwakeActive = false;

  void _syncProcessingKeepAwake() {
    if (_disposed) return;
    final active = _settings.batchSubtitleKeepScreenAwake && isProcessing;
    if (_processingKeepAwakeActive == active) return;
    _processingKeepAwakeActive = active;
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.transcriptionReason,
      active,
      detail: () => '字幕转录 · ${(progress.clamp(0, 1) * 100).floor()}%',
    );
  }

  final Map<String, Timer> _completedRemovalTimers = {};

  Map<String, bool> get pendingCompletedRemovals => {
    for (final key in _completedRemovalTimers.keys) key: true,
  };

  void _syncCompletedRemovals() {
    if (_disposed) return;
    for (final key in _completedRemovalTimers.keys.toList()) {
      if (!_settings.batchSubtitleAutoDelete ||
          !_completedJobs.containsKey(key)) {
        _completedRemovalTimers.remove(key)?.cancel();
      }
    }
    if (!_settings.batchSubtitleAutoDelete) return;
    for (final entry in _completedJobs.entries) {
      final key = entry.key;
      final job = entry.value;
      _completedRemovalTimers.putIfAbsent(key, () {
        return Timer(const Duration(seconds: 2), () {
          _completedRemovalTimers.remove(key);
          if (_disposed ||
              !_settings.batchSubtitleAutoDelete ||
              !identical(_completedJobs[key], job)) {
            return;
          }
          // Remove the queue row, preserving the generated subtitle for playback.
          _completedJobs.remove(key);
          _taskOrder.remove(key);
          _statusMessagesByMediaKey.remove(key);
          _scheduleSave();
          notifyListeners();
        });
      });
    }
  }

  // Getters
  final TranscriptionHotwordStore _hotwordStore;
  final bool _ownsHotwordStore;
  ModelCenterService get modelCenter => _modelCenter;
  TranscriptionHotwordStore get hotwordStore => _hotwordStore;
  String mediaKeyForVideo(String path, {String? videoId}) =>
      _mediaKey(path, videoId: videoId);

  ModelJobSpec currentTranscriptionConfigurationForVideo(
    String path, {
    String? videoId,
  }) => _scopeHotwords(
    _modelCenter.transcriptionConfiguration,
    _mediaKey(path, videoId: videoId),
  );

  ModelJobSpec _scopeHotwords(ModelJobSpec spec, String key) {
    if (!_hasHotwordModel(spec) || spec.asrEnhancements == null) {
      return spec;
    }
    final words = _hotwordStore.wordsFor(key);
    if (spec.asrEnhancements!.hotwords == words) return spec;
    return ModelJobSpec.fromJson({
      ...spec.toJson(),
      'asrEnhancements': spec.asrEnhancements!
          .copyWith(hotwords: words)
          .toJson(),
    });
  }

  bool _hasHotwordModel(ModelJobSpec spec) =>
      spec.profile.local &&
      localAsrAdapters[_modelCenter.artifact(spec.profile.model)?.engine]
              ?.supportsHotwords ==
          true;

  TranscriptionStatus get status => _status;
  String get statusMessage => _statusMessage;
  double get progress => _progress;
  double? get translationProgress => _translationProgress;
  String? get currentVideoPath => _currentVideoPath;
  String? get currentVideoId => _currentVideoId;
  String? get lastGeneratedSrtPath => _lastGeneratedSrtPath;
  bool get isResultConsumed {
    final mediaKey = _currentMediaKey;
    if (mediaKey == null) return true;
    return !_resultSrtByMediaKey.containsKey(mediaKey) ||
        _consumedResultMediaKeys.contains(mediaKey);
  }

  int get queuedCount => _queue.length;
  int get processingCount => isProcessing ? 1 : 0;
  int get pendingCount => queuedCount + processingCount;

  /// Scheduled work still counts while the previous worker is finishing.
  /// Failed/completed rows alone must leave Start-all available.
  bool get canPauseAll {
    return isProcessing ||
        _queue.any((job) => _startedMediaKeys.contains(job.mediaKey));
  }

  bool get isProcessing =>
      _status != TranscriptionStatus.idle &&
      _status != TranscriptionStatus.completed &&
      _status != TranscriptionStatus.error;

  void markResultConsumed() {
    final mediaKey = _currentMediaKey;
    if (mediaKey == null) return;
    if (_consumedResultMediaKeys.add(mediaKey)) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void markResultConsumedForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    if (_consumedResultMediaKeys.add(mediaKey)) {
      _scheduleSave();
      notifyListeners();
    }
  }

  /// Atomically claims the one-time notification for the latest generated
  /// subtitle of this video. A new transcription clears the claim again.
  bool consumeResultNotificationForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    if (!_resultSrtByMediaKey.containsKey(mediaKey) ||
        !_consumedResultMediaKeys.add(mediaKey)) {
      return false;
    }
    _scheduleSave();
    notifyListeners();
    return true;
  }

  bool hasUnconsumedResultForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    return _resultSrtByMediaKey.containsKey(mediaKey) &&
        !_consumedResultMediaKeys.contains(mediaKey);
  }

  String? getGeneratedSrtPathForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    return _resultSrtByMediaKey[mediaKey];
  }

  /// Translation written for this media, present only after that step succeeds.
  String? getGeneratedTranslationPathForVideo(
    String videoPath, {
    String? videoId,
  }) {
    return _jobForKey(
      _mediaKey(videoPath, videoId: videoId),
    )?.translatedSrtPath;
  }

  /// Status text stored for this media, including a translation failure note.
  String completionMessageForVideo(String videoPath, {String? videoId}) {
    return _statusMessagesByMediaKey[_mediaKey(videoPath, videoId: videoId)] ??
        '';
  }

  bool translateEnabledForVideo(String videoPath, {String? videoId}) {
    return _jobForKey(
          _mediaKey(videoPath, videoId: videoId),
        )?.translateEnabled ??
        false;
  }

  /// Settings edits rebuild the task explanation without changing its snapshot.
  late final Listenable _configurationChanges = Listenable.merge([
    _modelCenter,
    _hotwordStore,
  ]);
  Listenable get configurationChanges => _configurationChanges;

  TranscriptionTaskConfiguration? configurationForVideo(
    String videoPath, {
    String? videoId,
  }) {
    final job = _jobForKey(_mediaKey(videoPath, videoId: videoId));
    if (job == null) return null;
    return TranscriptionTaskConfiguration(
      transcription: job.modelSpec,
      punctuation: job.subtitlePunctuation,
      translation: TranscriptTranslateChoice(
        enabled: job.translateEnabled,
        direction: job.translateDirection,
        provider: subtitleTranslateProviderFromName(job.translateProviderName),
        aiOptions: job.translateAiOptions,
        apiProviderId: job.translateApiProviderId,
        apiEndpoint: job.translateEndpoint,
        sourceLanguage: job.translateSourceLanguage,
        targetLanguage: job.translateTargetLanguage,
        smartPolicy: job.translateSmartPolicy,
        localSpecification: job.translateLocalSpec,
      ),
    );
  }

  bool configurationChangedForVideo(
    String videoPath, {
    String? videoId,
    SubtitleTranslateSettings? translationSettings,
  }) {
    final saved = configurationForVideo(videoPath, videoId: videoId);
    if (saved == null) return false;
    if (_modelCenter.started &&
        saved.transcription != null &&
        (saved.transcription!.fingerprint !=
                currentTranscriptionConfigurationForVideo(
                  videoPath,
                  videoId: videoId,
                ).fingerprint ||
            saved.punctuation != _modelCenter.subtitlePunctuation)) {
      return true;
    }
    return saved.translation.enabled &&
        translationSettings != null &&
        saved.translation.configurationFingerprint !=
            TranscriptTranslateChoice.current(
              translationSettings,
            ).configurationFingerprint;
  }

  bool isVideoTranslating(String videoPath, {String? videoId}) {
    return isVideoRunning(videoPath, videoId: videoId) && _translatingCurrent;
  }

  _TranscriptionJob? _jobForKey(String mediaKey) {
    if (_currentJob?.mediaKey == mediaKey) return _currentJob;
    for (final job in _queue) {
      if (job.mediaKey == mediaKey) return job;
    }
    return _failedJobs[mediaKey] ??
        _completedJobs[mediaKey] ??
        _cancellingJobs[mediaKey];
  }

  bool isVideoQueued(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    return _queuedMediaKeys.contains(mediaKey);
  }

  bool isVideoRunning(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    return _currentMediaKey == mediaKey && isProcessing;
  }

  bool isVideoPaused(String videoPath, {String? videoId}) {
    final key = _mediaKey(videoPath, videoId: videoId);
    return _queuedMediaKeys.contains(key) && !_startedMediaKeys.contains(key);
  }

  /// An imported row has no generation to resume until its first start.
  /// Its first explicit action may still choose transcription with translation.
  bool isVideoAwaitingFirstStart(String videoPath, {String? videoId}) {
    final key = _mediaKey(videoPath, videoId: videoId);
    final job = _jobForKey(key);
    return _queuedMediaKeys.contains(key) &&
        !_startedMediaKeys.contains(key) &&
        job != null &&
        job.modelSpec == null &&
        !job.translateFrozen &&
        !job.streamConfigurationFrozen &&
        job.streamJournal == null;
  }

  bool isVideoFailed(String videoPath, {String? videoId}) =>
      _failedJobs.containsKey(_mediaKey(videoPath, videoId: videoId));

  bool retryVideo(
    String videoPath, {
    String? videoId,
    TranscriptTranslateChoice? translateChoice,
  }) => retryTask(
    _mediaKey(videoPath, videoId: videoId),
    translate: translateChoice,
  );

  bool isVideoStopping(String videoPath, {String? videoId}) =>
      isVideoRunning(videoPath, videoId: videoId) &&
      (_currentPauseRequested || _currentTaskRemoved);

  bool isVideoCancelling(String videoPath, {String? videoId}) =>
      _cancellingJobs.containsKey(_mediaKey(videoPath, videoId: videoId));

  /// Stop this generation and forget its resume data, keeping published files.
  /// Wait for the worker before detaching its stream or allowing a fresh run.
  Future<bool> cancelVideo(String videoPath, {String? videoId}) async {
    final key = _mediaKey(videoPath, videoId: videoId);
    final job = _jobForKey(key);
    if (job == null ||
        _completedJobs.containsKey(key) ||
        _cancellingJobs.containsKey(key)) {
      return false;
    }
    _cancellingJobs[key] = job;
    final checkpointKey = job.checkpointKey;
    final finished = _currentJob?.mediaKey == key
        ? _currentFinished?.future
        : null;
    try {
      _publishStreamPhase(key, SubtitleStreamPhase.stopping);
      if (!removeFromQueue(key)) return false;
      await finished;
      _removeTaskRecords(key);
      // A stopped stream can reconstruct its task via "continue generating".
      // Cancelled output becomes an ordinary saved subtitle instead.
      _streamStates.remove(key);
      _streamStores.remove(key);
      await _discardCheckpoint(checkpointKey);
      await _flushSave();
      return true;
    } finally {
      _cancellingJobs.remove(key);
      if (!_disposed) {
        subtitleFilesRevision.value++;
        notifyListeners();
      }
    }
  }

  bool pauseVideo(String videoPath, {String? videoId}) =>
      pauseTask(_mediaKey(videoPath, videoId: videoId));

  void resumeVideo(
    String videoPath, {
    String? videoId,
    TranscriptTranslateChoice? translateChoice,
  }) => startTask(
    _mediaKey(videoPath, videoId: videoId),
    translateIfUnfrozen: translateChoice,
  );

  bool restartVideo(
    String videoPath, {
    String? videoId,
    TranscriptTranslateChoice? translateChoice,
  }) => restartTask(
    _mediaKey(videoPath, videoId: videoId),
    translate: translateChoice,
  );

  /// Starts a new checkpoint generation after the previous worker has stopped.
  /// Keep the row's identity/order and all published subtitle files.
  bool restartTask(String mediaKey, {TranscriptTranslateChoice? translate}) {
    if (_cancellingJobs.containsKey(mediaKey) ||
        _currentJob?.mediaKey == mediaKey ||
        _startedMediaKeys.contains(mediaKey)) {
      return false;
    }
    final job = _jobForKey(mediaKey);
    if (job == null) return false;
    final oldCheckpointKey = job.checkpointKey;
    _prepareTaskForNewRun(mediaKey);
    job.checkpointScope = const Uuid().v4();
    job.modelSpec = null;
    job.translatedSrtPath = null;
    job.transcriptPath = null;
    job.transcriptSpecFingerprint = null;
    job.transcriptSourceIdentity = null;
    job.transcriptOutputFingerprint = null;
    job.streamJournal = null;
    job.streamConfigurationFrozen = false;
    job.subtitleSelectionOverridden = false;
    job.subtitlePunctuation = null;
    job.translationInputPath = null;
    job.translateEndpoint = null;
    _streamStates.remove(mediaKey);
    _streamStores.remove(mediaKey);
    _insertQueuedByTaskOrder(job);
    unawaited(_discardCheckpoint(oldCheckpointKey));
    startTask(mediaKey, translateIfUnfrozen: translate);
    return true;
  }

  int queuePositionForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    if (isVideoRunning(videoPath, videoId: videoId)) {
      return 1;
    }
    int index = 0;
    for (final job in _orderedPendingJobs) {
      index++;
      if (job.mediaKey == mediaKey) {
        return processingCount + index;
      }
    }
    return -1;
  }

  /// Match the scheduler's runnable order without letting paused tasks count
  /// towards a started task's execution position. Keep the underlying order
  /// so pause/resume and explicit retries retain their place within the queue.
  Iterable<_TranscriptionJob> get _orderedPendingJobs sync* {
    for (final job in _queue) {
      if (_startedMediaKeys.contains(job.mediaKey)) yield job;
    }
    for (final job in _queue) {
      if (!_startedMediaKeys.contains(job.mediaKey)) yield job;
    }
  }

  void clearPendingQueue() {
    final checkpointKeys = [
      ..._queue.map((job) => job.checkpointKey),
      ..._failedJobs.values.map((job) => job.checkpointKey),
    ];
    final removedKeys = <String>{
      ..._queue.map((job) => job.mediaKey),
      ..._failedJobs.keys,
    };
    _queue.clear();
    _queuedMediaKeys.clear();
    _startedMediaKeys.clear();
    _failedJobs.clear();
    _statusMessagesByMediaKey.clear();
    _taskOrder.removeWhere(removedKeys.contains);
    for (final key in checkpointKeys) {
      unawaited(_discardCheckpoint(key));
    }
    _scheduleSave();
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _cleanupManagedTempAudioDirectory();
    await _initPersistenceDir();
    await _loadState();
    _syncCompletedRemovals();
  }

  Future<void> shutdown() async {
    final done = _currentFinished?.future;
    pauseAllTasks();
    await done;
    _saveDebounceTimer?.cancel();
    // Also wait for a debounce write that already consumed _savePending.
    await _flushSave();
    await _cleanupManagedTempAudioDirectory();
  }

  // ──────────────── 持久化 ────────────────

  Future<void> _initPersistenceDir() async {
    try {
      final appDir = await resolveAppDataDirectory();
      _persistenceDirPath = appDir.path;
    } catch (e) {
      debugPrint('初始化持久化目录失败: $e');
    }
  }

  /// 带防抖的保存调度：500ms 内的多次变更合并为一次写入
  void _scheduleSave() {
    if (_disposed || _persistenceDirPath == null) return;
    _savePending = true;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(_saveDebounce, () {
      _flushSave();
    });
  }

  Future<void> _flushSave() async {
    _saveDebounceTimer?.cancel();
    if (!_savePending) {
      await _stateWrites.enqueue(() async {});
      return;
    }
    _savePending = false;
    await _stateWrites.enqueue(_saveState);
  }

  Future<void> _saveState() async {
    if (_persistenceDirPath == null) return;
    try {
      final file = File(p.join(_persistenceDirPath!, _persistenceFileName));

      final queueJson = _queue.map((j) => j.toJson()).toList();

      final completedJson = <Map<String, dynamic>>[];
      for (final entry in _completedJobs.entries) {
        final jobJson = entry.value.toJson();
        jobJson['resultSrtPath'] = _resultSrtByMediaKey[entry.key];
        jobJson['message'] = _statusMessagesByMediaKey[entry.key] ?? '转录完成';
        completedJson.add(jobJson);
      }

      final failedJson = <Map<String, dynamic>>[];
      for (final entry in _failedJobs.entries) {
        final jobJson = entry.value.toJson();
        jobJson['message'] = _statusMessagesByMediaKey[entry.key] ?? '转录失败';
        failedJson.add(jobJson);
      }

      final data = <String, dynamic>{
        'version': 2,
        'queue': queueJson,
        'active': _currentTaskRemoved || !isProcessing
            ? null
            : _currentJob?.toJson(),
        'completed': completedJson,
        'failed': failedJson,
        'startedKeys': _startedMediaKeys.toList(),
        'taskOrder': List<String>.of(_taskOrder),
        // 持久化已消费标记，确保“AI 字幕已自动加载”提示在转录完成后
        // 仅向用户展示一次，应用重启后不会重复弹出。
        'consumedKeys': _consumedResultMediaKeys.toList(),
      };

      await writeStorageJson(
        file,
        AppStorageService.instance.encodePaths(data),
      );
    } catch (e) {
      debugPrint('保存转录队列状态失败: $e');
    }
  }

  Future<void> _loadState() async {
    if (_persistenceDirPath == null) return;
    try {
      final file = File(p.join(_persistenceDirPath!, _persistenceFileName));
      final raw = await readStorageJson(file);
      if (raw == null) return;

      final data =
          AppStorageService.instance.decodePaths(raw) as Map<String, dynamic>;

      // 恢复排队任务。应用重启后统一回到未开始状态，避免旧的
      // “正在提取”标记再次自动占住队首。
      if (data['queue'] != null) {
        final queueList = data['queue'] as List;
        for (final item in queueList) {
          if (item is Map<String, dynamic>) {
            final job = _TranscriptionJob.fromJson(item);
            // 跳过不存在的文件
            if (job.videoPath.isNotEmpty) {
              // Preserve intent across process restarts. Captured settings
              // remain attached to the task until an explicit restart.
              _queue.add(job);
              _queuedMediaKeys.add(job.mediaKey);
            }
          }
        }
      }

      // 上次运行时仍处于 active 的任务说明进程被中断。将它恢复为
      // 可重试/可删除的失败任务，而不是重新塞回队首自动执行。
      final activeJson = data['active'];
      if (activeJson is Map<String, dynamic>) {
        final activeJob = _TranscriptionJob.fromJson(activeJson);
        if (activeJob.videoPath.isNotEmpty) {
          _queue.removeWhere((job) => job.mediaKey == activeJob.mediaKey);
          _queuedMediaKeys.remove(activeJob.mediaKey);
          _failedJobs[activeJob.mediaKey] = activeJob;
          final book = await _openCheckpointBook();
          final saved = book.tasks[activeJob.checkpointKey];
          _statusMessagesByMediaKey[activeJob.mediaKey] =
              saved != null && saved.hasProgress
              ? '上次识别中断，已保存完成的片段。点重试会从断点继续'
              : '上次运行异常中断，请重试或删除此任务';
        }
      }

      // 恢复已完成任务
      if (data['completed'] != null) {
        final completedList = data['completed'] as List;
        for (final item in completedList) {
          if (item is Map<String, dynamic>) {
            final job = _TranscriptionJob.fromJson(item);
            _completedJobs[job.mediaKey] = job;
            final srtPath = item['resultSrtPath'] as String?;
            if (srtPath != null && srtPath.isNotEmpty) {
              // 仅当 SRT 文件确实存在时才恢复引用
              if (await File(srtPath).exists()) {
                _resultSrtByMediaKey[job.mediaKey] = srtPath;
              }
            }
            final translated = job.translatedSrtPath;
            if (translated != null &&
                translated.isNotEmpty &&
                !await File(translated).exists()) {
              job.translatedSrtPath = null;
            }
            final msg = item['message'] as String?;
            if (msg != null && msg.isNotEmpty) {
              _statusMessagesByMediaKey[job.mediaKey] = msg;
            }
          }
        }
      }

      // 恢复失败任务
      if (data['failed'] != null) {
        final failedList = data['failed'] as List;
        for (final item in failedList) {
          if (item is Map<String, dynamic>) {
            final job = _TranscriptionJob.fromJson(item);
            _failedJobs[job.mediaKey] = job;
            final msg = item['message'] as String?;
            if (msg != null && msg.isNotEmpty) {
              _statusMessagesByMediaKey[job.mediaKey] = msg;
            }
          }
        }
      }

      // 恢复已消费标记：转录完成后“AI 字幕已自动加载”提示只应在第一次
      // 进入该视频时弹出，重启后对已消费过的结果不再重复提示。
      final consumedKeys = data['consumedKeys'];
      if (consumedKeys is List) {
        for (final key in consumedKeys) {
          if (key is String) {
            _consumedResultMediaKeys.add(key);
          }
        }
      }

      // startedKeys 只代表上次会话中的运行意图，不跨进程恢复。
      // 用户可以再次点击“开始全部”，不会出现幽灵任务自动堵队列。
      _startedMediaKeys.clear();

      final persistedOrder = data['taskOrder'];
      if (persistedOrder is List) {
        for (final key in persistedOrder.whereType<String>()) {
          if (_containsTask(key) && !_taskOrder.contains(key)) {
            _taskOrder.add(key);
          }
        }
      }
      final restoredJobs = <_TranscriptionJob>[
        ..._queue,
        ..._failedJobs.values,
        ..._completedJobs.values,
      ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final job in restoredJobs) {
        if (!_taskOrder.contains(job.mediaKey)) _taskOrder.add(job.mediaKey);
        if (job.streamJournal != null &&
            !_completedJobs.containsKey(job.mediaKey)) {
          try {
            final store = await StreamingSubtitleStore.open(
              File(job.streamJournal!),
            );
            if (store.phase != SubtitleStreamPhase.complete) {
              store.phase = SubtitleStreamPhase.paused;
            }
            _streamStores[job.mediaKey] = store;
            _emitStream(store);
          } catch (error) {
            _statusMessagesByMediaKey[job.mediaKey] = '字幕断点读取失败，可重新生成：$error';
          }
        }
      }

      // Older replacements could append a job to the pending list while its
      // displayed row retained an earlier position. Restore one order for both
      // scheduling and display, including queues saved by those versions.
      final orderByKey = {
        for (final (index, key) in _taskOrder.indexed) key: index,
      };
      _queue.sort(
        (a, b) => orderByKey[a.mediaKey]!.compareTo(orderByKey[b.mediaKey]!),
      );

      if (_queue.isNotEmpty ||
          _completedJobs.isNotEmpty ||
          _failedJobs.isNotEmpty) {
        debugPrint(
          '已恢复转录队列: ${_queue.length} 排队, ${_completedJobs.length} 完成, ${_failedJobs.length} 失败',
        );
      }
    } catch (e) {
      debugPrint('加载转录队列状态失败: $e');
    }
  }

  Future<TemporaryStorageCategoryReport> buildTemporaryStorageReport() async {
    if (isProcessing) {
      return const TemporaryStorageCategoryReport(
        id: 'ai_transcription_temp_audio',
        title: 'AI 识别临时音频',
        description: 'AI 字幕识别过程中提取到临时目录的音频文件',
        fileCount: 0,
        totalBytes: 0,
        canClean: false,
        note: '当前正在进行 AI 识别，临时音频已受保护，暂不允许清理。',
      );
    }

    final files = await _listManagedTempAudioFiles();
    var totalBytes = 0;
    for (final file in files) {
      totalBytes += await _safeFileSize(file);
    }

    return TemporaryStorageCategoryReport(
      id: 'ai_transcription_temp_audio',
      title: 'AI 识别临时音频',
      description: 'AI 字幕识别过程中提取到临时目录的音频文件',
      fileCount: files.length,
      totalBytes: totalBytes,
      canClean: files.isNotEmpty,
      note: files.isEmpty ? '未发现残留的 AI 临时音频。' : null,
    );
  }

  Future<void> clearTemporaryStorageArtifacts() async {
    if (isProcessing) {
      return;
    }
    await _cleanupManagedTempAudioDirectory();
  }

  // 开始转录
  Future<TranscriptionEnqueueResult> startTranscription(
    String videoPath, {
    String? videoId,
    String? videoTitle,
    String? videoDuration,
    LibraryService? libraryService,
    VideoItem? sourceItem,
    bool autoCache = false,
    bool autoStart = false,
    TranscriptTranslateChoice? translateChoice,
  }) async {
    if (videoPath.trim().isEmpty) {
      throw Exception("视频路径不能为空");
    }
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    if (isVideoCancelling(videoPath, videoId: videoId) ||
        _currentJob?.mediaKey == mediaKey ||
        isVideoQueued(videoPath, videoId: videoId)) {
      return TranscriptionEnqueueResult.alreadyQueued;
    }

    final libraryItem = _transcriptionSourceSnapshot(
      sourceItem ??
          (videoId == null ? null : libraryService?.getVideo(videoId)),
      videoPath,
      videoId,
    );
    final displayName =
        _nonEmpty(videoTitle) ??
        _nonEmpty(libraryItem?.title) ??
        p.basename(videoPath);
    _prepareTaskForNewRun(mediaKey);
    final job = _TranscriptionJob(
      videoPath: videoPath,
      videoId: videoId,
      mediaKey: mediaKey,
      libraryService: libraryService,
      sourceItem: libraryItem,
      autoCache: autoCache,
      isExternal: false,
      outputPathStrategy: null,
      customOutputDir: null,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      displayName: displayName,
      durationLabel:
          _nonEmpty(videoDuration) ??
          formatMediaDurationLabel(libraryItem?.durationMs ?? 0),
      checkpointScope: const Uuid().v4(),
    );
    if (translateChoice != null) {
      job.freezeTranslate(translateChoice);
    }
    _insertQueuedByTaskOrder(job);
    if (autoStart) {
      _startedMediaKeys.add(mediaKey);
    }
    _scheduleSave();
    notifyListeners();
    if (autoStart) {
      _ensureQueueProcessing();
    }
    return TranscriptionEnqueueResult.added;
  }

  /// Supply the actual selected source to an older paused/failed task before
  /// retrying. Matching both path and id prevents a late UI callback using the
  /// next episode's source for the previous task.
  void updateSourceForVideo(
    String videoPath, {
    String? videoId,
    required VideoItem sourceItem,
  }) {
    final snapshot = _transcriptionSourceSnapshot(
      sourceItem,
      videoPath,
      videoId,
    );
    final job = _jobForKey(_mediaKey(videoPath, videoId: videoId));
    if (snapshot == null ||
        job == null ||
        job.videoPath != videoPath ||
        _hasTranscriptionSource(job.sourceItem)) {
      return;
    }
    job.sourceItem = snapshot;
    _scheduleSave();
  }

  /// 开始处理单个任务（只处理这一个，处理完不会自动开始下一个）
  void startTask(
    String mediaKey, {
    TranscriptTranslateChoice? translateIfUnfrozen,
  }) {
    if (_cancellingJobs.containsKey(mediaKey)) return;
    _requeueFailedTask(mediaKey);
    if (!_queuedMediaKeys.contains(mediaKey) ||
        _startedMediaKeys.contains(mediaKey)) {
      return;
    }
    _refreshJobForStart(_jobForKey(mediaKey)!, translateIfUnfrozen);
    _startedMediaKeys.add(mediaKey);
    _scheduleSave();
    notifyListeners();
    _ensureQueueProcessing();
  }

  /// 开始处理所有排队任务（逐个处理直到全部完成）
  void startAllTasks({TranscriptTranslateChoice? translateIfUnfrozen}) {
    // Requeue failures before scheduling so original task order is preserved.
    for (final key in _failedJobs.keys.toList()) {
      _requeueFailedTask(key);
    }
    for (final job in _queue) {
      if (_startedMediaKeys.contains(job.mediaKey)) continue;
      _refreshJobForStart(job, translateIfUnfrozen);
      _startedMediaKeys.add(job.mediaKey);
    }
    _scheduleSave();
    notifyListeners();
    _ensureQueueProcessing();
  }

  void _refreshJobForStart(
    _TranscriptionJob job,
    TranscriptTranslateChoice? choice,
  ) {
    // Published streaming prefixes and their pending translations belong to
    // one frozen generation. New settings are applied by restartTask only.
    if (job.streamConfigurationFrozen ||
        (job.modelSpec != null && job.translateFrozen)) {
      return;
    }
    job.streamAssemblyVersion = 3;
    // Only jobs that have never captured a configuration adopt current settings.
    job.modelSpec = null;
    job.translatedSrtPath = null;
    if (choice != null || !job.translateFrozen) {
      job.freezeTranslate(choice ?? const TranscriptTranslateChoice.off());
    } else if (job.translateProviderName ==
        SubtitleTranslateProvider.local.name) {
      job.translateLocalSpec = null;
    }
  }

  /// Pause only this task; other explicitly started tasks keep running.
  bool pauseTask(String mediaKey) {
    if (_currentJob?.mediaKey == mediaKey && isProcessing) {
      _currentPauseRequested = true;
      _publishStreamPhase(mediaKey, SubtitleStreamPhase.stopping);
      _currentCancellation?.cancel('用户暂停了任务');
    } else if (_queuedMediaKeys.contains(mediaKey)) {
      _startedMediaKeys.remove(mediaKey);
      _statusMessagesByMediaKey[mediaKey] = '已暂停';
    } else {
      return false;
    }
    _scheduleSave();
    notifyListeners();
    return true;
  }

  /// 暂停整批任务：停止后续调度，并取消当前底层工作。当前任务会回到
  /// 原来的显示位置，之后可用“全部开始”或单项开始继续。
  void pauseAllTasks() {
    _startedMediaKeys.clear();
    if (_currentJob != null && isProcessing) {
      _currentPauseRequested = true;
      _publishStreamPhase(_currentJob!.mediaKey, SubtitleStreamPhase.stopping);
      _currentCancellation?.cancel('用户暂停了批量任务');
    }
    _scheduleSave();
    notifyListeners();
  }

  /// 某任务是否已被用户显式开始
  bool isTaskStarted(String mediaKey) => _startedMediaKeys.contains(mediaKey);

  /// 队列是否正在处理中
  bool get isQueueRunning => _isQueueProcessing;

  /// 已开始的排队任务数量（不含当前正在处理的）
  int get startedCount => _startedMediaKeys.length;

  void _ensureQueueProcessing() {
    if (_isQueueProcessing) return;
    unawaited(_processQueue());
  }

  Future<void> _processQueue() async {
    if (_isQueueProcessing) return;
    _isQueueProcessing = true;
    try {
      while (true) {
        // 在队列中查找第一个已被用户"开始"的任务
        final startIndex = _queue.indexWhere(
          (job) => _startedMediaKeys.contains(job.mediaKey),
        );
        if (startIndex < 0) break; // 没有更多已开始的任务，停止

        final job = _queue.removeAt(startIndex);
        _startedMediaKeys.remove(job.mediaKey);
        _queuedMediaKeys.remove(job.mediaKey);
        final cancellation = _JobCancellation();
        _currentJob = job;
        _currentFinished = Completer<void>();
        _currentCancellation = cancellation;
        _currentTaskRemoved = false;
        _hitRiskControlThisJob = false;
        _scheduleSave();
        Timer? timeoutTimer;
        final jobStarted = DateTime.now();
        void armRecognitionWatchdog() {
          timeoutTimer?.cancel();
          timeoutTimer = Timer(
            TranscriptionTiming.watchdogForLabel(_durationLabelForJob(job)),
            () {
              // Download and queue waits keep their own recovery. They must
              // not surface as a recognition timeout.
              if (_preparingMedia) {
                if (DateTime.now().difference(jobStarted) >
                    const Duration(hours: 6)) {
                  cancellation.cancel(
                    '下载或等待超过安全时限，已停下。已保存的进度可以继续',
                    timedOut: true,
                  );
                  return;
                }
                armRecognitionWatchdog();
                return;
              }
              cancellation.cancel(
                '识别时间比预期长，已先停下。点重试会从已完成的片段继续',
                timedOut: true,
              );
            },
          );
        }

        _preparingMedia = true;
        armRecognitionWatchdog();
        try {
          await _runJob(job, cancellation);
        } on GongyiAsrException catch (e) {
          if (e.isAccessDenied) {
            _consecutiveRiskControlFailures++;
            _nextRemoteRequestAt = DateTime.now().add(_riskControlCooldown);
            if (_consecutiveRiskControlFailures >= _riskControlStopThreshold) {
              final started = List<String>.from(_startedMediaKeys);
              _startedMediaKeys.clear();
              for (final key in started) {
                if (_queue.any((queued) => queued.mediaKey == key)) {
                  _statusMessagesByMediaKey[key] =
                      TranscriptionRetryPolicy.batchPausedMessage;
                }
              }
            }
          } else {
            // 断网、DNS 失败、服务端故障都不计入风控次数。
            _consecutiveRiskControlFailures = 0;
          }
          debugPrint(
            '[transcription] task failed kind=${e.kind} key=${job.mediaKey} message=${e.message}',
          );
        } on _JobCancelledException catch (e) {
          if (_currentPauseRequested && !_currentTaskRemoved) {
            _prepareTaskForNewRun(job.mediaKey);
            _insertQueuedByTaskOrder(job);
            _statusMessagesByMediaKey[job.mediaKey] = '已暂停';
            debugPrint("转录任务已暂停: ${job.videoPath}");
          } else if (e.timedOut && !_currentTaskRemoved) {
            _failedJobs[job.mediaKey] = job;
            _statusMessagesByMediaKey[job.mediaKey] = e.message;
            debugPrint("转录任务超时，已中断并跳过: ${job.videoPath}");
          } else {
            if (_currentTaskRemoved) {
              _removeTaskRecords(job.mediaKey);
            }
            debugPrint("转录任务已取消: ${job.videoPath}");
          }
        } finally {
          timeoutTimer?.cancel();
          if (identical(_currentCancellation, cancellation)) {
            _currentCancellation = null;
            _currentJob = null;
            _currentTaskRemoved = false;
            _currentPauseRequested = false;
            _currentVideoPath = null;
            _currentVideoId = null;
            _status = TranscriptionStatus.idle;
            _statusMessage = '';
            _progress = 0.0;
            _translationProgress = null;
            _localAsrProgress = null;
            _currentFinished?.complete();
            _currentFinished = null;
            if (!_disposed) notifyListeners();
          }
          _scheduleSave();
        }
      }
    } finally {
      _isQueueProcessing = false;
      _libraryService = null;
      _autoCache = false;
      _currentJobIsExternal = false;
      _currentJobOutputPathStrategy = null;
      _currentJobCustomOutputDir = null;
      _currentJobCreatedAt = 0;
      _scheduleSave();
    }
  }

  Future<void> _runJob(
    _TranscriptionJob job,
    _JobCancellation cancellation,
  ) async {
    _currentVideoPath = job.videoPath;
    _currentVideoId = job.videoId;
    _libraryService =
        job.libraryService ?? (job.videoId == null ? null : LibraryService());
    _autoCache = job.autoCache;
    _currentJobIsExternal = job.isExternal;
    _currentJobOutputPathStrategy = job.outputPathStrategy;
    _currentJobCustomOutputDir = job.customOutputDir;
    _currentJobCreatedAt = job.createdAt;
    _status = TranscriptionStatus.extracting;
    _statusMessage = "";
    _statusMessagesByMediaKey.remove(job.mediaKey);
    _progress = 0.0;
    _translationProgress = null;
    _localAsrProgress = null;
    _streamStarts.add((
      mediaKey: job.mediaKey,
      runId: '${job.checkpointKey}:${job.createdAt}',
    ));
    _audioDuration =
        TranscriptionTiming.parseClockLabel(_durationLabelForJob(job)) ??
        Duration.zero;
    _committedAudio = Duration.zero;
    if (!_disposed) notifyListeners();

    _PreparedAudioResult? preparedAudio;
    MaterializedMediaLease? materializedLease;
    VideoItem? materializedPodcast;
    try {
      cancellation.throwIfCancelled();
      if (job.retryRemoteTasks) {
        final book = await _openCheckpointBook();
        final checkpoint = book.tasks[job.checkpointKey];
        // Explicit retry of a failed public-service job starts fresh remote
        // work, while completed slices and audio compatibility choices survive.
        if (checkpoint != null) {
          for (final remote in checkpoint.remoteTasks.values) {
            remote.taskId = null;
            remote.lastQueryFailure = null;
          }
          await _writeCheckpointBook(book);
        }
        job.retryRemoteTasks = false;
        _scheduleSave();
        cancellation.throwIfCancelled();
      }
      if (!job.translateFrozen) {
        job.freezeTranslate(const TranscriptTranslateChoice.off());
      }
      if (job.modelSpec == null) {
        final captured = _modelCenter.started
            ? await _modelCenter.captureTranscription()
            : const ModelJobSpec(profile: ModelCenterService.legacyProfile);
        if (_hasHotwordModel(captured)) {
          await _hotwordStore.load();
        }
        cancellation.throwIfCancelled();
        job.modelSpec = _scopeHotwords(captured, job.mediaKey);
      }
      job.subtitlePunctuation ??= _modelCenter.subtitlePunctuation;
      cancellation.throwIfCancelled();
      if (job.translateEnabled &&
          job.translateProviderName == SubtitleTranslateProvider.local.name) {
        job.translateLocalSpec ??= await captureLocalTranslation(_modelCenter);
        cancellation.throwIfCancelled();
      }
      _scheduleSave();
      var transcriptionMediaPath = job.videoPath;
      if (job.streamsRecognition || job.streamsCloudTranslation) {
        job.streamConfigurationFrozen = true;
      }
      var libraryItem = job.sourceItem;
      if (!_hasTranscriptionSource(libraryItem)) {
        final saved = _transcriptionSourceSnapshot(
          job.videoId == null ? null : _libraryService?.getVideo(job.videoId!),
          job.videoPath,
          job.videoId,
        );
        libraryItem =
            (_hasTranscriptionSource(saved) ? saved : null) ??
            _transcriptionSourceSnapshot(
              PodcastPlaybackHooks.restoreSource?.call(
                job.videoPath,
                job.videoId,
              ),
              job.videoPath,
              job.videoId,
            ) ??
            libraryItem;
      }
      if (libraryItem != null && !identical(job.sourceItem, libraryItem)) {
        job.sourceItem = libraryItem;
        _scheduleSave();
      }
      if (libraryItem != null &&
          itemNeedsOnlineMaterialization(
            source: libraryItem.sourceRef,
            path: libraryItem.path,
          )) {
        _libraryService ??= LibraryService();
      }
      final isBilibiliStream =
          !job.isExternal &&
          libraryItem != null &&
          (libraryItem.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
              libraryItem.path.startsWith('bilibili://stream/'));
      if (libraryItem != null &&
          isCloudDriveMedia(
            source: libraryItem.sourceRef,
            path: libraryItem.path,
          )) {
        _updateStatus(
          TranscriptionStatus.downloading,
          '正在准备网盘音频。没有单独音轨时会先下载视频再提取',
          0.0,
        );
        materializedLease = await _libraryService!.acquireMaterializedMedia(
          libraryItem.id,
          MediaMaterializationRequirement.audioOnly,
          sourceItem: libraryItem,
          cancelSignal: cancellation.whenCancelled,
          onProgress: (download) {
            if (cancellation.isCancelled) return;
            final fraction = download.totalBytes == null
                ? download.progress.clamp(0.0, 1.0)
                : download.progress.clamp(0.0, 1.0);
            _updateStatus(
              TranscriptionStatus.downloading,
              download.message,
              _progressPlan.download(fraction),
            );
          },
        );
        transcriptionMediaPath = materializedLease.requiredAudioPath;
        cancellation.throwIfCancelled();
      }
      if (libraryItem?.sourceRef?.podcast != null) {
        final preparePodcast = PodcastPlaybackHooks.materialize;
        if (preparePodcast == null) throw StateError('播客服务尚未就绪，请稍后重试');
        _updateStatus(TranscriptionStatus.downloading, '正在准备播客音频...', 0.0);
        transcriptionMediaPath = await preparePodcast(
          libraryItem!,
          isCancelled: () => cancellation.isCancelled,
          cancelSignal: cancellation.whenCancelled,
          onProgress: (download) {
            if (cancellation.isCancelled) return;
            final fraction = download.fraction;
            final percent = download.totalBytes == null
                ? ''
                : ' ${(fraction * 100).toStringAsFixed(0)}%';
            final total = download.totalBytes == null
                ? ''
                : ' / ${_formatTransferBytes(download.totalBytes!)}';
            final speed = download.bytesPerSecond > 0
                ? ' · ${_formatTransferBytes(download.bytesPerSecond.round())}/s'
                : '';
            final eta = download.remaining == null
                ? ''
                : ' · 剩余约 ${download.remaining!.inSeconds}s';
            final reused = download.reusedBytes > 0
                ? ' · 已复用 ${_formatTransferBytes(download.reusedBytes)}'
                : '';
            _updateStatus(
              TranscriptionStatus.downloading,
              '${download.message.isEmpty ? '正在下载播客音频' : download.message}$percent · ${_formatTransferBytes(download.receivedBytes)}$total$speed$eta$reused',
              _progressPlan.download(fraction),
            );
          },
        );
        materializedPodcast = libraryItem;
        cancellation.throwIfCancelled();
      }
      if (isBilibiliStream) {
        _updateStatus(
          TranscriptionStatus.downloading,
          '正在准备下载 Bilibili 音频...',
          0.0,
        );
        try {
          materializedLease = await _libraryService!.acquireMaterializedMedia(
            libraryItem.id,
            MediaMaterializationRequirement.audioOnly,
            sourceItem: libraryItem,
            cancelSignal: cancellation.whenCancelled,
            onProgress: (download) {
              if (cancellation.isCancelled) return;
              final fraction = download.progress.clamp(0.0, 1.0);
              final percent = ' ${(fraction * 100).toStringAsFixed(0)}%';
              final total = download.totalBytes == null
                  ? ''
                  : ' / ${_formatTransferBytes(download.totalBytes!)}';
              final speed = download.bytesPerSecond > 0
                  ? ' · ${_formatTransferBytes(download.bytesPerSecond.round())}/s'
                  : '';
              final eta = download.remaining == null
                  ? ''
                  : ' · 剩余约 ${download.remaining!.inSeconds}s';
              _updateStatus(
                TranscriptionStatus.downloading,
                '正在下载音频$percent · ${_formatTransferBytes(download.receivedBytes)}$total$speed$eta',
                _progressPlan.download(fraction),
              );
            },
          );
          transcriptionMediaPath = materializedLease.requiredAudioPath;
        } catch (_) {
          cancellation.throwIfCancelled();
          rethrow;
        }
        cancellation.throwIfCancelled();
        _updateStatus(
          TranscriptionStatus.downloading,
          'Bilibili 音频下载完成，正在检查格式...',
          _progressPlan.download(1),
        );
      }
      _updateStatus(
        TranscriptionStatus.extracting,
        '正在检查音轨信息...',
        _progressPlan.preparation(0),
      );
      final modelSpec = job.modelSpec!;
      final usesLegacyAsr =
          modelSpec.profile.kind == TranscriptionServiceKind.gongyi;
      preparedAudio = await _prepareAudioForTranscription(
        transcriptionMediaPath,
        cancellation,
        normalizeUnknownDuration: usesLegacyAsr,
        audioExpected: libraryItem?.type == MediaType.audio,
      );
      final audioSeconds = preparedAudio.probe.durationSeconds;
      if (audioSeconds != null && audioSeconds.isFinite && audioSeconds > 0) {
        _audioDuration = Duration(milliseconds: (audioSeconds * 1000).round());
        job.durationLabel = formatMediaDurationLabel(
          _audioDuration.inMilliseconds,
        );
        if (libraryItem != null && libraryItem.durationMs <= 0) {
          await _libraryService!.updateVideoDuration(
            libraryItem.id,
            _audioDuration.inMilliseconds,
          );
        }
        _scheduleSave();
        if (!_disposed) notifyListeners();
      }
      cancellation.throwIfCancelled();

      final physicalIdentity = await _transcriptionSourceIdentity(
        transcriptionMediaPath,
      );
      final reference = libraryItem?.sourceRef;
      // Downloaded cache files can acquire another timestamp/path on resume.
      // Their logical media revision, rather than that cache file, owns ASR.
      final sourceIdentity =
          !modelSpec.profile.local && !job.streamsCloudTranslation
          ? physicalIdentity
          : reference?.cloudDrive != null
          ? 'cloud:${reference!.cloudDrive!.sourceKey}:${reference.cloudDrive!.revision ?? ''}'
          : reference?.podcast != null
          ? 'podcast:${jsonEncode(reference!.podcast!.toJson())}'
          : isBilibiliStream
          ? 'bilibili:${reference?.bvid ?? reference?.aid ?? libraryItem.path}:${reference?.cid ?? 0}:${reference?.page ?? 1}'
          : physicalIdentity;
      final savedTranscript = job.transcriptPath;
      final outputFingerprint = job.isExternal
          ? jsonEncode([
              _settings.batchSubtitleOutputPathStrategy.name,
              _settings.batchSubtitleCustomOutputDir,
            ])
          : '';
      final reuseTranscript =
          !job.streamsRecognition &&
          savedTranscript != null &&
          job.transcriptSpecFingerprint == modelSpec.fingerprint &&
          job.transcriptSourceIdentity == sourceIdentity &&
          job.transcriptOutputFingerprint == outputFingerprint &&
          await File(savedTranscript).exists();
      if (job.streamsCloudTranslation &&
          job.streamJournal != null &&
          !reuseTranscript) {
        throw StateError('源媒体或原字幕已改变，请使用“重新生成”创建新字幕');
      }
      late final String srtPath;
      String? wordTimingPath;
      ({String? path, String? language, String message})? streamedTranslation;
      if (reuseTranscript) {
        srtPath = savedTranscript;
        final timing = SubtitleWordTimingStore.pathFor(srtPath);
        if (await File(timing).exists()) wordTimingPath = timing;
        _updateStatus(
          TranscriptionStatus.transcribing,
          '已恢复本次原字幕',
          _progressPlan.recognition(1),
        );
      } else if (job.streamsRecognition) {
        final store = await _runLocalStream(
          job: job,
          prepared: preparedAudio,
          sourcePath: transcriptionMediaPath,
          sourceIdentity: sourceIdentity,
          cancellation: cancellation,
        );
        srtPath = store.primaryPath;
        final completedCues = store.primary.snapshot;
        wordTimingPath = await SubtitleWordTimingStore.writeInBackground(
          srtPath,
          completedCues,
        );
        job.transcriptPath = srtPath;
        job.transcriptSpecFingerprint = modelSpec.fingerprint;
        job.transcriptSourceIdentity = sourceIdentity;
        job.transcriptOutputFingerprint = outputFingerprint;
        streamedTranslation = (
          path: store.secondaryPath,
          language: store.targetLanguage,
          message: '转录完成',
        );
      } else {
        if (usesLegacyAsr) await _waitForRemoteRequestSlot(cancellation);
        _updateStatus(
          modelSpec.profile.local
              ? TranscriptionStatus.transcribing
              : TranscriptionStatus.uploading,
          modelSpec.profile.local ? '准备本地识别...' : '准备上传音频...',
          _progressPlan.recognition(0),
        );
        final subtitles = usesLegacyAsr
            ? await _transcribePrepared(
                preparedAudio: preparedAudio,
                sourcePath: transcriptionMediaPath,
                mediaKey: job.checkpointKey,
                cancellation: cancellation,
              )
            : await _transcribeWithModel(
                job: job,
                prepared: preparedAudio,
                sourcePath: transcriptionMediaPath,
                sourceIdentity: sourceIdentity,
                cancellation: cancellation,
              );
        cancellation.throwIfCancelled();
        if (usesLegacyAsr) {
          _consecutiveRiskControlFailures = 0;
          _nextRemoteRequestAt = DateTime.now().add(
            _hitRiskControlThisJob
                ? const Duration(seconds: 25)
                : _normalInterTaskDelay,
          );
        }
        _updateStatus(
          TranscriptionStatus.transcribing,
          '正在保存字幕文件...',
          _progressPlan.recognition(1),
        );
        // Keep punctuation as translation context, while publishing only the
        // requested output text. The internal input survives a paused task.
        final output = await _outputPreparer.transcript(
          subtitles,
          job.subtitlePunctuation!,
          keepTranslationInput:
              job.translateEnabled &&
              job.subtitlePunctuation != SubtitlePunctuation.preserve,
        );
        cancellation.throwIfCancelled();
        if (output.translationInput != null) {
          final input = File(
            p.join(
              _persistenceDirPath!,
              'model_jobs',
              '${const Uuid().v4()}.translation-input.srt',
            ),
          );
          await input.parent.create(recursive: true);
          await input.writeAsString(output.translationInput!, flush: true);
          job.translationInputPath = input.path;
        }
        cancellation.throwIfCancelled();
        srtPath = await _saveSrtFile(
          job.videoPath,
          output.srt,
          videoId: job.videoId,
        );
        cancellation.throwIfCancelled();
        try {
          wordTimingPath = await SubtitleWordTimingStore.writeEncoded(
            srtPath,
            output.wordTiming,
          );
        } on FileSystemException catch (error) {
          debugPrint('词级时间保存失败，保留句级字幕: $error');
        }
        job.transcriptPath = srtPath;
        job.transcriptSpecFingerprint = modelSpec.fingerprint;
        job.transcriptSourceIdentity = sourceIdentity;
        job.transcriptOutputFingerprint = outputFingerprint;
      }
      cancellation.throwIfCancelled();
      _lastGeneratedSrtPath = srtPath;
      final cloudStream = job.streamsCloudTranslation
          ? await _openCloudTranslationStream(
              job,
              srtPath,
              sourceIdentity,
              cancellation,
            )
          : null;

      ManagedSubtitleAsset? aiAsset;
      if (!job.isExternal && job.videoId != null && _libraryService != null) {
        try {
          aiAsset = await _libraryService!.registerManagedLocalSubtitle(
            job.videoId!,
            path: srtPath,
            kind: ManagedSubtitleAssetKind.ai,
            displayName: 'AI 字幕',
            wordTimingPath: wordTimingPath,
          );
          final currentVideo = _libraryService!.getVideo(job.videoId!);
          if (!job.streamsRecognition &&
              (cloudStream == null || _shouldSelectStream(job))) {
            await _libraryService!.updateVideoSubtitles(
              job.videoId!,
              srtPath,
              _autoCache,
              secondarySubtitlePath: currentVideo?.secondarySubtitlePath,
              isSecondaryCached:
                  currentVideo?.isSecondarySubtitleCached ?? false,
              shouldApply: cloudStream == null
                  ? null
                  : () => _shouldSelectStream(job),
            );
          }
        } catch (error) {
          debugPrint('原字幕登记失败，保留已生成的字幕文件: $error');
        }
      }
      // Commit the transcript before entering the cancellable translation step.
      // The player can use it immediately, and the library retains it on exit.
      if (!job.isExternal && !job.streamsRecognition && cloudStream == null) {
        _resultSrtByMediaKey[job.mediaKey] = srtPath;
        if (reuseTranscript) {
          _consumedResultMediaKeys.add(job.mediaKey);
        } else {
          _consumedResultMediaKeys.remove(job.mediaKey);
        }
        _updateStatus(
          TranscriptionStatus.transcribing,
          job.translateEnabled ? '原字幕已保存，正在准备翻译' : '转录完成',
          _progressPlan.recognition(1),
        );
        _scheduleSave();
        await _flushSave();
      }
      cancellation.throwIfCancelled();

      final translation = cloudStream != null
          ? await _translateCloudStream(job, cloudStream, cancellation)
          : streamedTranslation ??
                await _translateGeneratedSubtitle(job, srtPath, cancellation);
      cancellation.throwIfCancelled();
      job.translatedSrtPath = translation.path;

      // ── 外部视频软字幕内嵌 ──
      // The translation stays a sidecar. Embedding still muxes the transcript only.
      if (job.isExternal) {
        await _embedSoftSubtitlesIfNeeded(
          videoPath: job.videoPath,
          srtPath: srtPath,
          mediaKey: job.mediaKey,
          cancellation: cancellation,
        );
      }
      cancellation.throwIfCancelled();

      _updateStatus(TranscriptionStatus.transcribing, '正在保存字幕结果...', 0.99);
      if (!job.isExternal &&
          _currentVideoId != null &&
          _libraryService != null) {
        try {
          final currentVideo = _libraryService!.getVideo(_currentVideoId!);
          String? existingSecondaryPath = currentVideo?.secondarySubtitlePath;
          bool isSecondaryCached =
              currentVideo?.isSecondarySubtitleCached ?? false;
          final translatedPath = translation.path;
          if (translatedPath != null) {
            try {
              await _libraryService!.registerManagedLocalSubtitle(
                _currentVideoId!,
                path: translatedPath,
                kind: ManagedSubtitleAssetKind.translated,
                displayName: '翻译字幕',
                language: translation.language,
                sourceAssetId: aiAsset?.assetId,
              );
            } catch (error) {
              debugPrint('翻译字幕登记失败，仍写入副字幕路径: $error');
            }
            existingSecondaryPath = translatedPath;
            isSecondaryCached = _autoCache;
          }

          if ((!job.streamsRecognition && cloudStream == null) ||
              _shouldSelectStream(job)) {
            await _libraryService!.updateVideoSubtitles(
              _currentVideoId!,
              srtPath,
              _autoCache,
              secondarySubtitlePath: existingSecondaryPath,
              isSecondaryCached: isSecondaryCached,
              shouldApply: (job.streamsRecognition || cloudStream != null)
                  ? () => _shouldSelectStream(job)
                  : null,
            );
          }
          cancellation.throwIfCancelled();
          debugPrint("AI字幕已自动保存到库: $_currentVideoId");
        } catch (e) {
          if (e is _JobCancelledException) rethrow;
          debugPrint("自动保存字幕失败: $e");
        }
      }

      // Translation completion is a second result notification, even though
      // the primary path is unchanged. Consumers must load the new secondary.
      _resultSrtByMediaKey[job.mediaKey] = srtPath;
      if (job.isExternal || job.translateEnabled) {
        _consumedResultMediaKeys.remove(job.mediaKey);
      }
      final streamed = _streamStores[job.mediaKey];
      if (streamed != null && (job.streamsRecognition || cloudStream != null)) {
        await streamed.setPhase(SubtitleStreamPhase.complete);
        _emitStream(streamed);
      }
      _completedJobs[job.mediaKey] = job;
      _updateStatus(TranscriptionStatus.completed, translation.message, 1.0);
      await _discardCheckpoint(job.checkpointKey);
      _syncCompletedRemovals();
      _scheduleSave();
    } on _JobCancelledException {
      await _transitionStream(
        job.mediaKey,
        SubtitleStreamPhase.paused,
        '已停止并保留进度',
      );
      rethrow;
    } on GongyiAsrException catch (e) {
      cancellation.throwIfCancelled();
      _failedJobs[job.mediaKey] = job;
      _updateStatus(
        TranscriptionStatus.error,
        TranscriptionUserMessage.describe(e),
        0.0,
      );
      _scheduleSave();
      rethrow;
    } catch (e) {
      cancellation.throwIfCancelled();
      await _transitionStream(
        job.mediaKey,
        SubtitleStreamPhase.failed,
        TranscriptionUserMessage.describe(e),
      );
      _consecutiveRiskControlFailures = 0;
      _failedJobs[job.mediaKey] = job;
      _updateStatus(
        TranscriptionStatus.error,
        TranscriptionUserMessage.describe(e),
        0.0,
      );
      _scheduleSave();
      debugPrint("转录任务失败: ${job.videoPath}, $e");
    } finally {
      Future<void> releaseSafely(FutureOr<void> Function() release) async {
        try {
          await release();
        } catch (error) {
          // Resource cleanup must not replace the task's result/cancellation
          // or escape the serial worker and strand the remaining queue.
          debugPrint('清理转录临时资源失败: $error');
        }
      }

      if (cancellation.isCancelled) {
        await _transitionStream(
          job.mediaKey,
          SubtitleStreamPhase.paused,
          '已停止并保留进度',
        );
      }
      if (preparedAudio?.isTemporary == true) {
        await releaseSafely(
          () => _deleteFileIfExists(preparedAudio!.audioPath),
        );
      }
      if (materializedLease != null) {
        await releaseSafely(materializedLease.release);
      }
      if (materializedPodcast != null) {
        await releaseSafely(
          () => PodcastPlaybackHooks.releaseMaterialized?.call(
            materializedPodcast!,
          ),
        );
      }
    }
  }

  void _emitStream(
    StreamingSubtitleStore store, {
    List<SubtitleItem> primary = const [],
    List<SubtitleItem> secondary = const [],
  }) {
    if (_disposed) return;
    final header = store.header;
    final update = SubtitleStreamUpdate(
      generationId: header['generationId'] as String,
      mediaKey: header['mediaKey'] as String,
      videoPath: header['videoPath'] as String,
      videoId: header['videoId'] as String?,
      revision: store.revision,
      primaryPath: store.primaryPath,
      secondaryPath: store.secondaryPath,
      primary: store.primary.snapshot,
      secondary: store.secondary.snapshot,
      addedPrimary: primary,
      addedSecondary: secondary,
      primaryBytes: store.primaryBytes,
      secondaryBytes: store.secondaryBytes,
      processedThrough: store.through,
      phase: store.phase,
      message: store.message,
      autoCache: header['autoCache'] as bool? ?? false,
      primaryComplete: store.primaryComplete,
      autoSelectSuppressed: subtitleSelectionOverridden(
        header['mediaKey'] as String,
      ),
    );
    _streamStates[update.mediaKey] = update;
    _streamEvents.add(update);
    if (store.phase == SubtitleStreamPhase.complete) {
      // Playback retains its selected snapshot. Completed queue entries need
      // only metadata; a batch queue must not pin every transcript in RAM.
      _streamStates[update.mediaKey] = update.compact();
      _streamStores.remove(update.mediaKey);
    }
    subtitleFilesRevision.value++;
  }

  void _publishStreamPhase(String key, SubtitleStreamPhase phase) {
    final store = _streamStores[key];
    if (store == null) return;
    store.phase = phase;
    _emitStream(store);
  }

  Future<void> _transitionStream(
    String key,
    SubtitleStreamPhase phase,
    String message,
  ) async {
    final store = _streamStores[key];
    if (store == null || store.phase == phase) return;
    try {
      await store.setPhase(phase, message);
    } on FileSystemException catch (error) {
      debugPrint('字幕状态写入失败，保留最后的提交点：$error');
    }
    store.phase = phase;
    store.message = message;
    _emitStream(store);
  }

  Future<String> _allocateStreamPath(_TranscriptionJob job) async {
    if (!job.isExternal && job.videoId != null) {
      return _libraryService != null
          ? _libraryService!.allocateSubtitleFile(job.videoId!, 'ai.srt')
          : const TaskSubtitleStorageService().allocatePath(
              job.videoId!,
              'ai.srt',
            );
    }
    final storage = const TaskSubtitleStorageService();
    final custom = _settings.batchSubtitleCustomOutputDir;
    if (_settings.batchSubtitleOutputPathStrategy ==
            SubtitleOutputPathStrategy.customDirectory &&
        custom != null &&
        custom.isNotEmpty) {
      try {
        return await storage.allocateInside(
          Directory(custom),
          _aiSubtitleFileName(job.videoPath),
        );
      } on FileSystemException {
        /* use the existing sidecar/private fallback */
      }
    }
    try {
      return await storage.allocateInside(
        File(job.videoPath).parent,
        _aiSubtitleFileName(job.videoPath),
      );
    } on FileSystemException {
      return storage.allocateInside(
        Directory(p.join(_persistenceDirPath!, 'subtitles', 'external')),
        _aiSubtitleFileName(job.videoPath),
      );
    }
  }

  Future<void> _registerStream(
    _TranscriptionJob job,
    StreamingSubtitleStore store,
  ) async {
    if (job.isExternal || job.videoId == null || _libraryService == null) {
      return;
    }
    final original = await _libraryService!.registerManagedLocalSubtitle(
      job.videoId!,
      path: store.primaryPath,
      kind: ManagedSubtitleAssetKind.ai,
      displayName: 'AI 字幕',
    );
    if (store.secondaryPath != null) {
      await _libraryService!.registerManagedLocalSubtitle(
        job.videoId!,
        path: store.secondaryPath!,
        kind: ManagedSubtitleAssetKind.translated,
        displayName: '翻译字幕',
        language: store.targetLanguage,
        sourceAssetId: original?.assetId,
      );
    }
  }

  bool _shouldSelectStream(_TranscriptionJob job) =>
      shouldSelectGeneratedSubtitles?.call(job.mediaKey) ??
      !job.subtitleSelectionOverridden;

  Future<StreamingSubtitleStore> _openCloudTranslationStream(
    _TranscriptionJob job,
    String srtPath,
    String sourceIdentity,
    _JobCancellation cancellation,
  ) async {
    var store = _streamStores[job.mediaKey];
    if (store == null && job.streamJournal != null) {
      store = await StreamingSubtitleStore.open(File(job.streamJournal!));
    }
    cancellation.throwIfCancelled();
    if (store != null) {
      if (!store.primaryComplete ||
          store.primaryPath != srtPath ||
          store.header['sourceIdentity'] != sourceIdentity) {
        throw StateError('原字幕已改变，请使用“重新生成”创建新字幕');
      }
      await store.recoverOutputs();
      await store.setPhase(SubtitleStreamPhase.generating);
    } else {
      final cues = await _readCompletedTranscript(srtPath);
      cancellation.throwIfCancelled();
      if (cues.isEmpty) throw StateError('没有识别出可用字幕');
      final generation = const Uuid().v4();
      job.streamJournal = p.join(
        _persistenceDirPath!,
        'model_streams',
        '$generation.jsonl',
      );
      final secondary = await const TaskSubtitleStorageService().allocateInside(
        File(srtPath).parent,
        '${p.basenameWithoutExtension(srtPath)}.translated.srt',
      );
      store = await StreamingSubtitleStore.create(
        File(job.streamJournal!),
        {
          'version': 1,
          'generationId': generation,
          'mediaKey': job.mediaKey,
          'videoPath': job.videoPath,
          'videoId': job.videoId,
          'primaryPath': srtPath,
          'secondaryPath': secondary,
          'primaryComplete': true,
          'sourceIdentity': sourceIdentity,
          'autoCache': job.autoCache,
          'job': job.toJson(),
        },
        completedPrimary: [
          for (var i = 0; i < cues.length; i++) cues[i].copyWith(index: i + 1),
        ],
      );
    }
    _streamStores[job.mediaKey] = store;
    _committedAudio = store.through;
    _emitStream(store);
    _scheduleSave();
    await _flushSave();
    cancellation.throwIfCancelled();
    return store;
  }

  Future<({String? path, String? language, String message})>
  _translateCloudStream(
    _TranscriptionJob job,
    StreamingSubtitleStore store,
    _JobCancellation cancellation,
  ) async {
    final input = job.translationInputPath ?? store.primaryPath;
    final text = await File(input).readAsString();
    final source = await (job.translateSmartPolicy == null
        ? _outputPreparer.parse(text)
        : _outputPreparer.parseTranslation(text));
    cancellation.throwIfCancelled();
    if (source.length != store.primary.snapshot.length) {
      throw StateError('翻译输入与原字幕不匹配，请重新生成');
    }
    // Window boundaries are deterministic across resume; validated entries
    // inside an interrupted window are retained by LocalTranscriptionStream.
    final cues = [
      for (var i = 0; i < source.length; i++) source[i].copyWith(index: i + 1),
    ];
    _translatingCurrent = true;
    var registered = false;
    final stream = LocalTranscriptionStream(
      openStore: () async => store,
      choice: TranscriptTranslateChoice(
        enabled: true,
        direction: job.translateDirection,
        provider: SubtitleTranslateProvider.local,
        aiOptions: job.translateAiOptions,
        sourceLanguage: job.translateSourceLanguage,
        targetLanguage: job.translateTargetLanguage,
        smartPolicy: job.translateSmartPolicy,
        localSpecification: job.translateLocalSpec,
      ),
      center: _modelCenter,
      translator: _translationService,
      punctuation: job.subtitlePunctuation!,
      cancelSignal: cancellation.whenCancelled,
      checkCancelled: cancellation.throwIfCancelled,
      onFailure: () {},
      onActivity: (value, note) {
        if (cancellation.isCancelled || _disposed) return;
        _translationProgress = store.secondary.snapshot.length / cues.length;
        _updateStatus(
          TranscriptionStatus.translating,
          '已同步 ${store.secondary.snapshot.length}/${cues.length} 条译文'
          '${note == null ? '' : ' · $note'}',
          _progressPlan.translation(_translationProgress!),
        );
      },
      onCommitted: (value, primary, secondary) async {
        _committedAudio = value.through;
        job.translatedSrtPath = value.secondaryPath;
        if (!registered) {
          try {
            await _registerStream(job, value);
            registered = true;
          } catch (error) {
            debugPrint('增量译文已保存，登记稍后重试：$error');
          }
        }
        _scheduleSave();
        if (!cancellation.isCancelled) {
          _emitStream(value, secondary: secondary);
          _translationProgress = value.secondary.snapshot.length / cues.length;
          _updateStatus(
            TranscriptionStatus.translating,
            '已同步 ${value.secondary.snapshot.length}/${cues.length} 条译文',
            _progressPlan.translation(_translationProgress!),
          );
        }
      },
    );
    try {
      for (final batch in cloudTranslationBatches(
        cues,
        maxCues: job.translateLocalSpec!.translation.batchSize,
      )) {
        await stream.accept(batch);
      }
      await stream.drain();
      cancellation.throwIfCancelled();
      return (
        path: store.secondaryPath,
        language: store.targetLanguage,
        message: '转录和翻译完成',
      );
    } finally {
      await stream.close();
      _translatingCurrent = false;
      _translationProgress = null;
    }
  }

  static bool _isLocalCancellationError(Object error) {
    if (error is! StateError) return false;
    var message = TranscriptionUserMessage.describe(error);
    const prefix = '本地识别：';
    if (message.startsWith(prefix)) {
      message = TranscriptionUserMessage.describe(
        StateError(message.substring(prefix.length)),
      );
    }
    return const {'转录已取消', '任务已取消'}.contains(message);
  }

  Future<StreamingSubtitleStore> _runLocalStream({
    required _TranscriptionJob job,
    required _PreparedAudioResult prepared,
    required String sourcePath,
    required String sourceIdentity,
    required _JobCancellation cancellation,
  }) async {
    final previous = _streamStores[job.mediaKey];
    StreamingSubtitleStore? store =
        job.streamJournal != null && previous?.journal.path == job.streamJournal
        ? previous
        : null;
    if (store == null && job.streamJournal != null) {
      store = await StreamingSubtitleStore.open(File(job.streamJournal!));
    }
    if (store != null && store.header['sourceIdentity'] != sourceIdentity) {
      throw StateError('源媒体已改变，请使用“重新生成”创建新字幕');
    }
    AiSubtitleApiSettings? endpoint;
    if (job.translateEnabled &&
        job.translateProviderName == SubtitleTranslateProvider.ai.name) {
      endpoint = await _translationEndpointFor(job);
    }
    Future<StreamingSubtitleStore> openStore() async {
      if (store != null) return store!;
      final primary = await _allocateStreamPath(job);
      final generation = const Uuid().v4();
      job.streamJournal = p.join(
        _persistenceDirPath!,
        'model_streams',
        '$generation.jsonl',
      );
      final secondary = job.translateEnabled
          ? await const TaskSubtitleStorageService().allocateInside(
              File(primary).parent,
              '${p.basenameWithoutExtension(primary)}.translated.srt',
            )
          : null;
      store = await StreamingSubtitleStore.create(File(job.streamJournal!), {
        'version': 1,
        'generationId': generation,
        'mediaKey': job.mediaKey,
        'videoPath': job.videoPath,
        'videoId': job.videoId,
        'primaryPath': primary,
        'secondaryPath': secondary,
        'sourceIdentity': sourceIdentity,
        'autoCache': job.autoCache,
        'job': job.toJson(),
      });
      _streamStores[job.mediaKey] = store!;
      _scheduleSave();
      _emitStream(store!);
      await _flushSave();
      return store!;
    }

    if (store != null) {
      _streamStores[job.mediaKey] = store!;
      await store!.recoverOutputs();
      _committedAudio = store!.through;
      await store!.setPhase(SubtitleStreamPhase.generating);
      _emitStream(store!);
    }
    final abort = Completer<void>();
    final pipelineSignal = Future.any<void>([
      cancellation.whenCancelled,
      abort.future,
    ]);
    var registered = store != null;
    final stream = LocalTranscriptionStream(
      openStore: openStore,
      choice: TranscriptTranslateChoice(
        enabled: job.translateEnabled,
        direction: job.translateDirection,
        provider: subtitleTranslateProviderFromName(job.translateProviderName),
        aiOptions: job.translateAiOptions,
        apiProviderId: job.translateApiProviderId,
        sourceLanguage: job.translateSourceLanguage,
        targetLanguage: job.translateTargetLanguage,
        apiEndpoint: job.translateEndpoint,
        smartPolicy: job.translateSmartPolicy,
        localSpecification: job.translateLocalSpec,
      ),
      endpoint: endpoint,
      center: _modelCenter,
      translator: _translationService,
      recognitionLanguage: job.modelSpec!.profile.language,
      punctuation: job.subtitlePunctuation!,
      cancelSignal: pipelineSignal,
      checkCancelled: cancellation.throwIfCancelled,
      onFailure: () {
        if (!abort.isCompleted) abort.complete();
      },
      onActivity: (value, message) {
        if (cancellation.isCancelled || _disposed) return;
        _translationProgress = value;
        _updateStatus(
          TranscriptionStatus.translating,
          message ?? '正在翻译当前字幕批次',
          _progress,
        );
      },
      onCommitted: (value, primary, secondary) async {
        _committedAudio = value.through;
        if (!registered) {
          try {
            await _registerStream(job, value);
          } catch (error) {
            debugPrint('增量字幕已保存，登记稍后重试：$error');
          }
          registered = true;
        }
        if (!cancellation.isCancelled) {
          _emitStream(value, primary: primary, secondary: secondary);
          if (!_disposed) notifyListeners();
        }
      },
    );
    try {
      for (var attempt = 0; ; attempt++) {
        cancellation.throwIfCancelled();
        try {
          await _transcribeWithModel(
            job: job,
            prepared: prepared,
            sourcePath: sourcePath,
            sourceIdentity: sourceIdentity,
            cancellation: cancellation,
            onStableBatch: stream.accept,
            pipelineCancelSignal: pipelineSignal,
            onSessionClose: stream.close,
            onConsumerIdle: stream.releaseLocalModels,
            consumerHasResidentModel: () => stream.hasLocalModel,
          );
          break;
        } catch (error) {
          // Drain pending Bing work before deciding whether the native worker
          // stopped independently. A translation failure retains its own cause.
          await stream.close();
          cancellation.throwIfCancelled();
          if (!job.translateEnabled ||
              job.translateProviderName !=
                  SubtitleTranslateProvider.bing.name ||
              stream.failure != null ||
              !_isLocalCancellationError(error)) {
            rethrow;
          }
          if (attempt >= 1) {
            throw StateError('本地转录意外中断，自动恢复后仍未成功。已完成的字幕和译文已保留，请重试继续');
          }
          // The runner has released its native owners. Reuse the same frozen
          // job/checkpoints and stream, whose committed cue IDs prevent repeats.
          debugPrint('本地转录内部中断，正在从已保存断点恢复：$error');
          _updateStatus(
            TranscriptionStatus.transcribing,
            '本地转录意外中断，正在从已保存断点恢复...',
            _progress,
          );
        }
      }
      await stream.drain();
      cancellation.throwIfCancelled();
      if (store == null || store!.primary.snapshot.isEmpty) {
        throw StateError('没有识别出可用字幕');
      }
      _committedAudio = _audioDuration;
      return store!;
    } catch (error) {
      await stream.close();
      if (store != null) {
        await store!.setPhase(
          cancellation.isCancelled
              ? SubtitleStreamPhase.paused
              : SubtitleStreamPhase.failed,
          cancellation.isCancelled ? '已停止并保留进度' : '生成中断，可继续生成',
        );
        if (!registered) await _registerStream(job, store!);
        _emitStream(store!);
      }
      cancellation.throwIfCancelled();
      if (stream.failure != null) throw stream.failure!;
      rethrow;
    } finally {
      await stream.close();
      _translationProgress = null;
    }
  }

  Future<void> _waitForRemoteRequestSlot(_JobCancellation cancellation) async {
    final nextAt = _nextRemoteRequestAt;
    if (nextAt == null) return;
    final remaining = nextAt.difference(DateTime.now());
    if (remaining <= Duration.zero) return;
    _updateStatus(
      TranscriptionStatus.extracting,
      '正在等待安全请求间隔（约 ${remaining.inSeconds + 1} 秒）...',
      0.0,
    );
    await cancellation.delay(remaining);
  }

  /// Translates the transcript when this job was started with that choice.
  /// A failure keeps the transcript and says so; it does not fail the task.
  Future<({String? path, String? language, String message})>
  _translateGeneratedSubtitle(
    _TranscriptionJob job,
    String srtPath,
    _JobCancellation cancellation,
  ) async {
    if (!job.translateEnabled) {
      return (path: null, language: null, message: '转录完成');
    }
    _translatingCurrent = true;
    _translationProgress = 0;
    void reportTranslation(String? activity) {
      if (cancellation.isCancelled || _disposed) return;
      final fraction = _translationProgress ?? 0;
      _updateStatus(
        TranscriptionStatus.translating,
        '翻译 ${(fraction * 100).floor()}%'
        '${activity == null || activity.isEmpty ? '' : ' · $activity'}',
        _progressPlan.translation(fraction),
      );
    }

    reportTranslation('正在准备翻译');
    try {
      cancellation.throwIfCancelled();
      final inputPath = job.translationInputPath ?? srtPath;
      final text = await File(inputPath).readAsString();
      cancellation.throwIfCancelled();
      final plan = resolveTranscriptTranslation(
        direction: job.translateDirection,
        subtitleText: text,
        sourceLanguage: job.translateSourceLanguage,
        targetLanguage: job.translateTargetLanguage,
      );
      final provider = subtitleTranslateProviderFromName(
        job.translateProviderName,
      );
      AiSubtitleApiSettings? endpoint;
      if (provider == SubtitleTranslateProvider.ai) {
        endpoint = await _translationEndpointFor(job);
      }
      final result = await _translationService.translateSubtitleFile(
        inputPath: srtPath,
        sourceText: text,
        outputPunctuation: job.subtitlePunctuation!,
        cancelSignal: cancellation.whenCancelled,
        sourceLanguage: plan.sourceLanguage,
        targetLanguage: plan.targetLanguage,
        provider: provider,
        smartPolicy: job.translateSmartPolicy,
        videoPath: job.videoPath,
        outputDirectory: p.dirname(srtPath),
        outputFilePrefix: p.basenameWithoutExtension(srtPath),
        aiOptions: job.translateAiOptions,
        aiEndpoint: endpoint,
        localSpecification: job.translateLocalSpec,
        checkpointScope: job.checkpointScope,
        onProgress: (progress) {
          if (cancellation.isCancelled || _disposed) return;
          _translationProgress = progress.clamp(0.0, 1.0);
        },
        onActivity: reportTranslation,
      );
      cancellation.throwIfCancelled();
      final message = plan.assumedSimplifiedChinese
          ? '转录完成，未能判断原文语言，已译为简体中文'
          : '转录完成';
      return (
        path: result.outputPath,
        language: job.translateSmartPolicy == null
            ? plan.targetLanguage
            : 'mul',
        message: message,
      );
    } on _JobCancelledException {
      rethrow;
    } catch (error) {
      cancellation.throwIfCancelled();
      debugPrint('转录后翻译失败: $error');
      final local =
          subtitleTranslateProviderFromName(job.translateProviderName) ==
          SubtitleTranslateProvider.local;
      return (
        path: null,
        language: null,
        message:
            '转录完成，翻译未成功'
            '${local ? '：${localTranslationFailureSummary(error)}' : ''}',
      );
    } finally {
      _translatingCurrent = false;
      _translationProgress = null;
    }
  }

  void _updateStatus(
    TranscriptionStatus status,
    String message,
    double progress,
  ) {
    if (status == TranscriptionStatus.translating &&
            _currentJob?.streamConfigurationFrozen != true ||
        status == TranscriptionStatus.embedding ||
        status == TranscriptionStatus.completed ||
        status == TranscriptionStatus.error ||
        status == TranscriptionStatus.idle) {
      _localAsrProgress = null;
    }
    _status = status;
    _statusMessage = message;
    _preparingMedia = status == TranscriptionStatus.downloading;
    _progress = TranscriptionProgressPlan.advance(_progress, progress, status);
    final key = _currentMediaKey;
    if (key != null) {
      _statusMessagesByMediaKey[key] = message;
    }
    if (!_disposed) notifyListeners();
  }

  String _formatTransferBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kib = bytes / 1024;
    if (kib < 1024) return '${kib.toStringAsFixed(1)} KB';
    final mib = kib / 1024;
    if (mib < 1024) return '${mib.toStringAsFixed(1)} MB';
    return '${(mib / 1024).toStringAsFixed(2)} GB';
  }

  Future<_MediaProbeInfo> _probeMedia(
    String mediaPath, [
    _JobCancellation? cancellation,
  ]) async {
    cancellation?.throwIfCancelled();
    final isAudioInput = _looksLikeAudioInput(mediaPath);
    Object? lastError;
    try {
      if (_mediaProbe != null) {
        final info = await _mediaProbe(mediaPath);
        cancellation?.throwIfCancelled();
        if (info != null) {
          return _parseMediaProbeInfo(info, isAudioInput: isAudioInput);
        }
      } else if (FFmpegUtils.preferSystemFfmpeg) {
        final ffprobePath = await FFmpegUtils.ffprobePath;
        final probeProcess = await Process.start(ffprobePath, [
          '-v',
          'quiet',
          '-print_format',
          'json',
          '-show_streams',
          '-show_format',
          mediaPath,
        ]);

        final stdoutBuffer = StringBuffer();
        final stderrBuffer = StringBuffer();
        final stdoutSub = probeProcess.stdout
            .transform(utf8.decoder)
            .listen(stdoutBuffer.write);
        final stderrSub = probeProcess.stderr
            .transform(utf8.decoder)
            .listen(stderrBuffer.write);

        String? abortReason;
        final probeStartedAt = DateTime.now();
        final probeTimer = Timer.periodic(const Duration(milliseconds: 250), (
          _,
        ) {
          if (abortReason != null) return;
          if (cancellation?.isCancelled == true) {
            abortReason = cancellation!.reason;
            probeProcess.kill();
          } else if (DateTime.now().difference(probeStartedAt) >
              const Duration(seconds: 12)) {
            abortReason = 'ffprobe 探测超时，已强制终止';
            probeProcess.kill();
          }
        });

        final exitCode = await probeProcess.exitCode;
        probeTimer.cancel();
        await stdoutSub.cancel();
        await stderrSub.cancel();

        cancellation?.throwIfCancelled();
        if (abortReason != null) {
          lastError = StateError(abortReason!);
        } else if (exitCode == 0) {
          try {
            return _parseMediaProbeInfo(
              jsonDecode(stdoutBuffer.toString()) as Map<String, dynamic>,
              isAudioInput: isAudioInput,
            );
          } catch (e) {
            lastError = e;
          }
        } else {
          lastError = StateError(
            'ffprobe 退出码 $exitCode: ${_summarizeText(stderrBuffer.toString(), fallback: "未知错误")}',
          );
        }
        final fallbackInfo = await _probeMediaWithFfmpegCli(
          mediaPath,
          isAudioInput: isAudioInput,
          cancellation: cancellation,
        );
        if (fallbackInfo != null) {
          return fallbackInfo;
        }
      } else {
        // Do not use FFmpegKit.cancel() without a session id here: it cancels
        // unrelated playback/download/compose work in the same process.
        final session = await FFprobeKit.getMediaInformation(mediaPath);
        cancellation?.throwIfCancelled();
        final info = session.getMediaInformation();
        if (info != null) {
          return _parseMediaProbeInfo({
            'streams': [
              for (final stream in info.getStreams()) stream.getAllProperties(),
            ],
            'format': {'duration': info.getDuration()},
          }, isAudioInput: isAudioInput);
        }
      }
    } catch (e) {
      if (e is _JobCancelledException) rethrow;
      lastError = e;
      if (_mediaProbe == null && FFmpegUtils.preferSystemFfmpeg) {
        final fallbackInfo = await _probeMediaWithFfmpegCli(
          mediaPath,
          isAudioInput: isAudioInput,
          cancellation: cancellation,
        );
        if (fallbackInfo != null) {
          return fallbackInfo;
        }
      }
    }
    debugPrint("探测媒体音频信息失败: ${lastError ?? '未知错误'}");
    return _MediaProbeInfo(
      codec: null,
      durationSeconds: null,
      // Some damaged/unusual containers cannot be probed but FFmpeg can still
      // decode them. Let the extraction attempt decide instead of rejecting a
      // valid source solely because metadata probing failed.
      hasAudioStream: true,
      isAudioInput: isAudioInput,
    );
  }

  _MediaProbeInfo _parseMediaProbeInfo(
    Map<String, dynamic> json, {
    required bool isAudioInput,
  }) {
    final streams = (json['streams'] as List?) ?? const [];
    String? codec;
    int? channels;
    int? audioBitRate;
    double? audioStartSeconds;
    int audioStreams = 0;
    var describedStreams = 0;
    bool hasVideo = false;
    bool hasCover = false;
    bool hasAudioStream = false;
    for (final stream in streams) {
      if (stream is! Map) continue;
      if (const {
        'audio',
        'video',
        'subtitle',
        'data',
        'attachment',
      }.contains(stream['codec_type']?.toString())) {
        describedStreams++;
      }
      if (stream['codec_type']?.toString() == 'audio') {
        audioStreams++;
        if (!hasAudioStream) {
          hasAudioStream = true;
          codec = stream['codec_name']?.toString().toLowerCase();
          channels = int.tryParse('${stream['channels']}');
          audioBitRate = int.tryParse('${stream['bit_rate']}');
          audioStartSeconds = _parseDurationSeconds(stream['start_time']);
        }
      } else if (stream['codec_type']?.toString() == 'video') {
        final disposition = stream['disposition'];
        if (disposition is! Map || '${disposition['attached_pic']}' != '1') {
          hasVideo = true;
        } else {
          hasCover = true;
        }
      }
    }
    final format = json['format'];
    final durationSeconds = _parseDurationSeconds(
      format is Map ? format['duration'] : null,
    );
    final mediaStart =
        _parseDurationSeconds(format is Map ? format['start_time'] : null) ?? 0;
    final audioOffset =
        audioStartSeconds != null &&
            audioStartSeconds.isFinite &&
            mediaStart.isFinite
        ? math.max(0.0, audioStartSeconds - mediaStart)
        : 0.0;
    return _MediaProbeInfo(
      codec: codec,
      channels: channels,
      audioBitRate: audioBitRate,
      audioStartOffsetSeconds: audioOffset,
      audioStreams: audioStreams,
      hasVideo: hasVideo,
      durationSeconds: durationSeconds,
      // Missing/unknown streams or cover art alone are inconclusive metadata.
      // The bounded decoder attempt will decide whether audio is available.
      hasAudioStream:
          hasAudioStream || describedStreams == 0 || (hasCover && !hasVideo),
      isAudioInput: isAudioInput,
    );
  }

  Future<_MediaProbeInfo?> _probeMediaWithFfmpegCli(
    String mediaPath, {
    required bool isAudioInput,
    _JobCancellation? cancellation,
  }) async {
    try {
      cancellation?.throwIfCancelled();
      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      final process = await Process.start(ffmpegPath, [
        '-hide_banner',
        '-i',
        mediaPath,
      ]);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutSub = process.stdout
          .transform(utf8.decoder)
          .listen(stdoutBuffer.write);
      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .listen(stderrBuffer.write);
      String? abortReason;
      final startedAt = DateTime.now();
      final monitor = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (abortReason != null) return;
        if (cancellation?.isCancelled == true) {
          abortReason = cancellation!.reason;
          process.kill();
        } else if (DateTime.now().difference(startedAt) >
            const Duration(seconds: 12)) {
          abortReason = 'ffmpeg 回退探测超时';
          process.kill();
        }
      });
      await process.exitCode;
      monitor.cancel();
      await stdoutSub.cancel();
      await stderrSub.cancel();
      cancellation?.throwIfCancelled();
      if (abortReason != null) return null;
      final combinedOutput =
          '${stderrBuffer.toString()}\n${stdoutBuffer.toString()}'.replaceAll(
            '\r',
            '\n',
          );
      final audioLines = RegExp(
        r'^\s*Stream #.*Audio:[^\r\n]*',
        multiLine: true,
      ).allMatches(combinedOutput).toList();
      final hasAudioStream = audioLines.isNotEmpty;
      if (!hasAudioStream && !isAudioInput) {
        return null;
      }

      final codecMatch = RegExp(
        r'Audio:\s*([A-Za-z0-9_]+)',
      ).firstMatch(combinedOutput);
      final durationMatch = RegExp(
        r'Duration:\s*(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
      ).firstMatch(combinedOutput);
      double? durationSeconds;
      if (durationMatch != null) {
        final hours = int.tryParse(durationMatch.group(1) ?? '') ?? 0;
        final minutes = int.tryParse(durationMatch.group(2) ?? '') ?? 0;
        final seconds = double.tryParse(durationMatch.group(3) ?? '') ?? 0;
        durationSeconds = hours * 3600 + minutes * 60 + seconds;
      }

      final audioBitRate = double.tryParse(
        audioLines.isEmpty
            ? ''
            : RegExp(
                    r'(\d+(?:\.\d+)?) kb/s',
                  ).firstMatch(audioLines.first[0]!)?[1] ??
                  '',
      );

      return _MediaProbeInfo(
        codec: codecMatch?.group(1)?.toLowerCase(),
        channels: RegExp(r'Audio:[^\r\n]*\bmono\b').hasMatch(combinedOutput)
            ? 1
            : RegExp(r'Audio:[^\r\n]*\bstereo\b').hasMatch(combinedOutput)
            ? 2
            : null,
        durationSeconds: durationSeconds,
        audioBitRate: audioBitRate == null
            ? null
            : (audioBitRate * 1000).round(),
        audioStreams: audioLines.length,
        hasVideo: RegExp(r'^\s*Stream #.*Video:[^\r\n]*', multiLine: true)
            .allMatches(combinedOutput)
            .any((line) => !line[0]!.contains('attached pic')),
        hasAudioStream: hasAudioStream || isAudioInput,
        isAudioInput: isAudioInput,
      );
    } catch (e) {
      if (e is _JobCancelledException) rethrow;
      debugPrint("ffmpeg CLI 回退探测失败: $e");
      return null;
    }
  }

  Future<_PreparedAudioResult> _prepareAudioForTranscription(
    String mediaPath,
    _JobCancellation cancellation, {
    bool normalizeUnknownDuration = false,
    bool audioExpected = false,
  }) async {
    cancellation.throwIfCancelled();
    if (itemNeedsOnlineMaterialization(path: mediaPath)) {
      throw StateError('在线媒体的音频来源尚未准备完成，请重试音频下载');
    }
    final uri = Uri.tryParse(mediaPath);
    final remote = uri?.scheme == 'http' || uri?.scheme == 'https';
    if (!remote &&
        (uri == null ||
            uri.scheme.isEmpty ||
            uri.scheme == 'file' ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(mediaPath))) {
      final source = uri?.scheme == 'file'
          ? File.fromUri(uri!)
          : File(mediaPath);
      if (!await source.exists()) {
        throw StateError('媒体文件不存在或已不可访问，请重新定位文件后重试');
      }
      if (await source.length() == 0) {
        throw StateError('媒体文件为空，音频可能尚未下载完成，请重试');
      }
    }
    final probe = await _probeMedia(mediaPath, cancellation);
    cancellation.throwIfCancelled();
    // Audio playback sources and audio files can return partial metadata (for
    // example only their cover image). Defer to decoding in that case too.
    if (!probe.hasAudioStream && !audioExpected && !probe.isAudioInput) {
      throw Exception("媒体无音轨，无法生成字幕");
    }
    final seconds = probe.durationSeconds;
    if (normalizeUnknownDuration &&
        (seconds == null || !seconds.isFinite || seconds <= 0)) {
      // A compressed input's size is not a safe proxy for its duration.
      // Preserve complete extraction for unprobeable media, then probe the
      // normalized output before planning slices; otherwise a low-rate input
      // can be estimated too short and lose its remaining timeline.
      final maxAttempts = probe.isAudioInput ? 2 : 3;
      for (var attempt = 1; ; attempt++) {
        final output = await _createManagedTempAudioPath();
        try {
          cancellation.throwIfCancelled();
          _updateStatus(
            TranscriptionStatus.extracting,
            '未能读取音频时长，正在完整准备音频...',
            _progressPlan.preparation(0),
          );
          await _extractAudioToPath(
            mediaPath,
            output,
            useCopy: false,
            probe: probe,
            cancellation: cancellation,
          );
          cancellation.throwIfCancelled();
          if (await _safeFileSize(File(output)) < 800) {
            throw const _AudioPreparationException('提取出的音频过短', retryable: true);
          }
          final normalizedProbe = await _probeMedia(output, cancellation);
          cancellation.throwIfCancelled();
          return _PreparedAudioResult(
            audioPath: output,
            probe: normalizedProbe,
            isTemporary: true,
            compatibilityAudio: true,
          );
        } catch (error) {
          await _deleteFileIfExists(output);
          if (error is _JobCancelledException) rethrow;
          final retryable = error is _AudioPreparationException
              ? error.retryable
              : !probe.isAudioInput;
          if (!retryable || attempt >= maxAttempts) rethrow;
          await cancellation.delay(Duration(milliseconds: 600 * attempt));
        }
      }
    }
    // Keep preparation lazy for every service. Completed slices and remote
    // tasks must be restored before starting any extraction or conversion.
    return _PreparedAudioResult(audioPath: mediaPath, probe: probe);
  }

  bool _looksLikeAudioInput(String mediaPath) {
    return LibraryService.supportedAudioExtensions.contains(
      p.extension(mediaPath).toLowerCase(),
    );
  }

  double? _parseDurationSeconds(Object? rawValue) {
    if (rawValue == null) return null;
    if (rawValue is num) return rawValue.toDouble();
    return double.tryParse(rawValue.toString());
  }

  Duration _buildExtractionTimeout(
    _MediaProbeInfo probe, {
    required bool useCopy,
  }) {
    final seconds = probe.durationSeconds ?? 0;
    final int rounded = seconds.isFinite ? seconds.ceil() : 0;
    final int baseSeconds;
    final int scaleSeconds;
    if (useCopy) {
      baseSeconds = probe.isAudioInput ? 30 : 45;
      scaleSeconds = (rounded * 0.35).ceil();
    } else {
      baseSeconds = probe.isAudioInput ? 60 : 90;
      scaleSeconds = (rounded * 0.5).ceil();
    }
    final totalSeconds = (baseSeconds + scaleSeconds).clamp(45, 1800);
    return Duration(seconds: totalSeconds);
  }

  Duration _buildInactivityTimeout({required bool useCopy}) {
    return Duration(seconds: useCopy ? 20 : 35);
  }

  Future<void> _extractAudioToPath(
    String mediaPath,
    String audioPath, {
    required bool useCopy,
    required _MediaProbeInfo probe,
    required _JobCancellation cancellation,
    Duration? seekStart,
    Duration? takeDuration,
    Duration? inactivityTimeout,
    void Function(double ratio)? onProgress,
    bool pcm = false,
    bool cloudMp3 = false,
    AsrAudioChannel channel = AsrAudioChannel.mix,
  }) async {
    requireCommunityLocalMedia(mediaPath);
    final args = <String>[
      '-y',
      '-nostdin',
      '-hide_banner',
      '-loglevel',
      'warning',
      '-progress',
      'pipe:2',
      '-nostats',
      '-thread_queue_size',
      '512',
    ];
    // 先定位再读输入，避免每一段都把长文件从头解码一遍。
    if (seekStart != null && seekStart > Duration.zero) {
      args.addAll(['-ss', _ffmpegSeconds(seekStart)]);
    }
    if (takeDuration != null) {
      args.addAll(['-t', _ffmpegSeconds(takeDuration)]);
    }
    args.addAll(['-i', mediaPath, '-map', '0:a:0', '-vn', '-sn', '-dn']);
    if (useCopy) {
      args.addAll(['-c:a', 'copy']);
    } else {
      if (cloudMp3) {
        // Keep the source clock, including silence before a delayed audio
        // track. Plain extraction otherwise rebases its first sample to zero.
        args.addAll(['-af', 'aresample=async=1:first_pts=0']);
      }
      if (channel != AsrAudioChannel.mix) {
        final selected = channel == AsrAudioChannel.right && probe.channels != 1
            ? 1
            : 0;
        args.addAll(['-af', 'pan=mono|c0=c$selected']);
      }
      // Speech recognition does not benefit from multi-channel/high-rate
      // audio. A single encoder thread leaves CPU headroom for media playback.
      args.addAll([
        '-c:a',
        pcm
            ? 'pcm_s16le'
            : cloudMp3
            ? 'libmp3lame'
            : 'aac',
        '-ac',
        '1',
        '-ar',
        '16000',
        if (!pcm) ...['-b:a', cloudMp3 ? '64k' : '48k'],
        '-threads',
        '1',
      ]);
    }
    if (seekStart != null && seekStart > Duration.zero) {
      args.addAll(['-reset_timestamps', '1']);
    }
    args.add(audioPath);

    final timeout = _buildExtractionTimeout(probe, useCopy: useCopy);
    final resolvedInactivity =
        inactivityTimeout ?? _buildInactivityTimeout(useCopy: useCopy);
    final totalSeconds = takeDuration == null
        ? probe.durationSeconds
        : takeDuration.inMilliseconds / 1000.0;
    void reportTime(Duration processed) {
      if (cancellation.isCancelled ||
          totalSeconds == null ||
          !totalSeconds.isFinite ||
          totalSeconds <= 0) {
        return;
      }
      onProgress?.call(
        (processed.inMicroseconds / (totalSeconds * 1000000)).clamp(0.0, 1.0),
      );
    }

    debugPrint(
      "准备音频: codec=${probe.codec}, isAudio=${probe.isAudioInput}, useCopy=$useCopy, timeout=${timeout.inSeconds}s",
    );

    if (FFmpegUtils.preferSystemFfmpeg) {
      await FFmpegUtils.ensureAvailable();
      await _runWindowsFfmpeg(
        args,
        timeout: timeout,
        inactivityTimeout: resolvedInactivity,
        cancellation: cancellation,
        onProcessed: reportTime,
      );
      return;
    }

    await _runFfmpegKit(
      args,
      timeout: timeout,
      inactivityTimeout: resolvedInactivity,
      cancellation: cancellation,
      onProcessed: reportTime,
    );
  }

  Future<void> _runWindowsFfmpeg(
    List<String> args, {
    required Duration timeout,
    required Duration inactivityTimeout,
    required _JobCancellation cancellation,
    void Function(Duration processed)? onProcessed,
  }) async {
    final ffmpegPath = await FFmpegUtils.ffmpegPath;
    final process = await Process.start(ffmpegPath, args);
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final startedAt = DateTime.now();
    DateTime lastActivityAt = startedAt;
    String? abortReason;
    bool killRequested = false;
    var progressTail = '';

    void recordOutput(List<int> data, StringBuffer buffer) {
      if (data.isEmpty) return;
      lastActivityAt = DateTime.now();
      final text = utf8.decode(data, allowMalformed: true);
      buffer.write(text);
      if (identical(buffer, stderrBuffer) && onProcessed != null) {
        final lines = (progressTail + text).split('\n');
        progressTail = lines.removeLast();
        for (final line in lines) {
          if (!line.startsWith('out_time_us=')) continue;
          final microseconds = int.tryParse(line.substring(12).trim());
          if (microseconds != null) {
            onProcessed(Duration(microseconds: microseconds));
          }
        }
      }
    }

    final stdoutSub = process.stdout.listen(
      (data) => recordOutput(data, stdoutBuffer),
    );
    final stderrSub = process.stderr.listen(
      (data) => recordOutput(data, stderrBuffer),
    );
    final monitor = Timer.periodic(const Duration(seconds: 1), (_) {
      if (killRequested) return;
      final now = DateTime.now();
      if (cancellation.isCancelled) {
        abortReason = cancellation.reason;
        killRequested = true;
        process.kill();
      } else if (now.difference(lastActivityAt) > inactivityTimeout) {
        abortReason = "FFmpeg 输出长时间无变化，已自动中断";
        killRequested = true;
        process.kill();
      } else if (now.difference(startedAt) > timeout) {
        abortReason = "FFmpeg 提取超时，已自动中断";
        killRequested = true;
        process.kill();
      }
    });

    try {
      final exitCode = await process.exitCode;
      cancellation.throwIfCancelled();
      if (abortReason != null) {
        throw _AudioPreparationException(abortReason!, retryable: true);
      }
      if (exitCode != 0) {
        final errorText = _summarizeProcessLogs(stdoutBuffer, stderrBuffer);
        throw _AudioPreparationException(
          "FFmpeg 提取失败: $errorText",
          retryable: true,
        );
      }
    } finally {
      monitor.cancel();
      await stdoutSub.cancel();
      await stderrSub.cancel();
    }
  }

  Future<void> _runFfmpegKit(
    List<String> args, {
    required Duration timeout,
    required Duration inactivityTimeout,
    required _JobCancellation cancellation,
    void Function(Duration processed)? onProcessed,
  }) async {
    final completer = Completer<dynamic>();
    final startedAt = DateTime.now();
    DateTime lastActivityAt = startedAt;
    bool cancelRequested = false;
    String? cancelReason;

    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        if (!completer.isCompleted) {
          completer.complete(session);
        }
      },
      (_) {
        lastActivityAt = DateTime.now();
      },
      (statistics) {
        lastActivityAt = DateTime.now();
        onProcessed?.call(Duration(milliseconds: statistics.getTime().round()));
      },
    );

    final monitor = Timer.periodic(const Duration(seconds: 1), (_) {
      if (cancelRequested) return;
      final now = DateTime.now();
      if (cancellation.isCancelled) {
        cancelRequested = true;
        cancelReason = cancellation.reason;
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      } else if (now.difference(lastActivityAt) > inactivityTimeout) {
        cancelRequested = true;
        cancelReason = "FFmpeg 输出长时间无变化，已自动中断";
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      } else if (now.difference(startedAt) > timeout) {
        cancelRequested = true;
        cancelReason = "FFmpeg 提取超时，已自动中断";
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      }
    });

    try {
      final completedSession = await completer.future;
      cancellation.throwIfCancelled();
      final returnCode = await completedSession.getReturnCode();
      if (cancelRequested || ReturnCode.isCancel(returnCode)) {
        final logs = await completedSession.getAllLogsAsString();
        throw _AudioPreparationException(
          cancelReason ?? _summarizeText(logs, fallback: "FFmpeg 任务已取消"),
          retryable: true,
        );
      }
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await completedSession.getAllLogsAsString();
        throw _AudioPreparationException(
          "FFmpeg 提取失败: ${_summarizeText(logs, fallback: '未知错误')}",
          retryable: true,
        );
      }
    } finally {
      monitor.cancel();
    }
  }

  String _summarizeProcessLogs(
    StringBuffer stdoutBuffer,
    StringBuffer stderrBuffer,
  ) {
    final stderrText = stderrBuffer.toString().trim();
    if (stderrText.isNotEmpty) {
      return _summarizeText(stderrText, fallback: "未知错误");
    }
    final stdoutText = stdoutBuffer.toString().trim();
    return _summarizeText(stdoutText, fallback: "未知错误");
  }

  String _summarizeText(String text, {required String fallback}) {
    final normalized = text
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (normalized.isEmpty) return fallback;
    return normalized.length > 4
        ? normalized.sublist(normalized.length - 4).join(' | ')
        : normalized.join(' | ');
  }

  Future<Directory> _managedTempAudioDirectory() async {
    final tempDir = await getTemporaryDirectory();
    final dir = Directory(p.join(tempDir.path, _managedTempAudioDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _createManagedTempAudioPath({String extension = 'm4a'}) async {
    final dir = await _managedTempAudioDirectory();
    return p.join(
      dir.path,
      '$_managedTempAudioPrefix${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
  }

  Future<void> _cleanupManagedTempAudioDirectory() async {
    try {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, _managedTempAudioDirName),
      );
      if (!await dir.exists()) {
        return;
      }
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        try {
          if (entity is File) {
            await entity.delete();
          } else if (entity is Directory) {
            await entity.delete(recursive: true);
          }
        } catch (e) {
          debugPrint("清理临时音频目录成员失败: $e");
        }
      }
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    } catch (e) {
      debugPrint("清理临时音频目录失败: $e");
    }
  }

  Future<List<File>> _listManagedTempAudioFiles() async {
    try {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, _managedTempAudioDirName),
      );
      if (!await dir.exists()) {
        return const <File>[];
      }
      final files = <File>[];
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          files.add(entity);
        }
      }
      return files;
    } catch (e) {
      debugPrint("列出临时音频目录失败: $e");
      return const <File>[];
    }
  }

  Future<int> _safeFileSize(File file) async {
    try {
      if (!await file.exists()) {
        return 0;
      }
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _deleteFileIfExists(String path) async {
    final file = File(path);
    if (!await file.exists()) return;
    try {
      await file.delete();
    } catch (e) {
      debugPrint("删除文件失败: $path, $e");
    }
  }

  // 生成 SRT 格式
  /// Clarify empty-SRT failures: no ASR text vs Linux host with no sound card.
  Future<String> _emptyTranscriptionFailureMessage() async {
    if (UniversalPlatform.isLinux) {
      final hasOutput = await LinuxAudioDevice.hasLinuxAudioOutput();
      if (!hasOutput) {
        return '本机无音频设备，抽音频/识别可能失败';
      }
    }
    return '识别结果为空，无法生成字幕（可能为无声或静音）';
  }

  // 保存 SRT 文件
  Future<String> _saveSrtFile(
    String videoPath,
    String srtContent, {
    String? videoId,
  }) async {
    try {
      if (srtContent.trim().isEmpty) {
        throw Exception(await _emptyTranscriptionFailureMessage());
      }

      if (_currentJobIsExternal) {
        // Output location is resolved at the last reversible boundary instead
        // of when the task was enqueued. A setting changed while extraction,
        // upload, or recognition is running therefore applies to this task.
        final strategy = _settings.batchSubtitleOutputPathStrategy;
        final customOutputDir = _settings.batchSubtitleCustomOutputDir;
        if (strategy == SubtitleOutputPathStrategy.customDirectory &&
            customOutputDir != null &&
            customOutputDir.isNotEmpty) {
          try {
            final customDir = Directory(customOutputDir);
            if (!await customDir.exists()) {
              await customDir.create(recursive: true);
            }
            final fileName = _aiSubtitleFileName(videoPath);
            final srtPath = p.join(customDir.path, fileName);
            await File(srtPath).writeAsString(srtContent);
            debugPrint("外部视频AI字幕已保存到指定目录: $srtPath");
            return srtPath;
          } catch (e) {
            debugPrint("保存字幕到指定目录失败，回退到私有目录: $e");
          }
        }

        try {
          final videoFile = File(videoPath);
          if (await videoFile.exists()) {
            final dir = videoFile.parent.path;
            final fileName = _aiSubtitleFileName(videoPath);
            final srtPath = p.join(dir, fileName);
            await File(srtPath).writeAsString(srtContent);
            debugPrint("外部视频AI字幕已保存到视频同目录: $srtPath");
            return srtPath;
          }
        } catch (e) {
          debugPrint("保存字幕到视频同目录失败，回退到私有目录: $e");
        }
      }

      final trimmedVideoId = videoId?.trim() ?? '';
      if (trimmedVideoId.isEmpty) {
        throw StateError('媒体库转录任务缺少 videoId');
      }
      // Online Bilibili parts share one folder. Other cards keep their own.
      final library = _libraryService;
      final srtPath = library == null
          ? await const TaskSubtitleStorageService().allocatePath(
              trimmedVideoId,
              'ai.srt',
            )
          : await library.allocateSubtitleFile(trimmedVideoId, 'ai.srt');

      await File(srtPath).writeAsString(srtContent);
      debugPrint("AI字幕已保存到私有目录: $srtPath");

      return srtPath;
    } catch (e) {
      debugPrint("保存字幕到私有目录失败: $e");
      if (!_currentJobIsExternal) {
        throw Exception("保存任务字幕文件失败: $e");
      }
      try {
        final videoFile = File(videoPath);
        final dir = videoFile.parent.path;
        final fallbackFileName = _aiSubtitleFileName(
          videoPath,
          videoId: videoId,
        );
        final srtPath = p.join(dir, fallbackFileName);
        await File(srtPath).writeAsString(srtContent);
        debugPrint("AI字幕已保存到视频目录: $srtPath");
        return srtPath;
      } catch (e2) {
        throw Exception("保存字幕文件失败: $e");
      }
    }
  }

  String _durationLabelForJob(_TranscriptionJob job) {
    final saved = _nonEmpty(job.durationLabel);
    if (saved != null) return saved;
    if (job.isExternal || job.videoId == null) return '';
    final item = (job.libraryService ?? LibraryService()).getVideo(
      job.videoId!,
    );
    return formatMediaDurationLabel(item?.durationMs ?? 0);
  }

  List<BatchSubtitleTaskView> getQueueSnapshot() {
    final tasks = <BatchSubtitleTaskView>[];

    if (isProcessing && _currentVideoPath != null && !_currentTaskRemoved) {
      final currentKey = _currentMediaKey;
      if (currentKey != null) {
        final videoName =
            _currentJob?.displayName ?? p.basename(_currentVideoPath!);
        final perJobMessage =
            _statusMessagesByMediaKey[currentKey] ?? _statusMessage;
        tasks.add(
          BatchSubtitleTaskView(
            mediaKey: currentKey,
            videoPath: _currentVideoPath!,
            videoId: _currentVideoId,
            videoName: videoName,
            videoDuration: _currentJob == null
                ? ''
                : _durationLabelForJob(_currentJob!),
            isExternal: _currentJobIsExternal,
            status: _status,
            progress: _progress,
            translationProgress: _translationProgress,
            localAsrProgress: _localAsrProgress,
            audioProgress: localAudioProgress,
            statusMessage: perJobMessage,
            createdAt: _currentJobCreatedAt,
            outputPathStrategy: _currentJobIsExternal
                ? _settings.batchSubtitleOutputPathStrategy
                : _currentJobOutputPathStrategy,
            customOutputDir: _currentJobIsExternal
                ? _settings.batchSubtitleCustomOutputDir
                : _currentJobCustomOutputDir,
            isStarted: true,
          ),
        );
      }
    }

    int queueIdx = 0;
    for (final job in _orderedPendingJobs) {
      queueIdx++;
      final videoName = job.displayName;
      final isStarted = _startedMediaKeys.contains(job.mediaKey);
      // If started and waiting, compute queue position (1-based, after active job)
      final int effectiveQueuePos = isStarted
          ? (processingCount + queueIdx)
          : 0;
      tasks.add(
        BatchSubtitleTaskView(
          mediaKey: job.mediaKey,
          videoPath: job.videoPath,
          videoId: job.videoId,
          videoName: videoName,
          videoDuration: _durationLabelForJob(job),
          isExternal: job.isExternal,
          status: TranscriptionStatus.idle,
          progress: 0.0,
          statusMessage: isStarted
              ? '已加入队列，当前顺位：$effectiveQueuePos'
              : (_statusMessagesByMediaKey[job.mediaKey] ?? ''),
          createdAt: job.createdAt,
          outputPathStrategy: job.isExternal
              ? _settings.batchSubtitleOutputPathStrategy
              : job.outputPathStrategy,
          customOutputDir: job.isExternal
              ? _settings.batchSubtitleCustomOutputDir
              : job.customOutputDir,
          isStarted: isStarted,
        ),
      );
    }

    for (final entry in _failedJobs.entries) {
      final job = entry.value;
      final videoName = job.displayName;
      final failMsg = _statusMessagesByMediaKey[entry.key] ?? _statusMessage;
      tasks.add(
        BatchSubtitleTaskView(
          mediaKey: entry.key,
          videoPath: job.videoPath,
          videoId: job.videoId,
          videoName: videoName,
          videoDuration: _durationLabelForJob(job),
          isExternal: job.isExternal,
          status: TranscriptionStatus.error,
          progress: 0.0,
          statusMessage: failMsg.isNotEmpty ? failMsg : '转录失败',
          createdAt: job.createdAt,
          outputPathStrategy: job.outputPathStrategy,
          customOutputDir: job.customOutputDir,
        ),
      );
    }

    for (final entry in _completedJobs.entries) {
      final job = entry.value;
      final videoName = job.displayName;
      final completeMsg = _statusMessagesByMediaKey[entry.key] ?? '转录完成';
      tasks.add(
        BatchSubtitleTaskView(
          mediaKey: entry.key,
          videoPath: job.videoPath,
          videoId: job.videoId,
          videoName: videoName,
          videoDuration: _durationLabelForJob(job),
          isExternal: job.isExternal,
          status: TranscriptionStatus.completed,
          progress: 1.0,
          statusMessage: completeMsg,
          createdAt: job.createdAt,
          outputPathStrategy: job.outputPathStrategy,
          customOutputDir: job.customOutputDir,
        ),
      );
    }

    final byKey = <String, BatchSubtitleTaskView>{
      for (final task in tasks) task.mediaKey: task,
    };
    final ordered = <BatchSubtitleTaskView>[];
    for (final key in _taskOrder) {
      final task = byKey.remove(key);
      if (task != null) ordered.add(task);
    }
    ordered.addAll(byKey.values);
    return orderBatchSubtitleTasks(ordered);
  }

  /// A player status indicator needs one task, not a copy of the whole queue
  /// on every playback notification. The saved id remains authoritative.
  BatchSubtitleTaskView? taskSnapshotForVideo(String path, {String? videoId}) {
    final key = _mediaKey(path, videoId: videoId);
    final job = _jobForKey(key);
    if (job == null || (_currentMediaKey == key && _currentTaskRemoved)) {
      return null;
    }
    final running = _currentMediaKey == key && isProcessing;
    final scheduled =
        _queuedMediaKeys.contains(key) && _startedMediaKeys.contains(key);
    final failed = _failedJobs.containsKey(key);
    final completed = _completedJobs.containsKey(key);
    return BatchSubtitleTaskView(
      mediaKey: key,
      videoPath: job.videoPath,
      videoId: job.videoId,
      videoName: job.displayName,
      videoDuration: _durationLabelForJob(job),
      isExternal: job.isExternal,
      status: running
          ? _status
          : failed
          ? TranscriptionStatus.error
          : completed
          ? TranscriptionStatus.completed
          : TranscriptionStatus.idle,
      progress: running
          ? _progress
          : completed
          ? 1
          : 0,
      translationProgress: running ? _translationProgress : null,
      localAsrProgress: running ? _localAsrProgress : null,
      audioProgress: running ? localAudioProgress : null,
      statusMessage: scheduled
          ? '已加入队列，当前顺位：${queuePositionForVideo(path, videoId: videoId)}'
          : _statusMessagesByMediaKey[key] ??
                (running
                    ? _statusMessage
                    : completed
                    ? '转录完成'
                    : failed
                    ? '转录失败'
                    : '等待处理'),
      createdAt: job.createdAt,
      outputPathStrategy: job.outputPathStrategy,
      customOutputDir: job.customOutputDir,
      isStarted: running || _startedMediaKeys.contains(key),
    );
  }

  bool removeFromQueue(String mediaKey) {
    if (_currentMediaKey == mediaKey && isProcessing) {
      _currentTaskRemoved = true;
      _currentCancellation?.cancel('用户取消并删除了任务');
      _removeTaskRecords(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    final queueIndex = _queue.indexWhere((job) => job.mediaKey == mediaKey);
    if (queueIndex >= 0) {
      final removed = _queue.removeAt(queueIndex);
      unawaited(_discardCheckpoint(removed.checkpointKey));
      _queuedMediaKeys.remove(mediaKey);
      _startedMediaKeys.remove(mediaKey);
      _failedJobs.remove(mediaKey);
      _completedJobs.remove(mediaKey);
      _statusMessagesByMediaKey.remove(mediaKey);
      _taskOrder.remove(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    if (_failedJobs.containsKey(mediaKey)) {
      final removed = _failedJobs.remove(mediaKey)!;
      unawaited(_discardCheckpoint(removed.checkpointKey));
      _queuedMediaKeys.remove(mediaKey);
      _statusMessagesByMediaKey.remove(mediaKey);
      _taskOrder.remove(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    if (_completedJobs.containsKey(mediaKey)) {
      _completedJobs.remove(mediaKey);
      _resultSrtByMediaKey.remove(mediaKey);
      _consumedResultMediaKeys.remove(mediaKey);
      _statusMessagesByMediaKey.remove(mediaKey);
      _taskOrder.remove(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    if (_resultSrtByMediaKey.containsKey(mediaKey)) {
      _resultSrtByMediaKey.remove(mediaKey);
      _consumedResultMediaKeys.remove(mediaKey);
      _statusMessagesByMediaKey.remove(mediaKey);
      _taskOrder.remove(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    return false;
  }

  bool _requeueFailedTask(String mediaKey) {
    final job = _failedJobs.remove(mediaKey);
    if (job == null) return false;
    job.retryRemoteTasks = true;
    _prepareTaskForNewRun(mediaKey);
    _insertQueuedByTaskOrder(job);
    return true;
  }

  bool retryTask(String mediaKey, {TranscriptTranslateChoice? translate}) {
    if (!_requeueFailedTask(mediaKey)) return false;
    startTask(mediaKey, translateIfUnfrozen: translate);
    return true;
  }

  /// Moves a pending task to its final zero-based displayed queue position.
  ///
  /// [newIndex] is a final item index, not ReorderableListView's insertion
  /// gap. Keeping the UI-specific gap semantics out of the manager prevents
  /// downward moves from being adjusted twice and allows moving to the last
  /// queue position. Scheduled tasks stay ahead of unstarted/paused tasks;
  /// dragging across that boundary moves to the end of the task's own group.
  bool reorderTask(String mediaKey, int newIndex) {
    if (_currentMediaKey == mediaKey && isProcessing) {
      return false;
    }

    final currentIndex = _queue.indexWhere((job) => job.mediaKey == mediaKey);
    if (currentIndex < 0) return false;

    if (newIndex < 0 || newIndex >= _queue.length) return false;

    final job = _queue[currentIndex];
    final started = _startedMediaKeys.contains(mediaKey);
    final group = _queue
        .where(
          (queued) => _startedMediaKeys.contains(queued.mediaKey) == started,
        )
        .toList();
    final offset = started ? 0 : _queue.length - group.length;
    final groupIndex = (newIndex - offset).clamp(0, group.length - 1);
    final oldGroupIndex = group.indexOf(job);
    if (oldGroupIndex == groupIndex) return true;

    group.removeAt(oldGroupIndex);
    _queue.removeAt(currentIndex);
    final insertAt = groupIndex < group.length
        ? _queue.indexOf(group[groupIndex])
        : _queue.indexOf(group.last) + 1;
    _queue.insert(insertAt, job);
    _syncTaskOrderForQueuedMove(job.mediaKey, insertAt);
    _scheduleSave();
    notifyListeners();
    return true;
  }

  Future<TranscriptionEnqueueResult> startExternalTranscription(
    String videoPath, {
    required SubtitleOutputPathStrategy outputPathStrategy,
    String? customOutputDir,
  }) async {
    if (videoPath.trim().isEmpty) {
      throw Exception("视频路径不能为空");
    }
    final mediaKey = _mediaKey(videoPath);
    if (isVideoCancelling(videoPath) ||
        _currentJob?.mediaKey == mediaKey ||
        isVideoQueued(videoPath)) {
      return TranscriptionEnqueueResult.alreadyQueued;
    }

    _prepareTaskForNewRun(mediaKey);
    _insertQueuedByTaskOrder(
      _TranscriptionJob(
        videoPath: videoPath,
        videoId: null,
        mediaKey: mediaKey,
        libraryService: null,
        autoCache: false,
        isExternal: true,
        outputPathStrategy: outputPathStrategy,
        customOutputDir: customOutputDir,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        displayName: p.basename(videoPath),
        durationLabel: '',
        checkpointScope: const Uuid().v4(),
      ),
    );
    _scheduleSave();
    notifyListeners();
    return TranscriptionEnqueueResult.added;
  }

  /// 清除所有已完成的任务
  void clearAllCompleted() {
    final completedKeys = _completedJobs.keys.toSet();
    _completedJobs.clear();
    for (final key in List<String>.from(_statusMessagesByMediaKey.keys)) {
      if (_resultSrtByMediaKey.containsKey(key) &&
          !_failedJobs.containsKey(key) &&
          _currentMediaKey != key) {
        _statusMessagesByMediaKey.remove(key);
      }
    }
    _resultSrtByMediaKey.clear();
    _consumedResultMediaKeys.clear();
    _taskOrder.removeWhere(completedKeys.contains);
    _scheduleSave();
    notifyListeners();
  }

  /// 清除所有排队的任务（不删除已完成和失败的任务）
  void clearQueuedTasks() {
    for (final job in _queue) {
      unawaited(_discardCheckpoint(job.checkpointKey));
    }
    final queuedKeys = _queue.map((job) => job.mediaKey).toSet();
    _queue.clear();
    _queuedMediaKeys.clear();
    _startedMediaKeys.clear();
    _taskOrder.removeWhere(queuedKeys.contains);
    _scheduleSave();
    notifyListeners();
  }

  /// 清除所有任务；若当前任务正在处理，会先取消底层工作。
  void clearAllTasks() {
    final currentKey = _currentMediaKey;
    if (currentKey != null && isProcessing) {
      _currentTaskRemoved = true;
      _currentCancellation?.cancel('用户清除了全部任务');
    }
    _queue.clear();
    _queuedMediaKeys.clear();
    _startedMediaKeys.clear();
    _failedJobs.clear();
    _completedJobs.clear();
    _resultSrtByMediaKey.clear();
    _consumedResultMediaKeys.clear();
    _statusMessagesByMediaKey.clear();
    _taskOrder.clear();
    unawaited(_discardAllCheckpoints());
    _scheduleSave();
    notifyListeners();
  }

  bool _currentJobIsExternal = false;
  SubtitleOutputPathStrategy? _currentJobOutputPathStrategy;
  String? _currentJobCustomOutputDir;
  int _currentJobCreatedAt = 0;

  @override
  void dispose() {
    _disposed = true;
    if (_ownsHotwordStore) _hotwordStore.dispose();
    unawaited(_streamEvents.close());
    unawaited(_streamStarts.close());
    subtitleFilesRevision.dispose();
    _settings.removeListener(_syncCompletedRemovals);
    _settings.removeListener(_syncProcessingKeepAwake);
    if (_processingKeepAwakeActive) {
      AppWakelockCoordinator.setActive(
        AppWakelockCoordinator.transcriptionReason,
        false,
      );
      _processingKeepAwakeActive = false;
    }
    for (final timer in _completedRemovalTimers.values) {
      timer.cancel();
    }
    _completedRemovalTimers.clear();
    _saveDebounceTimer?.cancel();
    _currentCancellation?.cancel('转录管理器已释放');
    _queue.clear();
    _queuedMediaKeys.clear();
    _startedMediaKeys.clear();
    _failedJobs.clear();
    _completedJobs.clear();
    _resultSrtByMediaKey.clear();
    _consumedResultMediaKeys.clear();
    _statusMessagesByMediaKey.clear();
    _taskOrder.clear();
    super.dispose();
  }

  String? get _currentMediaKey {
    final currentPath = _currentVideoPath;
    if (currentPath == null || currentPath.isEmpty) return null;
    return _mediaKey(currentPath, videoId: _currentVideoId);
  }

  String _mediaKey(String videoPath, {String? videoId}) {
    final trimmedId = videoId?.trim();
    if (trimmedId != null && trimmedId.isNotEmpty) {
      return 'id:$trimmedId';
    }
    final normalizedPath = p.normalize(videoPath);
    final safePath = Platform.isWindows
        ? normalizedPath.toLowerCase()
        : normalizedPath;
    return 'path:$safePath';
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  void _removeTaskRecords(String mediaKey) {
    final checkpointKey = _jobForKey(mediaKey)?.checkpointKey ?? mediaKey;
    _queue.removeWhere((job) => job.mediaKey == mediaKey);
    _queuedMediaKeys.remove(mediaKey);
    _startedMediaKeys.remove(mediaKey);
    _failedJobs.remove(mediaKey);
    _completedJobs.remove(mediaKey);
    _resultSrtByMediaKey.remove(mediaKey);
    _consumedResultMediaKeys.remove(mediaKey);
    _statusMessagesByMediaKey.remove(mediaKey);
    _taskOrder.remove(mediaKey);
    unawaited(_discardCheckpoint(checkpointKey));
  }

  void _prepareTaskForNewRun(String mediaKey) {
    _failedJobs.remove(mediaKey);
    _completedJobs.remove(mediaKey);
    _resultSrtByMediaKey.remove(mediaKey);
    _consumedResultMediaKeys.remove(mediaKey);
    _statusMessagesByMediaKey.remove(mediaKey);
  }

  bool _containsTask(String mediaKey) {
    return _queue.any((job) => job.mediaKey == mediaKey) ||
        _failedJobs.containsKey(mediaKey) ||
        _completedJobs.containsKey(mediaKey) ||
        _currentJob?.mediaKey == mediaKey;
  }

  void _insertQueuedByTaskOrder(_TranscriptionJob job) {
    if (_queue.any((queued) => queued.mediaKey == job.mediaKey)) return;
    final jobOrder = _taskOrder.indexOf(job.mediaKey);
    if (jobOrder < 0) {
      _taskOrder.add(job.mediaKey);
      _queue.add(job);
    } else {
      final insertAt = _queue.indexWhere((queued) {
        final queuedOrder = _taskOrder.indexOf(queued.mediaKey);
        return queuedOrder >= 0 && queuedOrder > jobOrder;
      });
      if (insertAt < 0) {
        _queue.add(job);
      } else {
        _queue.insert(insertAt, job);
      }
    }
    _queuedMediaKeys.add(job.mediaKey);
  }

  void _syncTaskOrderForQueuedMove(String mediaKey, int queueIndex) {
    _taskOrder.remove(mediaKey);
    if (_queue.length == 1) {
      _taskOrder.add(mediaKey);
      return;
    }
    if (queueIndex < _queue.length - 1) {
      final nextKey = _queue[queueIndex + 1].mediaKey;
      final nextOrder = _taskOrder.indexOf(nextKey);
      _taskOrder.insert(
        nextOrder < 0 ? _taskOrder.length : nextOrder,
        mediaKey,
      );
    } else {
      final previousKey = _queue[queueIndex - 1].mediaKey;
      final previousOrder = _taskOrder.indexOf(previousKey);
      _taskOrder.insert(
        previousOrder < 0 ? _taskOrder.length : previousOrder + 1,
        mediaKey,
      );
    }
  }

  String _aiSubtitleFileName(String videoPath, {String? videoId}) {
    final trimmedId = videoId?.trim();
    if (trimmedId != null && trimmedId.isNotEmpty) {
      return '$trimmedId.ai.srt';
    }
    final name = p.basenameWithoutExtension(videoPath);
    return '$name.ai.srt';
  }

  /// 外部视频软字幕内嵌入口：根据设置决定是否将 SRT 嵌入视频
  Future<void> _embedSoftSubtitlesIfNeeded({
    required String videoPath,
    required String srtPath,
    required String mediaKey,
    required _JobCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    // The picker also accepts external audio files, while these settings are
    // explicitly for video soft subtitles. Trying to mux mov_text into audio
    // containers would turn an otherwise successful transcription into an
    // embedding failure.
    if (_looksLikeAudioInput(videoPath)) return;

    // Keep a reference to the singleton/injected service rather than copying
    // values. Settings used after ffmpeg finishes (delete original/SRT) are
    // consequently re-read and can still change while embedding is running.
    final settings = _settings;
    final bool shouldEmbed =
        settings.batchSubtitleEmbedSoftCopyAndEmbed ||
        settings.batchSubtitleEmbedSoftDeleteOriginal;
    if (!shouldEmbed) return;

    // Always mux into a unique staging file. Besides avoiding partially
    // written final files, this lets prefix/suffix and copy/replace changes
    // made during ffmpeg execution apply at the final commit boundary.
    final String stagingPath = _buildEmbeddingStagingPath(videoPath);
    final File stagingFile = File(stagingPath);

    _updateStatus(
      TranscriptionStatus.embedding,
      '正在内嵌软字幕...',
      _progressPlan.embedding(0),
    );
    try {
      await _embedSoftSubtitle(
        srcVideo: videoPath,
        srtPath: srtPath,
        outputPath: stagingPath,
        cancellation: cancellation,
        onProgress: (ratio) {
          final p = _progressPlan.embedding(ratio);
          _updateStatus(
            TranscriptionStatus.embedding,
            '正在内嵌软字幕 ${(ratio * 100).toInt()}%',
            p,
          );
        },
      );
      cancellation.throwIfCancelled();

      // 校验输出文件
      if (!await stagingFile.exists()) {
        throw Exception('内嵌软字幕失败：输出文件未生成');
      }
      final outputLength = await stagingFile.length();
      if (outputLength <= 0) {
        throw Exception('内嵌软字幕失败：输出文件大小为 0');
      }

      // Re-read every mode/naming field after ffmpeg. Turning embedding off
      // while it was running discards the staged result and preserves both
      // source video and SRT; changing modes or names affects this same task.
      final copyAndEmbed = settings.batchSubtitleEmbedSoftCopyAndEmbed;
      final replaceOriginal = settings.batchSubtitleEmbedSoftDeleteOriginal;
      if (!copyAndEmbed && !replaceOriginal) {
        await _safeDeleteFile(stagingPath);
        debugPrint('软字幕内嵌设置已关闭，丢弃暂存结果');
        return;
      }

      var outputPath = _buildEmbeddedOutputPath(videoPath, settings);
      final outputMatchesSource = _sameFilePath(outputPath, videoPath);
      if (copyAndEmbed && outputMatchesSource) {
        // A copy cannot share the source path. Use a deterministic safe name
        // when both naming switches are effectively empty/disabled.
        outputPath = _buildDefaultEmbeddedCopyPath(videoPath);
      }

      if (replaceOriginal && outputMatchesSource) {
        await _replaceFileSafely(
          sourcePath: videoPath,
          replacementPath: stagingPath,
        );
      } else {
        final outputFile = File(outputPath);
        if (await outputFile.exists()) {
          throw Exception('内嵌软字幕失败：目标文件已存在，为避免覆盖已保留原视频');
        }
        await stagingFile.rename(outputPath);

        // Delete only after the staged result has been validated and committed.
        if (replaceOriginal) {
          await _safeDeleteFile(videoPath);
        }
      }

      // This cleanup setting is intentionally read after committing the video,
      // so it remains live throughout the embedding stage.
      if (settings.batchSubtitleEmbedAutoDeleteSrt) {
        await _safeDeleteFile(srtPath);
        _resultSrtByMediaKey.remove(mediaKey);
        if (_lastGeneratedSrtPath == srtPath) {
          _lastGeneratedSrtPath = null;
        }
      } else {
        // 字幕未删除：SRT 仍在原位置，保留引用
        _resultSrtByMediaKey[mediaKey] = srtPath;
        _lastGeneratedSrtPath = srtPath;
      }
      debugPrint('软字幕内嵌完成: $outputPath');
    } catch (e) {
      // 嵌入失败 —— 保留原视频和 SRT，不删除任何文件
      debugPrint('软字幕内嵌失败: $e');
      // 清理可能产生的部分输出文件
      await _safeDeleteFile(stagingPath);
      rethrow;
    }
  }

  String _buildEmbeddingStagingPath(String videoPath) {
    final dir = p.dirname(videoPath);
    final baseName = p.basenameWithoutExtension(videoPath);
    final ext = p.extension(videoPath);
    final nonce = DateTime.now().microsecondsSinceEpoch;
    return p.join(dir, '.$baseName.ai_embedding_$nonce$ext');
  }

  String _buildDefaultEmbeddedCopyPath(String videoPath) {
    final dir = p.dirname(videoPath);
    final baseName = p.basenameWithoutExtension(videoPath);
    final ext = p.extension(videoPath);
    return p.join(dir, '${baseName}_AI字幕$ext');
  }

  bool _sameFilePath(String first, String second) {
    final normalizedFirst = p.normalize(p.absolute(first));
    final normalizedSecond = p.normalize(p.absolute(second));
    if (Platform.isWindows) {
      return normalizedFirst.toLowerCase() == normalizedSecond.toLowerCase();
    }
    return normalizedFirst == normalizedSecond;
  }

  Future<void> _replaceFileSafely({
    required String sourcePath,
    required String replacementPath,
  }) async {
    final source = File(sourcePath);
    final replacement = File(replacementPath);
    if (!await source.exists()) {
      throw Exception('替换原视频失败：原视频不存在');
    }

    final backupPath =
        '$sourcePath.ai_embedding_backup_${DateTime.now().microsecondsSinceEpoch}';
    final backup = File(backupPath);
    await source.rename(backupPath);
    try {
      await replacement.rename(sourcePath);
      final committed = File(sourcePath);
      if (!await committed.exists() || await committed.length() <= 0) {
        throw Exception('替换原视频失败：提交后的文件无效');
      }
    } catch (_) {
      await _safeDeleteFile(sourcePath);
      if (await backup.exists()) {
        await backup.rename(sourcePath);
      }
      rethrow;
    }

    try {
      await backup.delete();
    } catch (e) {
      debugPrint('清理原视频备份失败（嵌入结果已提交）: $backupPath, $e');
    }
  }

  /// 构建嵌入后的输出文件路径（含前缀/后缀命名）
  String _buildEmbeddedOutputPath(String videoPath, SettingsService settings) {
    final dir = p.dirname(videoPath);
    final ext = p.extension(videoPath);
    final baseName = p.basenameWithoutExtension(videoPath);
    String result = baseName;
    if (settings.batchSubtitleEmbedSoftPrefixEnabled &&
        settings.batchSubtitleEmbedSoftPrefix.isNotEmpty) {
      result = '${settings.batchSubtitleEmbedSoftPrefix}$result';
    }
    if (settings.batchSubtitleEmbedSoftSuffixEnabled &&
        settings.batchSubtitleEmbedSoftSuffix.isNotEmpty) {
      result = '$result${settings.batchSubtitleEmbedSoftSuffix}';
    }
    return p.join(dir, '$result$ext');
  }

  /// 使用 ffmpeg 将 SRT 软字幕嵌入视频（流拷贝模式，不重新编码）
  Future<void> _embedSoftSubtitle({
    required String srcVideo,
    required String srtPath,
    required String outputPath,
    required void Function(double ratio) onProgress,
    required _JobCancellation cancellation,
  }) async {
    final args = <String>[
      '-y',
      '-i',
      srcVideo,
      '-i',
      srtPath,
      '-c:v',
      'copy',
      '-c:a',
      'copy',
      '-map',
      '0:v?',
      '-map',
      '0:a?',
      '-map',
      '1:0',
      '-c:s',
      'mov_text',
      '-metadata:s:s:0',
      'title=AI字幕',
      '-metadata:s:s:0',
      'handler_name=AI字幕',
      '-metadata:s:s:0',
      'language=chi',
    ];

    // 探测视频时长用于进度计算
    double totalSeconds = 1.0;
    try {
      final probe = await _probeMedia(srcVideo, cancellation);
      totalSeconds = (probe.durationSeconds ?? 1.0).clamp(1.0, 99999.0);
    } catch (_) {
      cancellation.throwIfCancelled();
      // 探测失败使用默认时长
    }

    args.add(outputPath);

    if (FFmpegUtils.preferSystemFfmpeg) {
      await FFmpegUtils.ensureAvailable();
      await _runEmbedFfmpegWindows(
        args,
        totalSeconds: totalSeconds,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      return;
    }

    await _runEmbedFfmpegKit(
      args,
      totalSeconds: totalSeconds,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  /// Windows 平台软字幕嵌入 ffmpeg 执行
  Future<void> _runEmbedFfmpegWindows(
    List<String> args, {
    required double totalSeconds,
    required void Function(double ratio) onProgress,
    required _JobCancellation cancellation,
  }) async {
    final ffmpegPath = await FFmpegUtils.ffmpegPath;
    final process = await Process.start(ffmpegPath, args);
    final stderrBuffer = StringBuffer();
    final startedAt = DateTime.now();
    DateTime lastActivityAt = startedAt;
    bool killRequested = false;
    String? abortReason;
    final timeout = Duration(
      seconds: (totalSeconds * 0.5 + 120).clamp(60, 3600).toInt(),
    );
    final inactivityTimeout = Duration(seconds: 30);

    void recordLine(String line) {
      lastActivityAt = DateTime.now();
      stderrBuffer.writeln(line);
      final match = RegExp(
        r'time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
      ).firstMatch(line);
      if (match != null) {
        final h = double.tryParse(match.group(1) ?? '') ?? 0;
        final m = double.tryParse(match.group(2) ?? '') ?? 0;
        final s = double.tryParse(match.group(3) ?? '') ?? 0;
        final current = h * 3600 + m * 60 + s;
        final ratio = (current / totalSeconds).clamp(0.0, 1.0);
        onProgress(ratio);
      }
    }

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(recordLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(recordLine);

    final monitor = Timer.periodic(const Duration(seconds: 2), (_) {
      if (killRequested) return;
      final now = DateTime.now();
      if (cancellation.isCancelled) {
        abortReason = cancellation.reason;
        killRequested = true;
        process.kill();
      } else if (now.difference(lastActivityAt) > inactivityTimeout) {
        abortReason = 'FFmpeg 内嵌软字幕超时（无输出），已自动中断';
        killRequested = true;
        process.kill();
      } else if (now.difference(startedAt) > timeout) {
        abortReason = 'FFmpeg 内嵌软字幕总超时，已自动中断';
        killRequested = true;
        process.kill();
      }
    });

    final exitCode = await process.exitCode;
    monitor.cancel();
    cancellation.throwIfCancelled();

    if (abortReason != null) {
      throw Exception(abortReason);
    }
    if (exitCode != 0) {
      final errorText = _summarizeText(
        stderrBuffer.toString(),
        fallback: '未知错误',
      );
      throw Exception('FFmpeg 内嵌软字幕失败 (exit=$exitCode): $errorText');
    }
  }

  /// 非 Windows 平台软字幕嵌入 ffmpeg 执行
  Future<void> _runEmbedFfmpegKit(
    List<String> args, {
    required double totalSeconds,
    required void Function(double ratio) onProgress,
    required _JobCancellation cancellation,
  }) async {
    final completer = Completer<dynamic>();
    final startedAt = DateTime.now();
    DateTime lastActivityAt = startedAt;
    bool cancelRequested = false;
    String? cancelReason;
    final timeout = Duration(
      seconds: (totalSeconds * 0.5 + 120).clamp(60, 3600).toInt(),
    );
    final inactivityTimeout = Duration(seconds: 30);

    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        if (!completer.isCompleted) {
          completer.complete(session);
        }
      },
      (log) {
        lastActivityAt = DateTime.now();
        final message = log.getMessage();
        final match = RegExp(
          r'time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
        ).firstMatch(message);
        if (match != null) {
          final h = double.tryParse(match.group(1) ?? '') ?? 0;
          final m = double.tryParse(match.group(2) ?? '') ?? 0;
          final s = double.tryParse(match.group(3) ?? '') ?? 0;
          final current = h * 3600 + m * 60 + s;
          final ratio = (current / totalSeconds).clamp(0.0, 1.0);
          onProgress(ratio);
        }
      },
      (_) {
        lastActivityAt = DateTime.now();
      },
    );

    final monitor = Timer.periodic(const Duration(seconds: 2), (_) {
      if (cancelRequested) return;
      final now = DateTime.now();
      if (cancellation.isCancelled) {
        cancelRequested = true;
        cancelReason = cancellation.reason;
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      } else if (now.difference(lastActivityAt) > inactivityTimeout) {
        cancelRequested = true;
        cancelReason = 'FFmpeg 内嵌软字幕超时（无输出），已自动中断';
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      } else if (now.difference(startedAt) > timeout) {
        cancelRequested = true;
        cancelReason = 'FFmpeg 内嵌软字幕总超时，已自动中断';
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      }
    });

    try {
      final completedSession = await completer.future;
      cancellation.throwIfCancelled();
      final returnCode = await completedSession.getReturnCode();
      if (cancelRequested || ReturnCode.isCancel(returnCode)) {
        final logs = await completedSession.getAllLogsAsString();
        throw Exception(
          cancelReason ?? _summarizeText(logs ?? '', fallback: 'FFmpeg 已取消'),
        );
      }
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await completedSession.getAllLogsAsString();
        throw Exception(
          'FFmpeg 内嵌软字幕失败: ${_summarizeText(logs ?? '', fallback: '未知错误')}',
        );
      }
    } finally {
      monitor.cancel();
    }
  }

  Future<List<SubtitleItem>> _transcribeWithModel({
    required _TranscriptionJob job,
    required _PreparedAudioResult prepared,
    required String sourcePath,
    required String sourceIdentity,
    required _JobCancellation cancellation,
    Future<void> Function(StableAsrBatch)? onStableBatch,
    Future<void>? pipelineCancelSignal,
    Future<void> Function()? onSessionClose,
    Future<void> Function()? onConsumerIdle,
    bool Function()? consumerHasResidentModel,
  }) async {
    final seconds = prepared.probe.durationSeconds;
    if (seconds == null || !seconds.isFinite || seconds <= 0) {
      throw StateError('无法确定音频时长，请先将媒体下载为完整文件');
    }
    Future<String> prepare(
      Duration start,
      Duration length,
      bool pcm,
      void Function(double) onProgress, {
      AsrAudioChannel channel = AsrAudioChannel.mix,
    }) async {
      cancellation.throwIfCancelled();
      final path = await _createManagedTempAudioPath();
      final output = pcm ? p.setExtension(path, '.wav') : path;
      try {
        await _extractAudioToPath(
          sourcePath,
          output,
          useCopy: false,
          probe: prepared.probe,
          cancellation: cancellation,
          pcm: pcm,
          channel: channel,
          seekStart: start,
          takeDuration: length,
          onProgress: onProgress,
        );
        cancellation.throwIfCancelled();
        return output;
      } catch (_) {
        await _deleteFileIfExists(output);
        rethrow;
      }
    }

    Future<CloudAsrAudio> prepareCloud(
      Duration start,
      Duration length,
      bool force,
      void Function(double) progress,
    ) async {
      cancellation.throwIfCancelled();
      final probe = prepared.probe;
      if ((start + length).inMicroseconds / 1000000 <=
          probe.audioStartOffsetSeconds) {
        progress(1);
        return const CloudAsrAudio.silence();
      }
      final extension = switch (probe.codec) {
        'aac' => '.m4a',
        'mp3' => '.mp3',
        'flac' => '.flac',
        'opus' || 'vorbis' => '.ogg',
        'pcm_s16le' => '.wav',
        _ => null,
      };
      final sizeLimit =
          job.modelSpec!.profile.cloudCapabilities?.maxBytes ?? 20000000;
      final limit = math.min(20000000, sizeLimit);
      final sourceFile = File(sourcePath);
      final whole =
          start == Duration.zero &&
          (length.inMilliseconds - seconds * 1000).abs() < 250;
      if (!force &&
          whole &&
          extension != null &&
          probe.isAudioInput &&
          probe.audioStartOffsetSeconds <= 0 &&
          !probe.hasVideo &&
          probe.audioStreams == 1 &&
          p.extension(sourcePath).toLowerCase() == extension &&
          await sourceFile.length() <= limit) {
        progress(1);
        return CloudAsrAudio(sourcePath, temporary: false);
      }
      final copy =
          !force &&
          extension != null &&
          probe.audioBitRate != null &&
          start.inMicroseconds / 1000000 >= probe.audioStartOffsetSeconds &&
          probe.audioBitRate! / 8 * length.inMicroseconds / 1000000 * 1.05 +
                  65536 <=
              limit;
      final path = p.setExtension(
        await _createManagedTempAudioPath(),
        copy ? extension : '.mp3',
      );
      try {
        await _extractAudioToPath(
          sourcePath,
          path,
          useCopy: copy,
          probe: probe,
          cancellation: cancellation,
          cloudMp3: !copy,
          seekStart: start,
          takeDuration: length,
          onProgress: progress,
        );
        cancellation.throwIfCancelled();
        return CloudAsrAudio(path);
      } catch (_) {
        await _deleteFileIfExists(path);
        if (copy && !cancellation.isCancelled) {
          return prepareCloud(start, length, true, progress);
        }
        rethrow;
      }
    }

    return _modelRunner.run(
      spec: job.modelSpec!,
      sourceIdentity: sourceIdentity,
      checkpointScope: job.checkpointScope,
      duration: Duration(milliseconds: (seconds * 1000).round()),
      cancelSignal: pipelineCancelSignal ?? cancellation.whenCancelled,
      onStableBatch: onStableBatch,
      serializeConsumer:
          onStableBatch != null &&
          job.translateEnabled &&
          job.translateProviderName == SubtitleTranslateProvider.local.name,
      consumerModelBytes: job.translateLocalSpec == null
          ? 0
          : (_modelCenter
                    .artifact(job.translateLocalSpec!.profile.model)
                    ?.bytes ??
                0),
      consumerBatchSize: job.translateLocalSpec?.translation.batchSize ?? 8,
      consumerWorkingSetBytes: job.translateLocalSpec == null
          ? null
          : translationAllocationBytes(
              _modelCenter
                      .artifact(job.translateLocalSpec!.profile.model)
                      ?.bytes ??
                  0,
              gpu:
                  job.translateLocalSpec!.translation.acceleration ==
                      TranslationAcceleration.gpu ||
                  (job.translateLocalSpec!.translation.acceleration ==
                          TranslationAcceleration.auto &&
                      (Platform.isIOS || Platform.isMacOS)),
            ),
      streamAssemblyVersion: job.streamAssemblyVersion,
      onSessionClose: onSessionClose,
      onConsumerIdle: onConsumerIdle,
      consumerHasResidentModel: consumerHasResidentModel,
      prepareAudio: (start, length, pcm, onProgress) =>
          prepare(start, length, pcm, onProgress),
      prepareCloudAudio: job.modelSpec!.profile.cloudProvider == null
          ? null
          : prepareCloud,
      prepareAudioChannel: (start, length, channel, progress) =>
          prepare(start, length, true, progress, channel: channel),
      onProgress: (event) {
        if (cancellation.isCancelled) return;
        _localAsrProgress = event.local;
        _updateStatus(
          switch (event.stage) {
            ModelProcessingStage.preparing ||
            ModelProcessingStage.loading => TranscriptionStatus.extracting,
            ModelProcessingStage.uploading => TranscriptionStatus.uploading,
            _ => TranscriptionStatus.transcribing,
          },
          event.message,
          _progressPlan.recognition(event.fraction),
        );
      },
    );
  }

  Future<List<SubtitleItem>> _transcribePrepared({
    required _PreparedAudioResult preparedAudio,
    required String sourcePath,
    required String mediaKey,
    required _JobCancellation cancellation,
  }) async {
    final fileBytes = await _safeFileSize(File(preparedAudio.audioPath));
    final duration = TranscriptionTiming.durationFromProbe(
      seconds: preparedAudio.probe.durationSeconds,
      fileBytes: fileBytes,
    );
    final fingerprint = await _sourceFingerprint(sourcePath);
    final identity = PodcastPlaybackHooks.sourceIdentity?.call(sourcePath);
    final book = await _openCheckpointBook();
    final saved = book.tasks[mediaKey];
    final checkpoint =
        saved != null &&
            saved.matches(
              fingerprint.bytes,
              fingerprint.modifiedMs,
              identity: identity,
            )
        ? saved
        : TranscriptionTaskCheckpoint.empty(
            fingerprint.bytes,
            fingerprint.modifiedMs,
            identity: identity,
          );
    book.tasks[mediaKey] = checkpoint;
    debugPrint(
      '[transcription] recognize key=$mediaKey durationMs=${duration.inMilliseconds} '
      'resumedPieces=${checkpoint.pieces.length}',
    );

    final audioPrefetcher = TranscriptionAudioPrefetcher<_SliceAudio>(
      prepare: (slice, progress, cancelSignal) async {
        cancellation.throwIfCancelled();
        final preparationCancellation = _JobCancellation();
        unawaited(
          Future.any<void>([
            cancellation.whenCancelled,
            cancelSignal,
            preparationCancellation.whenCancelled,
          ]).then((_) {
            if (!preparationCancellation.isCancelled) {
              preparationCancellation.cancel(
                cancellation.isCancelled ? cancellation.reason : '后续音频准备已停止',
              );
            }
          }),
        );
        try {
          return await _materializeSlice(
            preparedAudio: preparedAudio,
            slice: slice,
            duration: duration,
            cancellation: preparationCancellation,
            forceTranscode:
                checkpoint.remoteTasks[slice.taskKey]?.normalizeAudio == true,
            onProgress: progress,
          );
        } finally {
          preparationCancellation.cancel('音频准备已结束');
        }
      },
      release: (audio) async {
        if (audio.temporary) await _deleteFileIfExists(audio.path);
      },
    );

    try {
      return await SliceRecognitionSession.run(
        duration: duration,
        checkpoint: checkpoint,
        log: debugPrint,
        checkCancelled: cancellation.throwIfCancelled,
        waitBetween: (delay, message) =>
            _waitWithCountdown(cancellation, delay, message),
        onPiece: (_) => _writeCheckpointBook(book),
        onProgress: (message, progress) {
          _updateStatus(
            _statusForRecognitionMessage(message),
            message,
            _progressPlan.recognition(progress),
          );
        },
        transcribe: (slice, label, onInner) {
          return _transcribeSlice(
            preparedAudio: preparedAudio,
            slice: slice,
            label: label,
            onInner: onInner,
            cancellation: cancellation,
            checkpoint: checkpoint,
            saveCheckpoint: () => _writeCheckpointBook(book),
            prepareAudio: (progress) => audioPrefetcher.take(slice, progress),
            onAudioReady: () {
              if (cancellation.isCancelled || _hitRiskControlThisJob) return;
              final next = TranscriptionSlicePlanner.nextUnfinished(
                start: Duration(
                  milliseconds: TranscriptionSlicePlanner.cursorAfter(
                    slice.start.inMilliseconds,
                    slice.end.inMilliseconds,
                    duration.inMilliseconds,
                  ),
                ),
                duration: duration,
                checkpoint: checkpoint,
              );
              if (next == null ||
                  checkpoint.remoteTasks[next.taskKey]?.taskId?.isNotEmpty ==
                      true) {
                return;
              }
              audioPrefetcher.prefetch(next);
            },
          );
        },
      );
    } on TranscriptionSlicePastEnd {
      throw const GongyiAsrException(GongyiAsrFailureKind.rejected, '待识别音频是空的');
    } finally {
      await audioPrefetcher.close();
    }
  }

  TranscriptionStatus _statusForRecognitionMessage(String message) {
    // Query messages can say "不会重新上传"; that is still result polling.
    if (message.contains('查询') || message.contains('服务器正在')) {
      return TranscriptionStatus.transcribing;
    }
    if (message.contains('上传')) return TranscriptionStatus.uploading;
    if (message.contains('准备音频') ||
        message.contains('提取') ||
        message.contains('整理') ||
        message.contains('转码')) {
      return TranscriptionStatus.extracting;
    }
    return TranscriptionStatus.transcribing;
  }

  Future<List<SubtitleItem>> _transcribeSlice({
    required _PreparedAudioResult preparedAudio,
    required TranscriptionSlice slice,
    required String? label,
    required void Function(double innerProgress, String message) onInner,
    required _JobCancellation cancellation,
    required TranscriptionTaskCheckpoint checkpoint,
    required Future<void> Function() saveCheckpoint,
    required Future<_SliceAudio> Function(void Function(double)) prepareAudio,
    required void Function() onAudioReady,
  }) async {
    cancellation.throwIfCancelled();
    final remote = checkpoint.remoteTasks.putIfAbsent(
      slice.taskKey,
      GongyiAsrTaskCheckpoint.new,
    )..onChanged = saveCheckpoint;
    _SliceAudio? audio;
    var audioReady = false;
    Future<String> prepare() async {
      // An expired task from the old hour-long policy may be polled, but any
      // replacement upload must use the new shorter slices.
      if (slice.overlap > Duration.zero ||
          slice.length > TranscriptionTiming.safeSliceLength) {
        throw const GongyiAsrException(
          GongyiAsrFailureKind.tooLong,
          '旧识别任务已失效，按无重叠且时长不超过 30 分钟的范围重新切分',
        );
      }
      audio ??= await prepareAudio(
        (ratio) => onInner(ratio * 0.2, '准备音频 ${(ratio * 100).floor()}%'),
      );
      if (audio!.pastEnd) throw const TranscriptionSlicePastEnd();
      if (!audio!.fastPath && !remote.normalizeAudio) {
        remote.normalizeAudio = true;
        await saveCheckpoint();
      }
      return audio!.path;
    }

    var waitingMessage = '稍后自动重试';
    Future<List<SubtitleItem>> recognize() => TranscriptionAttemptRunner.run(
      sliceLabel: label,
      log: debugPrint,
      delay: (wait) => _waitWithCountdown(cancellation, wait, waitingMessage),
      onWaiting: (message) {
        waitingMessage = message;
        if (message.contains('访问限制') ||
            message.contains('频率限制') ||
            message.contains('安全策略拦截')) {
          _hitRiskControlThisJob = true;
        }
        _updateStatus(TranscriptionStatus.transcribing, message, _progress);
      },
      attempt: () => _asrService.transcribeAudio(
        preparedAudio.audioPath,
        prepareAudio: prepare,
        includeWordTimings: true,
        cancelToken: cancellation.dioCancelToken,
        checkpoint: remote,
        onProgress: (inner, message) {
          if (cancellation.isCancelled) return;
          // This callback follows local preparation, or a saved task's first
          // query. Only local work runs ahead; submissions remain sequential.
          if (message.contains('访问限制') ||
              message.contains('频率限制') ||
              message.contains('安全策略拦截')) {
            _hitRiskControlThisJob = true;
          }
          if (!audioReady) {
            audioReady = true;
            onAudioReady();
          }
          onInner(0.2 + inner * 0.8, message);
        },
      ),
    );
    try {
      try {
        return await recognize();
      } on GongyiAsrException catch (error) {
        // A resumed fast task can fail after its temporary file was cleaned.
        // Its persisted format choice still permits the compatibility retry.
        final usedFastAudio = audio?.fastPath ?? !remote.normalizeAudio;
        if (!usedFastAudio ||
            remote.normalizeAudio ||
            !GongyiAudioPreparationPlan.shouldNormalizeAfter(
              error,
              taskPending: remote.taskId?.isNotEmpty == true,
            )) {
          rethrow;
        }
        // Retry a definitively rejected fast upload once using the established
        // 16 kHz mono format. A pending/uncertain task is never resubmitted.
        if (audio?.temporary == true) await _deleteFileIfExists(audio!.path);
        audio = null;
        audioReady = false;
        remote.normalizeAudio = true;
        await saveCheckpoint();
        await _waitWithCountdown(
          cancellation,
          TranscriptionTiming.betweenSlices,
          '原音频未被接受，改用兼容格式重试',
        );
        return await recognize();
      }
    } finally {
      if (audio?.temporary == true) await _deleteFileIfExists(audio!.path);
    }
  }

  Future<_SliceAudio> _materializeSlice({
    required _PreparedAudioResult preparedAudio,
    required TranscriptionSlice slice,
    required Duration duration,
    required _JobCancellation cancellation,
    bool forceTranscode = false,
    void Function(double ratio)? onProgress,
  }) async {
    final probe = preparedAudio.probe;
    if (preparedAudio.compatibilityAudio && slice.coversEntire(duration)) {
      onProgress?.call(1);
      return _SliceAudio(path: preparedAudio.audioPath, temporary: false);
    }
    final plan = forceTranscode && !preparedAudio.compatibilityAudio
        ? GongyiAudioPreparation.transcode
        : GongyiAudioPreparationPlan.choose(
            path: preparedAudio.audioPath,
            codec: probe.codec,
            durationSeconds: probe.durationSeconds,
            sliceSeconds: slice.length.inMilliseconds / 1000.0,
            wholeFile: slice.coversEntire(duration),
            isAudioInput: probe.isAudioInput,
            fileBytes: await _safeFileSize(File(preparedAudio.audioPath)),
            audioBitRate: probe.audioBitRate,
            audioStreams: probe.audioStreams,
            hasVideo: probe.hasVideo,
          );
    cancellation.throwIfCancelled();
    if (plan == GongyiAudioPreparation.direct) {
      debugPrint('[transcription] reusing original ${probe.codec} audio');
      onProgress?.call(1);
      return _SliceAudio(
        path: preparedAudio.audioPath,
        temporary: false,
        fastPath: true,
      );
    }
    final maxAttempts = probe.isAudioInput ? 2 : 3;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      cancellation.throwIfCancelled();
      final copy = plan == GongyiAudioPreparation.copy && attempt == 1;
      final out = await _createManagedTempAudioPath(
        extension: copy && probe.codec == 'mp3' ? 'mp3' : 'm4a',
      );
      try {
        onProgress?.call(0);
        await _extractAudioToPath(
          preparedAudio.audioPath,
          out,
          useCopy: copy,
          probe: _MediaProbeInfo(
            codec: probe.codec,
            durationSeconds: slice.length.inMilliseconds / 1000.0,
            hasAudioStream: true,
            isAudioInput: probe.isAudioInput,
          ),
          cancellation: cancellation,
          seekStart: slice.start,
          takeDuration: slice.length,
          inactivityTimeout: const Duration(seconds: 45),
          onProgress: onProgress,
        );
        cancellation.throwIfCancelled();
        final size = await _safeFileSize(File(out));
        if (size < 800) {
          await _deleteFileIfExists(out);
          if (slice.start > Duration.zero) return const _SliceAudio.pastEnd();
          throw const _AudioPreparationException('提取出的音频过短', retryable: true);
        }
        if (copy && size > GongyiAudioPreparationPlan.maximumFastAudioBytes) {
          await _deleteFileIfExists(out);
          debugPrint(
            '[transcription] copied audio exceeded budget; compressing',
          );
          continue;
        }
        onProgress?.call(1);
        return _SliceAudio(
          path: out,
          temporary: true,
          fastPath: copy && !preparedAudio.compatibilityAudio,
        );
      } catch (error) {
        await _deleteFileIfExists(out);
        if (error is _JobCancelledException) rethrow;
        lastError = error;
        final retryable = error is _AudioPreparationException
            ? error.retryable
            : !probe.isAudioInput;
        if (!copy && (!retryable || attempt == maxAttempts)) rethrow;
        debugPrint(
          '[transcription] audio preparation attempt $attempt: $error',
        );
        await cancellation.delay(Duration(milliseconds: 600 * attempt));
      }
    }
    throw lastError ?? Exception('切分音频失败');
  }

  Future<void> _waitWithCountdown(
    _JobCancellation cancellation,
    Duration delay,
    String message,
  ) async {
    final totalSeconds = delay.inSeconds;
    if (totalSeconds <= 0) {
      await cancellation.delay(delay);
      return;
    }
    for (var elapsed = 0; elapsed < totalSeconds; elapsed++) {
      final left = totalSeconds - elapsed;
      _updateStatus(
        TranscriptionStatus.transcribing,
        '$message（$left 秒）',
        _progress,
      );
      await cancellation.delay(const Duration(seconds: 1));
    }
  }

  String _ffmpegSeconds(Duration duration) {
    return (duration.inMilliseconds / 1000.0).toStringAsFixed(3);
  }

  Future<({int bytes, int modifiedMs})> _sourceFingerprint(String path) async {
    try {
      final stat = await File(path).stat();
      return (
        bytes: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
    } catch (error) {
      debugPrint('[transcription] 无法读取源文件指纹: $error');
      return (bytes: 0, modifiedMs: 0);
    }
  }

  Future<TranscriptionCheckpointBook> _openCheckpointBook() async {
    final existing = _checkpointBook;
    if (existing != null) return existing;
    final dir = _persistenceDirPath;
    if (dir == null) {
      return _checkpointBook = TranscriptionCheckpointBook();
    }
    try {
      final file = File(p.join(dir, _checkpointFileName));
      if (await file.exists()) {
        _checkpointBook = TranscriptionCheckpointBook.decode(
          await file.readAsString(),
        );
      } else {
        _checkpointBook = TranscriptionCheckpointBook();
      }
    } catch (error) {
      debugPrint('[transcription] 读取分段进度失败: $error');
      _checkpointBook = TranscriptionCheckpointBook();
    }
    return _checkpointBook!;
  }

  Future<AiSubtitleApiSettings> _translationEndpointFor(
    _TranscriptionJob job,
  ) async {
    final saved = await AiSubtitleApiSettingsStore().load();
    final active = job.translateApiProviderId.isEmpty
        ? saved
        : saved.selecting(job.translateApiProviderId);
    job.translateEndpoint ??= active.copyWith(apiKey: '', profiles: const {});
    final endpoint = job.translateEndpoint!;
    String address(String value) =>
        value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (address(endpoint.baseUrl) != address(active.baseUrl)) {
      throw StateError('翻译接口地址已更改，请从头开始以使用当前接口与语言设置');
    }
    return endpoint.copyWith(apiKey: active.apiKey);
  }

  Future<String> _transcriptionSourceIdentity(String sourcePath) async {
    final fingerprint = await _sourceFingerprint(sourcePath);
    final identity =
        PodcastPlaybackHooks.sourceIdentity?.call(sourcePath) ?? sourcePath;
    return '$identity:${fingerprint.bytes}:${fingerprint.modifiedMs}';
  }

  Future<void> _writeCheckpointBook(TranscriptionCheckpointBook book) async {
    final dir = _persistenceDirPath;
    if (dir == null) return;
    try {
      final file = File(p.join(dir, _checkpointFileName));
      await file.writeAsString(book.encode());
    } catch (error) {
      debugPrint('[transcription] 保存分段进度失败: $error');
    }
  }

  Future<void> _discardCheckpoint(String mediaKey) async {
    try {
      final book = await _openCheckpointBook();
      if (book.tasks.remove(mediaKey) == null) return;
      await _writeCheckpointBook(book);
    } catch (error) {
      debugPrint('[transcription] 删除分段进度失败: $error');
    }
  }

  Future<void> _discardAllCheckpoints() async {
    try {
      _checkpointBook = TranscriptionCheckpointBook();
      final dir = _persistenceDirPath;
      if (dir == null) return;
      final file = File(p.join(dir, _checkpointFileName));
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('[transcription] 清空分段进度失败: $error');
    }
  }

  /// 安全删除文件（不抛异常）
  Future<void> _safeDeleteFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return;
    try {
      await file.delete();
      debugPrint('已删除文件: $path');
    } catch (e) {
      debugPrint('删除文件失败（忽略）: $path, $e');
    }
  }
}

class _TranscriptionJob {
  VideoItem? sourceItem;
  SubtitlePunctuation? subtitlePunctuation;
  String? translationInputPath;
  int streamAssemblyVersion = 3;
  bool streamConfigurationFrozen = false;
  bool subtitleSelectionOverridden = false;
  bool get streamsRecognition =>
      modelSpec?.profile.local == true ||
      modelSpec?.profile.cloudProvider != null;
  bool get streamsCloudTranslation =>
      modelSpec?.profile.local == false &&
      modelSpec?.profile.cloudProvider == null &&
      translateEnabled &&
      translateProviderName == SubtitleTranslateProvider.local.name;
  String? streamJournal;
  AiSubtitleApiSettings? translateEndpoint;
  String checkpointScope;
  bool retryRemoteTasks = false;
  String get checkpointKey =>
      checkpointScope.isEmpty ? mediaKey : '$mediaKey\nrun:$checkpointScope';
  ModelJobSpec? modelSpec;
  ModelJobSpec? translateLocalSpec;
  final String videoPath;
  final String? videoId;
  final String mediaKey;
  final LibraryService? libraryService;
  final bool autoCache;
  final bool isExternal;
  final SubtitleOutputPathStrategy? outputPathStrategy;
  final String? customOutputDir;
  final int createdAt;
  final String displayName;
  String durationLabel;

  /// Recorded when the task is actually started. Unfrozen jobs ignore it.
  bool translateFrozen = false;
  bool translateEnabled = false;
  TranscriptTranslateDirection translateDirection =
      TranscriptTranslateDirection.auto;
  String? translateSourceLanguage, translateTargetLanguage;
  SmartTranslationPolicy? translateSmartPolicy;
  String translateProviderName = SubtitleTranslateProvider.bing.name;
  String translateApiProviderId = '';
  AiSubtitleTranslationSettings translateAiOptions =
      AiSubtitleTranslationSettings.defaults;
  String? translatedSrtPath;
  String? transcriptPath;
  String? transcriptSpecFingerprint;
  String? transcriptSourceIdentity;
  String? transcriptOutputFingerprint;

  _TranscriptionJob({
    required this.videoPath,
    required this.videoId,
    required this.mediaKey,
    required this.libraryService,
    this.sourceItem,
    required this.autoCache,
    this.isExternal = false,
    this.outputPathStrategy,
    this.customOutputDir,
    int? createdAt,
    String? displayName,
    this.durationLabel = '',
    this.checkpointScope = '',
  }) : createdAt = createdAt ?? 0,
       displayName = (displayName == null || displayName.trim().isEmpty)
           ? p.basename(videoPath)
           : displayName.trim();

  void freezeTranslate(TranscriptTranslateChoice choice) {
    translateFrozen = true;
    translateEnabled = choice.enabled;
    translateDirection = choice.direction;
    translateSourceLanguage = choice.sourceLanguage;
    translateTargetLanguage = choice.targetLanguage;
    translateSmartPolicy = choice.smartPolicy;
    translateProviderName = choice.provider.name;
    translateApiProviderId = choice.apiProviderId;
    translateAiOptions = choice.aiOptions;
    translateLocalSpec = choice.localSpecification;
    translateEndpoint = choice.apiEndpoint?.copyWith(
      apiKey: '',
      profiles: const {},
    );
  }

  /// 序列化为 JSON（不含非持久化字段：libraryService、autoCache）
  Map<String, dynamic> toJson() => {
    if (subtitlePunctuation != null)
      'subtitlePunctuation': subtitlePunctuation!.name,
    if (translationInputPath != null)
      'translationInputPath': translationInputPath,
    if (streamJournal != null) 'streamJournal': streamJournal,
    if (streamConfigurationFrozen) 'streamConfigurationFrozen': true,
    if (subtitleSelectionOverridden) 'subtitleSelectionOverridden': true,
    'streamAssemblyVersion': streamAssemblyVersion,
    if (translateEndpoint != null)
      'translateEndpoint': translateEndpoint!.toJson(),
    'videoPath': videoPath,
    if (sourceItem != null) 'sourceItem': _transcriptionSourceJson(sourceItem!),
    if (checkpointScope.isNotEmpty) 'checkpointScope': checkpointScope,
    if (retryRemoteTasks) 'retryRemoteTasks': true,
    if (modelSpec != null) 'modelSpec': modelSpec!.toJson(),
    if (translateLocalSpec != null)
      'translateLocalSpec': translateLocalSpec!.toJson(),
    'videoId': videoId,
    'mediaKey': mediaKey,
    'isExternal': isExternal,
    'outputPathStrategy': outputPathStrategy?.name,
    'customOutputDir': customOutputDir,
    'createdAt': createdAt,
    'displayName': displayName,
    'durationLabel': durationLabel,
    'translateFrozen': translateFrozen,
    'translateEnabled': translateEnabled,
    'translateDirection': translateDirection.name,
    if (translateSourceLanguage != null)
      'translateSourceLanguage': translateSourceLanguage,
    if (translateTargetLanguage != null)
      'translateTargetLanguage': translateTargetLanguage,
    if (translateSmartPolicy != null)
      'translateSmartPolicy': translateSmartPolicy!.toJson(),
    'translateProvider': translateProviderName,
    if (translateApiProviderId.isNotEmpty)
      'translateApiProviderId': translateApiProviderId,
    if (translateEnabled) 'translateAi': translateAiOptions.toJson(),
    if (translatedSrtPath != null) 'translatedSrtPath': translatedSrtPath,
    if (transcriptPath != null) 'transcriptPath': transcriptPath,
    if (transcriptSpecFingerprint != null)
      'transcriptSpecFingerprint': transcriptSpecFingerprint,
    if (transcriptSourceIdentity != null)
      'transcriptSourceIdentity': transcriptSourceIdentity,
    if (transcriptOutputFingerprint != null)
      'transcriptOutputFingerprint': transcriptOutputFingerprint,
  };

  /// 从 JSON 反序列化（libraryService 和 autoCache 在运行时重新注入）
  factory _TranscriptionJob.fromJson(Map<String, dynamic> json) {
    final strategyName = json['outputPathStrategy'] as String?;
    final job = _TranscriptionJob(
      videoPath: json['videoPath'] as String? ?? '',
      videoId: json['videoId'] as String?,
      mediaKey: json['mediaKey'] as String? ?? '',
      libraryService: null,
      sourceItem: json['sourceItem'] is Map
          ? _transcriptionSourceSnapshot(
              VideoItem.fromJson(
                Map<String, dynamic>.from(json['sourceItem'] as Map),
              ),
              json['videoPath'] as String? ?? '',
              json['videoId'] as String?,
            )
          : null,
      autoCache: false,
      isExternal: json['isExternal'] as bool? ?? false,
      outputPathStrategy: strategyName != null
          ? SubtitleOutputPathStrategy.values.firstWhere(
              (e) => e.name == strategyName,
              orElse: () => SubtitleOutputPathStrategy.sameAsVideo,
            )
          : null,
      customOutputDir: json['customOutputDir'] as String?,
      createdAt: json['createdAt'] as int? ?? 0,
      displayName: json['displayName'] as String?,
      durationLabel: json['durationLabel'] as String? ?? '',
      checkpointScope: json['checkpointScope'] as String? ?? '',
    );
    final modelJson = json['modelSpec'];
    job.retryRemoteTasks = json['retryRemoteTasks'] == true;
    job.modelSpec = modelJson is Map
        ? ModelJobSpec.fromJson(Map<String, dynamic>.from(modelJson))
        : null;
    if (json['translateLocalSpec'] is Map) {
      job.translateLocalSpec = ModelJobSpec.fromJson(
        Map<String, dynamic>.from(json['translateLocalSpec'] as Map),
      );
    }
    job.translateFrozen = json['translateFrozen'] == true;
    job.translateEnabled = json['translateEnabled'] == true;
    job.translateDirection = TranscriptTranslateDirection.fromStorage(
      json['translateDirection'] as String?,
    );
    job.translateSourceLanguage = json['translateSourceLanguage'] as String?;
    job.translateTargetLanguage = json['translateTargetLanguage'] as String?;
    if (json['translateSmartPolicy'] is Map) {
      job.translateSmartPolicy = SmartTranslationPolicy.fromJson(
        json['translateSmartPolicy'] as Map,
      );
    }
    final providerName = json['translateProvider'] as String?;
    if (providerName != null && providerName.isNotEmpty) {
      job.translateProviderName = subtitleTranslateProviderFromName(
        providerName,
      ).name;
    }
    job.translateApiProviderId =
        json['translateApiProviderId'] as String? ?? '';
    final aiJson = json['translateAi'];
    if (aiJson is Map) {
      job.translateAiOptions = AiSubtitleTranslationSettings.fromJson(
        Map<String, dynamic>.from(aiJson),
      );
    }
    final translated = json['translatedSrtPath'] as String?;
    if (translated != null && translated.isNotEmpty) {
      job.translatedSrtPath = translated;
    }
    job.streamJournal = json['streamJournal'] as String?;
    job.streamConfigurationFrozen = json['streamConfigurationFrozen'] == true;
    job.subtitleSelectionOverridden =
        json['subtitleSelectionOverridden'] == true;
    // Existing generations retain their published text after an app update.
    job.subtitlePunctuation = json.containsKey('subtitlePunctuation')
        ? SubtitlePunctuation.fromStorage(
            json['subtitlePunctuation'],
            fallback: SubtitlePunctuation.preserve,
          )
        : (job.streamConfigurationFrozen || json['transcriptPath'] != null
              ? SubtitlePunctuation.preserve
              : null);
    job.translationInputPath = json['translationInputPath'] as String?;
    job.streamAssemblyVersion =
        (json['streamAssemblyVersion'] as num?)?.toInt() ?? 1;
    if (json['translateEndpoint'] is Map) {
      job.translateEndpoint = AiSubtitleApiSettings.fromJson(
        Map<String, dynamic>.from(json['translateEndpoint'] as Map),
      );
    }
    job.transcriptPath = json['transcriptPath'] as String?;
    job.transcriptSpecFingerprint =
        json['transcriptSpecFingerprint'] as String?;
    job.transcriptSourceIdentity = json['transcriptSourceIdentity'] as String?;
    job.transcriptOutputFingerprint =
        json['transcriptOutputFingerprint'] as String?;
    return job;
  }
}

class _JobCancellation {
  final CancelToken dioCancelToken = CancelToken();
  final Completer<void> _cancelled = Completer<void>();
  bool _timedOut = false;
  String _reason = '任务已取消';

  bool get isCancelled => _cancelled.isCompleted;
  String get reason => _reason;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel(String reason, {bool timedOut = false}) {
    if (isCancelled) return;
    _reason = reason;
    _timedOut = timedOut;
    dioCancelToken.cancel(reason);
    _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw _JobCancelledException(_reason, timedOut: _timedOut);
    }
  }

  Future<void> delay(Duration duration) async {
    throwIfCancelled();
    await Future.any<void>([Future<void>.delayed(duration), whenCancelled]);
    throwIfCancelled();
  }
}

class _JobCancelledException implements Exception {
  final String message;
  final bool timedOut;

  const _JobCancelledException(this.message, {this.timedOut = false});

  @override
  String toString() => message;
}

class _SliceAudio {
  final String path;
  final bool temporary;
  final bool pastEnd;
  final bool fastPath;

  const _SliceAudio({
    required this.path,
    required this.temporary,
    this.fastPath = false,
  }) : pastEnd = false;

  const _SliceAudio.pastEnd()
    : path = '',
      temporary = false,
      pastEnd = true,
      fastPath = false;
}

class _PreparedAudioResult {
  final String audioPath;
  final _MediaProbeInfo probe;
  final bool isTemporary;
  final bool compatibilityAudio;

  const _PreparedAudioResult({
    required this.audioPath,
    required this.probe,
    this.isTemporary = false,
    this.compatibilityAudio = false,
  });
}

class _MediaProbeInfo {
  final String? codec;
  final int? channels;
  final int? audioBitRate;
  final double audioStartOffsetSeconds;
  final int audioStreams;
  final bool hasVideo;
  final double? durationSeconds;
  final bool hasAudioStream;
  final bool isAudioInput;

  const _MediaProbeInfo({
    required this.codec,
    this.channels,
    this.audioBitRate,
    this.audioStartOffsetSeconds = 0,
    this.audioStreams = 1,
    this.hasVideo = false,
    required this.durationSeconds,
    required this.hasAudioStream,
    required this.isAudioInput,
  });
}

class _AudioPreparationException implements Exception {
  final String message;
  final bool retryable;

  const _AudioPreparationException(this.message, {this.retryable = false});

  @override
  String toString() => message;
}
