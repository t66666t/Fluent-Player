import '../models/cloud_drive_models.dart';

/// Where a cloud quality switch stopped. Diagnostics and the UI use the same
/// vocabulary, so "no request was made" is never reported as a network failure.
enum CloudDriveQualitySwitchStage {
  entry,
  resolve,
  initialize,
  handoff,
  seek,
  warmFrame,
  commit,
  cleanup,
  done,
}

/// What happened. Only [failed] may be presented as a switch failure.
enum CloudDriveQualitySwitchResult {
  committed,
  alreadySelected,
  notReady,
  unavailable,
  cancelled,
  superseded,
  failed,
}

extension CloudDriveQualitySwitchResultX on CloudDriveQualitySwitchResult {
  bool get isSuccess =>
      this == CloudDriveQualitySwitchResult.committed ||
      this == CloudDriveQualitySwitchResult.alreadySelected;

  /// The old source is still playing and nothing was broken.
  bool get isHarmless =>
      this == CloudDriveQualitySwitchResult.cancelled ||
      this == CloudDriveQualitySwitchResult.superseded ||
      this == CloudDriveQualitySwitchResult.notReady ||
      this == CloudDriveQualitySwitchResult.alreadySelected;
}

/// One quality switch attempt, including the stage it reached.
///
/// The bool API keeps working for existing callers; this result exists so a
/// failure can be attributed to a real stage and so a superseded or cancelled
/// request does not show a failure toast.
class CloudDriveQualitySwitchOutcome {
  const CloudDriveQualitySwitchOutcome({
    required this.operationId,
    required this.requestedQualityId,
    required this.stage,
    required this.result,
    this.actualQualityId,
    this.reason,
    this.errorType,
    this.errorDetail,
    this.retryable = false,
    this.elapsedMs = 0,
    this.phases = const <String, int>{},
  });

  /// `q<counter>` — matches the matching playback log lines.
  final String operationId;
  final String requestedQualityId;
  final String? actualQualityId;
  final CloudDriveQualitySwitchStage stage;
  final CloudDriveQualitySwitchResult result;

  /// Already redacted. Never contains a signed URL, cookie or file name.
  final String? reason;
  final String? errorType;
  final String? errorDetail;
  final bool retryable;
  final int elapsedMs;

  /// Stage -> milliseconds spent in that stage.
  final Map<String, int> phases;

  bool get committed => result == CloudDriveQualitySwitchResult.committed;
  bool get succeeded => result.isSuccess;

  /// A real failure that happened after the request was made.
  bool get showFailure => result == CloudDriveQualitySwitchResult.failed;

  /// The switch never started (still preparing) or the rung is not usable.
  bool get showInfo =>
      result == CloudDriveQualitySwitchResult.notReady ||
      result == CloudDriveQualitySwitchResult.unavailable;

  String? get message {
    switch (result) {
      case CloudDriveQualitySwitchResult.committed:
      case CloudDriveQualitySwitchResult.alreadySelected:
      case CloudDriveQualitySwitchResult.superseded:
        return null;
      case CloudDriveQualitySwitchResult.notReady:
        return reason ?? '播放器还在准备，请稍后再切换画质';
      case CloudDriveQualitySwitchResult.unavailable:
        return reason ?? '这个画质暂时不可用';
      case CloudDriveQualitySwitchResult.cancelled:
        return reason ?? '画质切换已取消，已继续播放当前画质';
      case CloudDriveQualitySwitchResult.failed:
        return reason ?? '画质切换失败，已继续播放当前画质';
    }
  }

  /// One-line, redacted diagnostic for the copy-diagnostics action.
  String toDiagnosticLine() {
    final parts = <String>[
      'quality=$operationId',
      'requested=$requestedQualityId',
      if (actualQualityId != null) 'actual=$actualQualityId',
      'stage=${stage.name}',
      'result=${result.name}',
      'ms=$elapsedMs',
      if (phases.isNotEmpty)
        'phases=${phases.entries.map((entry) => '${entry.key}:${entry.value}').join(',')}',
      if (errorType != null) 'error=$errorType',
      if (errorDetail != null) 'detail=$errorDetail',
      if (reason != null && reason!.isNotEmpty) 'reason=$reason',
      if (retryable) 'retryable=1',
    ];
    return parts.join(' ');
  }

  @override
  String toString() => toDiagnosticLine();
}

/// Keeps the message short and free of secrets before it reaches a log or UI.
String sanitizeCloudDriveQualityReason(Object? error, {int maxLength = 180}) {
  if (error == null) return '';
  final raw = error is CloudDriveFailure ? error.message : '$error';
  final cleaned = redactCloudDriveLog(
    raw,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.length <= maxLength) return cleaned;
  return '${cleaned.substring(0, maxLength)}…';
}
