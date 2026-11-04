import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypt;
import 'package:path/path.dart' as p;

import '../portable_transfer/portable_transfer_models.dart';
import 'progress_sync_lan.dart';

/// Original files are streamed through authenticated encrypted frames. Session
/// keys travel only inside the paired control channel, never on the HTTP wire.
class FolderDirectTransport {
  FolderDirectTransport(this.lan);
  final ProgressSyncLan lan;
  static const protocolVersion = 3;
  static const _maxFrameBytes = 1024 * 1024;
  static final _cipher = crypt.AesGcm.with256bits();
  HttpServer? _server;
  Future<HttpServer>? _starting;
  final Map<String, _DirectSource> _sources = {};
  final Map<String, HttpClient> _clients = {};
  bool _closed = false, _listening = false;

  Future<Map<String, dynamic>> prepare({
    required String id,
    required String peerId,
    required PortableFolderFiles plan,
    required Future<Map<String, dynamic>> Function(Map<String, String>)
    complete,
  }) async {
    if (!lan.isTrustedPeer(peerId)) throw const FormatException('设备连接已失效');
    _server ??= await (_starting ??= HttpServer.bind(
      InternetAddress.anyIPv4,
      0,
    ));
    if (_closed) {
      await _server?.close(force: true);
      _server = null;
      throw const FormatException('传输已停止');
    }
    if (!_listening) {
      _listening = true;
      _server!.listen((request) => unawaited(_serve(request)));
    }
    final random = Random.secure();
    final token = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    _sources[id] = _DirectSource(
      peerId,
      token,
      crypt.SecretKey(key),
      lan.authorizationEpoch(peerId),
      plan,
      complete,
    );
    return {
      'protocol': protocolVersion,
      'id': id,
      'port': _server!.port,
      'token': token,
      'key': base64Encode(key),
      'size': plan.totalBytes,
    };
  }

  static bool safePath(String path) =>
      path.isNotEmpty &&
      path.length <= 2048 &&
      !path.contains('\\') &&
      !path.contains(':') &&
      !path.startsWith('/') &&
      !path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..') &&
      !RegExp(r'[\x00-\x1f]').hasMatch(path);

  static List<int> _aad(
    String id,
    String action,
    String direction, [
    String request = '',
    int? frame,
  ]) => utf8.encode(
    jsonEncode([
      'FluentPlayer.Direct.v3',
      id,
      action,
      direction,
      request,
      frame,
    ]),
  );

  static Future<List<int>> _seal(
    List<int> plain,
    crypt.SecretKey key,
    List<int> aad,
  ) async =>
      (await _cipher.encrypt(plain, secretKey: key, aad: aad)).concatenation();

  static Future<List<int>> _open(
    List<int> bytes,
    crypt.SecretKey key,
    List<int> aad,
  ) async {
    if (bytes.length < 28) throw const FormatException('传输记录不完整');
    try {
      return await _cipher.decrypt(
        crypt.SecretBox.fromConcatenation(
          bytes,
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: key,
        aad: aad,
      );
    } on crypt.SecretBoxAuthenticationError {
      throw const FormatException('传输内容校验失败，请重试');
    }
  }

  bool _validSource(String id, _DirectSource source) =>
      !_closed &&
      identical(_sources[id], source) &&
      lan.isRunning &&
      lan.isTrustedPeer(source.peerId) &&
      lan.authorizationEpoch(source.peerId) == source.authorizationEpoch;

  Future<void> _serve(HttpRequest request) async {
    _DirectSource? source;
    String? id, action, requestNonce;
    try {
      final parts = request.uri.pathSegments;
      if (parts.length != 3 ||
          parts.first != 'direct' ||
          request.method != 'POST') {
        throw const FormatException('传输请求无效');
      }
      id = parts[1];
      action = parts[2];
      source = _sources[id];
      if (source == null ||
          !_validSource(id, source) ||
          request.headers.value('X-Fluent-Transfer') != source.token) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      final sealed = await _readBytes(request, 32 * 1024 * 1024);
      final value = _object(
        await _open(sealed, source.key, _aad(id, action, 'request')),
      );
      requestNonce = base64Encode(sealed.sublist(0, 12));
      if (!_validSource(id, source) ||
          source.requests.length >= 400010 ||
          !source.requests.add(requestNonce)) {
        throw const FormatException('传输请求已失效');
      }
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.headers.contentType = ContentType.binary;
      switch (action) {
        case 'manifest':
          await _respond(
            request.response,
            {
              'manifest': source.plan.manifest,
              'files': [
                for (final file in source.plan.files)
                  {
                    'path': file.relativePath,
                    'size': file.size,
                    'modified': file.modifiedMs,
                  },
              ],
            },
            source.key,
            _aad(id, action, 'response', requestNonce),
          );
        case 'verify':
          final index = value['index'], length = value['length'];
          if (index is! int ||
              index < 0 ||
              index >= source.plan.files.length ||
              length is! int ||
              length < 0 ||
              length > source.plan.files[index].size) {
            throw const FormatException('文件请求无效');
          }
          final file = source.plan.files[index];
          await _unchanged(file);
          final hash = await _hashFile(
            File(file.path),
            end: length,
            check: () {
              if (!_validSource(id!, source!)) {
                throw const FormatException('传输已暂停');
              }
            },
          );
          await _unchanged(file);
          if (!_validSource(id, source)) throw const FormatException('传输已暂停');
          if (length == file.size) source.hashes[file.relativePath] = hash;
          await _respond(
            request.response,
            {'sha256': hash},
            source.key,
            _aad(id, action, 'response', requestNonce),
          );
        case 'file':
          final index = value['index'], offset = value['offset'];
          if (index is! int ||
              index < 0 ||
              index >= source.plan.files.length ||
              offset is! int) {
            throw const FormatException('文件请求无效');
          }
          final file = source.plan.files[index];
          if (offset < 0 || offset > file.size) {
            throw const FormatException('文件位置无效');
          }
          await _unchanged(file);
          var frame = 0;
          final result = _DigestResult(), prefix = _DigestResult();
          final digest = sha256.startChunkedConversion(result);
          final prefixDigest = sha256.startChunkedConversion(prefix);
          if (offset > 0) {
            await for (final bytes in File(file.path).openRead(0, offset)) {
              if (!_validSource(id, source)) {
                throw const FormatException('传输已暂停');
              }
              digest.add(bytes);
              prefixDigest.add(bytes);
            }
          }
          prefixDigest.close();
          if (offset > 0 && value['prefixHash'] != prefix.value.toString()) {
            digest.close();
            throw const FormatException('续传文件已损坏，请重试');
          }
          request.response.bufferOutput = false;
          await for (final bytes in File(file.path).openRead(offset)) {
            if (!_validSource(id, source)) throw const FormatException('传输已暂停');
            digest.add(bytes);
            final encrypted = await _seal(
              [1, ...bytes],
              source.key,
              _aad(id, action, 'frame', requestNonce, frame++),
            );
            if (!_validSource(id, source)) throw const FormatException('传输已暂停');
            final size = ByteData(4)..setUint32(0, encrypted.length);
            request.response.add(size.buffer.asUint8List());
            request.response.add(encrypted);
            // Keep disk reads and encryption behind the socket's backpressure.
            // A slow receiver must not queue an entire video in memory.
            await request.response.flush();
            if (!_validSource(id, source)) throw const FormatException('传输已暂停');
          }
          digest.close();
          await _unchanged(file);
          if (!_validSource(id, source)) throw const FormatException('传输已暂停');
          final hash = result.value.toString();
          source.hashes[file.relativePath] = hash;
          final trailer = await _seal(
            [
              2,
              ...utf8.encode(jsonEncode({'sha256': hash, 'size': file.size})),
            ],
            source.key,
            _aad(id, action, 'frame', requestNonce, frame),
          );
          request.response.add(
            (ByteData(4)..setUint32(0, trailer.length)).buffer.asUint8List(),
          );
          request.response.add(trailer);
          await request.response.close();
        case 'complete':
          final hashes = Map<String, String>.from(value['hashes'] as Map);
          if (hashes.length != source.plan.files.length) {
            throw const FormatException('文件尚未收齐');
          }
          for (final file in source.plan.files) {
            await _unchanged(file);
            final expected = source.hashes[file.relativePath];
            if (expected == null || hashes[file.relativePath] != expected) {
              throw const FormatException('文件内容与来源不一致，请重试');
            }
          }
          if (!_validSource(id, source)) throw const FormatException('传输已暂停');
          source.result ??= source.complete(Map.of(source.hashes));
          try {
            final result = await source.result!;
            if (!_validSource(id, source)) throw const FormatException('传输已暂停');
            await _respond(
              request.response,
              result,
              source.key,
              _aad(id, action, 'response', requestNonce),
            );
          } catch (_) {
            source.result = null;
            rethrow;
          }
        default:
          throw const FormatException('传输请求无效');
      }
    } catch (_) {
      // Once streaming starts the status line cannot be changed. Still close
      // the body so the receiver can reject the missing authenticated trailer.
      try {
        request.response.statusCode = 409;
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {
        try {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
        } catch (_) {}
      }
    }
  }

  static Future<void> _unchanged(PortableFolderFile file) async {
    final stat = await File(file.path).stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size != file.size ||
        stat.modified.millisecondsSinceEpoch != file.modifiedMs) {
      throw const FormatException('源文件已变化，请重新发送');
    }
  }

  Future<Map<String, dynamic>> receive({
    required String id,
    required String peerId,
    required String host,
    required Map<String, dynamic> offer,
    required Directory directory,
    required bool Function() isCancelled,
    required void Function(int completed, int total, double speed) onProgress,
    void Function()? onFilesReceived,
    int bytesPerSecondLimit = 0,
  }) async {
    if (offer['protocol'] != protocolVersion) {
      throw const FormatException('请更新另一台设备后使用加密文件同步');
    }
    final port = offer['port'], token = offer['token'];
    List<int> rawKey;
    try {
      rawKey = base64Decode(offer['key'] as String);
    } catch (_) {
      throw const FormatException('传输密钥无效');
    }
    if (offer['id'] != id ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        token is! String ||
        token.length < 32 ||
        token.length > 100 ||
        rawKey.length != 32 ||
        !lan.isTrustedPeer(peerId)) {
      throw const FormatException('传输信息无效');
    }
    final key = crypt.SecretKey(rawKey);
    final authorizationEpoch = lan.authorizationEpoch(peerId);
    final addresses = await InternetAddress.lookup(host);
    if (!addresses.any(_local)) throw const FormatException('请使用局域网地址');
    final address = addresses.firstWhere(_local).address;
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..maxConnectionsPerHost = 4;
    client.connectionTimeout = const Duration(seconds: 8);
    _clients[id]?.close(force: true);
    _clients[id] = client;
    void check() {
      if (_closed ||
          isCancelled() ||
          !lan.isRunning ||
          !lan.isTrustedPeer(peerId) ||
          lan.authorizationEpoch(peerId) != authorizationEpoch) {
        throw const FormatException('传输已暂停');
      }
    }

    Future<(HttpClientResponse, String)> request(
      String action,
      Map<String, dynamic> body,
    ) async {
      check();
      final uri = Uri(
        scheme: 'http',
        host: address,
        port: port,
        path: '/direct/$id/$action',
      );
      final bytes = await _seal(
        utf8.encode(jsonEncode(body)),
        key,
        _aad(id, action, 'request'),
      );
      check();
      final nonce = base64Encode(bytes.sublist(0, 12));
      final outgoing = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 10));
      outgoing.headers.set('X-Fluent-Transfer', token);
      outgoing.headers.contentType = ContentType.binary;
      outgoing.followRedirects = false;
      outgoing.contentLength = bytes.length;
      outgoing.add(bytes);
      final response = await outgoing.close().timeout(
        const Duration(minutes: 2),
      );
      check();
      if (response.statusCode != 200) {
        await response.listen((_) {}).cancel();
        throw const FormatException('源文件已变化或连接中断，请重试');
      }
      return (response, nonce);
    }

    Future<Map<String, dynamic>> jsonRequest(
      String action,
      Map<String, dynamic> body,
    ) async {
      final (response, nonce) = await request(action, body);
      final bytes = await _readBytes(
        response.timeout(const Duration(seconds: 30)),
        32 * 1024 * 1024,
      );
      final result = _object(
        await _open(bytes, key, _aad(id, action, 'response', nonce)),
      );
      check();
      return result;
    }

    try {
      final description = await jsonRequest('manifest', {});
      final files = (description['files'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      if (files.length > 100000) throw const FormatException('文件过多');
      final paths = <String>{};
      var total = 0;
      for (final file in files) {
        final path = file['path'], size = file['size'];
        if (path is! String ||
            !safePath(path) ||
            !paths.add(path.toLowerCase()) ||
            size is! int ||
            size < 0) {
          throw const FormatException('文件目录无效');
        }
        total += size;
      }
      if (total != offer['size']) throw const FormatException('文件大小已变化');
      await directory.create(recursive: true);
      final partials = Directory(p.join(directory.parent.path, 'direct-parts'));
      final journal = File(
        p.join(directory.parent.path, 'direct-receipt.json'),
      );
      final signature = sha256
          .convert(utf8.encode(jsonEncode(files)))
          .toString();
      final hashes = <String, String>{};
      var trustPartials = false;
      if (await journal.exists()) {
        Object? saved;
        try {
          saved = jsonDecode(await journal.readAsString());
        } catch (_) {}
        if (saved is Map) {
          if (saved['schemaVersion'] is int &&
              (saved['schemaVersion'] as int) > 1) {
            throw const FormatException('接收记录来自更新的版本，请更新应用后继续');
          }
          if ((saved['schemaVersion'] == null || saved['schemaVersion'] == 1) &&
              saved['signature'] == signature &&
              saved['hashes'] is Map) {
            hashes.addAll(Map<String, String>.from(saved['hashes'] as Map));
            trustPartials = true;
          }
        }
      }
      // Old receipts identify a resource, not its integrity: every resumed byte
      // is checked against the live source before publication.
      if (!trustPartials && await partials.exists()) {
        await partials.delete(recursive: true);
      }
      await partials.create(recursive: true);
      Future<void> writes = Future<void>.value();
      Future<void> save() {
        final encoded = jsonEncode({
          'schemaVersion': 1,
          'signature': signature,
          'hashes': hashes,
        });
        final write = writes.then((_) async {
          final tmp = File('${journal.path}.next');
          await tmp.writeAsString(encoded, flush: true);
          await tmp.rename(journal.path);
        });
        writes = write.catchError((_) {});
        return write;
      }

      await save();
      var next = 0, durable = 0, networkBytes = 0, recoveredBytes = 0;
      final clock = Stopwatch()..start();
      final speedWindow = TransferSpeedWindow();
      void emit() => onProgress(
        durable,
        total,
        speedWindow.add(clock.elapsedMicroseconds, durable - recoveredBytes),
      );
      final ticker = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => emit(),
      );
      try {
        await Future.wait(
          List.generate(min(4, max(1, files.length)), (_) async {
            while (next < files.length) {
              check();
              final index = next++, record = files[index];
              final path = record['path'] as String,
                  size = record['size'] as int;
              final target = File(
                p.joinAll([directory.path, ...path.split('/')]),
              );
              if (hashes.containsKey(path) &&
                  await target.exists() &&
                  await target.length() == size) {
                final local = await _hashFile(target, check: check);
                final remote = await jsonRequest('verify', {
                  'index': index,
                  'length': size,
                });
                if (local == remote['sha256']) {
                  hashes[path] = local;
                  durable += size;
                  recoveredBytes += size;
                  continue;
                }
              }
              hashes.remove(path);
              final partial = File(p.join(partials.path, '$index.part'));
              var offset = await partial.exists() ? await partial.length() : 0;
              if (offset > size) {
                await partial.delete();
                offset = 0;
              }
              var prefixHash = '';
              if (offset > 0) {
                prefixHash = await _hashFile(partial, check: check);
                final remote = await jsonRequest('verify', {
                  'index': index,
                  'length': offset,
                });
                if (prefixHash != remote['sha256']) {
                  await partial.delete();
                  offset = 0;
                  prefixHash = '';
                }
              }
              final result = _DigestResult();
              final digest = sha256.startChunkedConversion(result);
              if (offset > 0) {
                await for (final bytes in partial.openRead()) {
                  check();
                  digest.add(bytes);
                }
                recoveredBytes += offset;
                durable += offset;
              }
              final output = await partial.open(mode: FileMode.append);
              var pending = 0;
              final flushClock = Stopwatch()..start();
              var sawEnd = false, digestClosed = false;
              try {
                final (response, nonce) = await request('file', {
                  'index': index,
                  'offset': offset,
                  'prefixHash': prefixHash,
                });
                var frame = 0;
                await for (final encrypted in _frames(
                  response.timeout(const Duration(seconds: 30)),
                )) {
                  check();
                  final plain = await _open(
                    encrypted,
                    key,
                    _aad(id, 'file', 'frame', nonce, frame++),
                  );
                  check();
                  if (sawEnd || plain.isEmpty) {
                    throw const FormatException('文件帧无效');
                  }
                  if (plain.first == 2) {
                    final trailer = _object(plain.sublist(1));
                    digest.close();
                    digestClosed = true;
                    if (offset != size ||
                        trailer['size'] != size ||
                        trailer['sha256'] != result.value.toString()) {
                      throw const FormatException('文件内容与来源不一致，请重试');
                    }
                    sawEnd = true;
                    continue;
                  }
                  if (plain.first != 1) throw const FormatException('文件帧无效');
                  final bytes = plain.sublist(1);
                  offset += bytes.length;
                  if (offset > size) throw const FormatException('文件长度不符');
                  digest.add(bytes);
                  await output.writeFrom(bytes);
                  pending += bytes.length;
                  networkBytes += bytes.length;
                  if (pending >= 8 * 1024 * 1024 ||
                      flushClock.elapsedMilliseconds >= 180) {
                    await output.flush();
                    durable += pending;
                    pending = 0;
                    flushClock.reset();
                  }
                  if (bytesPerSecondLimit > 0) {
                    final due = networkBytes * 1000000 ~/ bytesPerSecondLimit;
                    while (clock.elapsedMicroseconds < due) {
                      check();
                      await Future<void>.delayed(
                        Duration(
                          microseconds: min(
                            100000,
                            due - clock.elapsedMicroseconds,
                          ),
                        ),
                      );
                    }
                  }
                }
                if (!sawEnd) throw const FormatException('文件未传完或校验未完成');
                await output.flush();
                durable += pending;
              } finally {
                await output.close();
                if (!digestClosed) digest.close();
              }
              check();
              await target.parent.create(recursive: true);
              if (await target.exists()) await target.delete();
              await partial.rename(target.path);
              hashes[path] = result.value.toString();
              await save();
            }
          }),
        );
        check();
        emit();
        onFilesReceived?.call();
        final result = await jsonRequest('complete', {'hashes': hashes});
        check();
        return result;
      } finally {
        ticker.cancel();
      }
    } finally {
      if (identical(_clients[id], client)) _clients.remove(id);
      client.close(force: true);
    }
  }

  static Future<String> _hashFile(
    File file, {
    int? end,
    required void Function() check,
  }) async {
    final result = _DigestResult();
    // Reads stay cancellable without buffering file bytes.
    final digest = sha256.startChunkedConversion(result);
    await for (final bytes in file.openRead(0, end)) {
      check();
      digest.add(bytes);
    }
    digest.close();
    check();
    return result.value.toString();
  }

  static Stream<List<int>> _frames(Stream<List<int>> stream) async* {
    final iterator = StreamIterator(stream);
    List<int> current = const [];
    var offset = 0;
    Future<Uint8List?> read(int count, {bool eof = false}) async {
      final result = Uint8List(count);
      var written = 0;
      while (written < count) {
        if (offset == current.length) {
          if (!await iterator.moveNext()) {
            if (written == 0 && eof) return null;
            throw const FormatException('文件帧未传完');
          }
          current = iterator.current;
          offset = 0;
          continue;
        }
        final take = min(count - written, current.length - offset);
        result.setRange(written, written + take, current, offset);
        written += take;
        offset += take;
      }
      return result;
    }

    try {
      while (true) {
        final header = await read(4, eof: true);
        if (header == null) break;
        final length = ByteData.sublistView(header).getUint32(0);
        if (length < 29 || length > _maxFrameBytes + 29) {
          throw const FormatException('文件帧大小无效');
        }
        yield (await read(length))!;
      }
    } finally {
      await iterator.cancel();
    }
  }

  static Future<List<int>> _readBytes(Stream<List<int>> stream, int max) async {
    final bytes = <int>[];
    await for (final part in stream) {
      bytes.addAll(part);
      if (bytes.length > max) throw const FormatException('目录记录过大');
    }
    return bytes;
  }

  static Map<String, dynamic> _object(List<int> bytes) =>
      Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  static Future<void> _respond(
    HttpResponse response,
    Map<String, dynamic> body,
    crypt.SecretKey key,
    List<int> aad,
  ) async {
    final bytes = await _seal(utf8.encode(jsonEncode(body)), key, aad);
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  void cancel(String id) {
    _sources.remove(id);
    _clients.remove(id)?.close(force: true);
  }

  Future<void> close() async {
    _closed = true;
    _sources.clear();
    for (final client in _clients.values) {
      client.close(force: true);
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  static bool _local(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    final b = address.rawAddress;
    return b.length == 4
        ? b[0] == 10 ||
              b[0] == 192 && b[1] == 168 ||
              b[0] == 172 && b[1] >= 16 && b[1] <= 31
        : b.length == 16 && (b[0] & 0xfe) == 0xfc;
  }
}

class _DigestResult implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// About two seconds of newly received network bytes.
///
/// The first samples inside 200 ms stay at 0 so a resumed prefix cannot
/// appear as a speed spike.
class TransferSpeedWindow {
  TransferSpeedWindow({this.window = const Duration(seconds: 2)});

  final Duration window;
  final List<(int, int)> _samples = [];

  double add(int elapsedMicros, int networkBytes) {
    if (networkBytes < 0 || elapsedMicros < 0) return 0;
    _samples.add((elapsedMicros, networkBytes));
    final oldest = elapsedMicros - window.inMicroseconds;
    while (_samples.length > 1 && _samples.first.$1 < oldest) {
      _samples.removeAt(0);
    }
    final span = elapsedMicros - _samples.first.$1;
    final delta = networkBytes - _samples.first.$2;
    if (span < 200000 || delta <= 0) return 0;
    return delta * 1000000 / span;
  }
}

class _DirectSource {
  _DirectSource(
    this.peerId,
    this.token,
    this.key,
    this.authorizationEpoch,
    this.plan,
    this.complete,
  );
  final String peerId, token;
  final crypt.SecretKey key;
  final (int, int) authorizationEpoch;
  final PortableFolderFiles plan;
  final Future<Map<String, dynamic>> Function(Map<String, String>) complete;
  final Set<String> requests = {};
  final Map<String, String> hashes = {};
  Future<Map<String, dynamic>>? result;
}
