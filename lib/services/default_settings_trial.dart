import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class TrialPreferenceBackend {
  Future<void> refresh();
  String? read(String key);
  Future<bool> write(String key, String value);
  Future<bool> remove(String key);
}

class SharedPreferencesTrialBackend implements TrialPreferenceBackend {
  SharedPreferencesTrialBackend(this.preferences);
  final SharedPreferences preferences;
  @override
  Future<void> refresh() => preferences.reload();
  @override
  String? read(String key) {
    final value = preferences.get(key);
    // A malformed non-string record still counts as an existing backup. Keep
    // the recovery entry visible and refuse to overwrite it with a new trial.
    return value == null
        ? null
        : value is String
        ? value
        : jsonEncode(value);
  }

  @override
  Future<bool> write(String key, String value) =>
      preferences.setString(key, value);
  @override
  Future<bool> remove(String key) => preferences.remove(key);
}

class TrialBackup {
  const TrialBackup(this.value, this.digest, this.phase);
  final Map<String, dynamic> value;
  final String digest;
  final String? phase;
}

/// Two verified, immutable copies of the ORIGINAL settings. Phase changes are
/// a separate record and cannot overwrite either backup with trial edits.
class DefaultSettingsTrialJournal {
  DefaultSettingsTrialJournal(this.backend);
  final Future<TrialPreferenceBackend> Function() backend;
  static const originalKey = 'defaultSettingsTrial.original.v1';
  static const recoveryKey = 'defaultSettingsTrial.recovery.v1';
  static const phaseKey = 'defaultSettingsTrial.phase.v1';
  static const storageKeys = {originalKey, recoveryKey, phaseKey};

  Future<bool> get hasRecords async {
    final store = await backend();
    await store.refresh();
    return storageKeys.any((key) => store.read(key) != null);
  }

  Future<void> _write(
    TrialPreferenceBackend store,
    String key,
    String value,
  ) async {
    if (!await store.write(key, value) || store.read(key) != value) {
      throw StateError('原设置备份或切换状态未能安全保存，请重试');
    }
  }

  Future<TrialBackup> saveOriginal(Map<String, dynamic> original) async {
    final store = await backend();
    await store.refresh();
    if (storageKeys.any((key) => store.read(key) != null)) {
      throw StateError('原设置备份尚未恢复，不能覆盖备份');
    }
    final payload = jsonEncode(original);
    final digest = sha256.convert(utf8.encode(payload)).toString();
    final envelope = jsonEncode({
      'version': 1,
      'payload': payload,
      'sha256': digest,
    });
    await _write(store, originalKey, envelope);
    await _write(store, recoveryKey, envelope);
    return TrialBackup(
      Map<String, dynamic>.from(jsonDecode(payload) as Map),
      digest,
      null,
    );
  }

  Future<TrialBackup?> read() async {
    final store = await backend();
    await store.refresh();
    final candidates = <TrialBackup>[];
    String? phase, phaseDigest;
    try {
      final value = jsonDecode(store.read(phaseKey) ?? '{}') as Map;
      if (value['version'] == 1) {
        phase = value['phase'] as String?;
        phaseDigest = value['sha256'] as String?;
      }
    } catch (_) {
      // Missing/damaged phase is an interrupted transition, never a new trial.
    }
    for (final key in [originalKey, recoveryKey]) {
      final raw = store.read(key);
      if (raw == null) continue;
      try {
        final envelope = jsonDecode(raw) as Map;
        if (envelope['version'] != 1) continue;
        final payload = envelope['payload'] as String;
        final digest = sha256.convert(utf8.encode(payload)).toString();
        if (digest != envelope['sha256']) continue;
        candidates.add(
          TrialBackup(
            Map<String, dynamic>.from(jsonDecode(payload) as Map),
            digest,
            phaseDigest == digest ? phase : null,
          ),
        );
      } catch (_) {
        // The other immutable copy can recover a damaged primary.
      }
    }
    if (candidates.isNotEmpty) {
      return candidates.firstWhere(
        (record) => record.digest == phaseDigest,
        orElse: () => candidates.first,
      );
    }
    if (storageKeys.any((key) => store.read(key) != null)) {
      throw const FormatException('原设置备份暂时无法校验，已保留全部备份，请勿清理应用数据');
    }
    return null;
  }

  Future<void> setPhase(TrialBackup original, String phase) async {
    await _write(
      await backend(),
      phaseKey,
      jsonEncode({'version': 1, 'phase': phase, 'sha256': original.digest}),
    );
  }

  /// Called only AFTER every original preference was restored and verified.
  /// A crash while deleting copies can only cause an idempotent restore.
  Future<void> clearAfterRestore() async {
    final store = await backend();
    await store.refresh();
    for (final key in [phaseKey, originalKey, recoveryKey]) {
      if (store.read(key) == null) continue;
      if (!await store.remove(key) || store.read(key) != null) {
        throw StateError('原设置已恢复，备份清理尚未完成；可再次点击恢复');
      }
    }
  }
}

enum DefaultSettingsTrialResult { activated, restored }

class DefaultSettingsTrial extends ChangeNotifier {
  DefaultSettingsTrial({
    required this.journal,
    required this.captureOriginal,
    required this.applyRecommended,
    required this.restoreOriginal,
    this.onReadBackup,
  });
  final DefaultSettingsTrialJournal journal;
  final Future<Map<String, dynamic>> Function() captureOriginal;
  final Future<void> Function() applyRecommended;
  final Future<void> Function(Map<String, dynamic>) restoreOriginal;
  final void Function(Map<String, dynamic>)? onReadBackup;
  Future<void>? _initialization;
  bool _hasBackup = false;
  bool _busy = false;
  String? error;
  bool get hasBackup => _hasBackup;
  bool get busy => _busy;
  String get label => busy
      ? '正在切换…'
      : hasBackup
      ? '恢复原有设置'
      : '测试默认设置';

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      _hasBackup = await journal.hasRecords;
      final original = await journal.read();
      if (original != null) onReadBackup?.call(original.value);
      if (original == null || original.phase == 'active') return;
      // Applying/restoring/missing phase means a previous process stopped in
      // the middle. Recover before SettingsService loads its fields.
      _busy = true;
      await _restore(original);
    } catch (failure) {
      // A read error must never hide the recovery action or permit another
      // trial to replace originals whose storage is temporarily unavailable.
      _hasBackup = true;
      error = '$failure';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<DefaultSettingsTrialResult?> toggle() async {
    if (_busy) return null;
    await initialize();
    if (_busy) return null;
    _busy = true;
    error = null;
    notifyListeners();
    try {
      if (_hasBackup) {
        final original = await journal.read();
        if (original == null) throw StateError('找不到原设置备份，未启动新的测试');
        await _restore(original);
        return DefaultSettingsTrialResult.restored;
      }
      final original = await captureOriginal();
      final backup = await journal.saveOriginal(original);
      _hasBackup = true;
      await journal.setPhase(backup, 'applying');
      try {
        await applyRecommended();
        await journal.setPhase(backup, 'active');
      } catch (_) {
        // A partially applied profile is never allowed to replace the backup.
        try {
          await _restore(backup);
        } catch (_) {
          // Keep the backup and recovery entry for an explicit retry/restart.
        }
        rethrow;
      }
      return DefaultSettingsTrialResult.activated;
    } catch (failure) {
      try {
        _hasBackup = await journal.hasRecords;
      } catch (_) {
        _hasBackup = true;
      }
      error = '$failure';
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _restore(TrialBackup original) async {
    await journal.setPhase(original, 'restoring');
    await restoreOriginal(original.value);
    await journal.clearAfterRestore();
    _hasBackup = false;
  }

  @visibleForTesting
  void resetForTest() {
    _initialization = null;
    _hasBackup = false;
    _busy = false;
    error = null;
  }
}
