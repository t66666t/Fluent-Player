import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as im;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../models/managed_subtitle_asset.dart';
import '../models/media_source_ref.dart';
import '../models/ocr_subtitle_models.dart';
import '../models/ocr_compute_preferences.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_stream.dart';
import '../utils/ffmpeg_utils.dart';
import 'library_service.dart';
import 'media_materialization_service.dart';
import 'ocr_duration_estimator.dart';
import 'ocr_model_manager.dart';
import 'ocr_processing_worker.dart';
import 'ocr_process_worker.dart';
import 'ocr_compute_service.dart';
import 'ocr_compute_policy.dart';
import 'ocr_android_worker.dart';
import '../features/model_center/inference_scheduler.dart';
import '../features/model_center/device_resource_monitor.dart';
import '../features/model_center/inference_resource_governor.dart';
import '../features/model_center/inference_tuning.dart';
import 'ocr_frame_pipeline.dart';
import 'ocr_execution_policy.dart';
import 'ocr_progress_tracker.dart';
import 'ocr_processing_keep_awake.dart';
import 'ocr_subtitle_stream.dart';
import 'subtitle_stream_source.dart';
import 'settings_service.dart';

export 'ocr_progress_tracker.dart' show OcrTaskProgressTracker;

class OcrSubtitleManager extends ChangeNotifier
    implements SubtitleStreamSource {
  static const _persistenceKey = 'ocrSubtitleActiveJobV1';
  static const _streamKey = 'ocrSubtitleStreamV1';
  final _streamEvents = StreamController<SubtitleStreamUpdate>.broadcast(
    sync: true,
  );
  final _streamStarts = StreamController<SubtitleGenerationStart>.broadcast(
    sync: true,
  );
  final _streamStates = <String, SubtitleStreamUpdate>{};
  OcrSubtitleStream? _streamRun;
  Completer<void>? _runFinished;
  bool _disposed = false;
  OcrSubtitleJob? _startingRequest;
  bool _selectionSuppressedDuringStart = false;
  @override
  bool Function(String)? shouldSelectGeneratedSubtitles;
  @override
  final ValueNotifier<int> subtitleFilesRevision = ValueNotifier<int>(0);
  @override
  Stream<SubtitleStreamUpdate> get subtitleUpdates => _streamEvents.stream;
  @override
  Stream<SubtitleGenerationStart> get subtitleGenerationStarts =>
      _streamStarts.stream;
  @override
  Iterable<SubtitleStreamUpdate> get subtitleStreams => _streamStates.values;
  bool get streamingPlaybackAttached => shouldSelectGeneratedSubtitles != null;
  String? get pendingRecoveryDirectory =>
      _streamRun != null && !_streamRun!.complete
      ? _streamRun!.directory.path
      : null;
  bool canResumeConfiguration({
    required String videoId,
    required List<OcrSubtitleTrack> tracks,
    required Duration start,
    required Duration end,
    required bool mirrorHorizontal,
    required bool mirrorVertical,
    String? videoQualityId,
  }) {
    final run = _streamRun;
    if (run == null || run.complete) return false;
    final saved = run.request;
    final frozen = saved['tracks'] as List;
    if (saved['videoId'] != videoId ||
        saved['videoQualityId'] != videoQualityId ||
        saved['startMs'] != start.inMilliseconds ||
        saved['endMs'] != end.inMilliseconds ||
        frozen.length != tracks.length ||
        saved['mirrorHorizontal'] != mirrorHorizontal ||
        saved['mirrorVertical'] != mirrorVertical) {
      return false;
    }
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i], previous = frozen[i] as Map;
      if (previous['modelId'] != track.modelId ||
          previous['language'] != track.language.name ||
          jsonEncode(previous['region']) != jsonEncode(track.region.toJson())) {
        return false;
      }
    }
    return true;
  }

  // Kept injectable for native A/B validation; not an additional user setting.
  final bool incrementalOutput;
  static const _regionsPersistenceKey = 'ocrSubtitleRegionsV1';
  static const _tracksPersistenceKey = 'ocrSubtitleTracksV1';
  static const _keepAwakePersistenceKey =
      'ocrSubtitleKeepScreenAwakeDuringProcessing';
  static const _modelSelectionsPersistenceKey = 'ocrSubtitleModelSelectionsV1';
  static const _performanceProfilePrefix = 'ocrSubtitlePerformanceV4';
  final LibraryService library;
  final OcrModelManager modelManager;
  final OcrComputeService computeService;
  final processingKeepAwake = OcrProcessingKeepAwake();
  OcrComputePreferences _computePreferences = const OcrComputePreferences();
  final _activeWorkers = <OcrWorker>{};
  OcrSubtitleJob? _job;
  bool _cancelled = false;
  bool _starting = false;
  FFmpegSession? _activeSession;
  Process? _activeProcess;
  OcrRawExtractor? _rawExtractor;
  Map<String, Object?> lastPerformance = const {};
  Completer<void>? _materializationCancellation;
  Completer<void>? _inferenceCancellation;
  MediaMaterializationProgress? _materializationProgress;
  List<String> _completedPaths = const <String>[];
  String _activeBackend = '自动选择中';
  Timer? _notifyTimer;
  Timer? _persistTimer;
  DateTime _lastNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _persistChain = Future<void>.value();
  Future<void>? _initialization;
  Future<void>? _performanceInitialization;
  final OcrPerformanceHistory _performanceHistory = OcrPerformanceHistory(
    mobile: Platform.isAndroid || Platform.isIOS,
  );
  OcrRuntimeEstimate? _runtimeEstimate;
  Timer? _estimateTimer;
  final Map<String, List<OcrSubtitleTrack>> _tracksByVideo = {};
  final Map<String, String> _videoQualities = {};

  String? videoQualityFor(String videoId) =>
      _videoQualities[videoId] ??
      (_job?.videoId == videoId ? _job?.videoQualityId : null);

  void rememberVideoQuality(String videoId, String qualityId) {
    _videoQualities[videoId] = qualityId;
  }

  final Map<OcrSubtitleLanguage, String> _rememberedModelIds = {};
  List<OcrSubtitleTrack> _defaultTracks = const [
    OcrSubtitleTrack(
      number: 1,
      region: NormalizedOcrRegion.subtitleDefault(),
      language: OcrSubtitleLanguage.chinese,
    ),
  ];
  final Map<String, String> _estimateIdentities = {};

  String _estimateSelectionKey(OcrSubtitleTrack track) =>
      '${track.language.name}:${track.modelId}';

  OcrSubtitleManager({
    required this.library,
    OcrModelManager? modelManager,
    OcrComputeService? computeService,
    this.incrementalOutput = true,
  }) : modelManager = modelManager ?? const OcrModelManager(),
       computeService = computeService ?? OcrComputeService() {
    library.addListener(_handleLibraryChanged);
  }

  OcrSubtitleJob? get job => _job;
  bool get isRunning => _job?.isRunning ?? false;
  @override
  SubtitleStreamUpdate? streamForVideo(String path, {String? videoId}) =>
      _streamStates.values
          .where(
            (s) =>
                s.videoPath == path || videoId != null && s.videoId == videoId,
          )
          .firstOrNull;
  @override
  bool hasSubtitleStreamForVideo(String path, {String? videoId}) =>
      streamForVideo(path, videoId: videoId) != null;
  @override
  SubtitleStreamUpdate? streamForPath(String path) =>
      _streamStates.values.where((s) => s.paths.contains(path)).firstOrNull;
  @override
  bool subtitleSelectionOverridden(String key) =>
      _streamRun?.selectionOverridden == true &&
      key.startsWith('${_streamRun!.mediaKey}:');
  @override
  void preserveSubtitleSelection(String path, {String? videoId}) {
    final pending = _startingRequest;
    if (pending != null &&
        (pending.videoPath == path || pending.videoId == videoId)) {
      _selectionSuppressedDuringStart = true;
    }
    final run = _streamRun;
    if (run == null ||
        run.complete ||
        !(run.request['videoPath'] == path ||
            run.request['videoId'] == videoId)) {
      return;
    }
    unawaited(
      run.preserveSelection().catchError((Object error) {
        debugPrint('OCR 字幕选择保存失败：$error');
      }),
    );
  }

  @override
  Future<void> stopStreamForPath(String path) async {
    if (streamForPath(path) == null) return;
    final done = _runFinished?.future;
    await cancel();
    await done;
    await _persistChain;
  }

  @override
  void resumeStreamForPath(String path) {
    final run = _streamRun;
    if (run == null ||
        run.complete ||
        isRunning ||
        _starting ||
        streamForPath(path) == null) {
      return;
    }
    unawaited(
      start(_jobFromStream(run)).catchError((Object error) {
        debugPrint('OCR 字幕恢复失败：$error');
      }),
    );
  }

  @override
  void forgetStreamForPath(String path) {
    if (streamForPath(path) == null || isRunning) return;
    _streamStates.clear();
    _streamRun?.releaseMemory();
    _streamRun = null;
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.remove(_streamKey))
          .catchError((Object error) {
            debugPrint('OCR 字幕恢复引用清理失败：$error');
            return false;
          }),
    );
    if (!_disposed) subtitleFilesRevision.value++;
  }

  String get activeBackend => _activeBackend;
  OcrComputePreferences get computePreferences => _computePreferences;
  bool get keepScreenAwakeDuringProcessing => processingKeepAwake.enabled;

  Future<void> setKeepScreenAwakeDuringProcessing(bool value) async {
    await initialize();
    processingKeepAwake.setEnabled(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepAwakePersistenceKey, value);
  }

  Future<void> setComputePreferences(OcrComputePreferences value) async {
    await initialize();
    if (isRunning || _starting) return;
    if (value.signature == _computePreferences.signature) return;
    _computePreferences = value;
    notifyListeners();
    await computeService.savePreferences(value);
  }

  Future<OcrComputeCapabilities> detectComputeDevices({bool refresh = false}) =>
      computeService.capabilities(refresh: refresh);
  MediaMaterializationProgress? get materializationProgress =>
      _materializationProgress;

  List<OcrSubtitleTrack> tracksForVideo(String videoId) {
    final modelId = rememberedModelIdFor(OcrSubtitleLanguage.chinese);
    // Keep track identity stable between choices so progress notifications do
    // not rebuild the panel's scrollable settings on every tick.
    if (_defaultTracks.first.modelId != modelId) {
      _defaultTracks = [_defaultTracks.first.copyWith(modelId: modelId)];
    }
    return List.unmodifiable(
      _tracksByVideo[videoId] ??
          (_job?.videoId == videoId ? _job!.tracks : null) ??
          _defaultTracks,
    );
  }

  String rememberedModelIdFor(OcrSubtitleLanguage language) =>
      _rememberedModelIds[language] ?? '';

  /// Only explicit model choices update defaults; opening an older video or
  /// restarting its task must preserve the user's latest choice for new videos.
  Future<void> rememberModelSelection(
    OcrSubtitleLanguage language,
    String modelId,
  ) async {
    await initialize();
    final presets = await modelManager.presets();
    if (modelId.isNotEmpty &&
        !presets.any(
          (model) => model.id == modelId && model.supports(language),
        )) {
      return;
    }
    if (modelId.isEmpty) {
      _rememberedModelIds.remove(language);
    } else {
      _rememberedModelIds[language] = modelId;
    }
    await _persistModelSelections();
  }

  void rememberTracks(String videoId, List<OcrSubtitleTrack> tracks) {
    _tracksByVideo[videoId] = _normalizeTracks(tracks);
    unawaited(_persistTracks());
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    processingKeepAwake.setEnabled(
      prefs.getBool(_keepAwakePersistenceKey) ?? true,
    );
    _computePreferences = await computeService.loadPreferences();
    await _loadPerformanceHistory();
    // Removed feature cleanup: discard cached automatic region proposals from
    // previous app versions. Manual OCR regions are stored under a separate key.
    await prefs.remove('ocrRegionDiscoveryCacheV1');
    final selectionsRaw = prefs.getString(_modelSelectionsPersistenceKey);
    if (selectionsRaw != null && selectionsRaw.isNotEmpty) {
      try {
        final selections = jsonDecode(selectionsRaw) as Map<String, dynamic>;
        final presets = await modelManager.presets();
        var migratedSelections = false;
        for (final language in OcrSubtitleLanguage.values) {
          final modelId = selections[language.name];
          if (modelId is! String || modelId.isEmpty) continue;
          final track = migrateRetiredOcrTrack(
            OcrSubtitleTrack(
              number: 1,
              region: const NormalizedOcrRegion.subtitleDefault(),
              language: language,
              modelId: modelId,
            ),
          );
          if (presets.any(
            (model) => model.id == track.modelId && model.supports(language),
          )) {
            _rememberedModelIds[language] = track.modelId;
            migratedSelections |= track.modelId != modelId;
          }
        }
        if (migratedSelections) await _persistModelSelections();
      } catch (error) {
        debugPrint('OCR model selection restore failed: $error');
        await prefs.remove(_modelSelectionsPersistenceKey);
      }
    }
    final tracksRaw = prefs.getString(_tracksPersistenceKey);
    if (tracksRaw != null && tracksRaw.isNotEmpty) {
      try {
        final tracksJson = jsonDecode(tracksRaw) as Map<String, dynamic>;
        var migratedSelections = false;
        for (final entry in tracksJson.entries) {
          final values = entry.value as List<dynamic>? ?? const <dynamic>[];
          final tracks = values
              .whereType<Map>()
              .map(
                (value) =>
                    OcrSubtitleTrack.fromJson(Map<String, dynamic>.from(value)),
              )
              .toList();
          if (tracks.isNotEmpty) {
            _tracksByVideo[entry.key] = _normalizeTracks(tracks);
            migratedSelections |= tracks.any(
              (track) => track.modelId == 'ppocr-v6-tiny',
            );
          }
        }
        if (migratedSelections) await _persistTracks();
      } catch (error) {
        debugPrint('OCR track persistence restore failed: $error');
        await prefs.remove(_tracksPersistenceKey);
      }
    }
    final regionsRaw = prefs.getString(_regionsPersistenceKey);
    if (regionsRaw != null && regionsRaw.isNotEmpty) {
      try {
        final regionsJson = jsonDecode(regionsRaw) as Map<String, dynamic>;
        for (final entry in regionsJson.entries) {
          final value = entry.value;
          if (value is Map) {
            final region = NormalizedOcrRegion.fromJson(
              Map<String, dynamic>.from(value),
            );
            _tracksByVideo.putIfAbsent(
              entry.key,
              () => <OcrSubtitleTrack>[
                OcrSubtitleTrack(
                  number: 1,
                  region: region,
                  language: OcrSubtitleLanguage.chinese,
                ),
              ],
            );
          }
        }
      } catch (error) {
        debugPrint('OCR region persistence restore failed: $error');
        await prefs.remove(_regionsPersistenceKey);
      }
    }
    final raw = prefs.getString(_persistenceKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final status = OcrSubtitleJobStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => OcrSubtitleJobStatus.interrupted,
        );
        final restoredTracks = (json['tracks'] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (value) =>
                  OcrSubtitleTrack.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList();
        final restored = OcrSubtitleJob(
          videoQualityId: json['videoQualityId'] as String?,
          compute: json.containsKey('compute')
              ? OcrComputePreferences.fromJson(json['compute'])
              : null,
          videoId: json['videoId']?.toString() ?? '',
          videoPath: json['videoPath']?.toString() ?? '',
          tracks: restoredTracks?.isNotEmpty == true
              ? _normalizeTracks(restoredTracks!)
              : <OcrSubtitleTrack>[
                  OcrSubtitleTrack(
                    number: 1,
                    language: OcrSubtitleLanguage.values.firstWhere(
                      (value) => value.name == json['language'],
                      orElse: () => OcrSubtitleLanguage.chinese,
                    ),
                    region: NormalizedOcrRegion.fromJson(
                      Map<String, dynamic>.from(
                        json['region'] as Map? ?? const {},
                      ),
                    ),
                  ),
                ],
          start: Duration(milliseconds: json['startMs'] as int? ?? 0),
          end: Duration(milliseconds: json['endMs'] as int? ?? 0),
          mirrorHorizontal: json['mirrorHorizontal'] as bool? ?? false,
          mirrorVertical: json['mirrorVertical'] as bool? ?? false,
          status: status,
          progress: (json['progress'] as num?)?.toDouble() ?? 0,
          statusMessage: json['statusMessage']?.toString() ?? '',
          outputPaths:
              (json['outputPaths'] as List<dynamic>?)
                  ?.map((value) => value.toString())
                  .toList() ??
              <String>[
                if (json['outputPath']?.toString().isNotEmpty == true)
                  json['outputPath'].toString(),
              ],
        );
        _job = restored.isRunning
            ? restored.copyWith(
                status: OcrSubtitleJobStatus.interrupted,
                statusMessage: '上次 OCR 任务被中断，临时帧已清理，可重新开始',
              )
            : restored;
      } catch (_) {
        await prefs.remove(_persistenceKey);
      }
    }
    if (incrementalOutput) {
      final directory = prefs.getString(_streamKey);
      if (directory != null) {
        try {
          final root = await SettingsService().resolveLargeDataRootDir();
          final relocated = Directory(
            p.join(
              root.path,
              'subtitles',
              'ocr_streams',
              p.basename(directory),
            ),
          );
          final run = await OcrSubtitleStream.open(
            await relocated.exists() ? relocated : Directory(directory),
          );
          _jobFromStream(run);
          _streamRun = run;
          if (_job?.videoId == run.request['videoId']) {
            _job = _job!.copyWith(
              videoPath: run.request['videoPath'] as String,
            );
          }
          if (!run.complete) {
            for (final store in run.stores.values) {
              if (!store.reconciled) store.phase = SubtitleStreamPhase.paused;
            }
          }
          _publishStream(run);
          if (run.complete) {
            final job = _job;
            final expected = Map<String, dynamic>.from(run.request)
              ..remove('compute');
            final current = job == null
                ? null
                : _streamRequest(job, job.videoPath);
            current?.remove('compute');
            if (job != null &&
                jsonEncode(current) == jsonEncode(expected) &&
                job.status != OcrSubtitleJobStatus.completed) {
              _job = job.copyWith(
                status: OcrSubtitleJobStatus.completed,
                progress: 1,
                outputPaths: run.paths,
                statusMessage: 'OCR 字幕已恢复并保存',
              );
              _queuePersist(_job!);
            }
            run.releaseMemory();
          }
        } catch (error) {
          _streamRun = null;
          _streamStates.clear();
          debugPrint('OCR 字幕恢复记录读取失败，保留原文件：$error');
        }
      }
    }
    await cleanupStaleTemporaryFiles();
  }

  bool isModelBundled(OcrSubtitleLanguage language) =>
      modelManager.isBundled(language);

  int bundledModelCountFor(OcrSubtitleLanguage language) =>
      modelManager.bundledModelCountFor(language);

  int get totalBundledOnnxModelCount => modelManager.totalBundledOnnxModelCount;

  List<String>? consumeCompletedPaths(String videoId) {
    if (_job?.videoId != videoId) return null;
    final value = _completedPaths;
    _completedPaths = const <String>[];
    return value;
  }

  Future<bool> isModelInstalled(OcrSubtitleLanguage language) =>
      modelManager.isInstalled(language);
  Future<bool> isTrackModelInstalled(OcrSubtitleTrack track) =>
      track.modelId.isEmpty
      ? isModelInstalled(track.language)
      : modelManager.isInstalled(track.language, modelId: track.modelId);

  Future<Duration> estimateDuration({
    required Duration mediaDuration,
    required Duration start,
    required Duration end,
    int trackCount = 1,
    List<OcrSubtitleTrack>? tracks,
    String? videoId,
  }) async {
    await _loadPerformanceHistory();
    final durationMs = math.max(0, mediaDuration.inMilliseconds);
    final startMs = start.inMilliseconds.clamp(0, durationMs);
    final endMs = end.inMilliseconds.clamp(0, durationMs);
    final selectedTracks =
        tracks ??
        List.generate(
          math.max(1, trackCount),
          (i) => OcrSubtitleTrack(
            number: i + 1,
            region: const NormalizedOcrRegion.subtitleDefault(),
            language: OcrSubtitleLanguage.chinese,
          ),
        );
    final resolvedTracks = <OcrSubtitleTrack>[];
    for (final track in selectedTracks) {
      final resolved = await modelManager.resolveTrackIdentity(track);
      _estimateIdentities[_estimateSelectionKey(track)] =
          resolved.modelIdentity;
      resolvedTracks.add(resolved);
    }
    return _performanceHistory.estimate(
      spanMs: math.max(0, endMs - startMs),
      videoId: videoId == null ? null : _performanceSourceId(videoId),
      tracks: resolvedTracks,
      pipeline: true,
      startMs: startMs,
    );
  }

  bool hasDurationMeasurements(String videoId, List<OcrSubtitleTrack> tracks) =>
      _performanceHistory.hasMeasurements(
        _performanceSourceId(videoId),
        tracks
            .map(
              (track) => track.copyWith(
                modelIdentity:
                    _estimateIdentities[_estimateSelectionKey(track)] ??
                    track.modelIdentity,
              ),
            )
            .toList(),
      );

  String _performanceSourceId(String videoId) {
    final item = library.getVideo(videoId);
    return '$videoId:${item?.sourceFingerprint ?? ''}:'
        '${item?.isVideoMirroredH ?? false}:${item?.isVideoMirroredV ?? false}';
  }

  String get _performanceProfileKey =>
      '$_performanceProfilePrefix.${Platform.operatingSystem}.${Platform.numberOfProcessors}';

  Future<void> _loadPerformanceHistory() =>
      _performanceInitialization ??= _restorePerformanceHistory();

  Future<void> _restorePerformanceHistory() async {
    final prefs = await SharedPreferences.getInstance();
    _performanceHistory.useLegacyProcessingRate(
      prefs.getDouble(
        'ocrSubtitlePerformanceV2.${Platform.operatingSystem}.${Platform.numberOfProcessors}',
      ),
    );
    final raw = prefs.getString(_performanceProfileKey);
    if (raw == null) return;
    try {
      _performanceHistory.restore(jsonDecode(raw));
    } catch (error) {
      debugPrint('OCR performance profile restore failed: $error');
    }
  }

  void _savePerformanceHistory() {
    // One bounded snapshot per job, queued after the recognition hot path.
    final snapshot = jsonEncode(_performanceHistory.toJson());
    _persistChain = _persistChain
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_performanceProfileKey, snapshot);
        })
        .catchError((Object error) {
          debugPrint('OCR performance profile save failed: $error');
        });
  }

  void _publishRemaining() {
    final current = _job;
    final estimate = _runtimeEstimate;
    if (current == null ||
        !current.isRunning ||
        estimate == null ||
        current.status == OcrSubtitleJobStatus.downloading ||
        current.status == OcrSubtitleJobStatus.materializing) {
      return;
    }
    final remaining = estimate.hasMeasurements ? estimate.remaining : null;
    if (remaining?.inSeconds != current.remaining?.inSeconds) {
      _update(
        current.copyWith(
          remaining: remaining,
          clearRemaining: remaining == null,
        ),
        persist: false,
      );
    }
  }

  Future<String> captureFrame({
    required String videoId,
    required String videoPath,
    required Duration position,
    bool mirrorHorizontal = false,
    bool mirrorVertical = false,
    int? maxWidth,
    bool fastPreview = false,
    String? videoQualityId,
    void Function(MediaMaterializationProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    await initialize();
    MaterializedMediaLease? frameLease;
    var effectiveVideoPath = videoPath;
    final sourceItem = library.getVideo(videoId);
    final online =
        sourceItem != null &&
        itemNeedsOnlineMaterialization(
          source: sourceItem.sourceRef,
          path: sourceItem.path,
        );
    final cloud =
        sourceItem != null &&
        isCloudDriveMedia(source: sourceItem.sourceRef, path: sourceItem.path);
    if (online) {
      frameLease = await library.acquireMaterializedMedia(
        videoId,
        MediaMaterializationRequirement.videoFrames,
        targetHeight: cloud || videoQualityId != null ? null : 1080,
        qualityId: videoQualityId,
        onProgress: onProgress,
        cancelSignal: cancelSignal,
      );
      effectiveVideoPath = frameLease.requiredVideoPath;
    }
    try {
      final root = await SettingsService().resolveLargeDataRootDir();
      final dir = Directory(
        p.join(root.path, 'ocr_temp', _safeId(videoId), 'preview'),
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      final output = p.join(
        dir.path,
        'preview_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      final attempts = fastPreview
          ? <Duration>[position]
          : <Duration>[
              position,
              if (position > const Duration(milliseconds: 500))
                position - const Duration(milliseconds: 500),
              if (position != Duration.zero) Duration.zero,
            ];
      String lastError = '';
      for (final at in attempts) {
        if (Platform.isAndroid || Platform.isIOS) {
          try {
            final bytes = await VideoThumbnail.thumbnailData(
              video: effectiveVideoPath,
              imageFormat: ImageFormat.JPEG,
              maxWidth: maxWidth ?? 0,
              timeMs: math.max(0, at.inMilliseconds),
              quality: fastPreview ? 40 : 90,
            );
            if (bytes != null && bytes.isNotEmpty) {
              List<int> outputBytes = bytes;
              if (mirrorHorizontal || mirrorVertical) {
                var image = im.decodeImage(bytes);
                if (image == null) throw StateError('无法解码原生预览帧');
                if (mirrorHorizontal) image = im.flipHorizontal(image);
                if (mirrorVertical) image = im.flipVertical(image);
                outputBytes = im.encodeJpg(
                  image,
                  quality: fastPreview ? 45 : 92,
                );
              }
              await File(output).writeAsBytes(outputBytes, flush: true);
              if (await _isUsableImage(output)) return output;
            }
          } catch (error) {
            lastError = '原生视频帧提取失败：$error';
            final failedOutput = File(output);
            if (await failedOutput.exists()) await failedOutput.delete();
          }
        }
        final args = <String>[
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-ss',
          _seconds(at),
          if (fastPreview) '-noaccurate_seek',
          '-i',
          effectiveVideoPath,
          '-map',
          '0:v:0',
          '-frames:v',
          '1',
          if (mirrorHorizontal || mirrorVertical || maxWidth != null) ...[
            '-vf',
            [
              if (mirrorHorizontal) 'hflip',
              if (mirrorVertical) 'vflip',
              if (maxWidth != null)
                'scale=trunc(min(iw\\,$maxWidth)/2)*2:-2:flags=fast_bilinear',
            ].join(','),
          ],
          '-q:v',
          fastPreview ? '6' : '2',
          '-c:v',
          'mjpeg',
          '-f',
          'image2',
          output,
        ];
        if (FFmpegUtils.preferSystemFfmpeg) {
          try {
            await FFmpegUtils.ensureAvailable();
            final ffmpegPath = await FFmpegUtils.ffmpegPath;
            final result = await Process.run(
              ffmpegPath,
              args,
            ).timeout(const Duration(seconds: 30));
            if (result.exitCode == 0 && await _isUsableImage(output)) {
              return output;
            }
            lastError = result.stderr?.toString().trim() ?? '';
          } catch (error) {
            lastError = error.toString();
          }
        } else {
          final session = await FFmpegKit.executeWithArguments(args);
          if (ReturnCode.isSuccess(await session.getReturnCode()) &&
              await _isUsableImage(output)) {
            return output;
          }
          lastError = (await session.getAllLogsAsString() ?? '').trim();
        }
        final failedOutput = File(output);
        if (await failedOutput.exists()) await failedOutput.delete();
      }
      debugPrint('OCR preview frame extraction failed: $lastError');
      final reason = _shortFfmpegError(lastError);
      if (reason.isEmpty) {
        throw StateError('无法提取当前视频画面');
      }
      throw StateError('无法提取当前视频画面：$reason');
    } finally {
      await frameLease?.release();
    }
  }

  Future<void> deletePreview(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final root = await SettingsService().resolveLargeDataRootDir();
      final previewRoot = p.join(root.path, 'ocr_temp');
      if (!p.isWithin(previewRoot, path)) return;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> cleanupTemporaryFilesForVideo(String videoId) async {
    try {
      final root = await SettingsService().resolveLargeDataRootDir();
      final directory = Directory(
        p.join(root.path, 'ocr_temp', _safeId(videoId)),
      );
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (error) {
      debugPrint('OCR temporary cleanup failed for $videoId: $error');
    }
  }

  Future<void> cleanupStaleTemporaryFiles() async {
    try {
      final root = await SettingsService().resolveLargeDataRootDir();
      final temporaryRoot = Directory(p.join(root.path, 'ocr_temp'));
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
      await temporaryRoot.create(recursive: true);

      final tasksRoot = Directory(p.join(root.path, 'subtitles', 'tasks'));
      if (await tasksRoot.exists()) {
        await for (final entity in tasksRoot.list(recursive: true)) {
          if (entity is File && entity.path.endsWith('.partial')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (error) {
      debugPrint('OCR stale temporary cleanup failed: $error');
    }
  }

  Future<bool> _isUsableImage(String path) async {
    final file = File(path);
    return await file.exists() && await file.length() > 0;
  }

  String _shortFfmpegError(String value) {
    final lines = value
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    final text = lines.last;
    return text.length <= 160 ? text : text.substring(text.length - 160);
  }

  Future<void> start(OcrSubtitleJob request) async {
    if (_starting || isRunning) throw StateError('已有 OCR 字幕任务正在运行');
    _starting = true;
    _startingRequest = request;
    _selectionSuppressedDuringStart = false;
    final finished = _runFinished = Completer<void>();
    try {
      await _start(request);
    } finally {
      _starting = false;
      _startingRequest = null;
      finished.complete();
    }
  }

  Future<void> _start(OcrSubtitleJob request) async {
    await initialize();
    if (isRunning) throw StateError('已有 OCR 字幕任务正在运行');
    await modelManager.initialize();
    final normalizedTracks = <OcrSubtitleTrack>[];
    for (final track in _normalizeTracks(request.tracks)) {
      normalizedTracks.add(
        await modelManager.freeze(track, requireInstalled: false),
      );
    }
    if (normalizedTracks.isEmpty) throw StateError('请至少保留一个 OCR 字幕区域');
    request = request.copyWith(
      tracks: normalizedTracks,
      compute: request.compute ?? _computePreferences,
    );
    final sourceVideoPath = request.videoPath;
    final compute = request.compute!;
    if (request.end <= request.start) throw StateError('OCR 时间范围无效');
    final recognitionProgress = OcrRegionProgressTracker(
      startMs: request.start.inMilliseconds,
      spanMs: math.max(1, (request.end - request.start).inMilliseconds),
      tracks: normalizedTracks.map((track) => track.number),
    );
    rememberTracks(request.videoId, normalizedTracks);
    _cancelled = false;
    final inferenceCancellation = Completer<void>();
    _inferenceCancellation = inferenceCancellation;
    _completedPaths = const <String>[];
    _activeBackend = '自动选择中';
    final timingSourceId = _performanceSourceId(request.videoId);
    final taskWatch = Stopwatch()..start();
    final runtimeEstimate = OcrRuntimeEstimate(
      history: _performanceHistory,
      videoId: timingSourceId,
      tracks: normalizedTracks,
      spanMs: (request.end - request.start).inMilliseconds,
      startMs: request.start.inMilliseconds,
      pipeline: true,
      elapsedMs: () => taskWatch.elapsedMilliseconds,
    );
    _runtimeEstimate = runtimeEstimate;
    _estimateTimer?.cancel();
    _estimateTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _publishRemaining(),
    );
    _update(
      request.copyWith(
        status: OcrSubtitleJobStatus.preparing,
        progress: 0,
        clearPreparationProgress: true,
        recognitionProgress: recognitionProgress.snapshot,
        remaining: runtimeEstimate.remaining,
        clearRemaining: !runtimeEstimate.hasMeasurements,
        statusMessage: '正在准备 OCR 字幕任务',
      ),
    );
    final workers = <OcrWorker>[];
    void Function()? releaseInference;
    InferenceResourceSession? resources;
    final modelLeases = <void Function()>[];
    Directory? tempRoot;
    OcrSubtitleStream? streaming;
    MaterializedMediaLease? materializedLease;
    final sourceItem = library.getVideo(request.videoId);
    final isOnline =
        sourceItem != null &&
        itemNeedsOnlineMaterialization(
          source: sourceItem.sourceRef,
          path: sourceItem.path,
        );
    final isCloud =
        sourceItem != null &&
        isCloudDriveMedia(source: sourceItem.sourceRef, path: sourceItem.path);
    final preparationLabel = sourceItem?.sourceRef?.podcast != null
        ? '正在准备播客视频素材'
        : isCloud
        ? '正在准备网盘视频素材'
        : '正在准备 Bilibili 视频素材';
    try {
      final components = <String>{};
      for (final track in normalizedTracks) {
        components.addAll(
          (await modelManager.preset(track.modelId)).componentIds,
        );
      }
      final retained = <String>{};
      void retainReadyComponents() {
        for (final id in components) {
          if (modelManager.center.installed(id) && retained.add(id)) {
            modelLeases.add(modelManager.center.retainModel(id));
          }
        }
      }

      retainReadyComponents();
      if (components.any((id) => !modelManager.center.installed(id))) {
        _update(
          _job!.copyWith(
            status: OcrSubtitleJobStatus.downloading,
            preparationProgress: 0,
            clearRemaining: true,
            statusMessage: '正在自动下载所选 OCR 模型',
          ),
        );
        await modelManager.prepareTracks(
          normalizedTracks,
          cancelSignal: inferenceCancellation.future,
          onProgress: (progress, message) {
            retainReadyComponents();
            _update(
              _job!.copyWith(
                status: OcrSubtitleJobStatus.downloading,
                preparationProgress: progress.clamp(0, 1),
                clearRemaining: true,
                statusMessage: message,
              ),
            );
          },
        );
        _throwIfCancelled();
      }
      retainReadyComponents();
      _update(
        _job!.copyWith(
          status: OcrSubtitleJobStatus.preparing,
          clearPreparationProgress: true,
          remaining: runtimeEstimate.remaining,
          clearRemaining: !runtimeEstimate.hasMeasurements,
          statusMessage: '正在准备 OCR 字幕任务',
        ),
      );
      if (isOnline) {
        _materializationCancellation = Completer<void>();
        _materializationProgress = MediaMaterializationProgress(
          stage: MediaMaterializationStage.resolving,
          progress: 0,
          message: preparationLabel,
        );
        _update(
          _job!.copyWith(
            status: OcrSubtitleJobStatus.materializing,
            preparationProgress: 0,
            clearRemaining: true,
            statusMessage: preparationLabel,
          ),
        );
        materializedLease = await library.acquireMaterializedMedia(
          request.videoId,
          MediaMaterializationRequirement.videoFrames,
          targetHeight: isCloud || request.videoQualityId != null ? null : 1080,
          qualityId: request.videoQualityId,
          cancelSignal: _materializationCancellation!.future,
          onProgress: (value) {
            _materializationProgress = value;
            _update(
              _job!.copyWith(
                status: OcrSubtitleJobStatus.materializing,
                preparationProgress: value.progress.clamp(0, 1),
                remaining: value.remaining == null
                    ? null
                    : value.remaining! +
                          _performanceHistory.estimate(
                            spanMs:
                                (request.end - request.start).inMilliseconds,
                            tracks: normalizedTracks,
                            videoId: timingSourceId,
                          ),
                clearRemaining:
                    value.remaining == null ||
                    !_performanceHistory.hasMeasurements(
                      timingSourceId,
                      normalizedTracks,
                    ),
                statusMessage:
                    '${value.message}${_materializationDetails(value)}',
              ),
            );
          },
        );
        request = request.copyWith(
          videoPath: materializedLease.requiredVideoPath,
        );
        _materializationProgress = null;
        // The sealed video track is already registered by materialization.
        // OCR must not start an extra audio download or replace active playback.
      }
      runtimeEstimate.preparationStarted();
      final preparationStartedMs = taskWatch.elapsedMilliseconds;
      final models = normalizedTracks
          .map((track) => track.modelIdentity)
          .toSet()
          .toList();
      final modelFiles = <int, OcrModelFiles>{};
      for (final track in normalizedTracks) {
        _throwIfCancelled();
        modelFiles[track.number] = await modelManager.filesFor(track);
      }
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      if (incrementalOutput) {
        streaming = await _openSubtitleStream(
          request,
          sourceVideoPath,
          dataRoot,
        );
      }
      tempRoot = Directory(
        p.join(dataRoot.path, 'ocr_temp', _safeId(request.videoId)),
      );
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      await tempRoot.create(recursive: true);
      _performanceHistory.recordPreparation(
        models.length,
        taskWatch.elapsedMilliseconds - preparationStartedMs,
      );

      final spanMs = math.max(1, (request.end - request.start).inMilliseconds);
      _update(_job!.copyWith(statusMessage: '等待本地推理资源'));
      try {
        releaseInference = await InferenceScheduler.instance.acquire(
          isCancelled: () => _cancelled,
          cancelSignal: inferenceCancellation.future,
        );
      } catch (_) {
        _throwIfCancelled();
        rethrow;
      }
      _throwIfCancelled();
      resources = await DeviceResourceMonitor.instance.openSession();
      final session = resources;
      final weights = <String, int>{};
      for (final entry in modelFiles.entries) {
        final files = entry.value;
        weights[files.identity] =
            await File(files.detection).length() +
            await File(files.recognition).length();
      }
      final largestWeights = weights.values.toList()
        ..sort((a, b) => b.compareTo(a));
      final estimatedModels = largestWeights
          .take(2)
          .fold<int>(0, (n, v) => n + v * 4 + 64 * 1024 * 1024);
      await session.checkAllocation(estimatedModels, modelLabel: 'OCR 模型与图像缓冲');
      final mobile = Platform.isAndroid || Platform.isIOS;
      final maxBatch = mobile ? 4 : 8;
      // A lazy settings scan temporarily owns Android's first private process.
      // Drain it before reserving task workers, including a CPU-only task.
      await Future.any<void>([
        computeService.waitForDetection(),
        inferenceCancellation.future,
      ]);
      _throwIfCancelled();
      final capabilities =
          compute.mode == OcrComputeMode.cpu ||
              (Platform.isIOS && compute.mode == OcrComputeMode.automatic)
          ? OcrComputeCapabilities(platform: Platform.operatingSystem)
          : await Future.any<OcrComputeCapabilities>([
              computeService.capabilities(),
              inferenceCancellation.future.then((_) {
                _throwIfCancelled();
                return OcrComputeCapabilities(
                  platform: Platform.operatingSystem,
                );
              }),
            ]);
      _throwIfCancelled();
      final computePlan = planOcrCompute(compute, capabilities);
      _activeBackend = computePlan.note;
      final executable = computeService.executable;
      final conservativeTracks = {
        for (final track in normalizedTracks)
          if (computeService.failed(
            track.modelIdentity,
            '${Platform.operatingSystem}:CPU',
            'conservative',
          ))
            track.number,
      };
      var helperAvailable = executable != null;
      // CPU inference also belongs outside the Android player: the supplied
      // Xiaomi tombstone is a native ORT CPU failure, which Dart cannot catch.
      final androidAvailable = Platform.isAndroid;
      var verifyDevice = true;
      Future<OcrWorker> startWorker(
        OcrModelFiles files,
        InferenceComputePermit permit,
        OcrWorkerAllocationGuard guard, {
        bool conservative = false,
      }) async {
        final safe =
            conservative ||
            conservativeTracks.any(
              (number) => modelFiles[number]!.identity == files.identity,
            );
        if (helperAvailable) {
          return ProcessOcrWorker.start(
            files,
            executable: executable!,
            tracks: modelFiles,
            cpuThreads: safe ? 1 : math.min(4, permit.threads),
            batchLimit: safe ? 1 : maxBatch,
            conservative: safe,
            checkAllocation: guard.checkAllocation,
            cancelSignal: inferenceCancellation.future,
            deviceKey: verifyDevice ? computePlan.device?.key : null,
          );
        }
        if (androidAvailable) {
          return AndroidOcrWorker.start(
            files,
            tracks: modelFiles,
            cpuThreads: safe ? 1 : math.min(4, permit.threads),
            batchLimit: safe ? 1 : maxBatch,
            conservative: safe,
            checkAllocation: guard.checkAllocation,
            cancelSignal: inferenceCancellation.future,
            deviceKey: verifyDevice ? computePlan.device?.key : null,
          );
        }
        return OcrProcessingWorker.start(
          files,
          tracks: modelFiles,
          cpuThreads: safe ? 1 : math.min(4, permit.threads),
          batchLimit: safe ? 1 : maxBatch,
          conservative: safe,
          checkAllocation: guard.checkAllocation,
        );
      }

      final desiredWorkers =
          computePlan.hardwareFirst || conservativeTracks.isNotEmpty
          ? 1
          : ocrWorkerCount(
              snapshot: session.governor.snapshot,
              budget: session.decision,
              regions: normalizedTracks.length,
              mediaMs: spanMs,
              modelBytes: estimatedModels,
            );
      final workerStartup = Stopwatch()..start();
      runtimeEstimate.trackStarted(0, needsStartup: true);
      final allocationGuards = <OcrWorkerAllocationGuard>[];
      for (var i = 0; i < desiredWorkers; i++) {
        final guard = OcrWorkerAllocationGuard(session);
        try {
          workers.add(
            await session.run(
              InferenceLane.ocr,
              (permit) => guard.run(
                permit,
                () => startWorker(
                  modelFiles[normalizedTracks[i].number]!,
                  permit,
                  guard,
                ),
              ),
              requested: ocrThreadsPerWorker(session.decision, desiredWorkers),
              cancelSignal: inferenceCancellation.future,
            ),
          );
          allocationGuards.add(guard);
          _activeWorkers.add(workers.last);
        } catch (error, stack) {
          _throwIfCancelled();
          // An optional second process has no frame history yet. Keep the
          // healthy first process if Android or the OS rejects the extra one.
          if (workers.isNotEmpty &&
              (error is OcrWorkerProcessFailure ||
                  isTransientInferencePressure(error))) {
            break;
          }
          final retryIsolated =
              (helperAvailable || androidAvailable) &&
              !isTransientInferencePressure(error);
          final missingHelper = helperAvailable && error is ProcessException;
          if (workers.isEmpty && (retryIsolated || missingHelper)) {
            debugPrint(
              'OCR worker startup failed; retrying once: $error\n$stack',
            );
            // A native exit must stay isolated on both Android and desktop.
            // Only an executable that cannot be launched uses the established
            // desktop CPU fallback. Release the old permit before retrying.
            if (missingHelper) helperAvailable = false;
            verifyDevice = false;
            conservativeTracks.addAll(normalizedTracks.map((t) => t.number));
            _activeBackend = '正在恢复 OCR 识别进程';
            _update(_job!.copyWith(statusMessage: _activeBackend));
            final fallbackGuard = OcrWorkerAllocationGuard(session);
            late final OcrWorker fallback;
            try {
              fallback = await session.run(
                InferenceLane.ocr,
                (permit) => fallbackGuard.run(
                  permit,
                  () => startWorker(
                    modelFiles[normalizedTracks[i].number]!,
                    permit,
                    fallbackGuard,
                    conservative: true,
                  ),
                ),
                requested: ocrThreadsPerWorker(session.decision, 1),
                cancelSignal: inferenceCancellation.future,
              );
            } catch (recoveryError, recoveryStack) {
              _throwIfCancelled();
              Error.throwWithStackTrace(
                StateError('OCR 识别进程启动失败（首次：$error；恢复：$recoveryError）'),
                recoveryStack,
              );
            }
            workers.add(fallback);
            allocationGuards.add(fallbackGuard);
            _activeWorkers.add(fallback);
            break;
          }
          // Preserve model/configuration errors and their original stack.
          rethrow;
        }
      }
      workerStartup.stop();
      _throwIfCancelled();
      runtimeEstimate.workerReady(workerStartup.elapsedMilliseconds);
      runtimeEstimate.pipelineStarted(workers: workers.length);
      final activeWorker = workers.first;
      final workersByTrack = {
        for (var i = 0; i < normalizedTracks.length; i++)
          normalizedTracks[i].number: workers[i % workers.length],
      };
      final guardsByTrack = {
        for (var i = 0; i < normalizedTracks.length; i++)
          normalizedTracks[i].number: allocationGuards[i % workers.length],
      };
      final assemblies = {
        for (final track in normalizedTracks)
          track.number: _OcrTrackAssembly(request.start),
      };
      final resumeAt = <int, int>{};
      if (streaming != null) {
        for (final track in normalizedTracks) {
          final store = streaming.stores[track.number]!;
          final state = assemblies[track.number]!;
          state.cues.addAll(
            store.primary.snapshot.map(
              (cue) => _OcrCue(cue.startTime, cue.endTime, cue.text),
            ),
          );
          final checkpoint = store.checkpoint;
          if (!store.reconciled && checkpoint != null) {
            for (final value in checkpoint['held'] as List? ?? const []) {
              final cue = value as Map;
              state.cues.add(
                _OcrCue(
                  Duration(milliseconds: cue['start'] as int),
                  Duration(milliseconds: cue['end'] as int),
                  cue['text'] as String,
                ),
              );
            }
            state.text = checkpoint['text'] as String? ?? '';
            state.start = checkpoint['startMs'] == null
                ? null
                : Duration(milliseconds: checkpoint['startMs'] as int);
            state.lastObserved = Duration(
              milliseconds:
                  checkpoint['lastObservedMs'] as int? ??
                  request.start.inMilliseconds,
            );
          }
          resumeAt[track.number] = store.reconciled
              ? request.end.inMilliseconds
              : store.through.inMilliseconds;
          recognitionProgress.completedThrough(
            track.number,
            resumeAt[track.number]!,
          );
        }
        for (final worker in workers) {
          final states = <int, Map<String, dynamic>>{};
          for (final track in normalizedTracks) {
            final checkpoint = streaming.stores[track.number]!.checkpoint;
            if (identical(workersByTrack[track.number], worker) &&
                checkpoint?['worker'] is Map) {
              states[track.number] = Map<String, dynamic>.from(
                checkpoint!['worker'] as Map,
              );
            }
          }
          if (states.isNotEmpty) await worker.restoreFrameHistory(states);
        }
        streaming.cuesBetween = (number, from, to) => [
          for (var i = from; i < to; i++)
            SubtitleItem(
              index: i + 1,
              startTime: assemblies[number]!.cues[i].start,
              endTime: assemblies[number]!.cues[i].end,
              text: assemblies[number]!.cues[i].text,
            ),
        ];
      }
      final results = <_OcrTrackResult>[];
      final signatures = {
        for (final track in normalizedTracks)
          track.number: inferenceTuningSignature(
            session,
            track.modelIdentity,
            'ocr-onnx-${activeWorker.runtimeVersion}-raw-v1',
            configuration:
                '${track.region.width}:${track.region.height}:workers=${workers.length}:${computePlan.signature}:helper=$helperAvailable',
          ),
      };
      final records = modelManager.center.inferenceTuning;
      final recoveredTracks = <int>{};
      final disabledHardware = <int>{};
      final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      String profileKey(OcrSubtitleTrack track) =>
          'ocr:${track.modelId}:${signatures[track.number]}';
      Map<String, dynamic>? validProfile(OcrSubtitleTrack track) {
        final r = records[profileKey(track)];
        final date = DateTime.tryParse(r?['testedAt'] as String? ?? '');
        if (date == null ||
            date.isAfter(DateTime.now()) ||
            DateTime.now().difference(date).inDays >= 14) {
          return null;
        }
        return r;
      }

      var processedFrames = 0, tuningMs = 0, steadyMs = 0, extractionMs = 0;
      final recognitionStartedMs = taskWatch.elapsedMilliseconds;
      final backends = <String>{};
      final trackBackends = <int, String>{};
      final thermalStates = <String>{};
      final memoryPressureStates = <String>{};
      final timingsUs = <String, int>{};
      var lastChunkAt = taskWatch.elapsedMilliseconds;
      _rawExtractor = OcrRawExtractor(
        resources: session,
        cancelSignal: inferenceCancellation.future,
      );
      _update(
        _job!.copyWith(
          status: OcrSubtitleJobStatus.recognizing,
          progress: recognitionProgress.progress,
          clearPreparationProgress: true,
          recognitionProgress: recognitionProgress.snapshot,
          statusMessage: '正在抽取并识别字幕帧',
        ),
      );
      await for (final chunk in _rawExtractor!.chunks(
        request,
        tempRoot,
        resumeFrom: streaming == null
            ? null
            : Duration(milliseconds: streaming.resumeFromMs),
      )) {
        _throwIfCancelled();
        extractionMs += chunk.extractionMs;
        runtimeEstimate.pipelineChunkStarted(
          mediaMs: (chunk.end - chunk.start).inMilliseconds,
          extractionMs: chunk.extractionMs,
          frames: {
            for (final track in normalizedTracks)
              track.number: chunk.frames[track.number]?.length ?? 0,
          },
          prefetch: session.decision.allowAudioPrefetch,
          workers:
              session.decision.pipeline &&
                  !(session.governor.snapshot.interacting &&
                      session.governor.snapshot.foreground)
              ? workers.length
              : 1,
        );
        final samples = [
          for (final track in normalizedTracks)
            for (final (index, frame)
                in (chunk.frames[track.number] ?? <OcrRawFrame>[]).indexed)
              (
                track: track,
                frame: frame,
                // mpdecimate skipped only duplicate frames before the next
                // retained PTS; this completed sample covers that interval.
                throughMs: index + 1 < chunk.frames[track.number]!.length
                    ? chunk.frames[track.number]![index + 1].atMs
                    : chunk.end.inMilliseconds,
              ),
        ];
        final frameCounts = <int, int>{};
        Future<void> processSample(int index) async {
          _throwIfCancelled();
          final sample = samples[index], track = samples[index].track;
          final frame = sample.frame;
          if (frame.atMs <
              (resumeAt[track.number] ?? request.start.inMilliseconds)) {
            return;
          }
          streaming?.checkFailure();
          if (frame.atMs > request.end.inMilliseconds) return;
          final profile = validProfile(track);
          final worker = workersByTrack[track.number]!;
          // Auto-selected routes fail independently. An incompatible OpenCL
          // graph can therefore move to Vulkan/QNN instead of disabling all
          // hardware for this model. An explicit selection remains respected.
          final device = computePlan.candidateDevices
              .where(
                (d) => !computeService.failed(
                  track.modelIdentity,
                  '${worker.runtimeVersion}:${d.key}',
                  compute.coreMLUnits,
                ),
              )
              .firstOrNull;
          final exhaustedHardware =
              computePlan.device != null && device == null;
          final safeMode =
              conservativeTracks.contains(track.number) ||
              recoveredTracks.contains(track.number);
          final deviceKey = '${worker.runtimeVersion}:${device?.key ?? 'cpu'}';
          final quarantined =
              device != null &&
              computeService.failed(
                track.modelIdentity,
                deviceKey,
                compute.coreMLUnits,
              );
          final canAccelerate =
              device != null &&
              !quarantined &&
              !disabledHardware.contains(track.number) &&
              !safeMode &&
              (worker.isolated || Platform.isIOS) &&
              // Share a desktop GPU through one process; the other CPU worker
              // can keep decoding/recognizing another region within its budget.
              (computePlan.hardwareFirst || identical(worker, workers.first));
          final allowed = [
            'CPU',
            if (worker.availableBackends.contains('XNNPACK')) 'XNNPACK',
            if (canAccelerate) device.provider,
          ];
          final spentToday = records.values
              .where((r) => r['ocrDay'] == day)
              .fold<int>(
                0,
                (n, r) => n + ((r['ocrSpentMs'] as num?)?.toInt() ?? 0),
              );
          final lastAttempt = DateTime.tryParse(
            records[profileKey(track)]?['attemptedAt'] as String? ?? '',
          );
          final credit =
              !safeMode &&
                  session.decision.allowTuning &&
                  (profile == null ||
                      profile['threadsTuned'] != true ||
                      profile['backendTuned'] != true) &&
                  (lastAttempt == null ||
                      DateTime.now().difference(lastAttempt).inSeconds >= 30)
              ? math.max(
                  0,
                  math.min(
                    30000 - spentToday,
                    session.productiveTime.inMilliseconds ~/ 20 - tuningMs,
                  ),
                )
              : 0;
          final hardwareMightRun =
              canAccelerate &&
              (computePlan.hardwareFirst ||
                  profile?['provider'] == device.provider ||
                  credit >= 2000 &&
                      profile?['threadsTuned'] == true &&
                      !(profile?['testedProviders'] as List? ?? const [])
                          .contains(device.provider));
          // Reserve before entering native code; an OS termination cannot make
          // the next launch repeatedly spend the automatic probe allowance.
          if (credit >= 2000) {
            final record = records.putIfAbsent(profileKey(track), () => {});
            final previousSpent = record['ocrDay'] == day
                ? (record['ocrSpentMs'] as num?)?.toInt() ?? 0
                : 0;
            record
              ..['ocrDay'] = day
              ..['attemptedAt'] = DateTime.now().toUtc().toIso8601String()
              ..['ocrSpentMs'] = 2000 + previousSpent;
            while (records.length > 96) {
              records.remove(
                records.keys.firstWhere((k) => k != profileKey(track)),
              );
            }
            await modelManager.center.save();
          }
          final started = taskWatch.elapsedMilliseconds;
          runtimeEstimate.pipelineFrameStarted(track.number);
          Future<OcrFrameAnalysis> runFrame({
            bool cpuOnly = false,
          }) => session.run(
            InferenceLane.ocr,
            (permit) => guardsByTrack[track.number]!.run(
              permit,
              () => workersByTrack[track.number]!.analyzeRawFrame(
                path: frame.path,
                offset: frame.offset,
                width: frame.width,
                height: frame.height,
                atMs: frame.atMs,
                track: track.number,
                threads: cpuOnly || safeMode ? 1 : permit.threads,
                preferredThreads: cpuOnly || safeMode
                    ? 1
                    : (profile?['threads'] as num?)?.toInt() ??
                          math.min(4, permit.threads),
                provider:
                    cpuOnly ||
                        safeMode ||
                        permit.decision.level ==
                            InferencePressureLevel.protective
                    ? 'CPU'
                    : canAccelerate && computePlan.hardwareFirst
                    ? device.provider
                    : profile?['provider'] as String? ?? 'CPU',
                deviceId: device?.id ?? 0,
                coreMLUnits: compute.coreMLUnits,
                gpuMemoryLimit: device == null
                    ? null
                    : math.max(
                        128 * 1024 * 1024,
                        math.min(
                          2 * 1073741824,
                          (device.availableBytes ??
                                  (device.dedicatedBytes > 0
                                      ? device.dedicatedBytes
                                      : 1073741824)) ~/
                              3,
                        ),
                      ),
                allowedProviders:
                    cpuOnly ||
                        safeMode ||
                        permit.decision.level ==
                            InferencePressureLevel.protective
                    ? const ['CPU']
                    : allowed,
                validateAcceleration: true,
                conservative: cpuOnly || safeMode,
                probeStage: profile?['threadsTuned'] == true
                    ? 'backend'
                    : 'cpu',
                testedProviders: List<String>.from(
                  profile?['testedProviders'] as List? ?? const [],
                ),
                testedThreads: List<int>.from(
                  profile?['testedThreads'] as List? ?? const [],
                ),
                batchLimit:
                    cpuOnly ||
                        safeMode ||
                        permit.decision.level ==
                            InferencePressureLevel.protective
                    ? 1
                    : permit.decision.level ==
                          InferencePressureLevel.constrained
                    ? math.min(2, maxBatch)
                    : maxBatch,
                residentModels:
                    ocrRetainModels(session.governor.snapshot, permit.decision)
                    ? 2
                    : 1,
                probeCreditMs:
                    cpuOnly || safeMode || !permit.decision.allowTuning
                    ? 0
                    : credit,
                remainingMediaMs: request.end.inMilliseconds - frame.atMs,
              ),
            ),
            requested: ocrThreadsPerWorker(session.decision, workers.length),
            minimumYieldInterval: const Duration(milliseconds: 250),
            cancelSignal: inferenceCancellation.future,
          );
          late OcrFrameAnalysis analysis;
          try {
            analysis = await runFrame();
          } on OcrWorkerProcessFailure {
            _throwIfCancelled();
            if (recoveredTracks.contains(track.number)) {
              throw StateError(
                '当前画面在稳健模式下仍无法识别，已安全停止任务。'
                '播放器可继续使用；请尝试调整字幕区域或换用其他 OCR 模型。',
              );
            }
            final failed = workersByTrack[track.number]!;
            final states = Map<int, Map<String, dynamic>>.from(
              failed.checkpoints,
            );
            final affected = workersByTrack.entries
                .where((e) => identical(e.value, failed))
                .map((e) => e.key)
                .toList();
            recoveredTracks.addAll(affected);
            disabledHardware.addAll(affected);
            if (!hardwareMightRun) {
              for (final number in affected) {
                final model = normalizedTracks.firstWhere(
                  (t) => t.number == number,
                );
                await computeService.markFailed(
                  model.modelIdentity,
                  '${Platform.operatingSystem}:CPU',
                  'conservative',
                );
              }
            }
            if (device != null && hardwareMightRun) {
              for (final number in affected) {
                final model = normalizedTracks.firstWhere(
                  (t) => t.number == number,
                );
                await computeService.markFailed(
                  model.modelIdentity,
                  deviceKey,
                  compute.coreMLUnits,
                );
              }
            }
            _activeBackend = '识别进程异常，正在恢复稳健模式';
            _update(_job!.copyWith(statusMessage: '正在恢复识别，已完成的字幕将保留'));
            await failed.close();
            verifyDevice = false;
            _activeWorkers.remove(failed);
            final guard = OcrWorkerAllocationGuard(session);
            final replacement = await session.run(
              InferenceLane.ocr,
              (permit) => guard.run(permit, () async {
                final next = await startWorker(
                  modelFiles[track.number]!,
                  permit,
                  guard,
                  conservative: true,
                );
                try {
                  await next.restoreFrameHistory(states);
                  return next;
                } catch (_) {
                  await next.close();
                  rethrow;
                }
              }),
              requested: ocrThreadsPerWorker(session.decision, workers.length),
              cancelSignal: inferenceCancellation.future,
            );
            workers[workers.indexOf(failed)] = replacement;
            _activeWorkers.add(replacement);
            for (final number in affected) {
              workersByTrack[number] = replacement;
              guardsByTrack[number] = guard;
            }
            // The failed native reservation has been released. Restore only
            // the compact pre-frame state, then replay this unfinished frame.
            analysis = await runFrame(cpuOnly: true);
          }
          final elapsed = taskWatch.elapsedMilliseconds - started;
          final probeCost = (analysis.tuning?['costMs'] as num?)?.toInt() ?? 0;
          if (credit >= 2000) {
            final old = records[profileKey(track)]!;
            old['ocrSpentMs'] = math.max(
              0,
              (old['ocrSpentMs'] as int) - 2000 + probeCost,
            );
            if (analysis.tuning != null) {
              old.addAll(analysis.tuning!);
              old['testedAt'] = DateTime.now().toUtc().toIso8601String();
            }
            tuningMs += probeCost;
            await modelManager.center.save();
          }
          if (analysis.tuning?['failedProvider'] != null) {
            if (device != null &&
                analysis.tuning!['failedProvider'] == device.provider) {
              if (compute.provider != 'auto') {
                disabledHardware.add(track.number);
              }
              await computeService.markFailed(
                track.modelIdentity,
                deviceKey,
                compute.coreMLUnits,
              );
            }
            records[profileKey(track)] = {
              ...?records[profileKey(track)],
              ...analysis.tuning!,
              if (compute.provider == 'auto') 'backendTuned': false,
              'testedAt': DateTime.now().toUtc().toIso8601String(),
            };
            await modelManager.center.save();
          }
          frameCounts.update(track.number, (n) => n + 1, ifAbsent: () => 1);
          runtimeEstimate.pipelineFrameCompleted(
            trackNumber: track.number,
            wallMs: math.max(0, elapsed - probeCost).toDouble(),
            executionProfile: '${analysis.backend}:raw-v2:w${workers.length}',
            warmup: analysis.warmup,
          );
          processedFrames++;
          for (final timing in analysis.timingsUs.entries) {
            timingsUs.update(
              timing.key,
              (n) => n + timing.value,
              ifAbsent: () => timing.value,
            );
          }
          backends.add(analysis.backend);
          thermalStates.add(session.governor.snapshot.thermal.name);
          memoryPressureStates.add(
            session.governor.snapshot.memoryPressure.name,
          );
          steadyMs += math.max(0, elapsed - probeCost);
          trackBackends[track.number] =
              '区域 ${track.number} · ${analysis.backend}'
              '${compute.mode == OcrComputeMode.accelerated && device == null ? '（${computePlan.note}）' : ''}'
              '${recoveredTracks.contains(track.number) || conservativeTracks.contains(track.number) ? '（稳健模式）' : ''}'
              '${exhaustedHardware || quarantined || disabledHardware.contains(track.number) || (device != null && analysis.tuning?['failedProvider'] == device.provider) ? '（加速不可用，已回退）' : ''}';
          _activeBackend =
              '${[for (final region in normalizedTracks) trackBackends[region.number] ?? '区域 ${region.number} · 准备中'].join(' / ')} · ${session.decision.reason}';
          recognitionProgress.completedThrough(track.number, sample.throughMs);
          if (recognitionProgress.shouldPublish()) {
            _update(
              _job!.copyWith(
                progress: recognitionProgress.progress,
                recognitionProgress: recognitionProgress.snapshot,
                statusMessage: '正在识别 OCR 字幕',
              ),
            );
          }
          if (!analysis.candidate) return;
          final state = assemblies[track.number]!;
          final text = _normalizeText(analysis.text);
          final boundary = Duration(
            milliseconds: analysis.boundaryMs.clamp(
              request.start.inMilliseconds,
              frame.atMs,
            ),
          );
          if (text.isEmpty) {
            if (state.text.isNotEmpty && state.start != null) {
              _appendCue(state.cues, state.start!, boundary, state.text);
            }
            state.text = '';
            state.start = null;
          } else if (state.text.isEmpty) {
            state.text = text;
            state.start = boundary;
          } else if (!_similar(state.text, text)) {
            _appendCue(state.cues, state.start!, boundary, state.text);
            state.text = text;
            state.start = boundary;
          }
          state.lastObserved = Duration(milliseconds: frame.atMs);
        }

        try {
          final queue = OcrRegionWorkQueue<int>(
            List.generate(samples.length, (index) => index),
            workers.length,
            (index) =>
                workers.indexOf(workersByTrack[samples[index].track.number]!),
          );
          OcrWorker? previousSerialWorker;
          while (true) {
            final group = queue.take(
              parallel:
                  session.decision.pipeline &&
                  ocrRetainModels(session.governor.snapshot, session.decision),
            );
            if (group.isEmpty) break;
            final first = group.first;
            if (!ocrRetainModels(session.governor.snapshot, session.decision)) {
              final current = workersByTrack[samples[first].track.number];
              if (!identical(current, previousSerialWorker)) {
                for (final worker in workers) {
                  if (!identical(worker, current)) {
                    await worker.releaseIdleModels();
                  }
                }
                previousSerialWorker = current;
              }
            } else {
              previousSerialWorker = null;
            }
            // At most one in-flight frame per worker. Waiting for the whole
            // group drains native work even when another frame fails/cancels.
            await Future.wait(group.map(processSample));
          }
        } finally {
          await Future.wait(
            workers.map((worker) async {
              try {
                await worker.closeFrameFiles();
              } on OcrWorkerProcessFailure {
                /* Preserve the original failure. */
              }
            }),
          );
        }
        final chunkMs = (chunk.end - chunk.start).inMilliseconds;
        for (final track in normalizedTracks) {
          recognitionProgress.completedThrough(
            track.number,
            chunk.end.inMilliseconds,
          );
          _performanceHistory.recordChunk(
            videoId: timingSourceId,
            track: track,
            mediaMs: chunkMs,
            extractionMs: (chunk.extractionMs / normalizedTracks.length)
                .round(),
            frames: frameCounts[track.number] ?? 0,
            steadyFrames: 0,
            recognitionMs: 0,
          );
        }
        runtimeEstimate.pipelineChunkCompleted(
          (chunk.end - request.start).inMilliseconds,
          taskWatch.elapsedMilliseconds - lastChunkAt,
        );
        if (streaming != null) {
          streaming.observe(
            OcrStreamCheckpoint(
              throughMs: chunk.end.inMilliseconds,
              stableCounts: {
                for (final track in normalizedTracks)
                  track.number: math.max(
                    0,
                    assemblies[track.number]!.cues.length - 1,
                  ),
              },
              states: {
                for (final track in normalizedTracks)
                  track.number: {
                    'version': 1,
                    'stableCount': math.max(
                      0,
                      assemblies[track.number]!.cues.length - 1,
                    ),
                    'held': assemblies[track.number]!.cues
                        .skip(
                          math.max(
                            0,
                            assemblies[track.number]!.cues.length - 1,
                          ),
                        )
                        .map(
                          (cue) => {
                            'start': cue.start.inMilliseconds,
                            'end': cue.end.inMilliseconds,
                            'text': cue.text,
                          },
                        )
                        .toList(),
                    'text': assemblies[track.number]!.text,
                    'startMs': assemblies[track.number]!.start?.inMilliseconds,
                    'lastObservedMs':
                        assemblies[track.number]!.lastObserved.inMilliseconds,
                    'worker':
                        workersByTrack[track.number]!.checkpoints[track.number],
                  },
              },
            ),
          );
        }
        lastChunkAt = taskWatch.elapsedMilliseconds;
        _update(
          _job!.copyWith(
            progress: recognitionProgress.progress,
            recognitionProgress: recognitionProgress.snapshot,
            statusMessage: '正在识别 OCR 字幕',
          ),
        );
      }
      _rawExtractor = null;
      for (final track in normalizedTracks) {
        final state = assemblies[track.number]!;
        if (streaming?.stores[track.number]?.reconciled != true &&
            state.text.isNotEmpty &&
            state.start != null) {
          _appendCue(
            state.cues,
            state.start!,
            request.end > state.lastObserved ? request.end : state.lastObserved,
            state.text,
          );
        }
        results.add(
          _OcrTrackResult(
            track,
            streaming?.stores[track.number]?.reconciled == true
                ? state.cues
                : _removePersistentOverlayLines(state.cues),
          ),
        );
      }
      final resumed = resumeAt.values.any(
        (through) => through > request.start.inMilliseconds,
      );
      // A resumed suffix must not be recorded as the cost of the full video.
      if (!resumed) {
        _performanceHistory.recordPipeline(
          videoId: timingSourceId,
          tracks: normalizedTracks,
          startMs: request.start.inMilliseconds,
          spanMs: spanMs,
          wallMs: math.max(
            0.0,
            taskWatch.elapsedMilliseconds -
                recognitionStartedMs -
                tuningMs -
                runtimeEstimate.pipelineStartupOverheadMs,
          ),
        );
      }
      lastPerformance = {
        'recoveredTracks': recoveredTracks.toList(),
        'conservativeTracks': {
          ...conservativeTracks,
          ...recoveredTracks,
        }.toList(),
        'modelIdentities': normalizedTracks
            .map((t) => t.modelIdentity)
            .toList(),
        'onnxruntime': activeWorker.runtimeVersion,
        'mediaMs': spanMs,
        'regions': normalizedTracks.length,
        'workers': workers.length,
        'frames': processedFrames,
        'timingsUs': timingsUs,
        'recognitionMs': steadyMs,
        'extractionMs': extractionMs,
        'pipelineMs': taskWatch.elapsedMilliseconds - recognitionStartedMs,
        'tuningMs': tuningMs,
        'startupMs': workerStartup.elapsedMilliseconds,
        'elapsedMs': taskWatch.elapsedMilliseconds,
        'peakResidentBytes': session.peakResidentBytes,
        'peakSlowFrameFraction': session.peakSlowFrameFraction,
        'thermalSupported': session.governor.snapshot.thermalSupported,
        'thermalStates': thermalStates.toList(),
        'memoryPressureStates': memoryPressureStates.toList(),
      };
      runtimeEstimate.finalizationStarted();
      final finalizationStartedMs = taskWatch.elapsedMilliseconds;
      _update(
        _job!.copyWith(
          status: OcrSubtitleJobStatus.writing,
          progress: OcrTaskProgressTracker.processingEnd,
          remaining: runtimeEstimate.remaining,
          statusMessage: '正在保存 OCR 字幕',
        ),
      );
      await Future.wait(workers.map((worker) => worker.close()));
      workers.clear();
      _throwIfCancelled();
      final now = DateTime.now();
      final outputs = <String>[];
      var cueCount = 0;
      if (streaming != null) {
        await streaming.finish({
          for (final result in results)
            result.track.number: [
              for (final (i, cue) in result.cues.indexed)
                SubtitleItem(
                  index: i + 1,
                  startTime: cue.start,
                  endTime: cue.end,
                  text: cue.text,
                ),
            ],
        }, request.end.inMilliseconds);
      }
      for (final result in results) {
        final fileName =
            'subtitle.ocr.${result.track.language.code}.r${result.track.number}.${DateFormat('yyyyMMdd_HHmmss').format(now)}.srt';
        final output =
            streaming?.stores[result.track.number]?.primaryPath ??
            await library.allocateSubtitleFile(request.videoId, fileName);
        if (streaming == null) {
          final partial = File('$output.partial');
          await partial.writeAsString(_toSrt(result.cues), flush: true);
          await partial.rename(output);
        }
        final displayName = streaming == null
            ? 'OCR 字幕 · ${result.track.language.label.replaceAll('（简繁兼容）', '')} · ${DateFormat('yyyy-MM-dd HH:mm').format(now)}'
            : _streamDisplayName(streaming, result.track);
        await library.registerManagedLocalSubtitle(
          request.videoId,
          path: output,
          kind: ManagedSubtitleAssetKind.ocr,
          displayName: displayName,
          language: result.track.language.code,
        );
        outputs.add(output);
        cueCount += result.cues.length;
      }
      _completedPaths = streaming != null && streamingPlaybackAttached
          ? const []
          : List.unmodifiable(outputs);
      _performanceHistory.recordFinalization(
        normalizedTracks.length,
        taskWatch.elapsedMilliseconds - finalizationStartedMs,
      );
      lastPerformance = {
        ...lastPerformance,
        'elapsedMs': taskWatch.elapsedMilliseconds,
        'finalizationMs': taskWatch.elapsedMilliseconds - finalizationStartedMs,
        'backends': backends.toList(),
        if (streaming != null) ...{
          'incrementalCommits': streaming.commitCount,
          'incrementalSavingUs': streaming.savingUs,
          'resumedFromMs': resumeAt.values.fold<int>(
            request.end.inMilliseconds,
            math.min,
          ),
        },
      };
      if (normalizedTracks.length == 1 && !resumed) {
        final track = normalizedTracks.single;
        final reference = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  request.videoId,
                  request.start.inMilliseconds,
                  request.end.inMilliseconds,
                  track.region.toJson(),
                  request.mirrorHorizontal,
                  request.mirrorVertical,
                ]),
              ),
            )
            .toString();
        final measurements = modelManager.center.ocrPerformance;
        final recordKey = '${track.modelId}:$reference';
        measurements.remove(recordKey);
        measurements[recordKey] = {
          ...lastPerformance,
          'modelId': track.modelId,
          'modelIdentity': track.modelIdentity,
          'language': track.language.name,
          'reference': reference,
          'device': ocrDeviceKey(session.governor.snapshot),
          'runtime': activeWorker.runtimeVersion,
          'backend': backends.join(' / '),
          'mediaMs': spanMs,
          'elapsedMs': taskWatch.elapsedMilliseconds,
          'realTimeFactor':
              (taskWatch.elapsedMilliseconds -
                  recognitionStartedMs +
                  workerStartup.elapsedMilliseconds) /
              spanMs,
          'testedAt': DateTime.now().toUtc().toIso8601String(),
        };
        while (measurements.length > 64) {
          measurements.remove(measurements.keys.first);
        }
        await modelManager.center.save();
      }
      _update(
        _job!.copyWith(
          status: OcrSubtitleJobStatus.completed,
          progress: 1,
          remaining: Duration.zero,
          outputPaths: outputs,
          statusMessage: '已生成 ${outputs.length} 条字幕轨，共 $cueCount 条字幕',
        ),
      );
      streaming?.releaseMemory();
    } on OcrDownloadCancelled {
      _setCancelled();
    } on _OcrJobCancelled {
      _setCancelled();
    } catch (error, stack) {
      if (_cancelled) {
        _setCancelled();
        return;
      }
      debugPrint('OCR subtitle failed: $error\n$stack');
      _update(
        _job!.copyWith(
          status: OcrSubtitleJobStatus.failed,
          statusMessage: 'OCR 字幕识别失败',
          error: error.toString(),
        ),
      );
    } finally {
      if (streaming != null && !streaming.complete) {
        try {
          await streaming.pause(
            failed: _job?.status == OcrSubtitleJobStatus.failed,
          );
        } catch (error) {
          debugPrint('OCR 增量提交中断，保留最后成功提交的字幕：$error');
          for (final store in streaming.stores.values) {
            if (store.phase != SubtitleStreamPhase.complete) {
              store.phase = SubtitleStreamPhase.failed;
            }
          }
          _publishStream(streaming);
        }
        streaming.cuesBetween = null;
      }
      _estimateTimer?.cancel();
      _estimateTimer = null;
      _runtimeEstimate = null;
      _savePerformanceHistory();
      taskWatch.stop();
      try {
        await Future.wait(workers.map((worker) => worker.close()));
      } catch (_) {}
      _activeWorkers.removeAll(workers);
      try {
        await _rawExtractor?.cancel();
      } finally {
        _rawExtractor = null;
        try {
          await resources?.close();
        } finally {
          releaseInference?.call();
          for (final lease in modelLeases.reversed) {
            lease();
          }
        }
      }
      _activeSession = null;
      _activeProcess = null;
      _materializationCancellation = null;
      if (identical(_inferenceCancellation, inferenceCancellation)) {
        _inferenceCancellation = null;
      }
      _materializationProgress = null;
      await materializedLease?.release();
      if (tempRoot != null && await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    }
  }

  Future<void> cancel() async {
    if (!isRunning) return;
    _cancelled = true;
    for (final worker in List.of(_activeWorkers)) {
      if (worker is ProcessOcrWorker) worker.cancel();
      if (worker is AndroidOcrWorker) unawaited(worker.cancel());
    }
    final inference = _inferenceCancellation;
    if (inference != null && !inference.isCompleted) inference.complete();
    final materialization = _materializationCancellation;
    if (materialization != null && !materialization.isCompleted) {
      materialization.complete();
    }
    await _rawExtractor?.cancel();
    await _activeSession?.cancel();
    _activeProcess?.kill();
  }

  final _registeredStreamPaths = <String>{};
  String? _streamSelectionRegistered;

  Map<String, dynamic> _streamRequest(OcrSubtitleJob job, String path) => {
    'videoId': job.videoId,
    'videoPath': path,
    'tracks': job.tracks.map((track) => track.toJson()).toList(),
    'startMs': job.start.inMilliseconds,
    'endMs': job.end.inMilliseconds,
    'mirrorHorizontal': job.mirrorHorizontal,
    'mirrorVertical': job.mirrorVertical,
    'compute': ?job.compute?.toJson(),
    'videoQualityId': ?job.videoQualityId,
  };

  OcrSubtitleJob _jobFromStream(OcrSubtitleStream run) {
    final value = run.request;
    return OcrSubtitleJob(
      videoId: value['videoId'] as String,
      videoQualityId: value['videoQualityId'] as String?,
      videoPath: value['videoPath'] as String,
      tracks: (value['tracks'] as List)
          .map(
            (track) => OcrSubtitleTrack.fromJson(
              Map<String, dynamic>.from(track as Map),
            ),
          )
          .toList(),
      start: Duration(milliseconds: value['startMs'] as int),
      end: Duration(milliseconds: value['endMs'] as int),
      mirrorHorizontal: value['mirrorHorizontal'] == true,
      mirrorVertical: value['mirrorVertical'] == true,
      compute: value['compute'] == null
          ? null
          : OcrComputePreferences.fromJson(value['compute']),
    );
  }

  Future<OcrSubtitleStream> _openSubtitleStream(
    OcrSubtitleJob job,
    String originalPath,
    Directory root,
  ) async {
    final request = _streamRequest(job, originalPath);
    final identity = Map<String, dynamic>.from(request)..remove('compute');
    final relativeVideo = p.isWithin(root.path, originalPath);
    if (relativeVideo) {
      identity['videoPath'] =
          'appdata:${p.posix.joinAll(p.split(p.relative(originalPath, from: root.path)))}';
    }
    final stat = await File(job.videoPath).stat();
    if (stat.type != FileSystemEntityType.file) throw StateError('OCR 视频文件不存在');
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'request': identity,
              'bytes': stat.size,
              'modified': stat.modified.microsecondsSinceEpoch,
            }),
          ),
        )
        .toString();
    var run = _streamRun;
    final resuming =
        run != null && !run.complete && run.fingerprint == fingerprint;
    if (run == null || run.complete || run.fingerprint != fingerprint) {
      run?.releaseMemory();
      _streamStates.clear();
      final generation = const Uuid().v4();
      final now = DateTime.now();
      final paths = <int, String>{};
      for (final track in job.tracks) {
        paths[track.number] = await library.allocateSubtitleFile(
          job.videoId,
          'subtitle.ocr.${track.language.code}.r${track.number}.'
          '${DateFormat('yyyyMMdd_HHmmss').format(now)}.srt',
        );
      }
      run = await OcrSubtitleStream.create(
        directory: Directory(
          p.join(root.path, 'subtitles', 'ocr_streams', generation),
        ),
        metadata: {
          'version': 1,
          'generationId': generation,
          'fingerprint': fingerprint,
          'request': {
            ...request,
            if (relativeVideo)
              'videoPath': p.posix.joinAll(
                p.split(p.relative(originalPath, from: root.path)),
              ),
          },
          'videoPathRelativeToRoot': relativeVideo,
          'createdAt': now.toIso8601String(),
        },
        paths: paths,
      );
      _streamRun = run;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_streamKey, generation);
    }
    if (_selectionSuppressedDuringStart) await run.preserveSelection();
    await run.resume(repair: resuming);
    run.onCommitted = () => _commitSubtitleStream(run!);
    for (var i = 0; i < run.stores.length; i += 2) {
      _streamStarts.add((
        mediaKey: '${run.mediaKey}:$i',
        runId: '${run.generationId}:$i',
      ));
    }
    return run;
  }

  Future<void> _commitSubtitleStream(OcrSubtitleStream run) async {
    if (_disposed || !identical(_streamRun, run)) return;
    _publishStream(run);
    if (_disposed) return;
    final request = _jobFromStream(run);
    for (final track in request.tracks) {
      final store = run.stores[track.number]!;
      if (store.primary.snapshot.isEmpty ||
          _registeredStreamPaths.contains(store.primaryPath)) {
        continue;
      }
      try {
        await library.registerManagedLocalSubtitle(
          request.videoId,
          path: store.primaryPath,
          kind: ManagedSubtitleAssetKind.ocr,
          displayName: _streamDisplayName(run, track),
          language: track.language.code,
          shareWithBilibiliPart: false,
        );
        _registeredStreamPaths.add(store.primaryPath);
      } catch (error) {
        debugPrint('OCR 增量字幕已保存，文件登记稍后重试：$error');
      }
    }
    if (streamingPlaybackAttached &&
        !run.selectionOverridden &&
        _streamSelectionRegistered != run.generationId &&
        run.stores.values.any((store) => store.primary.snapshot.isNotEmpty) &&
        shouldSelectGeneratedSubtitles?.call('${run.mediaKey}:0') != false) {
      final paths = run.paths;
      try {
        await library.updateVideoSubtitles(
          request.videoId,
          paths.first,
          false,
          secondarySubtitlePath: paths.length > 1 ? paths[1] : null,
          isSecondaryCached: false,
          shouldApply: () =>
              identical(_streamRun, run) &&
              !run.selectionOverridden &&
              shouldSelectGeneratedSubtitles?.call('${run.mediaKey}:0') !=
                  false,
        );
        _streamSelectionRegistered = run.generationId;
      } catch (error) {
        debugPrint('OCR 字幕已保存，播放选择稍后重试：$error');
      }
    }
  }

  String _streamDisplayName(OcrSubtitleStream run, OcrSubtitleTrack track) =>
      'OCR 字幕 · ${track.language.label.replaceAll('（简繁兼容）', '')} · '
      '${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.parse(run.metadata['createdAt'] as String))}';

  void _publishStream(OcrSubtitleStream run) {
    if (_disposed) return;
    final stores = run.stores.values.toList();
    for (var i = 0; i < stores.length; i += 2) {
      final group = stores.skip(i).take(2).toList();
      final primary = group.first,
          secondary = group.length > 1 ? group[1] : null;
      final key = '${run.mediaKey}:$i';
      final previous = _streamStates[key];
      final first = primary.primary.snapshot;
      final second =
          secondary?.primary.snapshot ?? SubtitleCueBuffer().snapshot;
      if (first.isEmpty && second.isEmpty && previous == null) continue;
      final phase = group.every((s) => s.phase == SubtitleStreamPhase.complete)
          ? SubtitleStreamPhase.complete
          : group.any((s) => s.phase == SubtitleStreamPhase.failed)
          ? SubtitleStreamPhase.failed
          : group.any((s) => s.phase == SubtitleStreamPhase.paused)
          ? SubtitleStreamPhase.paused
          : SubtitleStreamPhase.generating;
      List<SubtitleItem> additions(
        SubtitleCueSnapshot next,
        SubtitleCueSnapshot? old,
      ) {
        final start = old != null && next.extendsSnapshot(old) ? old.length : 0;
        return next.skip(start).toList();
      }

      final update = SubtitleStreamUpdate(
        generationId: '${run.generationId}:$i',
        mediaKey: key,
        videoId: run.request['videoId'] as String,
        videoPath: run.request['videoPath'] as String,
        revision: group.fold(0, (n, store) => n + store.revision),
        primaryPath: primary.primaryPath,
        secondaryPath: secondary?.primaryPath,
        primary: first,
        secondary: second,
        addedPrimary: additions(first, previous?.primary),
        addedSecondary: additions(second, previous?.secondary),
        primaryBytes: primary.primaryBytes,
        secondaryBytes: secondary?.primaryBytes ?? 0,
        processedThrough: group
            .map((s) => s.through)
            .reduce((a, b) => a < b ? a : b),
        phase: phase,
        publishedCount: first.length + second.length,
        autoSelectSuppressed: run.selectionOverridden || i > 0,
      );
      _streamStates[key] = update;
      _streamEvents.add(update);
      if (_disposed) return;
      if (phase == SubtitleStreamPhase.complete) {
        _streamStates[key] = update.compact();
      }
    }
    subtitleFilesRevision.value++;
  }

  String _formatTransferBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  String _materializationDetails(MediaMaterializationProgress value) {
    if (value.stage != MediaMaterializationStage.downloadingVideo &&
        value.stage != MediaMaterializationStage.downloadingAudio) {
      return '';
    }
    final total = value.totalBytes == null
        ? _formatTransferBytes(value.receivedBytes)
        : '${_formatTransferBytes(value.receivedBytes)} / '
              '${_formatTransferBytes(value.totalBytes!)}';
    final speed = value.bytesPerSecond > 0
        ? ' · ${_formatTransferBytes(value.bytesPerSecond.round())}/s'
        : '';
    final eta = value.remaining == null
        ? ''
        : ' · 剩余约 ${value.remaining!.inSeconds}s';
    return ' · $total$speed$eta';
  }

  String _normalizeText(String text) => text
      .replaceAll('\r', '')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');

  bool _similar(String a, String b) {
    final left = a.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final right = b.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (left == right) return true;
    final longest = math.max(left.length, right.length);
    if (longest == 0) return true;
    return 1 - _editDistance(left, right) / longest >= 0.82;
  }

  int _editDistance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final current = <int>[i + 1];
      for (var j = 0; j < b.length; j++) {
        current.add(
          math.min(
            math.min(current[j] + 1, previous[j + 1] + 1),
            previous[j] + (a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1),
          ),
        );
      }
      previous = current;
    }
    return previous.last;
  }

  void _appendCue(
    List<_OcrCue> cues,
    Duration start,
    Duration end,
    String text,
  ) {
    if (end <= start) end = start + const Duration(milliseconds: 500);
    if (end - start < const Duration(milliseconds: 300)) return;
    if (cues.isNotEmpty &&
        cues.last.text == text &&
        start - cues.last.end <= const Duration(milliseconds: 400)) {
      cues[cues.length - 1] = _OcrCue(cues.last.start, end, text);
    } else {
      cues.add(_OcrCue(start, end, text));
    }
  }

  List<_OcrCue> _removePersistentOverlayLines(List<_OcrCue> cues) {
    if (cues.length < 4) return cues;
    final stats = <String, _OverlayLineStats>{};
    for (final cue in cues) {
      final lines = cue.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      final keys = lines.map(_overlayLineKey).toSet();
      for (final key in keys) {
        final value = stats.putIfAbsent(
          key,
          () => _OverlayLineStats(first: cue.start, last: cue.end),
        );
        value.appearances++;
        value.last = cue.end;
        value.companions.addAll(keys.where((other) => other != key));
      }
    }
    final persistent = stats.entries
        .where((entry) {
          final value = entry.value;
          return value.appearances >= 4 &&
              value.appearances / cues.length >= 0.55 &&
              value.last - value.first >= const Duration(seconds: 8) &&
              value.companions.length >= 3;
        })
        .map((entry) => entry.key)
        .toSet();
    if (persistent.isEmpty) return cues;

    final filtered = <_OcrCue>[];
    for (final cue in cues) {
      final text = cue.text
          .split('\n')
          .map((line) => line.trim())
          .where(
            (line) =>
                line.isNotEmpty && !persistent.contains(_overlayLineKey(line)),
          )
          .join('\n');
      if (text.isNotEmpty) _appendCue(filtered, cue.start, cue.end, text);
    }
    return filtered;
  }

  String _overlayLineKey(String line) =>
      line.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  String _toSrt(List<_OcrCue> cues) {
    final out = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      out.writeln(i + 1);
      out.writeln('${_srtTime(cue.start)} --> ${_srtTime(cue.end)}');
      out.writeln(cue.text);
      out.writeln();
    }
    return out.toString();
  }

  String _srtTime(Duration value) {
    final ms = value.inMilliseconds;
    final hours = ms ~/ 3600000;
    final minutes = (ms ~/ 60000) % 60;
    final seconds = (ms ~/ 1000) % 60;
    final millis = ms % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${millis.toString().padLeft(3, '0')}';
  }

  void _update(OcrSubtitleJob value, {bool persist = true}) {
    if (_disposed) return;
    final previousStatus = _job?.status;
    _job = value;
    processingKeepAwake.updateJob(value);
    final immediate = previousStatus != value.status || !value.isRunning;
    final now = DateTime.now();
    if (immediate ||
        now.difference(_lastNotifyAt) >= const Duration(milliseconds: 250)) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      _lastNotifyAt = now;
      notifyListeners();
    } else {
      _notifyTimer ??= Timer(const Duration(milliseconds: 250), () {
        _notifyTimer = null;
        _lastNotifyAt = DateTime.now();
        notifyListeners();
      });
    }

    if (!persist) return;
    if (immediate ||
        now.difference(_lastPersistAt) >= const Duration(seconds: 1)) {
      _persistTimer?.cancel();
      _persistTimer = null;
      _lastPersistAt = now;
      _queuePersist(value);
    } else {
      _persistTimer ??= Timer(const Duration(seconds: 1), () {
        _persistTimer = null;
        final latest = _job;
        if (latest == null) return;
        _lastPersistAt = DateTime.now();
        _queuePersist(latest);
      });
    }
  }

  void _queuePersist(OcrSubtitleJob value) {
    _persistChain = _persistChain.then((_) => _persist(value)).catchError((
      Object error,
    ) {
      debugPrint('OCR state persistence failed: $error');
    });
  }

  Future<void> _persist(OcrSubtitleJob value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _persistenceKey,
      jsonEncode({
        'videoId': value.videoId,
        'videoPath': value.videoPath,
        'videoQualityId': ?value.videoQualityId,
        'tracks': value.tracks.map((track) => track.toJson()).toList(),
        'language': value.language.name,
        'region': value.region.toJson(),
        'startMs': value.start.inMilliseconds,
        'endMs': value.end.inMilliseconds,
        'mirrorHorizontal': value.mirrorHorizontal,
        'mirrorVertical': value.mirrorVertical,
        if (value.compute != null && !value.compute!.isDefault)
          'compute': value.compute!.toJson(),
        'status': value.status.name,
        'progress': value.progress,
        'statusMessage': value.statusMessage,
        'outputPath': value.outputPath,
        'outputPaths': value.outputPaths,
      }),
    );
  }

  Future<void> _persistModelSelections() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _modelSelectionsPersistenceKey,
        jsonEncode(
          _rememberedModelIds.map(
            (language, modelId) => MapEntry(language.name, modelId),
          ),
        ),
      );
    } catch (error) {
      debugPrint('OCR model selection save failed: $error');
    }
  }

  Future<void> _persistTracks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _tracksPersistenceKey,
        jsonEncode(
          _tracksByVideo.map(
            (videoId, tracks) => MapEntry(
              videoId,
              tracks.map((track) => track.toJson()).toList(),
            ),
          ),
        ),
      );
    } catch (error) {
      debugPrint('OCR region persistence failed: $error');
    }
  }

  List<OcrSubtitleTrack> _normalizeTracks(List<OcrSubtitleTrack> tracks) => [
    for (var index = 0; index < tracks.length; index++)
      migrateRetiredOcrTrack(
        OcrSubtitleTrack(
          number: index + 1,
          region: tracks[index].region.normalized(),
          language: tracks[index].language,
          modelId: tracks[index].modelId,
          modelIdentity: tracks[index].modelIdentity,
        ),
      ),
  ];

  void _setCancelled() => _update(
    _job!.copyWith(
      status: OcrSubtitleJobStatus.cancelled,
      statusMessage: _streamRun != null && !_streamRun!.complete
          ? '已停止识别，已生成字幕与恢复进度已保留'
          : 'OCR 字幕任务已取消',
    ),
  );

  void _throwIfCancelled() {
    if (_cancelled) throw const _OcrJobCancelled();
  }

  void _handleLibraryChanged() {
    final current = _job;
    if (current != null &&
        current.isRunning &&
        library.getVideo(current.videoId) == null) {
      unawaited(cancel());
      unawaited(cleanupTemporaryFilesForVideo(current.videoId));
    }
    final removedVideoIds = _tracksByVideo.keys
        .where((videoId) => library.getVideo(videoId) == null)
        .toList(growable: false);
    if (removedVideoIds.isEmpty) return;
    for (final videoId in removedVideoIds) {
      _tracksByVideo.remove(videoId);
    }
    unawaited(_persistTracks());
  }

  String _safeId(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

  String _seconds(Duration value) =>
      (value.inMilliseconds / 1000).toStringAsFixed(3);

  @override
  void dispose() {
    _disposed = true;
    unawaited(
      cancel().catchError((Object error) {
        debugPrint('OCR 停止时保留最后的提交点：$error');
      }),
    );
    processingKeepAwake.dispose();
    library.removeListener(_handleLibraryChanged);
    _notifyTimer?.cancel();
    _persistTimer?.cancel();
    _estimateTimer?.cancel();
    _activeProcess?.kill();
    unawaited(_rawExtractor?.cancel());
    unawaited(_activeSession?.cancel());
    unawaited(_streamEvents.close());
    unawaited(_streamStarts.close());
    subtitleFilesRevision.dispose();
    super.dispose();
  }
}

class _OcrCue {
  final Duration start;
  final Duration end;
  final String text;
  const _OcrCue(this.start, this.end, this.text);
}

class _OverlayLineStats {
  final Duration first;
  Duration last;
  int appearances = 0;
  final Set<String> companions = <String>{};

  _OverlayLineStats({required this.first, required this.last});
}

class _OcrTrackResult {
  final OcrSubtitleTrack track;
  final List<_OcrCue> cues;
  const _OcrTrackResult(this.track, this.cues);
}

class _OcrJobCancelled implements Exception {
  const _OcrJobCancelled();
}

@visibleForTesting
List<int> parseOcrFrameTimes(String logs) =>
    RegExp(r'pts_time:([+-]?(?:\d+(?:\.\d*)?|\.\d+))')
        .allMatches(logs)
        .map((match) {
          final seconds = double.tryParse(match.group(1) ?? '') ?? 0;
          return math.max(0, (seconds * 1000).round());
        })
        .toList(growable: false);

@visibleForTesting
String buildOcrFrameFilter({
  required NormalizedOcrRegion region,
  required bool mirrorHorizontal,
  required bool mirrorVertical,
}) {
  final r = region.normalized();
  return <String>[
    // The editor frame is mirrored before the rectangle is drawn. Apply the
    // same display transform first so the normalized crop remains identical.
    if (mirrorHorizontal) 'hflip',
    if (mirrorVertical) 'vflip',
    'crop=iw*${r.width}:ih*${r.height}:iw*${r.left}:ih*${r.top}',
    'scale=min(640\\,iw):-2:flags=area',
    'fps=10:round=near',
    'setpts=PTS-STARTPTS',
    // Keep the first confirmation frame after a change, discard subsequent
    // near-duplicates, and force at least one frame every ~2 seconds. This
    // avoids JPEG-encoding and Dart-decoding all 10 FPS just to reject them.
    'mpdecimate=max=20:keep=1:hi=768:lo=320:frac=0.10',
    'showinfo',
  ].join(',');
}

class _OcrTrackAssembly {
  _OcrTrackAssembly(this.lastObserved);
  final cues = <_OcrCue>[];
  String text = '';
  Duration? start;
  Duration lastObserved;
}
