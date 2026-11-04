import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'folder_receive_journal.dart';

/// Validates only an interrupted task's published files before skipping its
/// receive step. A receipt proves expected content, never current file bytes.
Future<bool> validateReceivedFolderFiles({
  required File journalFile,
  required String transferId,
  required String peerId,
  required String targetRootId,
  String? Function(String cardId)? currentMediaPath,
  bool Function()? isCancelled,
}) async {
  bool cancelled() => isCancelled?.call() == true;
  if (cancelled()) return false;
  late final FolderReceiveJournal journal;
  try {
    if (!await journalFile.exists() ||
        await journalFile.length() > 64 * 1024 * 1024) {
      return false;
    }
    final raw = jsonDecode(await journalFile.readAsString());
    if (raw is! Map ||
        raw['assets'] is! List ||
        (raw['assets'] as List).any((asset) => asset is! Map)) {
      return false;
    }
    journal = FolderReceiveJournal.fromJson(Map<String, dynamic>.from(raw));
  } on FileSystemException {
    return false;
  } on FormatException catch (error) {
    // Never turn a newer checkpoint into a legacy/missing checkpoint.
    if (error.message.contains('更新的版本')) rethrow;
    return false;
  } on TypeError {
    return false;
  }
  if (journal.transferId != transferId ||
      journal.peerId != peerId ||
      journal.targetRootId != targetRootId ||
      journal.manifestRevision != transferId) {
    return false;
  }
  final seen = <String, (int, String)>{};
  for (final asset in journal.assets) {
    if (cancelled() ||
        !asset.attached ||
        asset.expectedLength < 0 ||
        asset.confirmedBytes != asset.expectedLength) {
      return false;
    }
    final path = asset.permanentPath;
    if (path == null || path.isEmpty || !p.isAbsolute(path)) return false;
    final identity = asset.contentIdentity ?? '';
    final parts = identity.split(':');
    final expected =
        parts.length == 3 &&
            parts.first == 'sha256' &&
            int.tryParse(parts[1]) == asset.expectedLength
        ? parts.last
        : identity;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expected)) return false;
    final key = _pathKey(path);
    if (asset.role == 'primary' && currentMediaPath != null) {
      final cardId = asset.cardId;
      final current = cardId == null ? null : currentMediaPath(cardId);
      if (current == null || _pathKey(current) != key) return false;
    }
    final previous = seen[key];
    if (previous != null) {
      if (previous != (asset.expectedLength, expected)) return false;
      continue;
    }
    try {
      final file = File(path);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final before = await file.stat();
      if (before.size != asset.expectedLength) return false;
      final result = _DigestSink();
      final sink = sha256.startChunkedConversion(result);
      final handle = await file.open();
      var locked = false;
      try {
        // A non-blocking shared lock detects an exclusive writer without
        // leaving a native read indefinitely waiting for that writer.
        await handle.lock(FileLock.shared, 0, asset.expectedLength);
        locked = true;
        while (true) {
          if (cancelled()) return false;
          final chunk = await handle.read(1024 * 1024);
          if (chunk.isEmpty) break;
          sink.add(chunk);
        }
      } finally {
        sink.close();
        try {
          if (locked) await handle.unlock(0, asset.expectedLength);
        } finally {
          await handle.close();
        }
      }
      final after = await file.stat();
      if (cancelled() ||
          after.type != FileSystemEntityType.file ||
          before.size != after.size ||
          before.modified != after.modified ||
          result.value.toString() != expected) {
        return false;
      }
      seen[key] = (asset.expectedLength, expected);
    } on FileSystemException {
      return false;
    }
  }
  return !cancelled();
}

String _pathKey(String value) {
  final normalized = p.normalize(p.absolute(value));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) => this.value = value;
  @override
  void close() {}
}
