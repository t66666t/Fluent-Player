import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../models/cloud_drive_source_ref.dart';
import '../../../utils/serial_task_queue.dart';
import '../../../services/media_artwork_repository.dart';
import '../providers/cloud_drive_http.dart';
import '../providers/cloud_drive_provider.dart';
import '../models/cloud_drive_models.dart';
import 'cloud_drive_account_repository.dart';

/// Account/file/revision keyed local covers. Signed URLs live only in memory.
class CloudDriveThumbnails {
  CloudDriveThumbnails({
    required this.providers,
    required this.accounts,
    required this.root,
  });

  final CloudDriveProviderRegistry providers;
  final CloudDriveAccountRepository accounts;
  final Directory root;
  final _hints = <String, Uri>{};
  final _loads = <String, Future<String?>>{};
  final _misses = <String, DateTime>{};
  final _tokens = <CloudDriveCancelToken>{};
  final _metadata = <String, CloudDriveEntry>{};
  final _metadataLoads = <String, Future<CloudDriveEntry?>>{};
  final _metadataMisses = <String, DateTime>{};
  final _metadataWaiting = <Completer<void>>[];
  var _metadataActive = 0;
  final _publishes = SerialTaskQueue();
  final _waiting = <Completer<void>>[];
  var _active = 0;
  var _closed = false;

  static String cacheKey(CloudDriveSourceRef source) => sha256
      .convert(utf8.encode('${source.sourceKey}\n${source.revision ?? ''}'))
      .toString();

  void remember(CloudDriveSourceRef source, String? url) {
    final uri = Uri.tryParse(url?.trim() ?? '');
    if (!_isImageUri(uri)) return;
    final key = cacheKey(source);
    if (_hints[key] != uri) {
      _misses.removeWhere((k, _) => k.startsWith('$key|'));
    }
    _hints[key] = uri!;
  }

  void rememberEntry(CloudDriveSourceRef source, CloudDriveEntry entry) {
    remember(source, entry.thumbnailRef);
    if ((entry.durationMs ?? 0) > 0 &&
        (entry.thumbnailRef?.isNotEmpty ?? false)) {
      _metadata[cacheKey(source)] = entry;
    }
  }

  /// Lightweight file details only: never opens a stream or creates a card.
  /// Visible queue rows share these requests with browser cover downloads.
  Future<CloudDriveEntry?> metadata(
    CloudDriveSourceRef source, {
    bool refresh = false,
  }) {
    if (_closed) return Future.value();
    final key = cacheKey(source);
    if (refresh) {
      _metadata.remove(key);
      _metadataMisses.removeWhere(
        (requestKey, _) => requestKey.startsWith('$key|'),
      );
    }
    final cached = _metadata[key];
    if (cached != null) return Future.value(cached);
    final requestKey = '$key|${accounts.sessionGeneration}';
    final miss = _metadataMisses[requestKey];
    if (miss != null && DateTime.now().difference(miss).inSeconds < 30) {
      return Future.value();
    }
    return _metadataLoads.putIfAbsent(requestKey, () async {
      if (_metadataActive >= 2) {
        final slot = Completer<void>();
        _metadataWaiting.add(slot);
        await slot.future;
      } else {
        _metadataActive++;
      }
      final token = CloudDriveCancelToken();
      _tokens.add(token);
      try {
        if (_closed) return null;
        final account = accounts.findRemote(
          source.providerId,
          source.remoteAccountId,
        );
        final provider = providers[source.providerId];
        final credential = account == null
            ? null
            : await accounts.credentialFor(account);
        if (account == null || provider == null || credential == null) {
          return null;
        }
        final generation = accounts.sessionGeneration;
        final entry = await provider.getFile(
          CloudDriveFileRequest(
            credential: credential,
            accountLocalId: account.localId,
            remoteAccountId: source.remoteAccountId,
            driveId: source.driveId,
            fileId: source.fileId,
            pathHint: source.pathHint,
          ),
          cancelToken: token,
        );
        if (_closed ||
            token.isCancelled ||
            generation != accounts.sessionGeneration ||
            entry.providerId != source.providerId ||
            entry.remoteAccountId != source.remoteAccountId ||
            entry.driveId != source.driveId ||
            entry.fileId != source.fileId ||
            (source.revision != null &&
                entry.revision != null &&
                source.revision != entry.revision)) {
          return null;
        }
        _metadata[key] = entry;
        remember(source, entry.thumbnailRef);
        return entry;
      } catch (_) {
        return null;
      } finally {
        if (!_metadata.containsKey(key)) {
          _metadataMisses[requestKey] = DateTime.now();
        }
        _tokens.remove(token);
        _metadataLoads.remove(requestKey);
        if (_metadataWaiting.isNotEmpty) {
          _metadataWaiting.removeAt(0).complete();
        } else {
          _metadataActive--;
        }
      }
    });
  }

  Future<String?> ensure(CloudDriveSourceRef source) {
    if (_closed) return Future.value();
    final key = cacheKey(source);
    return _loads.putIfAbsent(key, () async {
      try {
        return await _ensure(source, key);
      } catch (_) {
        // A cover never prevents playback. Transient misses can be retried.
        _misses['$key|${accounts.sessionGeneration}'] = DateTime.now();
        return null;
      } finally {
        _loads.remove(key);
      }
    });
  }

  Future<String?> _ensure(CloudDriveSourceRef source, String key) async {
    final file = File(p.join(root.path, '$key.img'));
    if (await file.exists() && await file.length() > 0) return file.path;
    final missKey = '$key|${accounts.sessionGeneration}';
    final miss = _misses[missKey];
    if (miss != null && DateTime.now().difference(miss).inSeconds < 30) {
      return null;
    }
    if (_active >= 2) {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future;
    } else {
      _active++;
    }
    final token = CloudDriveCancelToken();
    _tokens.add(token);
    try {
      if (_closed) return null;
      final account = accounts.findRemote(
        source.providerId,
        source.remoteAccountId,
      );
      final provider = providers[source.providerId];
      final credential = account == null
          ? null
          : await accounts.credentialFor(account);
      if (account == null || provider == null || credential == null) {
        return null;
      }
      final request = CloudDriveFileRequest(
        credential: credential,
        accountLocalId: account.localId,
        remoteAccountId: source.remoteAccountId,
        driveId: source.driveId,
        fileId: source.fileId,
        pathHint: source.pathHint,
      );
      var uri = _hints[key];
      var fetchedMetadata = false;
      Future<Uri?> refresh({bool force = false}) async {
        fetchedMetadata = true;
        // A failed signed address must refresh even when duration was cached.
        if (force) _metadata.remove(key);
        final entry = await metadata(source);
        if (entry == null) return null;
        // Do not attach a newly replaced remote file to a stale card revision.
        if (source.revision != null &&
            entry.revision != null &&
            source.revision != entry.revision) {
          return null;
        }
        final candidate = Uri.tryParse(entry.thumbnailRef ?? '');
        if (!_isImageUri(candidate)) return null;
        _hints[key] = candidate!;
        return candidate;
      }

      uri ??= await refresh();
      if (uri == null) return null;
      List<int> bytes;
      try {
        bytes = await provider.readThumbnail(request, uri, cancelToken: token);
        inspectArtworkBytes(bytes);
      } catch (_) {
        if (fetchedMetadata || _closed) rethrow;
        uri = await refresh(force: true);
        if (uri == null) return null;
        bytes = await provider.readThumbnail(request, uri, cancelToken: token);
        inspectArtworkBytes(bytes);
      }
      if (_closed || token.isCancelled) return null;
      return await _publish(key, bytes);
    } finally {
      _tokens.remove(token);
      // Empty results are short-lived too; a grid rebuild must not hammer APIs.
      if (!await file.exists()) _misses[missKey] = DateTime.now();
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }

  /// A decoded video frame supplies a real cover when the provider has none.
  /// Publishing shares the same slot as a concurrent provider image download.
  Future<String?> rememberFrame(
    CloudDriveSourceRef source,
    List<int> bytes,
  ) async {
    try {
      inspectArtworkBytes(bytes);
      return await _publish(cacheKey(source), bytes);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _publish(String key, List<int> bytes) =>
      _publishes.enqueue(() async {
        if (_closed) return null;
        final file = File(p.join(root.path, '$key.img'));
        if (await file.exists() && await file.length() > 0) return file.path;
        await root.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsBytes(bytes, flush: true);
        if (_closed) {
          await temporary.delete();
          return null;
        }
        await temporary.rename(file.path);
        return file.path;
      });

  void close() {
    _closed = true;
    for (final token in _tokens) {
      token.cancel();
    }
    _hints.clear();
    _metadata.clear();
    _metadataMisses.clear();
  }

  static bool _isImageUri(Uri? uri) =>
      uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty;
}
