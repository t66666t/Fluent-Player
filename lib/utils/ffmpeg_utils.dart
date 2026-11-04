import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves ffmpeg/ffprobe binaries for desktop Process invocations.
///
/// **Linux / Phase L2:** `ffmpeg_kit_flutter_new` is not used on Linux — the
/// desktop bundle typically lacks a working `libffmpegkit.so`, so Kit dlopen
/// fails at startup. All FFmpeg work on Linux must go through [ffmpegPath] /
/// [ffprobePath] (system PATH or bundled installers). Windows keeps its
/// bundled/PATH resolution; Android/iOS keep FFmpegKit at call sites.
class FFmpegUtils {
  static Future<String>? _ffmpegPathFuture;
  static Future<String>? _ffprobePathFuture;
  static Future<bool>? _availableFuture;

  /// User-visible message when system ffmpeg/ffprobe cannot be run.
  static const String missingBinaryUserMessage =
      '未找到可用的 ffmpeg/ffprobe。Linux 不使用 FFmpeg Kit；安装包请完整解压，源码运行请安装系统 ffmpeg 并确保在 PATH 中，然后重试。';

  /// Prefer Process + system/bundled binaries over FFmpegKit.
  /// True on Windows (existing) and Linux (Kit disabled — no reliable .so).
  static bool get preferSystemFfmpeg => Platform.isWindows || Platform.isLinux;

  /// Desktop compose / long-running Process path (Windows, macOS, Linux).
  static bool get useDesktopProcessFfmpeg =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<String> get ffmpegPath async {
    if (Platform.isLinux) {
      return _ffmpegPathFuture ??= _resolveLinuxBinary('ffmpeg');
    }
    if (!(Platform.isWindows || Platform.isMacOS)) {
      return 'ffmpeg';
    }
    return _ffmpegPathFuture ??= _resolveDesktopBinaryPath(
      fileName: Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg',
      pathFallback: 'ffmpeg',
    );
  }

  static Future<String> get ffprobePath async {
    if (Platform.isLinux) {
      return _ffprobePathFuture ??= _resolveLinuxBinary('ffprobe');
    }
    if (!(Platform.isWindows || Platform.isMacOS)) {
      return 'ffprobe';
    }
    return _ffprobePathFuture ??= _resolveDesktopBinaryPath(
      fileName: Platform.isWindows ? 'ffprobe.exe' : 'ffprobe',
      pathFallback: 'ffprobe',
    );
  }

  /// Returns whether `ffmpeg -version` succeeds for the resolved binary.
  static Future<bool> get isAvailable async {
    return _availableFuture ??= () async {
      final path = await ffmpegPath;
      final ok = await _isBinaryOperational(path);
      if (!ok) {
        developer.log(missingBinaryUserMessage, name: 'ffmpeg.utils');
      }
      return ok;
    }();
  }

  /// Throws [StateError] with [missingBinaryUserMessage] when unavailable.
  static Future<void> ensureAvailable() async {
    if (!await isAvailable) {
      throw StateError(missingBinaryUserMessage);
    }
  }

  /// Clears cached availability (e.g. after user installs ffmpeg).
  static void resetAvailabilityCache() {
    _availableFuture = null;
    _ffmpegPathFuture = null;
    _ffprobePathFuture = null;
  }

  static Future<String> _resolveLinuxBinary(String name) async {
    final bundled = p.join(
      File(Platform.resolvedExecutable).parent.path,
      'bin',
      name,
    );
    if (await File(bundled).exists() && await _isBinaryOperational(bundled)) {
      return bundled;
    }
    return name;
  }

  static Future<String> _resolveDesktopBinaryPath({
    required String fileName,
    required String pathFallback,
  }) async {
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    final bundledPath = p.join(exeDir, fileName);
    if (await File(bundledPath).exists() &&
        await _isBinaryOperational(bundledPath)) {
      return bundledPath;
    }

    if (await _isBinaryOperational(pathFallback)) {
      return pathFallback;
    }

    return pathFallback;
  }

  static Future<bool> _isBinaryOperational(String binaryPath) async {
    try {
      final result = await Process.run(binaryPath, const [
        '-version',
      ]).timeout(const Duration(seconds: 8));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
