import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/ffmpeg_utils.dart';

import '../platform/local_playback_backend_policy.dart';

/// Creates a transparent playback copy for codecs which are not consistently
/// decoded by every video_player backend. The original library file is never
/// modified and the existing controller/UI remains in charge of playback.
class AudioPlaybackCompatibilityService {
  AudioPlaybackCompatibilityService._();

  static final Map<String, Future<File>> _inFlight = <String, Future<File>>{};
  static final Map<String, String> _probedSourceSignatures = <String, String>{};
  static final Map<String, String?> _probedAudioCodecs = <String, String?>{};
  static final Map<String, Future<String?>> _codecProbes =
      <String, Future<String?>>{};
  static const Set<String> _portableCodecs = <String>{'aac', 'mp3'};

  static Future<File> resolve(
    File source, {
    required bool isAudio,
    String? existingPlaybackPath,
    Directory? persistentDirectory,
  }) async {
    if (!isAudio || kIsWeb) return source;
    // Android local files normally stay on the platform backend. Probe audio
    // before controller creation and route only codecs that backend cannot
    // reliably decode to the already shipped media_kit/libmpv adapter. This
    // keeps ordinary local media and Bilibili behavior unchanged, avoids a
    // lossy/transcoding delay, and still exposes one VideoPlayerController to
    // the existing queue, notification and player screens.
    if (Platform.isAndroid) {
      if (LocalPlaybackBackendPolicy.isWideCodecBackendPreferred(source.path)) {
        return source;
      }
      final stat = await source.stat();
      final signature = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
      if (_probedSourceSignatures[source.path] == signature) return source;

      final codec = await probeAudioCodec(source.path);
      if (LocalPlaybackBackendPolicy.codecNeedsWideCodecBackend(codec)) {
        LocalPlaybackBackendPolicy.preferProbedWideCodecBackend(source.path);
      } else if (codec != null) {
        LocalPlaybackBackendPolicy.preferPlatformBackend(source.path);
      }
      _probedSourceSignatures[source.path] = signature;
      return source;
    }
    // Other native targets already use media_kit for local files.
    if (supportsDirectNativePlayback) return source;
    if (existingPlaybackPath != null) {
      final existing = File(existingPlaybackPath);
      if (await existing.exists() && await existing.length() > 0) {
        return existing;
      }
    }
    final codec = await probeAudioCodec(source.path);
    if (!needsCompatibilityCopy(codec)) return source;
    final future = _inFlight.putIfAbsent(
      source.path,
      () => _createAacCopy(source, persistentDirectory: persistentDirectory),
    );
    try {
      return await future;
    } finally {
      if (identical(_inFlight[source.path], future)) {
        _inFlight.remove(source.path);
      }
    }
  }

  @visibleForTesting
  static bool needsCompatibilityCopy(String? codec) =>
      codec != null && !_portableCodecs.contains(codec.toLowerCase());

  /// Kept explicit so tests document why compatibility copies are bypassed.
  /// Web does not use local [File] playback and is handled before this check.
  @visibleForTesting
  static bool get supportsDirectNativePlayback =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux;

  /// Returns a cached codec immediately when this source has already been
  /// inspected. A null value is intentionally ambiguous; callers which need a
  /// definitive answer should use [probeAudioCodec].
  static String? cachedAudioCodec(String path) => _probedAudioCodecs[path];

  /// Probes and caches the first audio stream codec without changing or
  /// materializing the source file.
  static Future<String?> probeAudioCodec(String path) {
    if (_probedAudioCodecs.containsKey(path)) {
      return Future<String?>.value(_probedAudioCodecs[path]);
    }
    return _codecProbes.putIfAbsent(path, () async {
      final codec = await _probeAudioCodec(path);
      _probedAudioCodecs[path] = codec;
      _codecProbes.remove(path);
      return codec;
    });
  }

  static Future<String?> _probeAudioCodec(String path) async {
    try {
      if (FFmpegUtils.preferSystemFfmpeg) {
        final ffprobePath = await FFmpegUtils.ffprobePath;
        final result = await Process.run(ffprobePath, <String>[
          '-v',
          'error',
          '-select_streams',
          'a:0',
          '-show_entries',
          'stream=codec_name',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          path,
        ]).timeout(const Duration(seconds: 12));
        if (result.exitCode != 0) return null;
        final codec = result.stdout.toString().trim().toLowerCase();
        return codec.isEmpty ? null : codec;
      }
      final session = await FFprobeKit.getMediaInformation(
        path,
      ).timeout(const Duration(seconds: 12));
      final information = session.getMediaInformation();
      if (information == null) return null;
      for (final stream in information.getStreams()) {
        if (stream.getType() == 'audio') {
          return stream.getCodec()?.toLowerCase();
        }
      }
    } catch (error) {
      debugPrint('Audio compatibility probe failed: $error');
    }
    return null;
  }

  static Future<File> _createAacCopy(
    File source, {
    Directory? persistentDirectory,
  }) async {
    final stat = await source.stat();
    final directory =
        persistentDirectory ??
        Directory(
          p.join(
            (await getApplicationDocumentsDirectory()).path,
            'playback_audio_compat',
          ),
        );
    await directory.create(recursive: true);
    final key = sha256
        .convert(
          '${source.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}'
              .codeUnits,
        )
        .toString();
    final output = File(p.join(directory.path, '$key.m4a'));
    if (await output.exists() && await output.length() > 0) return output;

    final partial = File('${output.path}.partial.m4a');
    if (await partial.exists()) await partial.delete();
    if (FFmpegUtils.preferSystemFfmpeg) {
      await FFmpegUtils.ensureAvailable();
      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      final result = await Process.run(ffmpegPath, <String>[
        '-y',
        '-i',
        source.path,
        '-map',
        '0:a:0',
        '-vn',
        '-c:a',
        'aac',
        '-b:a',
        '256k',
        '-movflags',
        '+faststart',
        partial.path,
      ]).timeout(const Duration(minutes: 5));
      if (result.exitCode != 0 || !await partial.exists()) {
        throw StateError(
          'Unable to prepare compatible audio: ${result.stderr}',
        );
      }
    } else {
      final session = await FFmpegKit.executeWithArguments(<String>[
        '-y',
        '-i',
        source.path,
        '-map',
        '0:a:0',
        '-vn',
        '-c:a',
        'aac',
        '-b:a',
        '256k',
        '-movflags',
        '+faststart',
        partial.path,
      ]).timeout(const Duration(minutes: 5));
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) || !await partial.exists()) {
        final logs = await session.getAllLogsAsString();
        throw StateError('Unable to prepare compatible audio: $logs');
      }
    }
    await partial.rename(output.path);
    return output;
  }
}
