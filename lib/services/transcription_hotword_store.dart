import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

@immutable
class TranscriptionHotwordPreset {
  const TranscriptionHotwordPreset({
    required this.id,
    required this.name,
    required this.words,
  });
  final String id, name, words;
  Map<String, String> toJson() => {'id': id, 'name': name, 'words': words};
}

/// Video drafts never become defaults. Only an explicit preset application
/// copies words to another video; saving a preset does not change any draft.
class TranscriptionHotwordStore extends ChangeNotifier {
  TranscriptionHotwordStore({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static const videosKey = 'transcription_video_hotwords_v1';
  static const presetsKey = 'transcription_hotword_presets_v1';
  final Future<SharedPreferences> Function() _preferences;
  Map<String, String> _videos = {};
  List<TranscriptionHotwordPreset> _presets = const [];
  List<TranscriptionHotwordPreset> get presets => _presets;
  String wordsFor(String mediaKey) => _videos[mediaKey] ?? '';
  bool loaded = false;
  String? loadError;
  bool _disposed = false;
  Future<void>? _loading;
  Future<void>? _writes;

  static String normalize(String words) {
    final lines = <String>{
      for (final line in words.replaceAll('\r\n', '\n').split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    };
    final result = lines.join('\n');
    if (lines.length > 100) throw const FormatException('最多输入 100 条热词');
    if (lines.any((line) => line.runes.length > 120)) {
      throw const FormatException('每条热词最多 120 个字');
    }
    if (result.length > 4000 || utf8.encode(result).length > 16000) {
      throw const FormatException('热词过长，请精简后保存');
    }
    return result;
  }

  static List<TranscriptionHotwordPreset> decodePresets(String? value) {
    if (value == null) return const [];
    final raw = jsonDecode(value);
    if (raw is! Map || raw['version'] != 1 || raw['presets'] is! List) {
      throw const FormatException('热词预设存储无效');
    }
    final ids = <String>{}, names = <String>{};
    return List.unmodifiable([
      for (final item in raw['presets'] as List)
        (() {
          if (item is! Map ||
              item['id'] is! String ||
              item['name'] is! String ||
              item['words'] is! String) {
            throw const FormatException('热词预设存储无效');
          }
          final id = item['id'] as String,
              name = (item['name'] as String).trim();
          final words = normalize(item['words'] as String);
          if (id.isEmpty ||
              name.isEmpty ||
              name.length > 40 ||
              words.isEmpty ||
              !ids.add(id) ||
              !names.add(name.toLowerCase())) {
            throw const FormatException('热词预设名称或内容无效');
          }
          return TranscriptionHotwordPreset(id: id, name: name, words: words);
        })(),
    ]);
  }

  static Map<String, String> _decodeVideos(String? value) {
    if (value == null) return {};
    final raw = jsonDecode(value);
    if (raw is! Map || raw['version'] != 1 || raw['videos'] is! Map) {
      throw const FormatException('视频热词存储无效');
    }
    final result = <String, String>{};
    for (final entry in (raw['videos'] as Map).entries) {
      if (entry.key is! String ||
          (entry.key as String).isEmpty ||
          entry.value is! String) {
        throw const FormatException('视频热词存储无效');
      }
      result[entry.key as String] = normalize(entry.value as String);
    }
    return result;
  }

  Future<void> load() {
    if (loaded) return Future.value();
    return _loading ??= Future<void>.microtask(() async {
      try {
        final prefs = await _preferences();
        final videos = _decodeVideos(prefs.getString(videosKey));
        final presets = decodePresets(prefs.getString(presetsKey));
        _videos = videos;
        _presets = presets;
        loaded = true;
        loadError = null;
      } catch (_) {
        loadError = '热词读取失败，原有内容已保留，请重试。';
        rethrow;
      } finally {
        _loading = null;
        _notify();
      }
    });
  }

  Future<void> _write(Future<void> Function(SharedPreferences) action) {
    final operation = (_writes ?? Future<void>.value()).then((_) async {
      await load();
      await action(await _preferences());
      _notify();
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> setWords(String mediaKey, String words) {
    if (mediaKey.isEmpty) throw ArgumentError.value(mediaKey);
    final normalized = normalize(words);
    return _write((prefs) async {
      final updated = _decodeVideos(prefs.getString(videosKey));
      if (normalized.isEmpty) {
        updated.remove(mediaKey);
      } else {
        updated[mediaKey] = normalized;
      }
      if (!await prefs.setString(
        videosKey,
        jsonEncode({'version': 1, 'videos': updated}),
      )) {
        throw StateError('视频热词未能保存，请重试');
      }
      _videos = updated;
    });
  }

  Future<void> savePreset({
    String? id,
    required String name,
    required String words,
  }) {
    final label = name.trim(), normalized = normalize(words);
    if (label.isEmpty || label.length > 40) {
      throw const FormatException('请输入 1–40 字的预设名称');
    }
    if (normalized.isEmpty) throw const FormatException('请先输入热词');
    return _write((prefs) async {
      final entries = decodePresets(prefs.getString(presetsKey)).toList();
      if (entries.any(
        (p) => p.id != id && p.name.toLowerCase() == label.toLowerCase(),
      )) {
        throw const FormatException('已有同名预设，请换个名称');
      }
      final preset = TranscriptionHotwordPreset(
        id: id ?? const Uuid().v4(),
        name: label,
        words: normalized,
      );
      final index = entries.indexWhere((p) => p.id == preset.id);
      if (index < 0) {
        entries.add(preset);
      } else {
        entries[index] = preset;
      }
      await _savePresets(prefs, entries);
    });
  }

  Future<void> deletePreset(String id) => _write((prefs) async {
    await _savePresets(
      prefs,
      decodePresets(
        prefs.getString(presetsKey),
      ).where((p) => p.id != id).toList(),
    );
  });

  Future<void> _savePresets(
    SharedPreferences prefs,
    List<TranscriptionHotwordPreset> entries, {
    bool legacyImported = false,
  }) async {
    final previous = jsonDecode(prefs.getString(presetsKey) ?? '{}') as Map;
    if (!await prefs.setString(
      presetsKey,
      jsonEncode({
        'version': 1,
        if (legacyImported || previous['legacyImported'] == true)
          'legacyImported': true,
        'presets': entries.map((e) => e.toJson()).toList(),
      }),
    )) {
      throw StateError('热词预设未能保存，请重试');
    }
    _presets = List.unmodifiable(entries);
  }

  /// Keep the old global list available for explicit reuse, never auto-apply it.
  Future<void> preserveLegacyWords(String words) async {
    final normalized = normalize(words);
    if (normalized.isEmpty) return;
    await _write((prefs) async {
      final previous = jsonDecode(prefs.getString(presetsKey) ?? '{}') as Map;
      if (previous['legacyImported'] == true) return;
      final entries = decodePresets(prefs.getString(presetsKey)).toList();
      if (!entries.any((p) => p.words == normalized)) {
        var name = '原有热词', suffix = 1;
        while (entries.any((p) => p.name == name)) {
          name = '原有热词 ${suffix++}';
        }
        entries.add(
          TranscriptionHotwordPreset(
            id: 'legacy-hotwords',
            name: name,
            words: normalized,
          ),
        );
      }
      await _savePresets(prefs, entries, legacyImported: true);
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
