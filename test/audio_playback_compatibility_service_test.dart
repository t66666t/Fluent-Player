import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/audio_playback_compatibility_service.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/local_playback_backend_policy.dart';

void main() {
  test('native builds use the wide-codec backend without transcoding', () {
    expect(
      AudioPlaybackCompatibilityService.supportsDirectNativePlayback,
      isTrue,
    );
  });

  test('WAV resolves to the original file without a lossy AAC copy', () async {
    final directory = await Directory.systemTemp.createTemp(
      'fluent_player_wav_test_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}tone.wav');
    await source.writeAsBytes(<int>[0x52, 0x49, 0x46, 0x46]);

    final resolved = await AudioPlaybackCompatibilityService.resolve(
      source,
      isAudio: true,
      existingPlaybackPath: '${directory.path}/old-lossy-copy.m4a',
    );

    expect(resolved.path, source.path);
  });

  test('library accepts common wide-codec audio and video containers', () {
    for (final path in <String>[
      'pcm.wav',
      'lossless.flac',
      'voice.opus',
      'archive.ape',
      'surround.dts',
      'disc.dsf',
      'movie.mkv',
      'camera.mxf',
      'legacy.rmvb',
    ]) {
      expect(LibraryService.isSupportedMediaPath(path), isTrue, reason: path);
    }
  });

  test('portable codecs do not need a compatibility copy', () {
    expect(
      AudioPlaybackCompatibilityService.needsCompatibilityCopy('aac'),
      isFalse,
    );
    expect(
      AudioPlaybackCompatibilityService.needsCompatibilityCopy('MP3'),
      isFalse,
    );
  });

  test('ALAC and other non-portable codecs need a compatibility copy', () {
    expect(
      AudioPlaybackCompatibilityService.needsCompatibilityCopy('alac'),
      isTrue,
    );
    expect(
      AudioPlaybackCompatibilityService.needsCompatibilityCopy('flac'),
      isTrue,
    );
  });

  test('wide-codec routing distinguishes ALAC from AAC in M4A', () {
    expect(
      LocalPlaybackBackendPolicy.codecNeedsWideCodecBackend('alac'),
      isTrue,
    );
    expect(
      LocalPlaybackBackendPolicy.codecNeedsWideCodecBackend('flac'),
      isFalse,
    );
    expect(
      LocalPlaybackBackendPolicy.codecNeedsWideCodecBackend('aac'),
      isFalse,
    );
    expect(
      LocalPlaybackBackendPolicy.codecNeedsWideCodecBackend('mp3'),
      isFalse,
    );
    expect(
      LocalPlaybackBackendPolicy.codecNeedsWideCodecBackend('pcm_s24le'),
      isFalse,
    );
  });

  test('persistent playback path survives library serialization', () {
    final item = VideoItem(
      id: 'audio-1',
      path: '/original/track.m4a',
      playbackPath: '/library/compatible_audio/track.m4a',
      title: 'Track',
      durationMs: 1000,
      lastUpdated: 1,
      type: MediaType.audio,
    );

    final restored = VideoItem.fromJson(item.toJson());
    expect(restored.path, '/original/track.m4a');
    expect(restored.playbackPath, '/library/compatible_audio/track.m4a');
  });
}
