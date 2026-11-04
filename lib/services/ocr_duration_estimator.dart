import 'dart:math' as math;

import '../models/ocr_subtitle_models.dart';

/// Passive timings only: no probing, image decoding, or I/O in the estimator.
/// Profiles distinguish decoding, retained-frame density, and recognition.
class OcrTimingProfile {
  double extractionMsPerMediaMs;
  double framesPerMediaMs;
  double frameMs;
  int mediaSamplesMs;
  int frameSamples;

  OcrTimingProfile({
    required this.extractionMsPerMediaMs,
    required this.framesPerMediaMs,
    required this.frameMs,
    this.mediaSamplesMs = 0,
    this.frameSamples = 0,
  });

  factory OcrTimingProfile.fallback(bool mobile) => OcrTimingProfile(
    extractionMsPerMediaMs: mobile ? 0.15 : 0.10,
    framesPerMediaMs: 0.002,
    frameMs: mobile ? 250 : 120,
  );

  OcrTimingProfile copy() => OcrTimingProfile(
    extractionMsPerMediaMs: extractionMsPerMediaMs,
    framesPerMediaMs: framesPerMediaMs,
    frameMs: frameMs,
    mediaSamplesMs: mediaSamplesMs,
    frameSamples: frameSamples,
  );

  double processingMs(int mediaMs) =>
      math.max(0, mediaMs) *
      (extractionMsPerMediaMs + framesPerMediaMs * frameMs);

  void observeExtraction(int mediaMs, int wallMs, int frames) {
    if (mediaMs <= 0 || wallMs < 0 || frames < 0) return;
    // Weight by video duration so a short calibration/tail chunk cannot
    // dominate the forecast for subsequent 15-second chunks.
    final weight = mediaMs / (math.min(mediaSamplesMs, 30000) + mediaMs);
    extractionMsPerMediaMs +=
        (math.max(1, wallMs) / mediaMs - extractionMsPerMediaMs) * weight;
    framesPerMediaMs += (frames / mediaMs - framesPerMediaMs) * weight;
    mediaSamplesMs += mediaMs;
  }

  void observeFrames(int frames, double wallMs) {
    if (frames <= 0 || !wallMs.isFinite || wallMs < 0) return;
    final weight = frames / (math.min(frameSamples, 16) + frames);
    frameMs += (math.max(0.1, wallMs / frames) - frameMs) * weight;
    frameSamples += frames;
  }

  Map<String, Object> toJson() => {
    'extraction': extractionMsPerMediaMs,
    'density': framesPerMediaMs,
    'frame': frameMs,
    'mediaSamples': mediaSamplesMs,
    'frameSamples': frameSamples,
  };

  static OcrTimingProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    double? number(String key) {
      final value = raw[key];
      return value is num && value.isFinite && value >= 0
          ? value.toDouble()
          : null;
    }

    final extraction = number('extraction');
    final density = number('density');
    final frame = number('frame');
    final mediaSamples = number('mediaSamples');
    final frameSamples = number('frameSamples');
    if (extraction == null ||
        density == null ||
        frame == null ||
        frame <= 0 ||
        mediaSamples == null ||
        frameSamples == null) {
      return null;
    }
    return OcrTimingProfile(
      extractionMsPerMediaMs: extraction,
      framesPerMediaMs: density,
      frameMs: frame,
      mediaSamplesMs: mediaSamples.toInt(),
      frameSamples: frameSamples.toInt(),
    );
  }
}

class OcrPerformanceHistory {
  static const maxProfiles = 96;
  final bool mobile;
  final Map<String, OcrTimingProfile> _profiles = {};
  final Map<String, String> _executionProfiles = {};
  final Map<String, ({double rate, int mediaMs})> _pipelines = {};
  String _modelKey(OcrSubtitleTrack track) => track.modelIdentity.isNotEmpty
      ? track.modelIdentity
      : track.modelId.isNotEmpty
      ? track.modelId
      : 'legacy-${track.language.name}';

  void useExecutionProfile(OcrSubtitleTrack track, String profile) {
    _executionProfiles[_modelKey(track)] = profile;
  }

  String executionProfileFor(OcrSubtitleTrack track) =>
      _executionProfiles[_modelKey(track)] ?? 'CPU:raw-v1';

  String _executionKey(OcrSubtitleTrack track) =>
      '${_modelKey(track)}:${executionProfileFor(track)}';
  final Map<String, double> _startupMs = {};
  OcrTimingProfile? _legacyBaseline;
  double? _preparationMsPerLanguage;
  double? _finalizationMsPerTrack;

  OcrPerformanceHistory({required this.mobile});

  /// Preserve the old device measurement as a weak prior for unseen settings.
  /// V2 had no phase data, so it cannot be treated as a calibrated ROI profile.
  void useLegacyProcessingRate(double? rate) {
    if (rate == null || !rate.isFinite || rate <= 0) return;
    final baseline = OcrTimingProfile.fallback(mobile);
    final wallMsPerMediaMs = 1 / rate.clamp(0.05, 200.0);
    baseline.extractionMsPerMediaMs = math.min(
      baseline.extractionMsPerMediaMs,
      wallMsPerMediaMs * 0.3,
    );
    baseline.frameMs =
        (wallMsPerMediaMs - baseline.extractionMsPerMediaMs) /
        baseline.framesPerMediaMs;
    _legacyBaseline = baseline;
  }

  OcrTimingProfile _fallback() =>
      _legacyBaseline?.copy() ?? OcrTimingProfile.fallback(mobile);

  // Crop shape affects the detector's scaled input size. A source-specific
  // profile also preserves the actual frame density for a previously used ROI.
  String _shapeKey(OcrSubtitleTrack track) {
    final r = track.region.normalized();
    return '${_executionKey(track)}:${track.language.name}:${(r.width * 20).round()}:${(r.height * 20).round()}';
  }

  String _sourceKey(String videoId, OcrSubtitleTrack track) {
    final r = track.region.normalized();
    return '${_executionKey(track)}:$videoId:${track.language.name}:'
        '${(r.left * 1000).round()}:${(r.top * 1000).round()}:'
        '${(r.right * 1000).round()}:${(r.bottom * 1000).round()}';
  }

  OcrTimingProfile profileFor(String? videoId, OcrSubtitleTrack track) =>
      (_profiles[videoId == null ? '' : _sourceKey(videoId, track)] ??
              _profiles[_shapeKey(track)] ??
              _fallback())
          .copy();

  List<String> _pipelineKeys(
    String? videoId,
    List<OcrSubtitleTrack> tracks,
    int startMs,
    int spanMs,
  ) {
    final shape = tracks.map(_shapeKey).join('|');
    final source = videoId == null
        ? null
        : tracks.map((track) => _sourceKey(videoId, track)).join('|');
    return [
      if (source != null) 'range:$startMs:$spanMs:$source',
      if (source != null) 'source:$source',
      'shape:$shape',
    ];
  }

  /// One observation per completed job captures decoding/recognition overlap
  /// and resource contention without running any extra inference.
  void recordPipeline({
    required String videoId,
    required List<OcrSubtitleTrack> tracks,
    required int spanMs,
    required double wallMs,
    int startMs = 0,
  }) {
    if (spanMs <= 0 || !wallMs.isFinite || wallMs < 0 || tracks.isEmpty) return;
    final measured = wallMs / spanMs;
    for (final key in _pipelineKeys(videoId, tracks, startMs, spanMs)) {
      final old = _pipelines.remove(key);
      final weight = spanMs / (math.min(old?.mediaMs ?? 0, 120000) + spanMs);
      _pipelines[key] = (
        rate:
            (old?.rate ?? measured) +
            (measured - (old?.rate ?? measured)) * weight,
        mediaMs: (old?.mediaMs ?? 0) + spanMs,
      );
    }
    while (_pipelines.length > maxProfiles) {
      _pipelines.remove(_pipelines.keys.first);
    }
  }

  bool hasMeasurements(String? videoId, List<OcrSubtitleTrack> tracks) =>
      tracks.isNotEmpty &&
      (tracks.every((track) {
            final profile = profileFor(videoId, track);
            return profile.mediaSamplesMs > 0 && profile.frameSamples > 0;
          }) ||
          _pipelineKeys(videoId, tracks, 0, 0).any(_pipelines.containsKey));

  String _startupKey(OcrSubtitleLanguage language, OcrSubtitleTrack? track) =>
      track == null || (track.modelId.isEmpty && track.modelIdentity.isEmpty)
      ? language.name
      : '${_executionKey(track)}:${language.name}';

  double startupMs(OcrSubtitleLanguage language, {OcrSubtitleTrack? track}) =>
      _startupMs[_startupKey(language, track)] ?? 2500;
  double preparationMs(int languageCount) =>
      (_preparationMsPerLanguage ?? 1000) * languageCount;
  double finalizationMs(int trackCount) => _finalizationMsPerTrack == null
      ? math.max(1000, 500 * trackCount).toDouble()
      : _finalizationMsPerTrack! * trackCount;

  Duration estimate({
    required int spanMs,
    required List<OcrSubtitleTrack> tracks,
    String? videoId,
    bool pipeline = false,
    int startMs = 0,
  }) {
    if (spanMs <= 0 || tracks.isEmpty) return Duration.zero;
    if (pipeline) {
      final models = <String, OcrSubtitleTrack>{
        for (final track in tracks) _modelKey(track): track,
      };
      final measured = _pipelineKeys(videoId, tracks, startMs, spanMs)
          .map((key) => _pipelines[key])
          .whereType<({double rate, int mediaMs})>()
          .firstOrNull;
      return _duration(
        preparationMs(models.length) +
            finalizationMs(tracks.length) +
            models.values.fold<double>(
              0,
              (ms, track) => ms + startupMs(track.language, track: track),
            ) +
            (measured == null
                ? _pipelineProcessingMs(
                    spanMs,
                    tracks.map((track) => profileFor(videoId, track)),
                  )
                : measured.rate * spanMs),
      );
    }
    var ms =
        preparationMs(tracks.map((t) => t.language).toSet().length) +
        finalizationMs(tracks.length);
    OcrSubtitleLanguage? previous;
    for (final track in tracks) {
      if (track.language != previous) {
        ms += startupMs(track.language, track: track);
      }
      ms += profileFor(videoId, track).processingMs(spanMs);
      previous = track.language;
    }
    return _duration(ms);
  }

  void recordChunk({
    required String videoId,
    required OcrSubtitleTrack track,
    required int mediaMs,
    required int extractionMs,
    required int frames,
    required int steadyFrames,
    required double recognitionMs,
  }) {
    for (final key in [_shapeKey(track), _sourceKey(videoId, track)]) {
      final profile = _profiles.remove(key) ?? _fallback();
      profile.observeExtraction(mediaMs, extractionMs, frames);
      profile.observeFrames(steadyFrames, recognitionMs);
      _profiles[key] = profile;
    }
    while (_profiles.length > maxProfiles) {
      _profiles.remove(_profiles.keys.first);
    }
  }

  void recordFrames({
    required String videoId,
    required OcrSubtitleTrack track,
    required double wallMs,
    required int frames,
  }) {
    if (!wallMs.isFinite || wallMs < 0) return;
    for (final key in [_shapeKey(track), _sourceKey(videoId, track)]) {
      final profile = _profiles.remove(key) ?? _fallback();
      profile.observeFrames(frames, wallMs);
      _profiles[key] = profile;
    }
    while (_profiles.length > maxProfiles) {
      _profiles.remove(_profiles.keys.first);
    }
  }

  void recordStartup(
    OcrSubtitleLanguage language,
    double ms, {
    OcrSubtitleTrack? track,
  }) {
    if (!ms.isFinite || ms < 0) return;
    final key = _startupKey(language, track);
    _startupMs[key] = _blend(_startupMs[key], ms);
  }

  void recordPreparation(int languages, int ms) {
    if (languages > 0 && ms >= 0) {
      _preparationMsPerLanguage = _blend(
        _preparationMsPerLanguage,
        ms / languages,
      );
    }
  }

  void recordFinalization(int tracks, int ms) {
    if (tracks > 0 && ms >= 0) {
      _finalizationMsPerTrack = _blend(_finalizationMsPerTrack, ms / tracks);
    }
  }

  static double _blend(double? old, double sample) =>
      old == null ? sample : old * 0.6 + sample * 0.4;

  Map<String, Object?> toJson() => {
    'profiles': _profiles.map((key, value) => MapEntry(key, value.toJson())),
    'executionProfiles': _executionProfiles,
    'pipelines': _pipelines.map(
      (key, value) =>
          MapEntry(key, {'rate': value.rate, 'mediaMs': value.mediaMs}),
    ),
    'startup': _startupMs,
    'preparation': _preparationMsPerLanguage,
    'finalization': _finalizationMsPerTrack,
  };

  void restore(Object? raw) {
    if (raw is! Map) return;
    if (raw['executionProfiles'] is Map) {
      for (final entry in (raw['executionProfiles'] as Map).entries) {
        if (entry.key is String && entry.value is String) {
          _executionProfiles[entry.key as String] = entry.value as String;
        }
      }
    }
    final profiles = raw['profiles'];
    if (profiles is Map) {
      for (final entry in profiles.entries) {
        final profile = OcrTimingProfile.fromJson(entry.value);
        if (entry.key is String && profile != null) {
          _profiles[entry.key as String] = profile;
        }
      }
      while (_profiles.length > maxProfiles) {
        _profiles.remove(_profiles.keys.first);
      }
    }
    double? valid(Object? value) =>
        value is num && value.isFinite && value >= 0 ? value.toDouble() : null;
    final pipelines = raw['pipelines'];
    if (pipelines is Map) {
      for (final entry in pipelines.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final data = entry.value as Map;
        final rate = valid(data['rate']);
        final mediaMs = valid(data['mediaMs']);
        if (rate != null && mediaMs != null && mediaMs > 0) {
          _pipelines[entry.key as String] = (
            rate: rate,
            mediaMs: mediaMs.toInt(),
          );
        }
      }
      while (_pipelines.length > maxProfiles) {
        _pipelines.remove(_pipelines.keys.first);
      }
    }
    final startup = raw['startup'];
    if (startup is Map) {
      for (final entry in startup.entries) {
        final value = valid(entry.value);
        if (entry.key is String && value != null) {
          _startupMs[entry.key as String] = value;
        }
      }
    }
    _preparationMsPerLanguage = valid(raw['preparation']);
    _finalizationMsPerTrack = valid(raw['finalization']);
  }
}

enum _OcrEstimatePhase {
  preparing,
  initializing,
  extracting,
  recognizing,
  idle,
  finalizing,
}

/// Counts real retained frames within the current chunk. Video timestamps are
/// only used for progress, never as a proxy for recognition work already done.
class OcrRuntimeEstimate {
  final bool pipeline;
  bool _pipelineRunning = false;
  bool _detailedPipeline = false;
  int _pipelineProcessedMs = 0;
  double? _pipelineRate;
  int _pipelineAtMs = 0;
  int _pipelineChunkMs = 0;
  int _pipelineChunkAtMs = 0;
  int _pipelineExtractionMs = 0;
  double _prefetchedMs = 0;
  bool _prefetch = true;
  int _pipelineWorkers = 1;
  final _pipelineFrameStarts = <int, int>{};
  late final List<int> _pipelineFrames;
  late final List<int> _pipelineDone;
  final Set<String> _warmedModels = {};
  final Map<(int, String), ({int frames, double wallMs})> _frameBatches = {};
  double pipelineStartupOverheadMs = 0;

  bool get hasMeasurements =>
      _phase == _OcrEstimatePhase.finalizing ||
      history.hasMeasurements(videoId, tracks) ||
      _profiles.every((p) => p.mediaSamplesMs > 0 && p.frameSamples > 0);

  void pipelineStarted({int workers = 1}) {
    _pipelineWorkers = workers.clamp(1, math.max(1, tracks.length));
    _pipelineRunning = true;
    _pipelineAtMs = elapsedMs();
  }

  void pipelineChunkStarted({
    required int mediaMs,
    required int extractionMs,
    required Map<int, int> frames,
    bool prefetch = true,
    int? workers,
  }) {
    if (workers != null) {
      _pipelineWorkers = workers.clamp(1, math.max(1, tracks.length));
    }
    _detailedPipeline = true;
    _pipelineChunkMs = mediaMs;
    _pipelineExtractionMs = extractionMs;
    _pipelineChunkAtMs = elapsedMs();
    _pipelineFrameStarts.clear();
    _prefetch = prefetch;
    for (var i = 0; i < tracks.length; i++) {
      _pipelineFrames[i] = frames[tracks[i].number] ?? 0;
      _pipelineDone[i] = 0;
      _observePipelineExtraction(i);
    }
  }

  void _observePipelineExtraction(int index) {
    _profiles[index].observeExtraction(
      _pipelineChunkMs,
      (_pipelineExtractionMs / math.max(1, tracks.length)).round(),
      _pipelineFrames[index],
    );
  }

  void pipelineFrameStarted(int trackNumber) {
    _pipelineFrameStarts[tracks.indexWhere((t) => t.number == trackNumber)] =
        elapsedMs();
    _lastFrameAtMs = elapsedMs();
  }

  /// Learn from each completed productive frame, including frames that emit
  /// no subtitle. Startup and automatic probes must not become per-frame cost.
  void pipelineFrameCompleted({
    required int trackNumber,
    required double wallMs,
    required String executionProfile,
    bool warmup = false,
  }) {
    final i = tracks.indexWhere((t) => t.number == trackNumber);
    final track = tracks[i];
    if (executionProfile != history.executionProfileFor(track)) {
      history.useExecutionProfile(track, executionProfile);
      _profiles[i] = history.profileFor(videoId, track);
      _observePipelineExtraction(i);
    }
    final key =
        '${track.modelIdentity}:${track.modelId}:$executionProfile:worker=${i % _pipelineWorkers}';
    final first = _warmedModels.add(key);
    if (first && warmup) {
      final overhead = math.max(0.0, wallMs - _profiles[i].frameMs);
      pipelineStartupOverheadMs += overhead;
      history.recordStartup(
        track.language,
        (i == 0 ? _workerStartupMs : 0) + overhead,
        track: track,
      );
    } else {
      _profiles[i].observeFrames(1, wallMs);
      final batchKey = (i, executionProfile);
      final batch = _frameBatches[batchKey];
      _frameBatches[batchKey] = (
        frames: (batch?.frames ?? 0) + 1,
        wallMs: (batch?.wallMs ?? 0) + wallMs,
      );
    }
    _pipelineDone[i]++;
    _pipelineFrameStarts.remove(i);
    _lastFrameAtMs = elapsedMs();
  }

  void pipelineChunkCompleted(int processedMediaMs, int wallMs) {
    // Merge persistent profiles once per chunk. The hot path only updates a
    // running average and two counters; it performs no storage I/O.
    for (final entry in _frameBatches.entries) {
      final track = tracks[entry.key.$1];
      final previous = history.executionProfileFor(track);
      history.useExecutionProfile(track, entry.key.$2);
      history.recordFrames(
        videoId: videoId,
        track: track,
        frames: entry.value.frames,
        wallMs: entry.value.wallMs,
      );
      history.useExecutionProfile(track, previous);
    }
    _frameBatches.clear();
    final delta = processedMediaMs - _pipelineProcessedMs;
    if (delta > 0 && wallMs >= 0) {
      final measured = wallMs / delta;
      final weight = delta / (math.min(_pipelineProcessedMs, 30000) + delta);
      _pipelineRate =
          (_pipelineRate ?? measured) +
          (measured - (_pipelineRate ?? measured)) * weight;
    }
    _prefetchedMs = _prefetch && _pipelineChunkMs > 0
        ? math.min(
            _pipelineExtractionCost(
              math.min(15000, math.max(0, spanMs - processedMediaMs)),
            ),
            math.max(0, elapsedMs() - _pipelineChunkAtMs).toDouble(),
          )
        : 0;
    _pipelineChunkMs = 0;
    _pipelineFrameStarts.clear();
    _pipelineProcessedMs = processedMediaMs;
    _pipelineAtMs = elapsedMs();
  }

  final OcrPerformanceHistory history;
  final String videoId;
  final List<OcrSubtitleTrack> tracks;
  final int spanMs;
  final int startMs;
  final int Function() elapsedMs;
  late final List<OcrTimingProfile> _profiles;
  late final List<int> _completedMs;
  _OcrEstimatePhase _phase = _OcrEstimatePhase.preparing;
  int _phaseStartedMs = 0;
  int _trackIndex = 0;
  int _chunkMs = 0;
  int _frames = 0;
  int _processedFrames = 0;
  int _lastFrameAtMs = 0;
  int _workerStartupMs = 0;
  bool _warmupPending = false;

  OcrRuntimeEstimate({
    required this.history,
    required this.videoId,
    required this.tracks,
    required this.spanMs,
    required this.elapsedMs,
    this.pipeline = false,
    this.startMs = 0,
  }) {
    _profiles = tracks.map((t) => history.profileFor(videoId, t)).toList();
    _completedMs = List.filled(tracks.length, 0);
    _pipelineFrames = List.filled(tracks.length, 0);
    _pipelineDone = List.filled(tracks.length, 0);
    _phaseStartedMs = elapsedMs();
  }

  void preparationStarted() => _begin(_OcrEstimatePhase.preparing);

  void trackStarted(int index, {required bool needsStartup}) {
    _trackIndex = index;
    if (needsStartup) _workerStartupMs = 0;
    _warmupPending = needsStartup || _warmupPending;
    _begin(
      needsStartup ? _OcrEstimatePhase.initializing : _OcrEstimatePhase.idle,
    );
  }

  void workerReady(int startupMs) {
    _workerStartupMs = startupMs;
    _begin(_OcrEstimatePhase.idle);
  }

  void extractionStarted(int mediaMs) {
    _chunkMs = mediaMs;
    _begin(_OcrEstimatePhase.extracting);
  }

  void recognitionStarted({required int frames, required int extractionMs}) {
    _profiles[_trackIndex].observeExtraction(_chunkMs, extractionMs, frames);
    _frames = frames;
    _processedFrames = 0;
    _begin(_OcrEstimatePhase.recognizing);
    _lastFrameAtMs = elapsedMs();
  }

  /// Returns false for the first frame after starting a worker: it includes
  /// the existing CPU/GPU warm-up and must not inflate steady-state throughput.
  bool frameCompleted(double wallMs) {
    _processedFrames++;
    _lastFrameAtMs = elapsedMs();
    if (_warmupPending) {
      history.recordStartup(
        tracks[_trackIndex].language,
        _workerStartupMs + math.max(0, wallMs - _profiles[_trackIndex].frameMs),
        track: tracks[_trackIndex],
      );
      _warmupPending = false;
      return false;
    }
    _profiles[_trackIndex].observeFrames(1, wallMs);
    return true;
  }

  void chunkCompleted() {
    _completedMs[_trackIndex] += _chunkMs;
    _chunkMs = 0;
    _begin(_OcrEstimatePhase.idle);
  }

  void finalizationStarted() => _begin(_OcrEstimatePhase.finalizing);

  void _begin(_OcrEstimatePhase phase) {
    _phase = phase;
    _phaseStartedMs = elapsedMs();
  }

  Duration get remaining {
    final now = elapsedMs();
    final phaseElapsed = math.max(0, now - _phaseStartedMs);
    final saving = history.finalizationMs(tracks.length);
    if (_phase == _OcrEstimatePhase.finalizing) {
      return _duration(math.max(1000, _phaseRemaining(saving, phaseElapsed)));
    }
    if (pipeline && !_pipelineRunning) {
      final predicted = history
          .estimate(
            spanMs: spanMs,
            startMs: startMs,
            tracks: tracks,
            videoId: videoId,
            pipeline: true,
          )
          .inMilliseconds
          .toDouble();
      final preparing = history.preparationMs(
        tracks.map((track) => history._modelKey(track)).toSet().length,
      );
      if (_phase == _OcrEstimatePhase.preparing) {
        return _duration(
          predicted - preparing + _phaseRemaining(preparing, phaseElapsed),
        );
      }
      final startup = history.startupMs(
        tracks.first.language,
        track: tracks.first,
      );
      if (_phase == _OcrEstimatePhase.initializing) {
        return _duration(
          predicted -
              preparing -
              startup +
              _phaseRemaining(startup, phaseElapsed),
        );
      }
      return _duration(
        predicted - preparing - math.min(startup, _workerStartupMs),
      );
    }
    if (pipeline && _pipelineRunning && _detailedPipeline) {
      return _duration(_pipelineRemaining(now) + saving);
    }
    if (pipeline && _pipelineRunning) {
      final rate =
          _pipelineRate ??
          _pipelineProcessingMs(spanMs, _profiles) / math.max(1, spanMs);
      final work = math.max(0, spanMs - _pipelineProcessedMs) * rate;
      return _duration(math.max(1000, work - (now - _pipelineAtMs)) + saving);
    }
    var ms = saving;
    final preparing = _phase == _OcrEstimatePhase.preparing;
    final firstIndex = preparing ? 0 : _trackIndex;
    OcrSubtitleLanguage? previous = preparing
        ? null
        : tracks[_trackIndex].language;
    for (var i = firstIndex; i < tracks.length; i++) {
      final track = tracks[i];
      if (i > firstIndex || preparing) {
        if (track.language != previous) {
          ms += history.startupMs(track.language, track: track);
        }
        ms += _profiles[i].processingMs(spanMs);
      } else {
        final profile = _profiles[i];
        final warmup = _warmupPending
            ? math.max(
                0.0,
                history.startupMs(track.language, track: track) -
                    _workerStartupMs,
              )
            : 0.0;
        final chunkActive =
            _phase == _OcrEstimatePhase.extracting ||
            _phase == _OcrEstimatePhase.recognizing;
        final futureMs = math.max(
          0,
          spanMs - _completedMs[i] - (chunkActive ? _chunkMs : 0),
        );
        ms += profile.processingMs(futureMs);
        switch (_phase) {
          case _OcrEstimatePhase.initializing:
            ms += _phaseRemaining(
              history.startupMs(track.language, track: track),
              phaseElapsed,
            );
          case _OcrEstimatePhase.extracting:
            ms +=
                _phaseRemaining(
                  profile.extractionMsPerMediaMs * _chunkMs,
                  phaseElapsed,
                ) +
                profile.framesPerMediaMs * _chunkMs * profile.frameMs +
                warmup;
          case _OcrEstimatePhase.recognizing:
            final left = math.max(0, _frames - _processedFrames);
            if (left > 0) {
              final inFlight = math.max(0, now - _lastFrameAtMs);
              // Account for an unusually slow frame before it completes. A
              // warm-up frame affects this frame only, not every future frame.
              final frameCost = _warmupPending
                  ? profile.frameMs
                  : math.max(profile.frameMs, inFlight.toDouble());
              ms +=
                  (left - 1) * frameCost +
                  _phaseRemaining(frameCost + warmup, inFlight);
            }
          default:
            ms += warmup;
        }
      }
      previous = track.language;
    }
    if (preparing) {
      ms += _phaseRemaining(
        history.preparationMs(tracks.map((t) => t.language).toSet().length),
        phaseElapsed,
      );
    }
    return _duration(ms);
  }

  double _pipelineExtractionCost(int mediaMs) => _profiles.fold<double>(
    0,
    (ms, p) => ms + p.extractionMsPerMediaMs * mediaMs,
  );

  double _pipelineRemaining(int now) {
    final futureMs = math.max(
      0,
      spanMs - _pipelineProcessedMs - _pipelineChunkMs,
    );
    final workerCosts = List<double>.filled(_pipelineWorkers, 0);
    for (var i = 0; i < tracks.length; i++) {
      final left = math.max(0, _pipelineFrames[i] - _pipelineDone[i]);
      if (_pipelineChunkMs == 0 || left == 0) continue;
      final profile = _profiles[i];
      final frameMs = profile.frameMs;
      final started = _pipelineFrameStarts[i];
      if (started != null) {
        final inFlight = math.max(0, now - started);
        // Wait for a completed measurement before revising other frames: an
        // in-flight call may include a one-off automatic tuning experiment.
        workerCosts[i % _pipelineWorkers] +=
            (left - 1) * frameMs + _phaseRemaining(frameMs, inFlight);
      } else {
        workerCosts[i % _pipelineWorkers] += left * frameMs;
      }
    }
    final current = workerCosts.reduce(math.max);
    var future = _pipelineProcessingMs(
      futureMs,
      _profiles,
      overlap: _prefetch,
      workers: _pipelineWorkers,
    );
    if (futureMs > 0 && _prefetch) {
      final extraction = _pipelineExtractionCost(math.min(15000, futureMs));
      final credit = _pipelineChunkMs > 0
          ? now - _pipelineChunkAtMs + current
          : _prefetchedMs + math.max(0, now - _pipelineAtMs);
      future -= math.min(extraction, credit);
      if (_pipelineChunkMs == 0 && credit >= extraction) {
        future += _phaseRemaining(extraction, credit.floor());
      }
    }
    return math.max(0, current + future);
  }

  // An unfinished phase cannot have a zero ETA just because its initial
  // forecast expired. Actual phase/frame timings replace this as work arrives.
  static double _phaseRemaining(double expected, int elapsed) => math.max(
    math.min(200.0, math.max(1.0, expected * 0.1)),
    expected - elapsed,
  );
}

// A decoded chunk and the next recognition chunk overlap. Include one chunk
// of fill/drain work; short jobs still pay both phases in full.
double _pipelineProcessingMs(
  int mediaMs,
  Iterable<OcrTimingProfile> profiles, {
  bool overlap = true,
  int workers = 1,
}) {
  if (mediaMs <= 0) return 0;
  var extraction = 0.0;
  final costs = List<double>.filled(math.max(1, workers), 0);
  var index = 0;
  for (final p in profiles) {
    extraction += p.extractionMsPerMediaMs * mediaMs;
    costs[index++ % costs.length] += p.framesPerMediaMs * p.frameMs * mediaMs;
  }
  final recognition = costs.reduce(math.max);
  if (!overlap) return extraction + recognition;
  return math.max(extraction, recognition) +
      math.min(extraction, recognition) * math.min(15000, mediaMs) / mediaMs;
}

Duration _duration(double ms) =>
    Duration(milliseconds: math.max(0, ms.round()));
