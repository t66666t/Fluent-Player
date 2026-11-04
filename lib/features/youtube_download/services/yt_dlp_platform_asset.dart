import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_runtime_abi.dart';

enum YtDlpDesktopOs { windows, macos, linux, android, unsupported }

enum YtDlpLinuxLibc { glibc, musl }

class YtDlpPlatformAsset {
  final YtDlpDesktopOs operatingSystem;
  final YtDlpRuntimeArch architecture;
  final String releaseAssetName;
  final String installedFileName;
  final String? bundledAssetPath;

  const YtDlpPlatformAsset({
    required this.operatingSystem,
    required this.architecture,
    required this.releaseAssetName,
    required this.installedFileName,
    required this.bundledAssetPath,
  });

  bool get isAndroid => operatingSystem == YtDlpDesktopOs.android;

  static Future<YtDlpPlatformAsset?> current() async {
    if (kIsWeb) {
      return null;
    }
    final os = Platform.isWindows
        ? YtDlpDesktopOs.windows
        : Platform.isMacOS
        ? YtDlpDesktopOs.macos
        : Platform.isLinux
        ? YtDlpDesktopOs.linux
        : Platform.isAndroid
        ? YtDlpDesktopOs.android
        : YtDlpDesktopOs.unsupported;
    final libc = os == YtDlpDesktopOs.linux
        ? await _detectLinuxLibc()
        : YtDlpLinuxLibc.glibc;
    return forTarget(
      operatingSystem: os,
      architecture: currentYtDlpRuntimeArch(),
      linuxLibc: libc,
    );
  }

  static YtDlpPlatformAsset? forTarget({
    required YtDlpDesktopOs operatingSystem,
    required YtDlpRuntimeArch architecture,
    YtDlpLinuxLibc linuxLibc = YtDlpLinuxLibc.glibc,
  }) {
    switch (operatingSystem) {
      case YtDlpDesktopOs.windows:
        final names = switch (architecture) {
          YtDlpRuntimeArch.x64 => ('yt-dlp.exe', 'yt-dlp.exe'),
          YtDlpRuntimeArch.arm64 => ('yt-dlp_arm64.exe', 'yt-dlp_arm64.exe'),
          YtDlpRuntimeArch.x86 => ('yt-dlp_x86.exe', 'yt-dlp_x86.exe'),
          _ => null,
        };
        if (names == null) return null;
        return YtDlpPlatformAsset(
          operatingSystem: operatingSystem,
          architecture: architecture,
          releaseAssetName: names.$1,
          installedFileName: 'yt-dlp.exe',
          bundledAssetPath: 'assets/binaries/windows/${names.$2}',
        );
      case YtDlpDesktopOs.macos:
        if (architecture != YtDlpRuntimeArch.x64 &&
            architecture != YtDlpRuntimeArch.arm64) {
          return null;
        }
        return YtDlpPlatformAsset(
          operatingSystem: operatingSystem,
          architecture: architecture,
          releaseAssetName: 'yt-dlp_macos',
          installedFileName: 'yt-dlp',
          bundledAssetPath: 'assets/binaries/macos/yt-dlp',
        );
      case YtDlpDesktopOs.linux:
        final prefix = linuxLibc == YtDlpLinuxLibc.musl
            ? 'yt-dlp_musllinux'
            : 'yt-dlp_linux';
        final suffix = switch (architecture) {
          YtDlpRuntimeArch.x64 => '',
          YtDlpRuntimeArch.arm64 => '_aarch64',
          _ => null,
        };
        if (suffix == null) return null;
        final assetName = '$prefix$suffix';
        return YtDlpPlatformAsset(
          operatingSystem: operatingSystem,
          architecture: architecture,
          releaseAssetName: assetName,
          installedFileName: 'yt-dlp',
          bundledAssetPath: 'assets/binaries/linux/$assetName',
        );
      case YtDlpDesktopOs.android:
        return YtDlpPlatformAsset(
          operatingSystem: operatingSystem,
          architecture: architecture,
          releaseAssetName: 'yt-dlp',
          installedFileName: 'yt-dlp',
          bundledAssetPath: null,
        );
      case YtDlpDesktopOs.unsupported:
        return null;
    }
  }

  static Future<YtDlpLinuxLibc> _detectLinuxLibc() async {
    try {
      final result = await Process.run('ldd', const ['--version']);
      final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
      if (output.contains('musl')) {
        return YtDlpLinuxLibc.musl;
      }
    } catch (_) {
      // Most desktop distributions use glibc. The downloaded executable is
      // still verified by checksum and by running `--version` before use.
    }
    return YtDlpLinuxLibc.glibc;
  }
}
