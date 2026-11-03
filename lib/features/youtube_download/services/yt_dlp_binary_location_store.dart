import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum YtDlpBinarySource { managed, custom }

class YtDlpBinaryLocationSettings {
  final YtDlpBinarySource source;
  final String managedDirectory;
  final String customBinaryPath;

  const YtDlpBinaryLocationSettings({
    required this.source,
    required this.managedDirectory,
    required this.customBinaryPath,
  });

  YtDlpBinaryLocationSettings copyWith({
    YtDlpBinarySource? source,
    String? managedDirectory,
    String? customBinaryPath,
  }) {
    return YtDlpBinaryLocationSettings(
      source: source ?? this.source,
      managedDirectory: managedDirectory ?? this.managedDirectory,
      customBinaryPath: customBinaryPath ?? this.customBinaryPath,
    );
  }
}

class YtDlpBinaryLocationStore {
  static const String _sourceKey = 'yt_dlp_binary_source_v1';
  static const String _managedDirectoryKey = 'yt_dlp_managed_directory_v1';
  static const String _customBinaryPathKey = 'yt_dlp_custom_binary_path_v1';

  const YtDlpBinaryLocationStore._();

  static Future<Directory> defaultManagedDirectory() async {
    if (Platform.isWindows) {
      return Directory(
        p.join(File(Platform.resolvedExecutable).parent.path, 'yt_dlp'),
      );
    }
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(p.join(supportDirectory.path, 'yt_dlp'));
  }

  static Future<YtDlpBinaryLocationSettings> load() async {
    final defaultDirectory = await defaultManagedDirectory();
    try {
      final prefs = await SharedPreferences.getInstance();
      final sourceName = prefs.getString(_sourceKey);
      final source = sourceName == YtDlpBinarySource.custom.name
          ? YtDlpBinarySource.custom
          : YtDlpBinarySource.managed;
      final managedDirectory = _normalizedOrFallback(
        prefs.getString(_managedDirectoryKey),
        defaultDirectory.path,
      );
      final customBinaryPath = _normalizedOrFallback(
        prefs.getString(_customBinaryPathKey),
        '',
      );
      return YtDlpBinaryLocationSettings(
        source: source,
        managedDirectory: managedDirectory,
        customBinaryPath: customBinaryPath,
      );
    } catch (_) {
      return YtDlpBinaryLocationSettings(
        source: YtDlpBinarySource.managed,
        managedDirectory: defaultDirectory.path,
        customBinaryPath: '',
      );
    }
  }

  static Future<void> save(YtDlpBinaryLocationSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString(_sourceKey, settings.source.name),
      prefs.setString(
        _managedDirectoryKey,
        p.normalize(settings.managedDirectory.trim()),
      ),
      prefs.setString(
        _customBinaryPathKey,
        settings.customBinaryPath.trim().isEmpty
            ? ''
            : p.normalize(settings.customBinaryPath.trim()),
      ),
    ]);
  }

  static String _normalizedOrFallback(String? value, String fallback) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? fallback : p.normalize(trimmed);
  }
}
