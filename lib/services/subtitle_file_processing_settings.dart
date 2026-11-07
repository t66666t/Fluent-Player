import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'subtitle_optimization.dart';

/// File processing remembers its stages independently of transcription.
class SubtitleFileProcessingSettings {
  const SubtitleFileProcessingSettings({
    this.optimize = false,
    this.translate = true,
  });

  static const preferencesKey = 'subtitle_file_processing_v1';
  static Future<void> _pending = Future<void>.value();
  final bool optimize, translate;
  bool get hasWork => optimize || translate;

  SubtitleFileProcessingSettings copyWith({bool? optimize, bool? translate}) =>
      SubtitleFileProcessingSettings(
        optimize: optimize ?? this.optimize,
        translate: translate ?? this.translate,
      );

  Map<String, bool> toJson() => {'optimize': optimize, 'translate': translate};

  static Future<T> _ordered<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static Future<SubtitleFileProcessingSettings> _read(
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString(preferencesKey);
    if (raw != null) {
      final value = jsonDecode(raw) as Map;
      return SubtitleFileProcessingSettings(
        optimize: value['optimize'] == true,
        translate: value['translate'] != false,
      );
    }
    // Capture the existing optimization preference once. Later changes in
    // transcription must never silently change a file-processing switch.
    final legacy = await SubtitleOptimizationSettings.load();
    final value = SubtitleFileProcessingSettings(optimize: legacy.enabled);
    await _write(prefs, value);
    return value;
  }

  static Future<void> _write(
    SharedPreferences prefs,
    SubtitleFileProcessingSettings value,
  ) async {
    if (!await prefs.setString(preferencesKey, jsonEncode(value.toJson()))) {
      throw StateError('字幕处理偏好未能保存');
    }
  }

  static Future<SubtitleFileProcessingSettings> load() =>
      _ordered(() async => _read(await SharedPreferences.getInstance()));

  /// Merge just the explicit edit, so rapid toggles and overlapping views do
  /// not overwrite the other stage or race a page being reopened.
  static Future<SubtitleFileProcessingSettings> update({
    bool? optimize,
    bool? translate,
  }) => _ordered(() async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _read(prefs);
    final next = current.copyWith(optimize: optimize, translate: translate);
    await _write(prefs, next);
    return next;
  });
}
