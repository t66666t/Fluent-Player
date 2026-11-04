import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'portable_transfer_models.dart';

/// Last choices on the export settings page.
///
/// Fluent Pack and Zip do not share a form: sidecars and checksums only exist
/// for a pack, while subtitle embedding and danmaku only exist for a zip.
/// Each format therefore keeps its own blob so restoring one cannot reset the
/// other.
class PortableExportRememberedSettings {
  final PortableCompression compression;
  final bool wrapInFolder;
  final bool includeSidecars;
  final bool verifyChecksums;
  final bool zipEmbedSubtitles;
  final bool zipExternalSubtitles;
  final bool includeDanmaku;
  final bool includeBilibiliCache;

  const PortableExportRememberedSettings({
    this.compression = PortableCompression.fast,
    this.wrapInFolder = true,
    this.includeSidecars = true,
    this.verifyChecksums = true,
    this.zipEmbedSubtitles = true,
    this.zipExternalSubtitles = false,
    this.includeDanmaku = true,
    this.includeBilibiliCache = true,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'compression': compression.name,
    'wrapInFolder': wrapInFolder,
    'includeSidecars': includeSidecars,
    'verifyChecksums': verifyChecksums,
    'zipEmbedSubtitles': zipEmbedSubtitles,
    'zipExternalSubtitles': zipExternalSubtitles,
    'includeDanmaku': includeDanmaku,
    'includeBilibiliCache': includeBilibiliCache,
  };

  factory PortableExportRememberedSettings.fromJson(Map<String, dynamic> json) {
    return PortableExportRememberedSettings(
      compression: PortableCompression.values.firstWhere(
        (value) => value.name == json['compression'],
        orElse: () => PortableCompression.fast,
      ),
      // Missing keys keep the historical defaults. An explicit false must stay
      // false, which `!= false` does for the options that start enabled.
      wrapInFolder: json['wrapInFolder'] != false,
      includeSidecars: json['includeSidecars'] != false,
      verifyChecksums: json['verifyChecksums'] != false,
      zipEmbedSubtitles: json['zipEmbedSubtitles'] != false,
      zipExternalSubtitles: json['zipExternalSubtitles'] == true,
      includeDanmaku: json['includeDanmaku'] != false,
      includeBilibiliCache: json['includeBilibiliCache'] != false,
    );
  }
}

class PortableExportSettingsMemory {
  static const fluentPackKey = 'portable_export_settings.fluentPack';
  static const zipKey = 'portable_export_settings.zip';

  static String keyFor(PortableExportFormat format) =>
      format == PortableExportFormat.zip ? zipKey : fluentPackKey;

  static Future<PortableExportRememberedSettings> load(
    PortableExportFormat format,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyFor(format));
      if (raw == null || raw.isEmpty) {
        return const PortableExportRememberedSettings();
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const PortableExportRememberedSettings();
      return PortableExportRememberedSettings.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (error) {
      debugPrint('读取导出设置失败，改用默认值: $error');
      return const PortableExportRememberedSettings();
    }
  }

  static Future<void> save(
    PortableExportFormat format,
    PortableExportRememberedSettings settings,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyFor(format), jsonEncode(settings.toJson()));
    } catch (error) {
      debugPrint('保存导出设置失败: $error');
    }
  }
}
