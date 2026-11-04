import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/subtitle_debug_preset.dart';

/// Global subtitle mode; the historical name is retained for integrations.
class SubtitleDebugSession extends ChangeNotifier {
  static const available = true;
  static const storageKey = 'globalSubtitlePresetMode.v1';
  static final instance = SubtitleDebugSession();
  SharedPreferences? _prefs;
  Future<void> _writes = Future<void>.value();
  bool _initialized = false;
  int _revision = 0;
  bool _enabled = false;
  bool _catalogVisible = true;
  String? _selectedId;
  final Map<String, SubtitleDebugPreset> _custom = {};
  // Kept outside preset snapshots: exports only use the ordinary textScale.
  final Map<String, double> _ghostTextScales = {
    for (final p in subtitleDebugPresets) p.id: p.textScale,
  };
  String? saveError;
  // Retain navigation while the sidebar is closed.
  String browserCategory = '全部';
  String browserQuery = '';
  double browserOffset = 0;

  bool get enabled => _enabled;
  bool get catalogVisible => _enabled && _catalogVisible;
  SubtitleDebugPreset? get preset => presetForMode();
  SubtitleDebugPreset? presetForMode({bool ghost = false}) =>
      _enabled && _selectedId != null
      ? resolvedForDisplay(_selectedId!, ghost: ghost)
      : null;
  bool get usesPresets => preset != null;
  SubtitleDebugPreset resolved(String id) =>
      _custom[id] ?? subtitleDebugPresets.firstWhere((p) => p.id == id);

  double ghostTextScale(String id) => _ghostTextScales[id]!;

  SubtitleDebugPreset resolvedForDisplay(String id, {bool ghost = false}) {
    final p = resolved(id);
    return ghost ? p.copyWith(textScale: ghostTextScale(id)) : p;
  }

  Future<void> initialize([SharedPreferences? preferences]) async {
    if (_initialized) return;
    final revision = _revision;
    _prefs = preferences ?? await SharedPreferences.getInstance();
    _initialized = true;
    if (_revision != revision) return;
    try {
      final raw = _prefs!.getString(storageKey);
      if (raw == null) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      _enabled = data['enabled'] == true;
      _catalogVisible = data['catalogVisible'] != false;
      final id = data['selectedId'];
      _selectedId = subtitleDebugPresets.any((p) => p.id == id)
          ? id as String
          : null;
      final custom = data['custom'];
      if (custom is Map) {
        for (final value in custom.values) {
          final p = SubtitleDebugPreset.restore(value);
          if (p != null) _custom[p.id] = p;
        }
      }
      final ghostScales = data['ghostTextScales'];
      bool migrated = false;
      for (final base in subtitleDebugPresets) {
        final value = ghostScales is Map ? ghostScales[base.id] : null;
        if (value is num && value.isFinite) {
          _ghostTextScales[base.id] = value.toDouble().clamp(.6, 1.8);
        } else {
          // Snapshot the old shared value once, before either mode is edited.
          _ghostTextScales[base.id] = resolved(base.id).textScale;
          migrated = true;
        }
      }
      if (migrated) {
        await _commit();
      } else {
        notifyListeners();
      }
    } catch (_) {
      _enabled = false;
      _selectedId = null;
      _custom.clear();
    }
  }

  Future<void> _commit() {
    _revision++;
    final snapshot = jsonEncode({
      'enabled': _enabled,
      'catalogVisible': _catalogVisible,
      'selectedId': _selectedId,
      'custom': _custom.map((id, p) => MapEntry(id, p.toJson())),
      'ghostTextScales': Map<String, double>.of(_ghostTextScales),
    });
    notifyListeners();
    _writes = _writes.then((_) async {
      try {
        _prefs ??= await SharedPreferences.getInstance();
        if (!await _prefs!.setString(storageKey, snapshot)) {
          throw StateError('save failed');
        }
        if (saveError != null) {
          saveError = null;
          notifyListeners();
        }
      } catch (_) {
        saveError = '字幕设置未能保存，请重试';
        notifyListeners();
      }
    });
    return _writes;
  }

  Future<void> toggle() {
    _enabled = !_enabled;
    if (_enabled) _catalogVisible = true;
    return _commit();
  }

  Future<void> select(SubtitleDebugPreset? preset) {
    if (!_enabled) return Future<void>.value();
    _selectedId = preset?.id;
    return _commit();
  }

  Future<void> useOriginal() {
    _selectedId = null;
    _catalogVisible = false;
    return _commit();
  }

  Future<void> openCatalog() {
    _catalogVisible = true;
    return _commit();
  }

  Future<void> updatePreset(SubtitleDebugPreset preset) {
    _custom[preset.id] = preset;
    return _commit();
  }

  Future<void> updateGhostTextScale(String id, double value) {
    if (!value.isFinite || !_ghostTextScales.containsKey(id)) {
      throw ArgumentError('Invalid ghost subtitle preset scale');
    }
    _ghostTextScales[id] = value.clamp(.6, 1.8);
    return _commit();
  }

  Future<void> resetPreset(String id) {
    _custom.remove(id);
    _ghostTextScales[id] = resolved(id).textScale;
    return _commit();
  }

  Future<void> close() {
    _enabled = false;
    return _commit();
  }

  /// Includes inactive presets and both independent scales. A compose-job
  /// preset snapshot intentionally omits ghost sizing; a settings export must
  /// retain it even when the ordinary mode or another preset is selected.
  Map<String, dynamic> exportSettingsSnapshot({bool includeCatalog = true}) => {
    'version': 1,
    'enabled': _enabled,
    'catalogVisible': _catalogVisible,
    'selectedId': _selectedId,
    'custom': _custom.map((id, preset) => MapEntry(id, preset.toJson())),
    if (includeCatalog)
      'presets': {
        for (final base in subtitleDebugPresets)
          base.id: resolved(base.id).toJson(),
      },
    'ghostTextScales': Map<String, double>.of(_ghostTextScales),
  };

  Future<void> flush() => _writes;

  /// The caller has already durably written and verified this snapshot. Drain
  /// [flush] first so an older queued preset save cannot undo a restoration.
  void applySettingsSnapshot(Map<String, dynamic> data) {
    final id = data['selectedId'];
    final custom = <String, SubtitleDebugPreset>{};
    for (final value in (data['custom'] as Map? ?? {}).values) {
      final preset = SubtitleDebugPreset.restore(value);
      if (preset != null) custom[preset.id] = preset;
    }
    final scales = data['ghostTextScales'] as Map? ?? {};
    final ghost = <String, double>{
      for (final base in subtitleDebugPresets)
        base.id: scales[base.id] is num && (scales[base.id] as num).isFinite
            ? (scales[base.id] as num).toDouble().clamp(.6, 1.8)
            : (custom[base.id] ?? base).textScale,
    };
    _revision++;
    _enabled = data['enabled'] == true;
    _catalogVisible = data['catalogVisible'] != false;
    _selectedId = subtitleDebugPresets.any((preset) => preset.id == id)
        ? id as String
        : null;
    _custom
      ..clear()
      ..addAll(custom);
    _ghostTextScales
      ..clear()
      ..addAll(ghost);
    saveError = null;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    browserCategory = '全部';
    browserQuery = '';
    browserOffset = 0;
    _writes = Future<void>.value();
    _prefs = null;
    _initialized = false;
    _revision++;
    _enabled = false;
    _catalogVisible = true;
    _selectedId = null;
    _custom.clear();
    _ghostTextScales
      ..clear()
      ..addEntries(
        subtitleDebugPresets.map((p) => MapEntry(p.id, p.textScale)),
      );
    saveError = null;
  }
}
