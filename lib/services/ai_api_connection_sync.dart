import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// Identity includes the protocol and complete address. In particular, matching
/// hosts or provider labels alone never authorizes reuse of a credential.
String? aiApiConnectionIdentity(String address, String protocol) {
  final uri = Uri.tryParse(address.trim());
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !const ['openAiCompatible', 'anthropic', 'gemini'].contains(protocol)) {
    return null;
  }
  final normalized = uri
      .replace(scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase())
      .toString()
      .replaceFirst(RegExp(r'/+$'), '');
  return '$protocol|$normalized';
}

class SharedAiApiConnection {
  const SharedAiApiConnection({
    required this.id,
    required this.baseUrl,
    required this.protocol,
    required this.model,
    required this.models,
    required this.owners,
    this.apiKey = '',
  });
  final String id, baseUrl, protocol, model, apiKey;
  final List<String> models, owners;
  String? get identity => aiApiConnectionIdentity(baseUrl, protocol);
}

/// Shares only connection data. Each consumer retains its own selected model,
/// prompts, backend and task snapshots. Different existing keys stay separate;
/// once two consumers share a key, explicit edits and clearing it propagate.
class AiApiConnectionSync {
  AiApiConnectionSync({
    required this.preferences,
    required this.readSecret,
    required this.writeSecret,
    required this.deleteSecret,
    this.chatProfileId,
  });
  final Future<SharedPreferences> Function() preferences;
  final Future<String?> Function(String) readSecret;
  final Future<void> Function(String, String) writeSecret;
  final Future<void> Function(String) deleteSecret;
  final String Function(String, String)? chatProfileId;
  static const preferencesKey = 'ai_shared_api_connections_v1';
  static final changes = ValueNotifier<int>(0);
  static String secretKey(String id) => 'ai_shared_api_key_v1:$id';
  static Future<void>? _writes;

  Future<T> _serial<T>(Future<T> Function() action) {
    final previous = _writes;
    final done = Completer<void>();
    final pending = done.future;
    _writes = pending;
    return () async {
      try {
        if (previous != null) await previous;
        return await action();
      } finally {
        if (identical(_writes, pending)) _writes = null;
        done.complete();
      }
    }();
  }

  Map<String, dynamic> _decode(SharedPreferences prefs) {
    final raw = prefs.getString(preferencesKey);
    if (raw == null) return {'imported': false, 'entries': <dynamic>[]};
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['entries'] is! List) {
      throw const FormatException('共享 AI 接口配置无法读取');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _persist(
    SharedPreferences prefs,
    Map<String, dynamic> data,
  ) async {
    if (!await prefs.setString(preferencesKey, jsonEncode(data))) {
      throw StateError('共享 AI 接口未能保存');
    }
  }

  Future<void> _saveKey(String id, String key) async {
    if (key.isEmpty) {
      await deleteSecret(secretKey(id));
    } else {
      await writeSecret(secretKey(id), key);
      if (await readSecret(secretKey(id)) != key) {
        throw StateError('共享 API 密钥未能安全保存');
      }
    }
  }

  List<Map<String, dynamic>> _entries(Map<String, dynamic> data) =>
      (data['entries'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  Future<SharedAiApiConnection> _value(Map<String, dynamic> row) async =>
      SharedAiApiConnection(
        id: row['id'] as String,
        baseUrl: row['baseUrl'] as String,
        protocol: row['protocol'] as String,
        model: row['model'] as String,
        models: (row['models'] as List).cast<String>(),
        owners: (row['owners'] as List).cast<String>(),
        apiKey: await readSecret(secretKey(row['id'] as String)) ?? '',
      );

  Future<Map<String, dynamic>> _open(SharedPreferences prefs) async {
    final data = _decode(prefs);
    if (data['imported'] == true) return data;
    final entries = _entries(data);
    // Import native stores once, before an explicit edit can replace an old
    // key. This links equal credentials and preserves already distinct ones.
    Future<void> seed(
      String owner,
      Map source,
      String protocol,
      String key,
    ) async {
      final url = _text(source['baseUrl']);
      if (key.isEmpty || aiApiConnectionIdentity(url, protocol) == null) return;
      await _publish(
        entries,
        owner,
        url,
        protocol,
        key,
        _text(source['model']),
        _modelIds(source['models']),
      );
    }

    Map? object(String key) {
      try {
        final raw = prefs.getString(key);
        final value = raw == null ? null : jsonDecode(raw);
        return value is Map ? value : null;
      } on FormatException {
        return null;
      }
    }

    final chat = object('ai_chat_settings_v1');
    if (chat != null) {
      final keyMap = await readSecret('ai_chat_api_keys_v1');
      Map keys = const {};
      try {
        final decoded = keyMap == null ? null : jsonDecode(keyMap);
        if (decoded is Map) {
          keys = {
            for (final e in decoded.entries)
              if (e.key is String && e.value is String) e.key: e.value,
          };
        }
      } on FormatException {
        /* Never infer credentials from preferences. */
      }
      final profiles = chat['apiProfiles'];
      final protocol = chat['apiProtocol'] == null
          ? 'openAiCompatible'
          : _text(chat['apiProtocol']);
      final savedId = _text(chat['apiProfileId']);
      final active = savedId.isNotEmpty
          ? savedId
          : chatProfileId?.call(_text(chat['baseUrl']), protocol) ?? 'custom';
      final legacyKey = await readSecret('ai_chat_api_key_v1') ?? '';
      if (profiles is Map && profiles.isNotEmpty) {
        for (final entry in profiles.entries) {
          if (entry.value is! Map) continue;
          final row = entry.value as Map;
          final key =
              keys[entry.key] as String? ??
              (entry.key == active ? legacyKey : '');
          await seed(
            'chat:${entry.key}',
            row,
            row['protocol'] == null
                ? 'openAiCompatible'
                : _text(row['protocol']),
            key,
          );
        }
      } else {
        if (active.isNotEmpty) {
          await seed(
            'chat:$active',
            {
              ...chat,
              'model': chat['backend'] == null || chat['backend'] == 'api'
                  ? _text(chat['model'])
                  : _text(chat['apiModel']),
              'models': chat['backend'] == null || chat['backend'] == 'api'
                  ? chat['savedModels']
                  : const [],
            },
            protocol,
            keys[active] as String? ?? legacyKey,
          );
        }
      }
    }
    final subtitles = object('subtitle_ai_api_v1');
    if (subtitles != null) {
      final profiles = subtitles['profiles'];
      final active = subtitles['providerId'] is String
          ? subtitles['providerId'] as String
          : 'custom';
      final legacyKey = await readSecret('subtitle_ai_api_key_v1') ?? '';
      if (profiles is Map && profiles.isNotEmpty) {
        for (final entry in profiles.entries) {
          if (entry.value is! Map) continue;
          final row = entry.value as Map;
          final key =
              await readSecret('subtitle_ai_api_key_v1:${entry.key}') ??
              (entry.key == active ? legacyKey : '');
          await seed(
            'subtitle-profile:${entry.key}',
            row,
            _subtitleProtocol(row),
            key,
          );
        }
      } else {
        await seed(
          'subtitle-profile:$active',
          subtitles,
          _subtitleProtocol(subtitles),
          legacyKey,
        );
      }
    }
    final rawRegistry = prefs.getString('subtitle_ai_connections_v1');
    if (rawRegistry != null) {
      try {
        final rows = jsonDecode(rawRegistry);
        if (rows is List) {
          for (final row in rows.whereType<Map>()) {
            if (row['id'] is! String || row['endpoint'] is! Map) continue;
            final source = row['endpoint'] as Map;
            await seed(
              'subtitle:${row['id']}',
              source,
              _subtitleProtocol(source),
              await readSecret('subtitle_ai_connection_key_v1:${row['id']}') ??
                  '',
            );
          }
        }
      } on FormatException {
        /* The native registry reports its own corruption. */
      }
    }
    data['entries'] = entries;
    data['imported'] = true;
    await _persist(prefs, data);
    return data;
  }

  static String _text(Object? value) => value is String ? value : '';
  static String _subtitleProtocol(Map source) =>
      Uri.tryParse(_text(source['baseUrl']))?.host.toLowerCase() ==
          'generativelanguage.googleapis.com'
      ? 'gemini'
      : 'openAiCompatible';

  static List<String> _modelIds(Object? raw) => raw is List
      ? {
          for (final value in raw)
            if (value is String && value.isNotEmpty)
              value
            else if (value is Map && value['id'] is String)
              value['id'] as String,
        }.toList()
      : [];

  Future<void> prepare() => _serial(() async {
    await _open(await preferences());
  });

  Future<SharedAiApiConnection?> findUnique(
    String baseUrl,
    String protocol,
  ) async {
    final identity = aiApiConnectionIdentity(baseUrl, protocol);
    if (identity == null) return null;
    // Form autofill is read-only and never holds the shared write queue.
    final data = _decode(await preferences());
    final rows = _entries(data)
        .where(
          (row) =>
              (row['owners'] as List).isNotEmpty &&
              aiApiConnectionIdentity(
                    row['baseUrl'] as String,
                    row['protocol'] as String,
                  ) ==
                  identity,
        )
        .toList();
    return rows.length == 1 ? _value(rows.single) : null;
  }

  Future<Map<String, dynamic>> _publish(
    List<Map<String, dynamic>> rows,
    String owner,
    String url,
    String protocol,
    String key,
    String model,
    List<String> models,
  ) async {
    final identity = aiApiConnectionIdentity(url, protocol)!;
    Map<String, dynamic>? selected;
    for (final row in rows) {
      final owners = (row['owners'] as List).cast<String>();
      if (owners.contains(owner)) {
        if (aiApiConnectionIdentity(
              row['baseUrl'] as String,
              row['protocol'] as String,
            ) ==
            identity) {
          selected = row;
        } else {
          row['owners'] = owners.where((value) => value != owner).toList();
        }
      }
    }
    if (selected == null) {
      final matching = <Map<String, dynamic>>[];
      for (final row in rows) {
        if ((row['owners'] as List).isEmpty ||
            aiApiConnectionIdentity(
                  row['baseUrl'] as String,
                  row['protocol'] as String,
                ) !=
                identity) {
          continue;
        }
        matching.add(row);
        if ((await readSecret(secretKey(row['id'] as String)) ?? '') == key) {
          selected = row;
          break;
        }
      }
      // A never-configured empty connection can receive its first key. An
      // explicitly cleared account stays cleared, and ambiguous accounts never
      // absorb one another's credentials.
      if (selected == null && key.isNotEmpty && matching.length == 1) {
        final placeholder = matching.single;
        if (placeholder['cleared'] != true &&
            (await readSecret(secretKey(placeholder['id'] as String)) ?? '')
                .isEmpty) {
          selected = placeholder;
        }
      }
    }
    if (selected == null) {
      selected = {'id': const Uuid().v4(), 'owners': <String>[]};
      rows.add(selected);
    }
    final oldKey = await readSecret(secretKey(selected['id'] as String)) ?? '';
    final cleared =
        key.trim().isEmpty &&
        (oldKey.isNotEmpty || selected['cleared'] == true);
    await _saveKey(selected['id'] as String, key.trim());
    selected.addAll({
      'baseUrl': url,
      'protocol': protocol,
      'model': model,
      'models': models.toSet().toList(),
      'cleared': cleared,
      'owners': {
        ...(selected['owners'] as List).cast<String>(),
        owner,
      }.toList(),
    });
    return selected;
  }

  Future<void> publish({
    required String owner,
    required String baseUrl,
    required String protocol,
    required String apiKey,
    required String model,
    required List<String> models,
  }) => _serial(() async {
    if (aiApiConnectionIdentity(baseUrl, protocol) == null) return;
    final prefs = await preferences();
    final data = await _open(prefs);
    final rows = _entries(data);
    await _publish(rows, owner, baseUrl, protocol, apiKey, model, models);
    data['entries'] = rows;
    await _persist(prefs, data);
    changes.value++;
  });

  Future<SharedAiApiConnection?> resolve({
    required String owner,
    required String baseUrl,
    required String protocol,
    required String apiKey,
    String model = '',
    List<String> models = const [],
    String? sourceId,
  }) => _serial(() async {
    final identity = aiApiConnectionIdentity(baseUrl, protocol);
    if (identity == null) return null;
    final prefs = await preferences();
    final data = await _open(prefs);
    final rows = _entries(data);
    final candidates = <SharedAiApiConnection>[];
    for (final row in rows) {
      if (aiApiConnectionIdentity(
                row['baseUrl'] as String,
                row['protocol'] as String,
              ) !=
              identity ||
          (row['owners'] as List).isEmpty) {
        continue;
      }
      final value = await _value(row);
      if (value.owners.contains(owner)) return value;
      candidates.add(value);
    }
    final sameKey = candidates
        .where((value) => value.apiKey == apiKey)
        .firstOrNull;
    final selected = sourceId != null
        ? candidates.where((c) => c.id == sourceId).firstOrNull
        : apiKey.isNotEmpty
        ? sameKey
        : candidates.length == 1
        ? candidates.single
        : null;
    if (selected != null) {
      final row = rows.firstWhere((row) => row['id'] == selected.id);
      row['owners'] = {...selected.owners, owner}.toList();
      data['entries'] = rows;
      await _persist(prefs, data);
      return _value(row);
    }
    if (apiKey.isNotEmpty) {
      final row = await _publish(
        rows,
        owner,
        baseUrl,
        protocol,
        apiKey,
        model,
        models,
      );
      data['entries'] = rows;
      await _persist(prefs, data);
      return _value(row);
    }
    return null;
  });

  /// No keychain access is needed to populate an interface picker.
  Future<List<SharedAiApiConnection>> metadata() async {
    await _writes;
    final rows = _entries(_decode(await preferences()));
    return [
      for (final row in rows)
        if ((row['owners'] as List).isNotEmpty)
          SharedAiApiConnection(
            id: row['id'] as String,
            baseUrl: row['baseUrl'] as String,
            protocol: row['protocol'] as String,
            model: row['model'] as String,
            models: (row['models'] as List).cast<String>(),
            owners: (row['owners'] as List).cast<String>(),
          ),
    ];
  }
}
