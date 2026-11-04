import 'dart:convert';

class BilibiliMediaProbeResult {
  const BilibiliMediaProbeResult({
    required this.duration,
    required this.hasVideo,
    required this.hasAudio,
    this.videoCodec,
  });

  final Duration duration;
  final bool hasVideo;
  final bool hasAudio;
  final String? videoCodec;

  static BilibiliMediaProbeResult? fromFfprobeJson(String output) {
    final decoded = jsonDecode(output);
    if (decoded is! Map) return null;

    final format = decoded['format'];
    final durationSeconds = format is Map
        ? double.tryParse(format['duration']?.toString() ?? '')
        : null;
    final streams = decoded['streams'];
    if (durationSeconds == null || durationSeconds <= 0 || streams is! List) {
      return null;
    }

    var hasVideo = false;
    var hasAudio = false;
    String? videoCodec;
    for (final stream in streams) {
      if (stream is! Map) continue;
      final type = stream['codec_type']?.toString();
      if (type == 'video') {
        hasVideo = true;
        videoCodec ??= stream['codec_name']?.toString();
      } else if (type == 'audio') {
        hasAudio = true;
      }
    }

    return BilibiliMediaProbeResult(
      duration: Duration(milliseconds: (durationSeconds * 1000).round()),
      hasVideo: hasVideo,
      hasAudio: hasAudio,
      videoCodec: videoCodec,
    );
  }

  /// Parses the media header printed by `ffmpeg -hide_banner -i <file>`.
  /// FFmpeg intentionally exits non-zero when no output is specified, but it
  /// has already read everything needed for this lightweight integrity check.
  static BilibiliMediaProbeResult? fromFfmpegHeader(String output) {
    final durationMatch = RegExp(
      r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)',
      caseSensitive: false,
    ).firstMatch(output);
    if (durationMatch == null) return null;

    final hours = int.tryParse(durationMatch.group(1)!);
    final minutes = int.tryParse(durationMatch.group(2)!);
    final seconds = double.tryParse(durationMatch.group(3)!);
    if (hours == null || minutes == null || seconds == null) return null;
    final durationMs = (((hours * 60 + minutes) * 60 + seconds) * 1000).round();
    if (durationMs <= 0) return null;

    final videoMatch = RegExp(
      r'^\s*Stream\s+#.*?:\s*Video:\s*([^,\s]+)',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(output);
    final hasAudio = RegExp(
      r'^\s*Stream\s+#.*?:\s*Audio:',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(output);

    return BilibiliMediaProbeResult(
      duration: Duration(milliseconds: durationMs),
      hasVideo: videoMatch != null,
      hasAudio: hasAudio,
      videoCodec: videoMatch?.group(1)?.toLowerCase(),
    );
  }
}
