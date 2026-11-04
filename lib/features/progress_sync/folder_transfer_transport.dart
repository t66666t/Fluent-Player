import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'progress_sync_lan.dart';

enum FolderTransferPhase {
  hashing,
  connecting,
  transferring,
  verifying,
  completed,
  cancelled,
  failed,
}

@immutable
class FolderTransferProgress {
  const FolderTransferProgress({
    required this.transferId,
    required this.phase,
    required this.totalBytes,
    required this.receivedBytes,
    required this.verifiedBytes,
    required this.resumedBytes,
    required this.phaseBytes,
    required this.bytesPerSecond,
    required this.elapsed,
  });
  final String transferId;
  final FolderTransferPhase phase;
  final int totalBytes;

  /// Unique plaintext bytes present or currently being received, including resume.
  final int receivedBytes;

  /// Authenticated chunks flushed to disk and recorded in the checkpoint.
  final int verifiedBytes;
  final int resumedBytes;

  /// Actual bytes hashed during hashing/verifying, otherwise receivedBytes.
  final int phaseBytes;
  final double bytesPerSecond;
  final Duration elapsed;
}

class FolderTransferException implements Exception {
  const FolderTransferException(this.code, [this.message = '']);
  final String code;
  final String message;
  @override
  String toString() => message.isEmpty ? code : '$code: $message';
}

class FolderTransferCancelled extends FolderTransferException {
  const FolderTransferCancelled() : super('cancelled');
}

class FolderTransferCancellation {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const FolderTransferCancelled();
  }

  void Function() _listen(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

/// Capability secret: serialize only through the paired encrypted control RPC.
/// Never expose this object in discovery, URLs, logs or plaintext notifications.
@immutable
class FolderTransferOffer {
  const FolderTransferOffer({
    required this.transferId,
    required this.senderId,
    required this.receiverId,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.chunkSize,
    required this.port,
    required this.sessionKey,
    required this.createdAt,
    required this.expiresAt,
    this.cipher = 'chacha20-poly1305',
  });
  final String transferId, senderId, receiverId, fileName, sha256, sessionKey;
  final int size, chunkSize, port;
  final DateTime createdAt, expiresAt;
  final String cipher;
  int get version => 1;
  int get chunkCount => (size + chunkSize - 1) ~/ chunkSize;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'cipher': cipher,
    'transferId': transferId,
    'senderId': senderId,
    'receiverId': receiverId,
    'fileName': fileName,
    'size': size,
    'sha256': sha256,
    'chunkSize': chunkSize,
    'port': port,
    'sessionKey': sessionKey,
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
  };
  factory FolderTransferOffer.fromJson(Map<String, dynamic> json) {
    try {
      if (json['version'] != 1) throw const FormatException();
      final offer = FolderTransferOffer(
        transferId: json['transferId'] as String,
        senderId: json['senderId'] as String,
        receiverId: json['receiverId'] as String,
        fileName: json['fileName'] as String,
        size: json['size'] as int,
        sha256: json['sha256'] as String,
        chunkSize: json['chunkSize'] as int,
        port: json['port'] as int,
        sessionKey: json['sessionKey'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          json['createdAt'] as int,
          isUtc: true,
        ),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          json['expiresAt'] as int,
          isUtc: true,
        ),
        cipher: json['cipher'] as String,
      );
      offer._validate();
      return offer;
    } catch (_) {
      throw const FolderTransferException('invalidOffer');
    }
  }
  void _validate() {
    if (cipher != 'chacha20-poly1305' ||
        !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(transferId) ||
        senderId.isEmpty ||
        senderId.length > 100 ||
        receiverId.isEmpty ||
        receiverId.length > 100 ||
        fileName.isEmpty ||
        fileName.length > 255 ||
        size < 0 ||
        size > 2 * 1024 * 1024 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        chunkSize < 64 * 1024 ||
        chunkSize > 8 * 1024 * 1024 ||
        chunkCount > 1000000 ||
        port < 1 ||
        port > 65535 ||
        sessionKey.length > 50 ||
        base64Decode(sessionKey).length != 32 ||
        !expiresAt.isAfter(createdAt) ||
        expiresAt.difference(createdAt).inDays > 7) {
      throw const FolderTransferException('invalidOffer');
    }
  }
}

/// Binary range transport for an already-created, uncompressed fluentpack file.
/// Four persistent worker isolates handle AEAD, SHA and random file writes; the
/// UI isolate only handles bounded socket buffers and small progress updates.
class FolderTransferTransport {
  FolderTransferTransport({required this.lan});
  final ProgressSyncLan lan;
  final _pool = _TransferWorkers(4);
  final Map<String, _SendCapability> _sending = {};
  final Map<String, (String, FolderTransferCancellation)> _preparing = {};
  final Map<String, FolderTransferCancellation> _receiving = {};
  final Map<String, String> _receivingPeers = {};
  HttpServer? _server;
  Future<void>? _starting;
  Timer? _expiry;
  bool _closed = false;
  int _activeRequests = 0;
  int? get port => _server?.port;

  Future<void> start({InternetAddress? bindAddress}) {
    if (_starting != null) return _starting!;
    if (_server != null) return Future.value();
    return _starting = _start(bindAddress).whenComplete(() => _starting = null);
  }

  Future<void> _start(InternetAddress? bindAddress) async {
    if (_closed) throw const FolderTransferException('closed');
    await _pool.start();
    final server = await HttpServer.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      0,
    );
    if (_closed) {
      await server.close(force: true);
      return;
    }
    _server = server;
    server.idleTimeout = const Duration(seconds: 30);
    server.listen((request) => unawaited(_serve(request)), onError: (_) {});
    lan.addListener(_checkTrust);
    _expiry = Timer.periodic(const Duration(seconds: 30), (_) => _checkTrust());
  }

  Future<FolderTransferOffer> prepareSend(
    File file, {
    required String peerId,
    String? transferId,
    String? fileName,
    int chunkSize = 2 * 1024 * 1024,
    Duration validity = const Duration(hours: 24),
    FolderTransferCancellation? cancellation,
    void Function(FolderTransferProgress)? onProgress,
  }) async {
    await start();
    if (!lan.isRunning || !lan.isTrustedPeer(peerId)) {
      throw const FolderTransferException('unpaired');
    }
    final id = transferId ?? _randomHex(16);
    if (_preparing.containsKey(id)) {
      throw const FolderTransferException('alreadyPreparing');
    }
    if (_sending.length + _preparing.length >= 8 && !_sending.containsKey(id)) {
      throw const FolderTransferException('tooManyTransfers');
    }
    final cancel = FolderTransferCancellation();
    final detachParent = cancellation?._listen(() {
      cancel.cancel();
      if (identical(_sending[id]?.cancellation, cancel)) cancelSend(id);
    });
    var granted = false;
    _preparing[id] = (peerId, cancel);
    try {
      cancel.throwIfCancelled();
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw const FolderTransferException('sourceMissing');
      }
      final stopwatch = Stopwatch()..start();
      void report(int bytes) => onProgress?.call(
        FolderTransferProgress(
          transferId: id,
          phase: FolderTransferPhase.hashing,
          totalBytes: stat.size,
          receivedBytes: 0,
          verifiedBytes: 0,
          resumedBytes: 0,
          phaseBytes: bytes,
          bytesPerSecond:
              bytes * 1000000 / max(1, stopwatch.elapsedMicroseconds),
          elapsed: stopwatch.elapsed,
        ),
      );
      report(0);
      final result = await _pool.run(
        {'op': 'hashFile', 'path': file.path},
        cancellation: cancel,
        onProgress: report,
      );
      cancel.throwIfCancelled();
      final after = await file.stat();
      if (after.size != stat.size ||
          after.modified != stat.modified ||
          !lan.isTrustedPeer(peerId) ||
          !lan.isRunning) {
        throw const FolderTransferException('sourceChanged');
      }
      final now = DateTime.now().toUtc();
      final offer = FolderTransferOffer(
        transferId: id,
        senderId: lan.deviceId,
        receiverId: peerId,
        fileName: fileName ?? file.uri.pathSegments.last,
        size: stat.size,
        sha256: result['sha256'] as String,
        chunkSize: chunkSize,
        port: port!,
        sessionKey: base64Encode(_randomBytes(32)),
        createdAt: now,
        expiresAt: now.add(validity),
      );
      offer._validate();
      _revokeCapability(id);
      _sending[id] = _SendCapability(
        offer,
        file,
        stat.modified,
        cancel,
        detachParent,
      );
      granted = true;
      report(stat.size);
      cancel.throwIfCancelled();
      return offer;
    } finally {
      _preparing.remove(id);
      if (!granted) {
        detachParent?.call();
        cancel.cancel();
      }
    }
  }

  void cancelSend(String transferId) {
    _preparing[transferId]?.$2.cancel();
    _revokeCapability(transferId);
  }

  void _revokeCapability(String transferId) {
    final capability = _sending.remove(transferId);
    capability?.cancellation.cancel();
    capability?.detachParent?.call();
  }

  Future<File> receive(
    FolderTransferOffer offer, {
    required File destination,
    File? checkpointFile,
    int parallelism = 4,
    int maxRetries = 3,
    int bytesPerSecondLimit = 0,
    String? host,
    FolderTransferCancellation? cancellation,
    void Function(FolderTransferProgress)? onProgress,
  }) async {
    if (_closed) throw const FolderTransferException('closed');
    offer._validate();
    if (offer.receiverId != lan.deviceId ||
        !lan.isTrustedPeer(offer.senderId) ||
        offer.expiresAt.isBefore(DateTime.now()) ||
        !lan.isRunning) {
      throw const FolderTransferException('unpaired');
    }
    if (_receiving.containsKey(offer.transferId)) {
      throw const FolderTransferException('alreadyReceiving');
    }
    if (_receiving.length >= 2) {
      throw const FolderTransferException('tooManyTransfers');
    }
    await start();
    final peer = lan.nearbyDevices
        .where((p) => p.id == offer.senderId)
        .firstOrNull;
    final address = await _localAddress(host ?? peer?.host ?? '');
    if (_closed) throw const FolderTransferException('closed');
    if (_receiving.containsKey(offer.transferId)) {
      throw const FolderTransferException('alreadyReceiving');
    }
    if (_receiving.length >= 2) {
      throw const FolderTransferException('tooManyTransfers');
    }
    final cancel = FolderTransferCancellation();
    final removeCancel = cancellation?._listen(cancel.cancel);
    _receiving[offer.transferId] = cancel;
    _receivingPeers[offer.transferId] = offer.senderId;
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 8)
      ..maxConnectionsPerHost = parallelism.clamp(1, 4)
      ..idleTimeout = const Duration(seconds: 30);
    final releaseClient = cancel._listen(() => client.close(force: true));
    final progress = _Progress(offer, onProgress);
    final ticker = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => progress.emit(),
    );
    _TransferJournal? journal;
    var stoppedForFailure = false;
    try {
      cancel.throwIfCancelled();
      journal = await _TransferJournal.open(
        checkpointFile ?? File('${destination.path}.transfer.jsonl'),
        destination,
        offer,
      );
      final completed = <int>{};
      var candidate = journal.completed.keys.toList();
      var nextCandidate = 0;
      progress.phase = FolderTransferPhase.verifying;
      await Future.wait(
        List.generate(parallelism.clamp(1, 4), (_) async {
          while (nextCandidate < candidate.length) {
            cancel.throwIfCancelled();
            final index = candidate[nextCandidate++];
            final length = _chunkLength(offer, index);
            final check = await _pool.run({
              'op': 'hashRange',
              'path': destination.path,
              'offset': index * offer.chunkSize,
              'length': length,
            }, cancellation: cancel);
            if (check['sha256'] == journal!.completed[index]) {
              completed.add(index);
              progress.verified += length;
              progress.resumed += length;
            }
            progress.phaseBytes += length;
          }
        }),
      );
      progress.phase = FolderTransferPhase.transferring;
      progress.phaseBytes = 0;
      progress.emit(force: true);
      final session = await _openSession(client, address, offer, cancel);
      var nextIndex = 0;
      final rateClock = Stopwatch()..start();
      var nextPermitMicros = 0;
      Object? failure;
      StackTrace? failureTrace;
      await Future.wait(
        List.generate(parallelism.clamp(1, 4), (_) async {
          try {
            while (nextIndex < offer.chunkCount) {
              cancel.throwIfCancelled();
              final index = nextIndex++;
              if (completed.contains(index)) continue;
              if (bytesPerSecondLimit > 0) {
                final permit = max(
                  nextPermitMicros,
                  rateClock.elapsedMicroseconds,
                );
                nextPermitMicros =
                    permit +
                    (_chunkLength(offer, index) *
                        1000000 ~/
                        bytesPerSecondLimit);
                while (rateClock.elapsedMicroseconds < permit) {
                  cancel.throwIfCancelled();
                  await Future<void>.delayed(
                    Duration(
                      microseconds: min(
                        100000,
                        permit - rateClock.elapsedMicroseconds,
                      ),
                    ),
                  );
                }
              }
              String? hash;
              for (
                var attempt = 0;
                attempt <= maxRetries.clamp(0, 8);
                attempt++
              ) {
                cancel.throwIfCancelled();
                if (!lan.isTrustedPeer(offer.senderId)) {
                  throw const FolderTransferException('unpaired');
                }
                try {
                  final bytes = await _downloadChunk(
                    client,
                    address,
                    offer,
                    index,
                    progress,
                    cancel,
                    session,
                  );
                  final result = await _pool.run({
                    'op': 'decryptWrite',
                    'path': destination.path,
                    'offset': index * offer.chunkSize,
                    'length': _chunkLength(offer, index),
                    'data': TransferableTypedData.fromList([bytes]),
                    'key': _fileKey(offer),
                    'aad': _aad(offer, index),
                  }, cancellation: cancel);
                  hash = result['sha256'] as String;
                  break;
                } catch (_) {
                  progress.inFlight.remove(index);
                  cancel.throwIfCancelled();
                  if (attempt >= maxRetries.clamp(0, 8)) rethrow;
                  await Future<void>.delayed(
                    Duration(milliseconds: 150 * (attempt + 1)),
                  );
                }
              }
              await journal!.record(index, hash!);
              completed.add(index);
              progress.inFlight.remove(index);
              progress.verified += _chunkLength(offer, index);
              progress.emit();
            }
          } catch (error, stack) {
            if (failure == null) {
              failure = error;
              failureTrace = stack;
              stoppedForFailure = error is! FolderTransferCancelled;
            }
            cancel.cancel();
          }
        }),
      );
      if (failure != null) Error.throwWithStackTrace(failure!, failureTrace!);
      cancel.throwIfCancelled();
      progress.phase = FolderTransferPhase.verifying;
      progress.phaseBytes = 0;
      progress.emit(force: true);
      final checksum = await _pool.run(
        {'op': 'hashFile', 'path': destination.path},
        cancellation: cancel,
        onProgress: (bytes) {
          progress.phaseBytes = bytes;
          progress.emit();
        },
      );
      progress.phaseBytes = offer.size;
      progress.emit(force: true);
      if (checksum['sha256'] != offer.sha256) {
        await journal.reset();
        throw const FolderTransferException('checksumMismatch');
      }
      progress.phase = FolderTransferPhase.completed;
      progress.phaseBytes = offer.size;
      progress.emit(force: true);
      return destination;
    } catch (error) {
      final wasCancelled =
          error is FolderTransferCancelled ||
          (cancel.isCancelled && !stoppedForFailure);
      progress.phase = wasCancelled
          ? FolderTransferPhase.cancelled
          : FolderTransferPhase.failed;
      progress.emit(force: true);
      if (wasCancelled && error is! FolderTransferCancelled) {
        throw const FolderTransferCancelled();
      }
      rethrow;
    } finally {
      ticker.cancel();
      releaseClient();
      removeCancel?.call();
      client.close(force: true);
      await journal?.close();
      _receiving.remove(offer.transferId);
      _receivingPeers.remove(offer.transferId);
    }
  }

  Future<Uint8List> _downloadChunk(
    HttpClient client,
    String host,
    FolderTransferOffer offer,
    int index,
    _Progress progress,
    FolderTransferCancellation cancel,
    _BulkSession session,
  ) async {
    final start = index * offer.chunkSize;
    final length = _chunkLength(offer, index);
    final request = await client.getUrl(
      Uri(
        scheme: 'http',
        host: host,
        port: offer.port,
        path: '/folder-transfer/v1/${offer.transferId}',
      ),
    );
    request.followRedirects = false;
    final nonce = base64Encode(_randomBytes(18));
    final sequence = ++session.sequence;
    request.headers
      ..set(HttpHeaders.rangeHeader, 'bytes=$start-${start + length - 1}')
      ..set('X-FPT-Device', lan.deviceId)
      ..set('X-FPT-Nonce', nonce)
      ..set('X-FPT-Session', session.id)
      ..set('X-FPT-Sequence', sequence)
      ..set('X-FPT-Proof', _proof(offer, index, nonce, session.id, sequence));
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.partialContent ||
        (response.contentLength != -1 &&
            response.contentLength != length + 28)) {
      throw const FolderTransferException('rangeRejected');
    }
    final bytes = Uint8List(length + 28);
    var offset = 0, lastPlain = 0;
    await for (final part in response.timeout(const Duration(seconds: 30))) {
      cancel.throwIfCancelled();
      if (offset + part.length > bytes.length) {
        throw const FolderTransferException('invalidChunk');
      }
      bytes.setRange(offset, offset + part.length, part);
      offset += part.length;
      final plainReceived = (offset - 12).clamp(0, length);
      progress.networkBytes += plainReceived - lastPlain;
      lastPlain = plainReceived;
      progress.inFlight[index] = plainReceived;
      progress.networkUpdate();
    }
    if (offset != bytes.length) {
      throw const FolderTransferException('incompleteChunk');
    }
    return bytes;
  }

  Future<_BulkSession> _openSession(
    HttpClient client,
    String host,
    FolderTransferOffer offer,
    FolderTransferCancellation cancel,
  ) async {
    cancel.throwIfCancelled();
    final nonce = base64Encode(_randomBytes(18));
    final request = await client.getUrl(
      Uri(
        scheme: 'http',
        host: host,
        port: offer.port,
        path: '/folder-transfer/v1/${offer.transferId}/session',
      ),
    );
    request.followRedirects = false;
    request.headers
      ..set('X-FPT-Device', lan.deviceId)
      ..set('X-FPT-Nonce', nonce)
      ..set('X-FPT-Proof', _bootstrapProof(offer, nonce));
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok) {
      throw const FolderTransferException('sessionRejected');
    }
    final bytes = <int>[];
    await for (final part in response.timeout(const Duration(seconds: 15))) {
      cancel.throwIfCancelled();
      if (bytes.length + part.length > 4096) {
        throw const FolderTransferException('invalidSession');
      }
      bytes.addAll(part);
    }
    if (bytes.length < 28) {
      throw const FolderTransferException('invalidSession');
    }
    final plain = await Chacha20.poly1305Aead().decrypt(
      SecretBox(
        bytes.sublist(12, bytes.length - 16),
        nonce: bytes.sublist(0, 12),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: SecretKey(_derive(offer, 'session')),
      aad: _bootstrapAad(offer),
    );
    final result = jsonDecode(utf8.decode(plain)) as Map;
    final id = result['session'];
    if (result['nonce'] != nonce ||
        id is! String ||
        id.length > 40 ||
        base64Decode(id).length != 24) {
      throw const FolderTransferException('invalidSession');
    }
    return _BulkSession(id);
  }

  Future<void> _serve(HttpRequest request) async {
    _activeRequests++;
    try {
      if (_closed ||
          _activeRequests > 12 ||
          request.method != 'GET' ||
          !_isLocal(request.connectionInfo?.remoteAddress)) {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      final pieces = request.uri.pathSegments;
      if ((pieces.length != 3 && pieces.length != 4) ||
          pieces[0] != 'folder-transfer' ||
          pieces[1] != 'v1') {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      final send = _sending[pieces[2]];
      final nonce = request.headers.value('X-FPT-Nonce');
      final proof = request.headers.value('X-FPT-Proof');
      final range = RegExp(
        r'^bytes=(\d+)-(\d+)$',
      ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (send == null ||
          !lan.isRunning ||
          !lan.isTrustedPeer(send.offer.receiverId) ||
          send.offer.expiresAt.isBefore(DateTime.now()) ||
          request.headers.value('X-FPT-Device') != send.offer.receiverId ||
          nonce == null ||
          nonce.length > 40 ||
          base64Decode(nonce).length != 18 ||
          proof == null ||
          send.cancellation.isCancelled) {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (pieces.length == 4 && pieces[3] == 'session') {
        if (!_constantEqual(proof, _bootstrapProof(send.offer, nonce)) ||
            send.bootstrapNonces.length >= 1024) {
          request.response.statusCode = HttpStatus.forbidden;
          return;
        }
        if (!send.bootstrapNonces.add(nonce)) {
          request.response.statusCode = HttpStatus.conflict;
          return;
        }
        final sessionId = base64Encode(_randomBytes(24));
        send.session = sessionId;
        send.replay = _BulkReplay();
        final box = await Chacha20.poly1305Aead().encrypt(
          utf8.encode(jsonEncode({'nonce': nonce, 'session': sessionId})),
          secretKey: SecretKey(_derive(send.offer, 'session')),
          aad: _bootstrapAad(send.offer),
        );
        final bytes = [...box.nonce, ...box.cipherText, ...box.mac.bytes];
        request.response.contentLength = bytes.length;
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'no-store',
        );
        request.response.add(bytes);
        return;
      }
      if (pieces.length != 3 || range == null) {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      final start = int.parse(range.group(1)!);
      final end = int.parse(range.group(2)!);
      final index = start ~/ send.offer.chunkSize;
      final session = request.headers.value('X-FPT-Session');
      final sequence = int.tryParse(
        request.headers.value('X-FPT-Sequence') ?? '',
      );
      if (start < 0 ||
          start >= send.offer.size ||
          start % send.offer.chunkSize != 0 ||
          end != start + _chunkLength(send.offer, index) - 1 ||
          session == null ||
          session != send.session ||
          sequence == null ||
          sequence <= 0 ||
          !_constantEqual(
            proof,
            _proof(send.offer, index, nonce, session, sequence),
          )) {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (!send.replay.accept(sequence)) {
        request.response.statusCode = HttpStatus.conflict;
        return;
      }
      final stat = await send.file.stat();
      if (stat.size != send.offer.size || stat.modified != send.modified) {
        request.response.statusCode = HttpStatus.conflict;
        return;
      }
      final encrypted = await _pool.run({
        'op': 'readEncrypt',
        'path': send.file.path,
        'offset': start,
        'length': _chunkLength(send.offer, index),
        'key': _fileKey(send.offer),
        'aad': _aad(send.offer, index),
      }, cancellation: send.cancellation);
      if (send.cancellation.isCancelled ||
          !lan.isTrustedPeer(send.offer.receiverId)) {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      final bytes = (encrypted['data'] as TransferableTypedData)
          .materialize()
          .asUint8List();
      request.response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = bytes.length;
      request.response.headers
        ..contentType = ContentType.binary
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${send.offer.size}',
        );
      request.response.add(bytes);
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
      _activeRequests--;
    }
  }

  void _checkTrust() {
    for (final entry in _preparing.values.toList()) {
      if (!lan.isRunning || !lan.isTrustedPeer(entry.$1)) entry.$2.cancel();
    }
    for (final entry in _sending.entries.toList()) {
      if (!lan.isRunning ||
          !lan.isTrustedPeer(entry.value.offer.receiverId) ||
          entry.value.cancellation.isCancelled ||
          entry.value.offer.expiresAt.isBefore(DateTime.now())) {
        cancelSend(entry.key);
      }
    }
    for (final entry in _receiving.entries.toList()) {
      if (!lan.isRunning ||
          !lan.isTrustedPeer(_receivingPeers[entry.key] ?? '')) {
        entry.value.cancel();
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiry?.cancel();
    lan.removeListener(_checkTrust);
    for (final id in _sending.keys.toList()) {
      cancelSend(id);
    }
    for (final cancel in _receiving.values.toList()) {
      cancel.cancel();
    }
    for (final pending in _preparing.values.toList()) {
      pending.$2.cancel();
    }
    await _server?.close(force: true);
    _server = null;
    await _pool.close();
  }
}

class _SendCapability {
  _SendCapability(
    this.offer,
    this.file,
    this.modified,
    this.cancellation,
    this.detachParent,
  );
  final FolderTransferOffer offer;
  final File file;
  final DateTime modified;
  final FolderTransferCancellation cancellation;
  final void Function()? detachParent;
  String? session;
  _BulkReplay replay = _BulkReplay();
  final Set<String> bootstrapNonces = {};
}

class _BulkSession {
  _BulkSession(this.id);
  final String id;
  int sequence = 0;
}

class _BulkReplay {
  int highest = 0;
  final Set<int> seen = {};
  bool accept(int value) {
    if (value > 9007199254740991 ||
        value <= highest - 4096 ||
        !seen.add(value)) {
      return false;
    }
    if (value > highest) {
      highest = value;
      seen.removeWhere((n) => n <= highest - 4096);
    }
    return true;
  }
}

class _Progress {
  _Progress(this.offer, this.callback);
  final FolderTransferOffer offer;
  final void Function(FolderTransferProgress)? callback;
  final stopwatch = Stopwatch()..start();
  final Map<int, int> inFlight = {};
  final Queue<(int, int)> samples = Queue();
  FolderTransferPhase phase = FolderTransferPhase.connecting;
  int verified = 0, resumed = 0, phaseBytes = 0, networkBytes = 0;
  int lastEmit = -1000000;
  void networkUpdate() {
    final now = stopwatch.elapsedMicroseconds;
    samples.add((now, networkBytes));
    while (samples.length > 1 && samples.first.$1 < now - 2000000) {
      samples.removeFirst();
    }
  }

  void emit({bool force = false}) {
    final now = stopwatch.elapsedMicroseconds;
    if (!force && now - lastEmit < 100000) return;
    lastEmit = now;
    final bytes = min(
      offer.size,
      verified + inFlight.values.fold<int>(0, (a, b) => a + b),
    );
    final speed = samples.isEmpty || now - samples.last.$1 > 2000000
        ? 0.0
        : (networkBytes - samples.first.$2) *
              1000000 /
              max(100000, now - samples.first.$1);
    callback?.call(
      FolderTransferProgress(
        transferId: offer.transferId,
        phase: phase,
        totalBytes: offer.size,
        receivedBytes: bytes,
        verifiedBytes: verified,
        resumedBytes: resumed,
        phaseBytes: phase == FolderTransferPhase.transferring
            ? bytes
            : phaseBytes,
        bytesPerSecond: speed,
        elapsed: stopwatch.elapsed,
      ),
    );
  }
}

class _TransferJournal {
  _TransferJournal(
    this.file,
    this.destination,
    this.offer,
    this.writer,
    this.completed,
  );
  final File file, destination;
  final FolderTransferOffer offer;
  final RandomAccessFile writer;
  final Map<int, String> completed;
  Future<void> _tail = Future.value();
  static Map<String, dynamic> _header(
    File destination,
    FolderTransferOffer o,
  ) => {
    'version': 1,
    'transferId': o.transferId,
    'senderId': o.senderId,
    'receiverId': o.receiverId,
    'sha256': o.sha256,
    'size': o.size,
    'chunkSize': o.chunkSize,
    'destination': destination.absolute.path,
  };
  static Future<_TransferJournal> open(
    File file,
    File destination,
    FolderTransferOffer offer,
  ) async {
    final completed = <int, String>{};
    final expected = _header(destination, offer);
    var valid = false;
    if (await file.exists()) {
      if (await file.length() > 192 * 1024 * 1024) {
        throw const FolderTransferException('invalidCheckpoint');
      }
      var first = true, count = 0;
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (++count > 1000002 || line.length > 4096) {
          throw const FolderTransferException('invalidCheckpoint');
        }
        if (first) {
          first = false;
          valid = jsonEncode(jsonDecode(line)) == jsonEncode(expected);
          if (!valid) throw const FolderTransferException('checkpointMismatch');
        } else {
          try {
            final record = jsonDecode(line) as Map;
            final index = record['index'];
            final sha = record['sha256'];
            if (index is int &&
                index >= 0 &&
                index < offer.chunkCount &&
                sha is String &&
                RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
              completed[index] = sha;
            }
          } catch (_) {
            /* A crash may leave the final journal line partial. */
          }
        }
      }
    }
    final exists = await destination.exists();
    if (!valid && exists && await destination.length() != 0) {
      throw const FolderTransferException('destinationExists');
    }
    await destination.parent.create(recursive: true);
    if (!exists || !valid || await destination.length() != offer.size) {
      completed.clear();
      final output = await destination.open(mode: FileMode.write);
      try {
        await output.truncate(offer.size);
        await output.flush();
      } finally {
        await output.close();
      }
    }
    await file.parent.create(recursive: true);
    if (!valid) {
      await file.writeAsString('${jsonEncode(expected)}\n', flush: true);
    }
    final writer = await file.open(mode: FileMode.append);
    final length = await writer.length();
    if (length > 0) {
      await writer.setPosition(length - 1);
      if (await writer.readByte() != 10) {
        await writer.setPosition(length);
        await writer.writeByte(10);
        await writer.flush();
      }
    }
    await writer.setPosition(await writer.length());
    return _TransferJournal(file, destination, offer, writer, completed);
  }

  Future<void> record(int index, String sha) => _tail = _tail.then((_) async {
    await writer.writeString(
      '${jsonEncode({'index': index, 'sha256': sha})}\n',
    );
    await writer.flush();
    completed[index] = sha;
  });
  Future<void> reset() => _tail = _tail.then((_) async {
    await writer.truncate(0);
    await writer.setPosition(0);
    await writer.writeString('${jsonEncode(_header(destination, offer))}\n');
    await writer.flush();
    completed.clear();
  });
  Future<void> close() async {
    try {
      await _tail;
    } finally {
      await writer.close();
    }
  }
}

int _chunkLength(FolderTransferOffer offer, int index) =>
    min(offer.chunkSize, offer.size - index * offer.chunkSize);
List<int> _aad(FolderTransferOffer offer, int index) => utf8.encode(
  jsonEncode([
    'FluentFolderTransfer',
    1,
    offer.cipher,
    offer.transferId,
    offer.senderId,
    offer.receiverId,
    offer.sha256,
    offer.size,
    index * offer.chunkSize,
    _chunkLength(offer, index),
  ]),
);
List<int> _derive(FolderTransferOffer offer, String purpose) =>
    digest.Hmac(digest.sha256, base64Decode(offer.sessionKey))
        .convert(
          utf8.encode('fluent-folder-transfer/v1/${offer.cipher}/$purpose'),
        )
        .bytes;
List<int> _fileKey(FolderTransferOffer offer) => _derive(offer, 'file');
String _proof(
  FolderTransferOffer offer,
  int index,
  String nonce,
  String session,
  int sequence,
) => base64Encode(
  digest.Hmac(digest.sha256, _derive(offer, 'auth')).convert([
    ..._aad(offer, index),
    ...utf8.encode('\n$nonce\n$session\n$sequence'),
  ]).bytes,
);
List<int> _bootstrapAad(FolderTransferOffer offer) => utf8.encode(
  jsonEncode([
    'FluentFolderTransferSession',
    1,
    offer.cipher,
    offer.transferId,
    offer.senderId,
    offer.receiverId,
    offer.sha256,
  ]),
);
String _bootstrapProof(FolderTransferOffer offer, String nonce) => base64Encode(
  digest.Hmac(
    digest.sha256,
    _derive(offer, 'auth'),
  ).convert([..._bootstrapAad(offer), ...utf8.encode('\n$nonce')]).bytes,
);
bool _constantEqual(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

List<int> _randomBytes(int size) {
  final random = Random.secure();
  return List.generate(size, (_) => random.nextInt(256));
}

String _randomHex(int size) =>
    _randomBytes(size).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
bool _isLocal(InternetAddress? address) {
  if (address == null) return false;
  if (address.isLoopback || address.isLinkLocal) return true;
  final bytes = address.rawAddress;
  return bytes.length == 4
      ? bytes[0] == 10 ||
            (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168)
      : bytes.length == 16 && (bytes[0] & 0xfe) == 0xfc;
}

Future<String> _localAddress(String host) async {
  if (host.isEmpty) throw const FolderTransferException('peerUnavailable');
  final parsed = InternetAddress.tryParse(host);
  final addresses = parsed == null
      ? await InternetAddress.lookup(host).timeout(const Duration(seconds: 8))
      : [parsed];
  for (final address in addresses) {
    if (_isLocal(address)) return address.address;
  }
  throw const FolderTransferException('nonLocalAddress');
}

class _TransferWorkers {
  _TransferWorkers(this.count);
  final int count;
  final List<_TransferWorker> workers = [];
  final Queue<_Work> queue = Queue();
  Future<void>? _starting;
  bool _closed = false;
  Future<void> start() => _starting ??= Future.wait(
    List.generate(count, (_) async {
      final worker = await _TransferWorker.spawn();
      if (_closed) {
        worker.close();
      } else {
        workers.add(worker);
      }
    }),
  ).then((_) {});
  Future<Map<String, dynamic>> run(
    Map<String, dynamic> task, {
    FolderTransferCancellation? cancellation,
    void Function(int)? onProgress,
  }) async {
    await start();
    if (_closed) throw const FolderTransferCancelled();
    cancellation?.throwIfCancelled();
    if (queue.length >= 64) throw const FolderTransferException('workerBusy');
    final work = _Work(task, cancellation, onProgress);
    queue.add(work);
    _pump();
    return work.result.future;
  }

  void _pump() {
    for (final worker in workers) {
      if (worker.busy || queue.isEmpty) continue;
      final work = queue.removeFirst();
      worker
          .execute(work)
          .then(
            (result) {
              work.result.complete(result);
              _pump();
            },
            onError: (Object error, StackTrace stack) {
              work.result.completeError(error, stack);
              _pump();
            },
          );
    }
  }

  Future<void> close() async {
    _closed = true;
    while (queue.isNotEmpty) {
      queue.removeFirst().result.completeError(const FolderTransferCancelled());
    }
    for (final worker in workers) {
      worker.close();
    }
    workers.clear();
  }
}

class _Work {
  _Work(this.task, this.cancellation, this.onProgress);
  final Map<String, dynamic> task;
  final FolderTransferCancellation? cancellation;
  final void Function(int)? onProgress;
  final result = Completer<Map<String, dynamic>>();
}

class _TransferWorker {
  _TransferWorker(this.port);
  final ReceivePort port;
  late Isolate isolate;
  SendPort? sender;
  final ready = Completer<void>();
  Completer<Map<String, dynamic>>? pending;
  void Function(int)? progress;
  int sequence = 0;
  bool busy = false;
  static Future<_TransferWorker> spawn() async {
    final worker = _TransferWorker(ReceivePort());
    worker.port.listen(worker._receive);
    worker.isolate = await Isolate.spawn(
      _transferWorkerMain,
      worker.port.sendPort,
      onError: worker.port.sendPort,
      onExit: worker.port.sendPort,
    );
    await worker.ready.future.timeout(const Duration(seconds: 15));
    return worker;
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      sender = message;
      ready.complete();
    } else if (message is Map) {
      if (message.containsKey('progress')) {
        progress?.call(message['progress'] as int);
      } else {
        final waiter = pending;
        pending = null;
        if (waiter != null && !waiter.isCompleted) {
          if (message['error'] != null) {
            waiter.completeError(
              message['error'] == 'cancelled'
                  ? const FolderTransferCancelled()
                  : FolderTransferException(
                      'workerFailure',
                      message['error'] as String,
                    ),
            );
          } else {
            waiter.complete(Map<String, dynamic>.from(message));
          }
        }
      }
    } else {
      final waiter = pending;
      pending = null;
      if (waiter != null && !waiter.isCompleted) {
        waiter.completeError(const FolderTransferException('workerExited'));
      }
      if (!ready.isCompleted) {
        ready.completeError(const FolderTransferException('workerExited'));
      }
    }
  }

  Future<Map<String, dynamic>> execute(_Work work) async {
    busy = true;
    final id = ++sequence;
    final waiter = Completer<Map<String, dynamic>>();
    pending = waiter;
    progress = work.onProgress;
    final remove = work.cancellation?._listen(
      () => sender?.send({'cancel': id}),
    );
    sender!.send({...work.task, 'id': id});
    try {
      return await waiter.future;
    } finally {
      remove?.call();
      progress = null;
      busy = false;
    }
  }

  void close() {
    isolate.kill(priority: Isolate.immediate);
    final waiter = pending;
    pending = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(const FolderTransferCancelled());
    }
    port.close();
  }
}

class _DigestSink implements Sink<digest.Digest> {
  digest.Digest? value;
  @override
  void add(digest.Digest data) {
    value = data;
  }

  @override
  void close() {}
}

@pragma('vm:entry-point')
void _transferWorkerMain(SendPort output) {
  final input = ReceivePort();
  final cancelled = <int>{};
  final cipher = Chacha20.poly1305Aead();
  output.send(input.sendPort);
  input.listen((dynamic raw) async {
    final task = Map<String, dynamic>.from(raw as Map);
    if (task['cancel'] case final int id) {
      cancelled.add(id);
      return;
    }
    final id = task['id'] as int;
    void check() {
      if (cancelled.contains(id)) throw const FolderTransferCancelled();
    }

    try {
      check();
      final op = task['op'];
      if (op == 'hashFile') {
        final sink = _DigestSink();
        final converter = digest.sha256.startChunkedConversion(sink);
        var bytes = 0;
        final timer = Stopwatch()..start();
        var last = -100;
        await for (final chunk in File(task['path'] as String).openRead()) {
          check();
          converter.add(chunk);
          bytes += chunk.length;
          if (timer.elapsedMilliseconds - last >= 100) {
            last = timer.elapsedMilliseconds;
            output.send({'progress': bytes});
          }
        }
        converter.close();
        output.send({'progress': bytes});
        output.send({'sha256': sink.value.toString()});
      } else if (op == 'hashRange' || op == 'readEncrypt') {
        final file = await File(task['path'] as String).open();
        Uint8List bytes;
        try {
          await file.setPosition(task['offset'] as int);
          bytes = await file.read(task['length'] as int);
        } finally {
          await file.close();
        }
        check();
        if (bytes.length != task['length']) {
          throw const FolderTransferException('sourceChanged');
        }
        if (op == 'hashRange') {
          output.send({'sha256': digest.sha256.convert(bytes).toString()});
        } else {
          final box = await cipher.encrypt(
            bytes,
            secretKey: SecretKey(List<int>.from(task['key'] as List)),
            aad: List<int>.from(task['aad'] as List),
          );
          check();
          output.send({
            'data': TransferableTypedData.fromList([
              Uint8List.fromList(box.nonce),
              Uint8List.fromList(box.cipherText),
              Uint8List.fromList(box.mac.bytes),
            ]),
          });
        }
      } else if (op == 'decryptWrite') {
        final bytes = (task['data'] as TransferableTypedData)
            .materialize()
            .asUint8List();
        if (bytes.length != (task['length'] as int) + 28) {
          throw const FolderTransferException('invalidChunk');
        }
        final plain = await cipher.decrypt(
          SecretBox(
            Uint8List.sublistView(bytes, 12, bytes.length - 16),
            nonce: Uint8List.sublistView(bytes, 0, 12),
            mac: Mac(Uint8List.sublistView(bytes, bytes.length - 16)),
          ),
          secretKey: SecretKey(List<int>.from(task['key'] as List)),
          aad: List<int>.from(task['aad'] as List),
        );
        check();
        final file = await File(
          task['path'] as String,
        ).open(mode: FileMode.append);
        try {
          await file.setPosition(task['offset'] as int);
          await file.writeFrom(plain);
          await file.flush();
        } finally {
          await file.close();
        }
        check();
        output.send({'sha256': digest.sha256.convert(plain).toString()});
      } else {
        throw const FolderTransferException('invalidOperation');
      }
    } catch (error) {
      output.send({
        'error': error is FolderTransferCancelled
            ? 'cancelled'
            : error.toString(),
      });
    } finally {
      cancelled.remove(id);
    }
  });
}
