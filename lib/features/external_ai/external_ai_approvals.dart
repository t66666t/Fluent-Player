import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'external_ai_action_store.dart';
import 'external_ai_preferences.dart';

/// The MCP caller can request an approval, but cannot approve it. Only the
/// application's UI can resolve it or change the user's delegation policy.
class ExternalAiApprovals extends ChangeNotifier {
  ExternalAiApprovals({required this.store, required this.preferences});
  final ExternalAiActionStore store;
  final ExternalAiPreferences? Function() preferences;
  Map<String, dynamic> _state = {'version': 1, 'requests': <String, dynamic>{}};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  Future<void> _operations = Future.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _operations.then((_) => work());
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> initialize() => _loading ??= () async {
    _state = await store.load();
    _state.putIfAbsent('requests', () => <String, dynamic>{});
  }();
  Map<String, dynamic> get _requests =>
      _state['requests'] as Map<String, dynamic>;
  String get grant => sha256
      .convert(
        utf8.encode(
          jsonEncode([preferences()?.token, preferences()?.scopeFolderId]),
        ),
      )
      .toString();
  bool _delegated(String category) {
    final p = preferences();
    return switch (category) {
      'tasks' => p?.autoTaskDecisions == true,
      'downloads' => p?.autoModelDownloads == true,
      'remote' => p?.autoRemoteProcessing == true,
      // Global defaults always require a concrete, app-side confirmation.
      _ => false,
    };
  }

  static Object? _canonical(Object? v) => v is Map
      ? {
          for (final k in v.keys.cast<String>().toList()..sort())
            k: _canonical(v[k]),
        }
      : v is List
      ? v.map(_canonical).toList()
      : v;

  Future<void> _save() async {
    final copy = jsonDecode(jsonEncode(_state)) as Map<String, dynamic>;
    final write = _writes.then((_) => store.save(copy));
    _writes = write.catchError((Object _) {});
    await write;
    notifyListeners();
  }

  /// Returns a safe pending result, or null when this exact operation is allowed.
  /// Fingerprint includes private frozen configuration; it is never displayed.
  Future<Map<String, dynamic>?> require({
    required List<String> categories,
    required Object identity,
    required Map<String, dynamic> preview,
  }) => _serial(
    () =>
        _require(categories: categories, identity: identity, preview: preview),
  );

  Future<Map<String, dynamic>?> _require({
    required List<String> categories,
    required Object identity,
    required Map<String, dynamic> preview,
  }) async {
    await initialize();
    if (categories.every(_delegated)) return null;
    final stamp = grant;
    final fingerprint = sha256
        .convert(
          utf8.encode(jsonEncode(_canonical([stamp, categories, identity]))),
        )
        .toString();
    final existing = _requests.entries
        .where(
          (e) =>
              e.value['fingerprint'] == fingerprint &&
              e.value['grant'] == stamp,
        )
        .firstOrNull;
    if (existing != null) {
      final row = existing.value as Map;
      final expires = DateTime.tryParse(row['expiresAt'] as String? ?? '');
      if (expires != null && expires.isAfter(DateTime.now())) {
        if (row['status'] == 'approved') return null;
        return _safe(existing.key, row);
      }
    }
    // Expired requests have no authority and can be pruned without losing work.
    _requests.removeWhere(
      (_, v) =>
          DateTime.tryParse(
            v['expiresAt'] as String? ?? '',
          )?.isBefore(DateTime.now()) !=
          false,
    );
    if (_requests.length >= 200) throw StateError('待确认记录过多，请先处理已有请求');
    final id = const Uuid().v4();
    final row = <String, dynamic>{
      'grant': stamp,
      'fingerprint': fingerprint,
      'status': 'pending',
      'categories': categories,
      'preview': preview,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'expiresAt': DateTime.now()
          .add(const Duration(hours: 24))
          .toUtc()
          .toIso8601String(),
    };
    _requests[id] = row;
    await _save();
    return _safe(id, row);
  }

  Map<String, dynamic> _safe(String id, Map row) => {
    'approvalId': id,
    'status': row['status'] == 'pending' ? 'approval_required' : row['status'],
    'categories': row['categories'],
    'preview': row['preview'],
    'expiresAt': row['expiresAt'],
    'nextStep': '请用户在播放器「外部 AI 连接 → 待确认」处理；确认后原参数重试。Agent 无法替用户批准。',
  };
  List<Map<String, dynamic>> get requests => [
    for (final e in _requests.entries)
      if (e.value['grant'] == grant &&
          DateTime.tryParse(
                e.value['expiresAt'] as String? ?? '',
              )?.isAfter(DateTime.now()) ==
              true)
        _safe(e.key, e.value as Map),
  ];

  /// App UI only: no MCP route calls this method.
  Future<void> resolve(String id, {required bool approve}) =>
      _serial(() => _resolve(id, approve: approve));

  Future<void> _resolve(String id, {required bool approve}) async {
    await initialize();
    final row = _requests[id];
    if (row is! Map ||
        row['grant'] != grant ||
        row['status'] != 'pending' ||
        preferences()?.enabled != true ||
        preferences()?.allowTaskControl != true ||
        DateTime.parse(row['expiresAt'] as String).isBefore(DateTime.now())) {
      throw StateError('确认已失效');
    }
    row['status'] = approve ? 'approved' : 'denied';
    try {
      await _save();
    } catch (_) {
      row['status'] = 'pending';
      rethrow;
    }
  }
}
