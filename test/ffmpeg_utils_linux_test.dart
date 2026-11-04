import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player_app/utils/media_duration_probe.dart';

void main() {
  group('Linux FFmpeg integration', () {
    test('preferSystemFfmpeg is true on Linux', () {
      expect(FFmpegUtils.preferSystemFfmpeg, isTrue);
      expect(FFmpegUtils.useDesktopProcessFfmpeg, isTrue);
    });

    test('isAvailable reflects system ffmpeg', () async {
      FFmpegUtils.resetAvailabilityCache();
      final available = await FFmpegUtils.isAvailable;
      final which = await Process.run('which', ['ffmpeg']);
      expect(available, which.exitCode == 0);
    });

    test('ensureAvailable message when forcing failure is user-visible', () {
      expect(
        FFmpegUtils.missingBinaryUserMessage,
        contains('Linux 不使用 FFmpeg Kit'),
      );
    });

    test(
      'duration probe uses CLI and returns positive ms for sample',
      () async {
        final sample = File(
          '/workspace/Video-master-test/videos/en/big_buck_bunny.mp4',
        );
        if (!await sample.exists()) {
          return;
        }
        if (!await FFmpegUtils.isAvailable) {
          return;
        }
        final ms = await MediaDurationProbe.probeDurationMs(
          sample.path,
          allowVideoPlayerFallback: false,
        );
        expect(ms, greaterThan(0));
      },
    );
  }, skip: !Platform.isLinux);
}
