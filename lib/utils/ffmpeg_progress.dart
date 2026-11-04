Duration? parseFfmpegTimestamp(String value) {
  final match = RegExp(r'^(\d+):(\d+):(\d+(?:\.\d+)?)$').firstMatch(value);
  if (match == null) return null;
  return Duration(
    microseconds:
        ((int.parse(match[1]!) * 3600 +
                    int.parse(match[2]!) * 60 +
                    double.parse(match[3]!)) *
                1000000)
            .round(),
  );
}

/// FFmpeg reports output timestamps during stream copy as well as encoding.
/// Desktop progress output and FFmpegKit statistics share this calculation.
class FfmpegProgress {
  FfmpegProgress({required this.onProgress, Duration duration = Duration.zero})
    : _duration = duration;

  final void Function(double) onProgress;
  Duration _duration;
  Duration processed = Duration.zero;
  int _percent = -1;

  void update(Duration time) {
    if (time > processed) processed = time;
    if (_duration <= Duration.zero) return;
    final ratio = (processed.inMicroseconds / _duration.inMicroseconds).clamp(
      0.0,
      .99,
    );
    final percent = (ratio * 100).floor();
    if (percent == _percent) return;
    _percent = percent;
    onProgress(ratio);
  }

  void readLine(String line) {
    if (_duration <= Duration.zero) {
      final match = RegExp(
        r'Duration: (\d+:\d+:\d+(?:\.\d+)?)',
      ).firstMatch(line);
      if (match != null) {
        _duration = parseFfmpegTimestamp(match[1]!)!;
        update(processed);
      }
    }
    if (line.startsWith('out_time_us=')) {
      final time = int.tryParse(line.substring(12));
      if (time != null) update(Duration(microseconds: time));
    }
  }
}
