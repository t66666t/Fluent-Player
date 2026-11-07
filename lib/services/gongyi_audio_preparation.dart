import 'package:path/path.dart' as p;

import 'gongyi_asr_service.dart';

enum GongyiAudioPreparation { direct, copy, transcode }

/// Chooses a fast path only for formats exercised against the upload service.
/// The byte budget is an application policy, not a claimed server limit.
class GongyiAudioPreparationPlan {
  static const maximumFastAudioBytes = 32 * 1024 * 1024;

  static GongyiAudioPreparation choose({
    required String path,
    required String? codec,
    required double? durationSeconds,
    required double sliceSeconds,
    required bool wholeFile,
    required bool isAudioInput,
    required int fileBytes,
    int? audioBitRate,
    int audioStreams = 1,
    bool hasVideo = false,
    bool preferMp3 = false,
  }) {
    if (preferMp3 && codec != 'mp3') {
      return GongyiAudioPreparation.transcode;
    }
    if (durationSeconds == null ||
        !durationSeconds.isFinite ||
        durationSeconds <= 0 ||
        !sliceSeconds.isFinite ||
        sliceSeconds <= 0 ||
        (codec != 'aac' && codec != 'mp3')) {
      return GongyiAudioPreparation.transcode;
    }
    final extension = p.extension(path).toLowerCase();
    final directlyReadable =
        codec == 'aac' && extension == '.m4a' ||
        codec == 'mp3' && extension == '.mp3';
    if (wholeFile &&
        isAudioInput &&
        !hasVideo &&
        audioStreams == 1 &&
        directlyReadable &&
        fileBytes > 0 &&
        fileBytes <= maximumFastAudioBytes) {
      return GongyiAudioPreparation.direct;
    }

    // Prefer the selected audio stream's rate: the video's size/rate includes
    // pictures and must never determine whether its audio needs compression.
    final double? estimatedBytes;
    if (audioBitRate != null && audioBitRate > 0) {
      estimatedBytes = audioBitRate / 8 * sliceSeconds;
    } else if (isAudioInput && fileBytes > 0 && !hasVideo) {
      estimatedBytes = fileBytes * (sliceSeconds / durationSeconds);
    } else {
      estimatedBytes = null;
    }
    // Leave room for container overhead; the actual copy is checked as well.
    if (estimatedBytes != null &&
        estimatedBytes * 1.05 + 65536 <= maximumFastAudioBytes) {
      return GongyiAudioPreparation.copy;
    }
    return GongyiAudioPreparation.transcode;
  }

  static bool shouldNormalizeAfter(
    GongyiAsrException error, {
    required bool taskPending,
  }) {
    if (taskPending || error.queryRetryExhausted) return false;
    if (error.kind == GongyiAsrFailureKind.tooLong) {
      // Conversion cannot shorten a recording. Keep the existing adaptive
      // splitting path when the server explicitly identifies duration.
      return !RegExp(
        r'时长|过长|太长|duration|too long|length',
        caseSensitive: false,
      ).hasMatch(error.serverMessage ?? error.message);
    }
    if (error.kind != GongyiAsrFailureKind.rejected) return false;
    // An explicit terminal rejection is safe to replace. Network errors,
    // access restrictions and uncertain submissions keep their original task.
    if (error.taskFinished) return true;
    return RegExp(
      r'解码|编码|音频格式|文件格式|不支持.*音频|codec|decode|unsupported.*(audio|format)',
      caseSensitive: false,
    ).hasMatch(error.serverMessage ?? error.message);
  }
}
