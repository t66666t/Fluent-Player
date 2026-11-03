import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/ffmpeg_progress.dart';

void main() {
  test(
    'stream-copy timestamps report monotonic progress until final validation',
    () {
      final values = <double>[];
      final progress = FfmpegProgress(
        duration: const Duration(seconds: 100),
        onProgress: values.add,
      );
      for (final line in [
        'out_time_us=0',
        'out_time_us=25000000',
        'out_time_us=24000000',
        'out_time_us=25001000',
        'out_time_us=100000000',
        'progress=end',
      ]) {
        progress.readLine(line);
      }
      expect(values, [0, .25, .99]);
      expect(progress.processed, const Duration(seconds: 100));
    },
  );

  test(
    'unknown duration stays unknown until FFmpeg supplies input metadata',
    () {
      final values = <double>[];
      final progress = FfmpegProgress(onProgress: values.add);
      progress.readLine('frame=123');
      progress.readLine('out_time_us=30000000');
      expect(values, isEmpty);
      progress.readLine(
        '  Duration: 00:02:00.00, start: 0.000000, bitrate: 2000 kb/s',
      );
      expect(values, [.25]);
    },
  );

  test(
    'FFmpegKit milliseconds and desktop microseconds produce the same percentage',
    () {
      final desktop = <double>[], mobile = <double>[];
      final first = FfmpegProgress(
        duration: const Duration(seconds: 90),
        onProgress: desktop.add,
      );
      final second = FfmpegProgress(
        duration: const Duration(seconds: 90),
        onProgress: mobile.add,
      );
      for (final millis in [0, 1000, 45000, 90000]) {
        first.readLine('out_time_us=${millis * 1000}');
        second.update(Duration(milliseconds: millis));
      }
      expect(mobile, desktop);
      expect(mobile, [0, 1 / 90, .5, .99]);
    },
  );
}
