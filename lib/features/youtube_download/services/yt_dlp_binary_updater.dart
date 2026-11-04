// Community edition: executable downloader implementation removed.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_runtime_abi.dart';

class YtDlpBinaryReleaseInfo {
  final String version;
  final String assetName;
  final String downloadUrl;
  final String releasePageUrl;
  final String? checksumUrl;

  const YtDlpBinaryReleaseInfo({
    required this.version,
    required this.assetName,
    required this.downloadUrl,
    required this.releasePageUrl,
    this.checksumUrl,
  });
}

enum YtDlpBinaryUpdateStatus { updated, alreadyUpToDate }

class YtDlpBinaryUpdateResult {
  final YtDlpBinaryUpdateStatus status;
  final String previousVersion;
  final String currentVersion;
  final YtDlpBinaryReleaseInfo release;

  const YtDlpBinaryUpdateResult({
    required this.status,
    required this.previousVersion,
    required this.currentVersion,
    required this.release,
  });
}

class YtDlpBinaryUpdater {
  const YtDlpBinaryUpdater();

  static int compareVersions(String left, String right) {
    return 0;
  }

  static bool get supportsOnlineUpdate =>
      !kIsWeb &&
      (Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isAndroid ||
          (Platform.isLinux &&
              (currentYtDlpRuntimeArch() == YtDlpRuntimeArch.x64 ||
                  currentYtDlpRuntimeArch() == YtDlpRuntimeArch.arm64)));

  static bool get supportsLatestReleaseCheck =>
      !kIsWeb &&
      (Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux ||
          Platform.isAndroid);

  Future<YtDlpBinaryReleaseInfo> fetchLatestRelease() async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<YtDlpBinaryUpdateResult> updateToLatest({
    required String? currentVersion,
    void Function(double progress)? onProgress,
    Future<String?> Function(String binaryPath)? validateBinary,
  }) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }
}
