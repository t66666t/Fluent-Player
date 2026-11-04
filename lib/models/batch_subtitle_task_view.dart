import 'subtitle_output_path_strategy.dart';
import 'transcription_status.dart';
import 'local_asr_progress.dart';
import 'transcription_progress.dart';

class BatchSubtitleTaskView {
  final String mediaKey;
  final String videoPath;
  final String? videoId;
  final String videoName;
  final String videoDuration;
  final bool isExternal;
  final TranscriptionStatus status;
  final double progress;
  final double? translationProgress;
  final LocalAsrProgress? localAsrProgress;
  final TranscriptionAudioProgress? audioProgress;
  final String statusMessage;
  final int createdAt;
  final SubtitleOutputPathStrategy? outputPathStrategy;
  final String? customOutputDir;
  final bool isStarted;

  const BatchSubtitleTaskView({
    required this.mediaKey,
    required this.videoPath,
    this.videoId,
    required this.videoName,
    required this.videoDuration,
    required this.isExternal,
    required this.status,
    required this.progress,
    this.translationProgress,
    this.localAsrProgress,
    this.audioProgress,
    this.statusMessage = '',
    required this.createdAt,
    this.outputPathStrategy,
    this.customOutputDir,
    this.isStarted = false,
  });

  bool get isRunning => switch (status) {
    TranscriptionStatus.idle ||
    TranscriptionStatus.completed ||
    TranscriptionStatus.error => false,
    _ => true,
  };

  BatchSubtitleTaskView copyWith({
    String? mediaKey,
    String? videoPath,
    String? videoId,
    String? videoName,
    String? videoDuration,
    bool? isExternal,
    TranscriptionStatus? status,
    double? progress,
    double? translationProgress,
    LocalAsrProgress? localAsrProgress,
    TranscriptionAudioProgress? audioProgress,
    String? statusMessage,
    int? createdAt,
    SubtitleOutputPathStrategy? outputPathStrategy,
    String? customOutputDir,
    bool? isStarted,
  }) {
    return BatchSubtitleTaskView(
      mediaKey: mediaKey ?? this.mediaKey,
      videoPath: videoPath ?? this.videoPath,
      videoId: videoId ?? this.videoId,
      videoName: videoName ?? this.videoName,
      videoDuration: videoDuration ?? this.videoDuration,
      isExternal: isExternal ?? this.isExternal,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      translationProgress: translationProgress ?? this.translationProgress,
      localAsrProgress: localAsrProgress ?? this.localAsrProgress,
      audioProgress: audioProgress ?? this.audioProgress,
      statusMessage: statusMessage ?? this.statusMessage,
      createdAt: createdAt ?? this.createdAt,
      outputPathStrategy: outputPathStrategy ?? this.outputPathStrategy,
      customOutputDir: customOutputDir ?? this.customOutputDir,
      isStarted: isStarted ?? this.isStarted,
    );
  }
}

/// Running work stays at the top in both display directions. Scheduled work
/// follows it, ahead of paused/unstarted tasks and history. Preserve each
/// group's queue order; reversing the display never changes execution order.
List<BatchSubtitleTaskView> orderBatchSubtitleTasks(
  Iterable<BatchSubtitleTaskView> tasks, {
  bool descending = false,
}) {
  final running = <BatchSubtitleTaskView>[];
  final scheduled = <BatchSubtitleTaskView>[];
  final remaining = <BatchSubtitleTaskView>[];
  for (final task in tasks) {
    if (task.isRunning) {
      running.add(task);
    } else if (task.status == TranscriptionStatus.idle && task.isStarted) {
      scheduled.add(task);
    } else {
      remaining.add(task);
    }
  }
  return [
    ...running,
    ...(descending ? scheduled.reversed : scheduled),
    ...(descending ? remaining.reversed : remaining),
  ];
}
