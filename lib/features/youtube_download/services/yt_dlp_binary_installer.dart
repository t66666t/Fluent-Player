// Community edition: executable downloader implementation removed.
import 'dart:io';

import 'package:video_player_app/features/youtube_download/services/yt_dlp_platform_asset.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_version.dart';

class YtDlpBinaryInstaller {
  static const String bundledSource = 'bundled';
  static const String officialReleaseSource = 'official-release';

  static Future<void> ensureInstalled() async {}

  static String get bundledYtDlpVersion {
    if (Platform.isAndroid) {
      return YtDlpVersions.androidBundled;
    }
    if (Platform.isMacOS) {
      return YtDlpVersions.macosBundled;
    }
    if (Platform.isLinux) {
      return YtDlpVersions.linuxBundled;
    }
    return YtDlpVersions.windowsBundled;
  }

  static Future<YtDlpPlatformAsset?> resolveCurrentPlatformAsset() async {
    return null;
  }

  static Future<String?> resolveManagedYtDlpPath() async {
    return null;
  }

  static Future<String?> resolveInstalledBinaryPath(String fileName) async {
    return null;
  }

  static Future<Directory> resolveInstallDirectory() async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  static Future<Directory> migrateInstallDirectory(String newPath) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  static Future<void> markBinaryAsManaged({
    required String fileName,
    required String versionStamp,
    required String source,
  }) async {}

  static Future<void> ensureExecutable(File file) async {}
}

class _BinaryAssetSpec {
  final String assetPath;
  final String outputFileName;
  final bool executable;
  final String versionStamp;

  const _BinaryAssetSpec({
    required this.assetPath,
    required this.outputFileName,
    required this.executable,
    required this.versionStamp,
  });

  bool get isYtDlp =>
      outputFileName == 'yt-dlp.exe' || outputFileName == 'yt-dlp';
}
