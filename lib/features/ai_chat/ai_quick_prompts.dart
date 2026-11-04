import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_chat_copy.dart';

/// A short display name and the complete, unmodified draft to insert.
@immutable
class AiQuickPrompt {
  const AiQuickPrompt({
    required this.id,
    required this.name,
    required this.text,
  });

  final String id;
  final String name;
  final String text;

  static const mediaPlaceholder = '{{媒体}}';

  String nameFor(AiChatMediaCopy media) =>
      name.replaceAll(mediaPlaceholder, media.noun);
  String textFor(AiChatMediaCopy media) =>
      text.replaceAll(mediaPlaceholder, media.noun);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'text': text};
}

/// Independent of media sessions and model settings, so saving a connection or
/// switching conversations cannot overwrite the user's shared prompt library.
class AiQuickPromptStore extends ChangeNotifier {
  AiQuickPromptStore({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static final instance = AiQuickPromptStore();
  static const preferenceKey = 'ai_chat_quick_prompts_v1';
  static const _copy = AiChatMediaCopy(AiQuickPrompt.mediaPlaceholder);
  static final defaults = List<AiQuickPrompt>.unmodifiable([
    AiQuickPrompt(id: 'summary', name: _copy.summarize, text: _copy.summarize),
    AiQuickPrompt(
      id: 'explain',
      name: _copy.hardConcept,
      text: _copy.hardConcept,
    ),
    AiQuickPrompt(
      id: 'key-points',
      name: _copy.timestamps,
      text: _copy.timestamps,
    ),
    AiQuickPrompt(
      id: 'notes',
      name: _copy.completeNotes,
      text: _copy.completeNotesPrompt,
    ),
  ]);

  final Future<SharedPreferences> Function() _preferences;
  List<AiQuickPrompt> _entries = defaults;
  List<AiQuickPrompt> get entries => _entries;
  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();
  bool _loaded = false;
  bool _disposed = false;
  int _revision = 0;
  String? loadError;
  bool get loading => _loading != null;

  static void _validate(List<AiQuickPrompt> entries) {
    final ids = <String>{};
    for (final entry in entries) {
      if (entry.id.trim().isEmpty ||
          entry.name.trim().isEmpty ||
          entry.text.trim().isEmpty ||
          !ids.add(entry.id)) {
        throw const FormatException('提示词的名称、正文或标识无效。');
      }
    }
  }

  /// An explicitly empty library stays empty. Invalid data is never silently
  /// written back over the original preference value.
  static List<AiQuickPrompt> decode(String? raw) {
    if (raw == null) return defaults;
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['entries'] is! List) {
      throw const FormatException('无法读取已保存的提示词。');
    }
    final entries = <AiQuickPrompt>[];
    for (final value in decoded['entries'] as List) {
      if (value is! Map ||
          value['id'] is! String ||
          value['name'] is! String ||
          value['text'] is! String) {
        throw const FormatException('无法读取已保存的提示词。');
      }
      entries.add(
        AiQuickPrompt(
          id: value['id'],
          name: value['name'],
          text: value['text'],
        ),
      );
    }
    _validate(entries);
    return List.unmodifiable(entries);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    final revision = _revision;
    // Publish the pending future before a synchronous storage failure can run
    // _load's cleanup. Otherwise that completed future would prevent retries.
    return _loading ??= Future<void>.microtask(() => _load(revision));
  }

  Future<void> _load(int revision) async {
    try {
      final preferences = await _preferences();
      final entries = decode(preferences.getString(preferenceKey));
      if (revision == _revision) {
        _entries = entries;
        _loaded = true;
        loadError = null;
      }
    } catch (_) {
      if (revision == _revision) {
        loadError = '提示词读取失败，可重试或恢复默认。原有保存内容仍保留。';
      }
    } finally {
      _loading = null;
      _notify();
    }
  }

  Future<void> replace(List<AiQuickPrompt> entries) => _commit(entries);
  Future<void> restoreDefaults() => _commit(defaults, restore: true);

  Future<void> _commit(List<AiQuickPrompt> entries, {bool restore = false}) {
    _validate(entries);
    final snapshot = List<AiQuickPrompt>.unmodifiable(entries);
    ++_revision;
    final operation = _writes.then((_) async {
      final preferences = await _preferences();
      final saved = restore
          ? await preferences.remove(preferenceKey)
          : await preferences.setString(
              preferenceKey,
              jsonEncode({
                'version': 1,
                'entries': snapshot.map((entry) => entry.toJson()).toList(),
              }),
            );
      if (!saved) throw StateError('提示词保存失败，请重试。');
      _entries = snapshot;
      _loaded = true;
      loadError = null;
      _notify();
    });
    // Failed writes leave the live library unchanged and can be retried.
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
