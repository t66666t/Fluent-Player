import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/clipboard_link.dart';
import 'clipboard_parse_repeat.dart';
import 'clipboard_snapshot.dart';

class _HandledClipboardUpdate {
  const _HandledClipboardUpdate({
    this.textFingerprint,
    this.linksFingerprint,
    this.updateToken,
    this.persistentToken,
    this.hasNativeRevision = false,
  });

  final String? textFingerprint;
  final String? linksFingerprint;
  final String? updateToken;
  final String? persistentToken;
  final bool hasNativeRevision;

  Map<String, Object?> toJson() => {
    'textFingerprint': textFingerprint,
    'linksFingerprint': linksFingerprint,
    'updateToken': persistentToken,
  };
}

/// Only the latest handled clipboard update is retained. Link fingerprints
/// identify a batch (including a dropped batch), never blacklist old URLs.
class ClipboardLinkHistory {
  static const storageKey = 'clipboardPromptSnapshotV2';
  static const legacyStorageKey = 'clipboardPromptLinkHistoryV1';
  _HandledClipboardUpdate? _persisted;
  _HandledClipboardUpdate? _session;
  _HandledClipboardUpdate? _dropAcknowledgement;
  bool? _policy;
  SharedPreferences? _prefs;
  Future<void>? _loading;
  Future<void> _writes = Future.value();

  Future<void> load({String? legacyText}) =>
      _loading ??= _load(legacyText: legacyText);

  Future<void> _load({String? legacyText}) async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final stored = prefs.get(storageKey);
    try {
      final value = stored is String && stored.length <= 2048
          ? jsonDecode(stored)
          : null;
      _HandledClipboardUpdate? parse(Object? value) {
        if (value is! Map) return null;
        String? fingerprint(String key) {
          final entry = value[key];
          return entry is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(entry)
              ? entry
              : null;
        }

        final text = fingerprint('textFingerprint');
        final links = fingerprint('linksFingerprint');
        final token = value['updateToken'];
        if (text != null || links != null) {
          return _HandledClipboardUpdate(
            textFingerprint: text,
            linksFingerprint: links,
            persistentToken:
                token is String && token.isNotEmpty && token.length <= 512
                ? token
                : null,
          );
        }
        return null;
      }

      _persisted = parse(value);
      if (value is Map) {
        _dropAcknowledgement = parse(value['drop']);
      }
    } on FormatException {
      // An optional corrupt record must not prevent prompting.
    }
    if (_persisted == null &&
        stored == null &&
        legacyText?.isNotEmpty == true &&
        legacyText!.length <= ClipboardLinkDetector.maxTextLength) {
      _persisted = _HandledClipboardUpdate(
        textFingerprint: clipboardTextFingerprint(legacyText),
      );
    }
    // The old 200-URL history is deliberately never consulted.
  }

  String _linksKey(Iterable<ClipboardLink> links) {
    final identities = links.map((link) => link.identity).toSet().toList()
      ..sort();
    return sha256.convert(utf8.encode(identities.join('\n'))).toString();
  }

  void _usePolicy(bool skipRepeated) {
    if (_policy == skipRepeated) return;
    _policy = skipRepeated;
    _session = null;
  }

  void beginActivation() {
    if (_policy == false) _session = null;
  }

  /// An update already displayed needs neither URL extraction nor another hash.
  bool hasHandledNativeRevision(
    ClipboardSnapshot snapshot, {
    required bool skipRepeated,
  }) {
    _usePolicy(skipRepeated);
    final record = _session ?? (skipRepeated ? _persisted : null);
    if (record == null ||
        record.textFingerprint == null ||
        !snapshot.hasNativeRevision) {
      return false;
    }
    if (_session != null) {
      return record.hasNativeRevision &&
          record.updateToken == snapshot.updateToken;
    }
    return record.persistentToken != null &&
        record.persistentToken == snapshot.persistentToken;
  }

  bool shouldSkip(
    ClipboardSnapshot snapshot,
    Iterable<ClipboardLink> links, {
    required bool skipRepeated,
  }) {
    _usePolicy(skipRepeated);
    final drop = _dropAcknowledgement;
    if (drop != null) {
      final recordedToken = drop.updateToken ?? drop.persistentToken;
      final currentToken = drop.updateToken == null
          ? snapshot.persistentToken
          : snapshot.hasNativeRevision
          ? snapshot.updateToken
          : null;
      if (shouldSkipClipboardParse(
        fingerprint: _linksKey(links),
        handledFingerprint: drop.linksFingerprint,
        updateToken: currentToken,
        handledUpdateToken: recordedToken,
      )) {
        if (recordedToken == null || currentToken != null) {
          unawaited(
            remember(
              snapshot,
              links,
              skipRepeated: skipRepeated,
            ).catchError((Object _) {}),
          );
        }
        return true;
      }
      // A drag of another URL must not replace the last actual clipboard update.
      // This acknowledgement has now been observed and is no longer relevant.
      _dropAcknowledgement = null;
      unawaited(_save().catchError((Object _) {}));
    }
    final record = _session ?? (skipRepeated ? _persisted : null);
    if (record == null) return false;
    final recordedNative = _session == null
        ? record.persistentToken != null
        : record.hasNativeRevision;
    final currentNative = _session == null
        ? snapshot.persistentToken != null
        : snapshot.hasNativeRevision;
    // Drops contain URLs rather than the source's share text. Only that special
    // record may match by link batch; ordinary copies compare complete text.
    final matches = shouldSkipClipboardParse(
      fingerprint: record.textFingerprint == null
          ? _linksKey(links)
          : snapshot.fingerprint,
      handledFingerprint: record.textFingerprint ?? record.linksFingerprint,
      updateToken: recordedNative != currentNative
          ? null
          : (_session == null
                ? snapshot.persistentToken
                : snapshot.updateToken),
      handledUpdateToken: _session == null
          ? record.persistentToken
          : record.updateToken,
    );
    if (matches &&
        !(recordedNative && !currentNative) &&
        (_session == null ||
            record.updateToken == null ||
            !recordedNative && currentNative)) {
      // Adopt the current revision when migrating a legacy/content-only record.
      // It was already presented; later recopies must be allowed through.
      unawaited(
        remember(
          snapshot,
          links,
          skipRepeated: skipRepeated,
        ).catchError((Object _) {}),
      );
    }
    return matches;
  }

  Future<void> remember(
    ClipboardSnapshot snapshot,
    Iterable<ClipboardLink> links, {
    required bool skipRepeated,
  }) {
    _usePolicy(skipRepeated);
    final previous = _session;
    if (previous?.hasNativeRevision == true &&
        !snapshot.hasNativeRevision &&
        previous!.textFingerprint == snapshot.fingerprint) {
      // A temporary metadata failure is not evidence of a new copy. Retain
      // the known native token so its eventual recovery cannot cause a repeat.
      return Future<void>.value();
    }
    return _remember(
      _HandledClipboardUpdate(
        textFingerprint: snapshot.fingerprint,
        linksFingerprint: _linksKey(links),
        updateToken: snapshot.updateToken,
        persistentToken: snapshot.persistentToken,
        hasNativeRevision: snapshot.hasNativeRevision,
      ),
    );
  }

  Future<void> rememberDrop(
    Iterable<ClipboardLink> links, {
    required ClipboardRevision? revision,
    required bool skipRepeated,
  }) {
    _usePolicy(skipRepeated);
    _dropAcknowledgement = _HandledClipboardUpdate(
      linksFingerprint: _linksKey(links),
      updateToken: revision?.token,
      persistentToken: revision?.persistent == true ? revision!.token : null,
      hasNativeRevision: revision != null,
    );
    return _save();
  }

  Future<void> _remember(_HandledClipboardUpdate record) {
    _session = record;
    _persisted = record;
    _dropAcknowledgement = null;
    return _save();
  }

  Future<void> _save() {
    final encoded = jsonEncode({
      ...?_persisted?.toJson(),
      if (_dropAcknowledgement != null) 'drop': _dropAcknowledgement!.toJson(),
    });
    final write = _writes.then((_) async {
      await _prefs?.setString(storageKey, encoded);
    });
    // A failed optional write must not poison subsequent saves.
    _writes = write.catchError((Object _) {});
    return write;
  }
}
