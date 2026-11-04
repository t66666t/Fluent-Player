import 'subtitle_debug_preset.dart';
import 'subtitle_position.dart';
import 'package:flutter/material.dart';
import 'subtitle_style.dart';

enum VideoComposeStage {
  queued,
  preparing,
  rendering,
  finalizing,
  completed,
  failed,
  materializing,
}

enum VideoComposeResolution { source, p360, p480, p720, p1080, p1440, p2160 }

enum VideoComposeRenderMode {
  precise,
  approximate;

  String get storageValue => name;

  static VideoComposeRenderMode fromStorage(
    Object? value, {
    VideoComposeRenderMode fallback = VideoComposeRenderMode.approximate,
  }) {
    final String raw = value?.toString() ?? '';
    return VideoComposeRenderMode.values.firstWhere(
      (mode) => mode.storageValue == raw,
      orElse: () => fallback,
    );
  }
}

class VideoComposeSoftSubtitleTrack {
  final String path;
  final String title;

  const VideoComposeSoftSubtitleTrack({
    required this.path,
    required this.title,
  });

  Map<String, dynamic> toJson() {
    return {'path': path, 'title': title};
  }

  factory VideoComposeSoftSubtitleTrack.fromJson(Map<String, dynamic> json) {
    return VideoComposeSoftSubtitleTrack(
      path: json['path'] as String? ?? '',
      title: json['title'] as String? ?? '',
    );
  }
}

SubtitlePlacementSnapshot? _placementFromJson(Object? json) {
  final SubtitlePlacementParse parsed = SubtitlePlacementSnapshot.parse(json);
  if (parsed.kind == SubtitlePlacementParseKind.parsed) return parsed.snapshot;
  return null;
}

class VideoComposeRequest {
  final String videoId;
  final String videoPath;
  final String title;
  final String? primarySubtitlePath;
  final String? secondarySubtitlePath;
  final String? primaryFontLanguage;
  final String? secondaryFontLanguage;
  final bool renderSecondarySubtitle;
  final bool continuousSubtitle;
  final bool embedSoftSubtitles;
  final bool softSubtitleOnly;
  final bool softSubtitleUseSourceQuality;
  final List<VideoComposeSoftSubtitleTrack> softSubtitleTracks;
  final VideoComposeResolution resolution;
  final VideoComposeRenderMode renderMode;

  /// 普通（非幽灵）横屏字幕样式。保留 subtitleStyle 名称兼容旧任务。
  final SubtitleStyle subtitleStyle;
  final SubtitleDebugPreset? subtitlePreset;

  /// 普通（非幽灵）竖屏字幕样式。
  final SubtitleStyle subtitleStylePortrait;
  final Alignment subtitleAlignment;

  /// Frozen normal-caption placement. Null on old jobs: a preset keeps its
  /// default bottom inset, and a job without a preset keeps [subtitleAlignment].
  final SubtitlePlacementSnapshot? subtitlePlacement;
  final bool splitSubtitleByLine;
  final double subtitleItemGap;
  final int subtitleRendererVersion;
  final String outputPath;

  const VideoComposeRequest({
    required this.videoId,
    required this.videoPath,
    required this.title,
    this.primarySubtitlePath,
    this.secondarySubtitlePath,
    this.primaryFontLanguage,
    this.secondaryFontLanguage,
    required this.renderSecondarySubtitle,
    required this.continuousSubtitle,
    required this.embedSoftSubtitles,
    required this.softSubtitleOnly,
    required this.softSubtitleUseSourceQuality,
    required this.softSubtitleTracks,
    required this.resolution,
    this.renderMode = VideoComposeRenderMode.precise,
    required this.subtitleStyle,
    this.subtitlePreset,
    SubtitleStyle? subtitleStylePortrait,
    required this.subtitleAlignment,
    this.subtitlePlacement,
    this.splitSubtitleByLine = true,
    this.subtitleItemGap = 6.0,
    this.subtitleRendererVersion = 1,
    required this.outputPath,
  }) : subtitleStylePortrait = subtitleStylePortrait ?? subtitleStyle;

  VideoComposeRequest copyWith({String? videoPath}) => VideoComposeRequest(
    videoId: videoId,
    videoPath: videoPath ?? this.videoPath,
    title: title,
    primarySubtitlePath: primarySubtitlePath,
    secondarySubtitlePath: secondarySubtitlePath,
    primaryFontLanguage: primaryFontLanguage,
    secondaryFontLanguage: secondaryFontLanguage,
    renderSecondarySubtitle: renderSecondarySubtitle,
    continuousSubtitle: continuousSubtitle,
    embedSoftSubtitles: embedSoftSubtitles,
    softSubtitleOnly: softSubtitleOnly,
    softSubtitleUseSourceQuality: softSubtitleUseSourceQuality,
    softSubtitleTracks: softSubtitleTracks,
    resolution: resolution,
    renderMode: renderMode,
    subtitleStyle: subtitleStyle,
    subtitlePreset: subtitlePreset,
    subtitleStylePortrait: subtitleStylePortrait,
    subtitleAlignment: subtitleAlignment,
    subtitlePlacement: subtitlePlacement,
    splitSubtitleByLine: splitSubtitleByLine,
    subtitleItemGap: subtitleItemGap,
    subtitleRendererVersion: subtitleRendererVersion,
    outputPath: outputPath,
  );

  SubtitleStyle styleForCanvas({required int width, required int height}) =>
      height > width ? subtitleStylePortrait : subtitleStyle;

  Map<String, dynamic> toJson() {
    return {
      'videoId': videoId,
      'videoPath': videoPath,
      'title': title,
      'primarySubtitlePath': primarySubtitlePath,
      'secondarySubtitlePath': secondarySubtitlePath,
      'primaryFontLanguage': primaryFontLanguage,
      'secondaryFontLanguage': secondaryFontLanguage,
      'renderSecondarySubtitle': renderSecondarySubtitle,
      'continuousSubtitle': continuousSubtitle,
      'embedSoftSubtitles': embedSoftSubtitles,
      'softSubtitleOnly': softSubtitleOnly,
      'softSubtitleUseSourceQuality': softSubtitleUseSourceQuality,
      'softSubtitleTracks': softSubtitleTracks.map((e) => e.toJson()).toList(),
      'resolution': resolution.index,
      'renderMode': renderMode.storageValue,
      'subtitleStyle': subtitleStyle.toJson(),
      if (subtitlePreset != null) 'subtitlePreset': subtitlePreset!.toJson(),
      'subtitleStyleLandscape': subtitleStyle.toJson(),
      'subtitleStylePortrait': subtitleStylePortrait.toJson(),
      'subtitleAlignmentX': subtitleAlignment.x,
      'subtitleAlignmentY': subtitleAlignment.y,
      if (subtitlePlacement != null)
        'subtitlePlacement': subtitlePlacement!.toJson(),
      'splitSubtitleByLine': splitSubtitleByLine,
      'subtitleItemGap': subtitleItemGap,
      'subtitleRendererVersion': subtitleRendererVersion,
      'outputPath': outputPath,
    };
  }

  factory VideoComposeRequest.fromJson(Map<String, dynamic> json) {
    return VideoComposeRequest(
      videoId: json['videoId'] as String? ?? '',
      videoPath: json['videoPath'] as String? ?? '',
      title: json['title'] as String? ?? 'Unknown',
      primarySubtitlePath: json['primarySubtitlePath'] as String?,
      secondarySubtitlePath: json['secondarySubtitlePath'] as String?,
      primaryFontLanguage: json['primaryFontLanguage'] as String?,
      secondaryFontLanguage: json['secondaryFontLanguage'] as String?,
      renderSecondarySubtitle: json['renderSecondarySubtitle'] as bool? ?? true,
      continuousSubtitle: json['continuousSubtitle'] as bool? ?? false,
      embedSoftSubtitles: json['embedSoftSubtitles'] as bool? ?? false,
      softSubtitleOnly: json['softSubtitleOnly'] as bool? ?? false,
      softSubtitleUseSourceQuality:
          json['softSubtitleUseSourceQuality'] as bool? ?? true,
      softSubtitleTracks:
          (json['softSubtitleTracks'] as List<dynamic>? ?? const <dynamic>[])
              .map(
                (e) => VideoComposeSoftSubtitleTrack.fromJson(
                  e as Map<String, dynamic>,
                ),
              )
              .toList(),
      resolution:
          VideoComposeResolution.values[(json['resolution'] as int?) ?? 0],
      renderMode: VideoComposeRenderMode.fromStorage(json['renderMode']),
      subtitlePreset: SubtitleDebugPreset.restore(json['subtitlePreset']),
      subtitleStyle: SubtitleStyle.fromJson(
        (json['subtitleStyleLandscape'] ??
                json['subtitleStyle'] ??
                const <String, dynamic>{})
            as Map<String, dynamic>,
      ),
      subtitleStylePortrait: SubtitleStyle.fromJson(
        (json['subtitleStylePortrait'] ??
                json['subtitleStyleLandscape'] ??
                json['subtitleStyle'] ??
                const <String, dynamic>{})
            as Map<String, dynamic>,
      ),
      subtitleAlignment: Alignment(
        (json['subtitleAlignmentX'] as num?)?.toDouble() ?? 0.0,
        (json['subtitleAlignmentY'] as num?)?.toDouble() ?? 0.8,
      ),
      subtitlePlacement: _placementFromJson(json['subtitlePlacement']),
      splitSubtitleByLine: json['splitSubtitleByLine'] as bool? ?? true,
      subtitleItemGap: (json['subtitleItemGap'] as num?)?.toDouble() ?? 6.0,
      subtitleRendererVersion:
          (json['subtitleRendererVersion'] as num?)?.toInt() ?? 0,
      outputPath: json['outputPath'] as String? ?? '',
    );
  }
}

class VideoComposeTaskState {
  final String taskId;
  final VideoComposeRequest request;
  final DateTime createdAt;
  final DateTime? completedAt;
  final VideoComposeStage stage;
  final double progress;
  final String message;
  final String? error;

  const VideoComposeTaskState({
    required this.taskId,
    required this.request,
    required this.createdAt,
    this.completedAt,
    required this.stage,
    required this.progress,
    required this.message,
    this.error,
  });

  VideoComposeTaskState copyWith({
    VideoComposeStage? stage,
    double? progress,
    String? message,
    String? error,
    DateTime? completedAt,
  }) {
    return VideoComposeTaskState(
      taskId: taskId,
      request: request,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
      stage: stage ?? this.stage,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      error: error,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'taskId': taskId,
      'request': request.toJson(),
      'createdAt': createdAt.millisecondsSinceEpoch,
      'completedAt': completedAt?.millisecondsSinceEpoch,
      'stage': stage.index,
      'progress': progress,
      'message': message,
      'error': error,
    };
  }

  factory VideoComposeTaskState.fromJson(Map<String, dynamic> json) {
    return VideoComposeTaskState(
      taskId: json['taskId'] as String? ?? '',
      request: VideoComposeRequest.fromJson(
        json['request'] as Map<String, dynamic>? ?? {},
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        json['createdAt'] as int? ?? 0,
      ),
      completedAt: json['completedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['completedAt'] as int)
          : null,
      stage: VideoComposeStage.values[(json['stage'] as int?) ?? 0],
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      message: json['message'] as String? ?? '',
      error: json['error'] as String?,
    );
  }
}
