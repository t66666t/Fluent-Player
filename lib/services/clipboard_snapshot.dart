import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// An OS clipboard update, independent of the text written by that update.
class ClipboardRevision {
  const ClipboardRevision(this.token, {required this.persistent});

  final String token;
  final bool persistent;

  static ClipboardRevision? fromPlatform(Object? value) {
    if (value is! Map) return null;
    final token = value['token'];
    if (token is! String || token.isEmpty || token.length > 512) return null;
    return ClipboardRevision(token, persistent: value['persistent'] == true);
  }

  bool sameAs(ClipboardRevision? other) =>
      other != null && token == other.token && persistent == other.persistent;
}

class ClipboardSnapshot {
  const ClipboardSnapshot({
    required this.text,
    required this.updateToken,
    this.persistentToken,
    this.hasNativeRevision = true,
  });

  final String text;
  final String updateToken;
  final String? persistentToken;
  final bool hasNativeRevision;

  String get fingerprint => clipboardTextFingerprint(text);

  bool sameUpdate(ClipboardSnapshot other) =>
      updateToken == other.updateToken && text == other.text;
}

String clipboardTextFingerprint(String text) =>
    sha256.convert(utf8.encode(text.trim())).toString();

/// Reads metadata on demand, without polling or changing the clipboard.
/// Reading around the text also handles delayed rendering and concurrent copies.
class ClipboardSnapshotReader {
  static const channel = MethodChannel(
    'com.example.video_player_app/clipboard_revision',
  );

  final _fallbackScope = Object();
  String? _observedText;
  int _fallbackRevision = 0;
  int _nextRead = 0;
  int _latestCompletedRead = 0;
  ClipboardSnapshot? _nativeSnapshot;
  bool _platformAvailable = true;

  Future<ClipboardRevision?> readRevision() async {
    if (!_platformAvailable) return null;
    try {
      return ClipboardRevision.fromPlatform(
        await channel
            .invokeMethod<Object?>('getRevision')
            .timeout(const Duration(milliseconds: 200)),
      );
    } on MissingPluginException {
      _platformAvailable = false;
      return null;
    } on PlatformException {
      // Clipboard permission/focus may be temporary. Try again next activation.
      return null;
    } on TimeoutException {
      return null;
    }
  }

  Future<ClipboardSnapshot?> read() => _read(++_nextRead);

  Future<ClipboardSnapshot?> _read(int request) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final before = await readRevision();
      final cached = _nativeSnapshot;
      if (before != null && cached?.updateToken == before.token) {
        if (request > _latestCompletedRead) _latestCompletedRead = request;
        return cached;
      }
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final after = await readRevision();
      if (before != null || after != null) {
        if (before == null || !before.sameAs(after)) continue;
      }
      final text = data?.text ?? '';
      if (request >= _latestCompletedRead) {
        _latestCompletedRead = request;
        if (text != _observedText) {
          _observedText = text;
          _fallbackRevision++;
        }
      }
      final snapshot = ClipboardSnapshot(
        text: text,
        updateToken:
            after?.token ??
            'fallback/${identityHashCode(_fallbackScope)}/$_fallbackRevision',
        persistentToken: after?.persistent == true ? after!.token : null,
        hasNativeRevision: after != null,
      );
      if (after != null && request >= _latestCompletedRead) {
        _nativeSnapshot = snapshot;
      }
      return snapshot;
    }
    // Never associate text with a revision belonging to another copy.
    return null;
  }
}
