import 'dart:ui';
import 'ocr_compute_preferences.dart';

enum OcrSubtitleLanguage { chinese, english, japanese, korean, latin }

extension OcrSubtitleLanguageInfo on OcrSubtitleLanguage {
  String get code => switch (this) {
    OcrSubtitleLanguage.chinese => 'zh-Hans',
    OcrSubtitleLanguage.english => 'en',
    OcrSubtitleLanguage.japanese => 'ja',
    OcrSubtitleLanguage.korean => 'ko',
    OcrSubtitleLanguage.latin => 'latin',
  };

  String get label => switch (this) {
    OcrSubtitleLanguage.chinese => '中文（简繁兼容）',
    OcrSubtitleLanguage.english => '英文',
    OcrSubtitleLanguage.japanese => '日文',
    OcrSubtitleLanguage.korean => '韩文',
    OcrSubtitleLanguage.latin => '拉丁字母语言',
  };
}

class NormalizedOcrRegion {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const NormalizedOcrRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  const NormalizedOcrRegion.subtitleDefault()
    : left = 0.05,
      top = 0.72,
      right = 0.95,
      bottom = 1.0;

  double get width => right - left;
  double get height => bottom - top;
  Rect get rect => Rect.fromLTRB(left, top, right, bottom);

  NormalizedOcrRegion normalized({
    double minWidth = 0.03,
    double minHeight = 0.02,
  }) {
    var l = left.clamp(0.0, 1.0);
    var t = top.clamp(0.0, 1.0);
    var r = right.clamp(0.0, 1.0);
    var b = bottom.clamp(0.0, 1.0);
    if (r < l) (l, r) = (r, l);
    if (b < t) (t, b) = (b, t);
    if (r - l < minWidth) {
      r = (l + minWidth).clamp(0.0, 1.0);
      l = (r - minWidth).clamp(0.0, 1.0);
    }
    if (b - t < minHeight) {
      b = (t + minHeight).clamp(0.0, 1.0);
      t = (b - minHeight).clamp(0.0, 1.0);
    }
    return NormalizedOcrRegion(left: l, top: t, right: r, bottom: b);
  }

  Rect toPixelRect(Size sourceSize) => Rect.fromLTRB(
    left * sourceSize.width,
    top * sourceSize.height,
    right * sourceSize.width,
    bottom * sourceSize.height,
  );

  double intersectionOverUnion(NormalizedOcrRegion other) {
    final a = normalized();
    final b = other.normalized();
    final intersectionWidth =
        (a.right < b.right ? a.right : b.right) -
        (a.left > b.left ? a.left : b.left);
    final intersectionHeight =
        (a.bottom < b.bottom ? a.bottom : b.bottom) -
        (a.top > b.top ? a.top : b.top);
    if (intersectionWidth <= 0 || intersectionHeight <= 0) return 0;
    final intersection = intersectionWidth * intersectionHeight;
    final union = a.width * a.height + b.width * b.height - intersection;
    return union <= 0 ? 0 : intersection / union;
  }

  NormalizedOcrRegion union(NormalizedOcrRegion other) {
    final a = normalized();
    final b = other.normalized();
    return NormalizedOcrRegion(
      left: a.left < b.left ? a.left : b.left,
      top: a.top < b.top ? a.top : b.top,
      right: a.right > b.right ? a.right : b.right,
      bottom: a.bottom > b.bottom ? a.bottom : b.bottom,
    ).normalized();
  }

  bool get isSubtitleDefault =>
      (left - 0.05).abs() < 0.000001 &&
      (top - 0.72).abs() < 0.000001 &&
      (right - 0.95).abs() < 0.000001 &&
      (bottom - 1.0).abs() < 0.000001;

  Map<String, dynamic> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };

  factory NormalizedOcrRegion.fromJson(Map<String, dynamic> json) =>
      NormalizedOcrRegion(
        left: (json['left'] as num?)?.toDouble() ?? 0.05,
        top: (json['top'] as num?)?.toDouble() ?? 0.72,
        right: (json['right'] as num?)?.toDouble() ?? 0.95,
        bottom: (json['bottom'] as num?)?.toDouble() ?? 1.0,
      ).normalized();
}

enum OcrSubtitleJobStatus {
  idle,
  preparing,
  downloading,
  extracting,
  recognizing,
  writing,
  completed,
  cancelled,
  interrupted,
  failed,
  materializing,
}

class OcrSubtitleTrack {
  final int number;
  final NormalizedOcrRegion region;
  final OcrSubtitleLanguage language;
  final String modelId;
  final String modelIdentity;

  const OcrSubtitleTrack({
    required this.number,
    required this.region,
    required this.language,
    this.modelId = '',
    this.modelIdentity = '',
  });

  OcrSubtitleTrack copyWith({
    int? number,
    NormalizedOcrRegion? region,
    OcrSubtitleLanguage? language,
    String? modelId,
    String? modelIdentity,
  }) => OcrSubtitleTrack(
    number: number ?? this.number,
    region: region ?? this.region,
    language: language ?? this.language,
    modelId: modelId ?? this.modelId,
    modelIdentity: modelIdentity ?? this.modelIdentity,
  );

  Map<String, dynamic> toJson() => {
    'number': number,
    'region': region.toJson(),
    'language': language.name,
    if (modelId.isNotEmpty) 'modelId': modelId,
    if (modelIdentity.isNotEmpty) 'modelIdentity': modelIdentity,
  };

  factory OcrSubtitleTrack.fromJson(Map<String, dynamic> json) =>
      OcrSubtitleTrack(
        modelId: json['modelId'] as String? ?? '',
        modelIdentity: json['modelIdentity'] as String? ?? '',
        number: (json['number'] as num?)?.toInt() ?? 1,
        region: NormalizedOcrRegion.fromJson(
          Map<String, dynamic>.from(json['region'] as Map? ?? const {}),
        ),
        language: OcrSubtitleLanguage.values.firstWhere(
          (value) => value.name == json['language'],
          orElse: () => OcrSubtitleLanguage.chinese,
        ),
      );
}

/// Volatile recognition counters. They do not change persisted job identities.
class OcrRecognitionProgress {
  OcrRecognitionProgress({
    required this.total,
    required Map<int, Duration> completedByTrack,
  }) : completedByTrack = Map.unmodifiable(completedByTrack);

  final Duration total;
  final Map<int, Duration> completedByTrack;
}

class OcrSubtitleJob {
  final String videoId;
  final String videoPath;
  final List<OcrSubtitleTrack> tracks;
  final Duration start;
  final Duration end;
  final bool mirrorHorizontal;
  final bool mirrorVertical;
  final OcrSubtitleJobStatus status;
  final double progress;
  final double? preparationProgress;
  final OcrRecognitionProgress? recognitionProgress;
  final String statusMessage;
  final Duration? remaining;
  final List<String> outputPaths;
  final String? error;
  final OcrComputePreferences? compute;

  /// Exact online representation; null retains the legacy preparation policy.
  final String? videoQualityId;

  const OcrSubtitleJob({
    required this.videoId,
    required this.videoPath,
    required this.tracks,
    required this.start,
    required this.end,
    this.mirrorHorizontal = false,
    this.mirrorVertical = false,
    this.status = OcrSubtitleJobStatus.idle,
    this.progress = 0,
    this.preparationProgress,
    this.recognitionProgress,
    this.statusMessage = '',
    this.remaining,
    this.outputPaths = const <String>[],
    this.error,
    this.compute,
    this.videoQualityId,
  });

  OcrSubtitleLanguage get language => tracks.first.language;
  NormalizedOcrRegion get region => tracks.first.region;
  String? get outputPath => outputPaths.isEmpty ? null : outputPaths.first;

  bool get isRunning => const {
    OcrSubtitleJobStatus.preparing,
    OcrSubtitleJobStatus.downloading,
    OcrSubtitleJobStatus.extracting,
    OcrSubtitleJobStatus.recognizing,
    OcrSubtitleJobStatus.writing,
    OcrSubtitleJobStatus.materializing,
  }.contains(status);

  OcrSubtitleJob copyWith({
    String? videoPath,
    List<OcrSubtitleTrack>? tracks,
    OcrSubtitleJobStatus? status,
    double? progress,
    double? preparationProgress,
    bool clearPreparationProgress = false,
    OcrRecognitionProgress? recognitionProgress,
    String? statusMessage,
    Duration? remaining,
    bool clearRemaining = false,
    List<String>? outputPaths,
    String? error,
    OcrComputePreferences? compute,
    String? videoQualityId,
  }) => OcrSubtitleJob(
    videoId: videoId,
    videoPath: videoPath ?? this.videoPath,
    tracks: tracks ?? this.tracks,
    start: start,
    end: end,
    mirrorHorizontal: mirrorHorizontal,
    mirrorVertical: mirrorVertical,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    preparationProgress: clearPreparationProgress
        ? null
        : preparationProgress ?? this.preparationProgress,
    recognitionProgress: recognitionProgress ?? this.recognitionProgress,
    statusMessage: statusMessage ?? this.statusMessage,
    remaining: clearRemaining ? null : remaining ?? this.remaining,
    outputPaths: outputPaths ?? this.outputPaths,
    error: error ?? this.error,
    compute: compute ?? this.compute,
    videoQualityId: videoQualityId ?? this.videoQualityId,
  );
}
