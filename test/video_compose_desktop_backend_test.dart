import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'video compose probing resolves Windows/Linux binaries and keeps Apple Kit',
    () {
      final source = File(
        'lib/services/video_compose/video_compose_probe_service.dart',
      ).readAsStringSync();

      expect(source, contains('FFprobeKit.getMediaInformation'));
      expect(source, contains('FFmpegUtils.preferSystemFfmpeg'));
      final resolver = File('lib/utils/ffmpeg_utils.dart').readAsStringSync();
      expect(resolver, contains('Platform.isWindows || Platform.isLinux'));
      expect(source, contains('FFmpegUtils.ffprobePath'));
      expect(source, isNot(contains('runInShell: true')));
    },
  );

  test('desktop video compose starts the resolved FFmpeg directly', () {
    final executor = File(
      'lib/services/video_compose/video_compose_executor.dart',
    ).readAsStringSync();
    final resolver = File('lib/utils/ffmpeg_utils.dart').readAsStringSync();

    expect(executor, contains('runInShell: false'));
    expect(executor, contains('FFmpegUtils.useDesktopProcessFfmpeg'));
    expect(resolver, contains('Platform.isWindows || Platform.isMacOS'));
    expect(resolver, contains('_resolveDesktopBinaryPath'));
    expect(resolver, contains('preferSystemFfmpeg'));
  });
}
