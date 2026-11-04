import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../utils/serial_task_queue.dart';

abstract class ProgressSyncStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
}

/// Keys, credentials and progress are encrypted at rest. Only the wrapping key
/// lives in the platform key store; writes are serialized and atomically replaced.
class FileProgressSyncStore implements ProgressSyncStore {
  FileProgressSyncStore({
    FlutterSecureStorage? secureStorage,
    Future<Directory> Function()? directoryProvider,
    this.maxStoredBytes = 64 * 1024 * 1024,
    this.maxPlainBytes = 128 * 1024 * 1024,
  }) : _secure = secureStorage ?? const FlutterSecureStorage(),
       _directory = directoryProvider ?? getApplicationSupportDirectory;
  final FlutterSecureStorage _secure;
  final Future<Directory> Function() _directory;
  final SerialTaskQueue _queue = SerialTaskQueue();
  final int maxStoredBytes, maxPlainBytes;
  static const _keyName = 'fluent_player_progress_sync_key_v1';
  SecretKey? _key;
  final _cipher = AesGcm.with256bits();
  Future<File> _file() async =>
      File(p.join((await _directory()).path, 'progress_sync_v1.enc'));
  Future<SecretKey> _loadKey({required bool existing}) async {
    if (_key != null) return _key!;
    var raw = await _secure.read(key: _keyName);
    if (raw == null) {
      if (existing) throw const FormatException('同步密钥不可用');
      raw = base64Encode(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)),
      );
      await _secure.write(key: _keyName, value: raw);
    }
    return _key = SecretKey(base64Decode(raw));
  }

  @override
  Future<Map<String, dynamic>?> read() => _queue.enqueue(() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final storedBytes = await file.length();
    // Older writers had no stored-size bound. Permit one bounded legacy read
    // so the next checkpoint can compact an otherwise unreadable catalog.
    final legacyLimit = (maxPlainBytes * 4 ~/ 3) + 4096;
    if (storedBytes > max(maxStoredBytes, legacyLimit)) {
      throw const FormatException('同步记录过大');
    }
    final box = Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
    final version = box['version'];
    if (storedBytes > maxStoredBytes && version != 1) {
      throw const FormatException('同步记录过大');
    }
    if (version != 1 && !(version == 2 && box['compression'] == 'gzip')) {
      throw const FormatException('同步记录版本不受支持，原记录已保留');
    }
    final plain = await _cipher.decrypt(
      SecretBox(
        base64Decode(box['cipherText'] as String),
        nonce: base64Decode(box['nonce'] as String),
        mac: Mac(base64Decode(box['mac'] as String)),
      ),
      secretKey: await _loadKey(existing: true),
      aad: utf8.encode(
        version == 2
            ? 'FluentPlayer.ProgressSync.Store.v2|gzip'
            : 'FluentPlayer.ProgressSync.Store.v1',
      ),
    );
    final decoded = version == 2
        ? await _decodeCompressedStore(plain, maxPlainBytes)
        : plain;
    if (decoded.length > maxPlainBytes) throw const FormatException('同步记录过大');
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(decoded)) as Map);
  });
  @override
  Future<void> write(Map<String, dynamic> value) {
    final encoded = utf8.encode(jsonEncode(value));
    return _queue.enqueue(() async {
      if (encoded.length > maxPlainBytes) {
        throw const FormatException('同步记录超出容量，上一份有效记录已保留');
      }
      final file = await _file();
      final compressed = encoded.length > 1024 * 1024;
      final payload = compressed
          ? await _encodeCompressedStore(encoded)
          : encoded;
      final box = await _cipher.encrypt(
        payload,
        secretKey: await _loadKey(existing: await file.exists()),
        aad: utf8.encode(
          compressed
              ? 'FluentPlayer.ProgressSync.Store.v2|gzip'
              : 'FluentPlayer.ProgressSync.Store.v1',
        ),
      );
      final contents = jsonEncode({
        'version': compressed ? 2 : 1,
        if (compressed) 'compression': 'gzip',
        'nonce': base64Encode(box.nonce),
        'cipherText': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
      if (utf8.encode(contents).length > maxStoredBytes) {
        throw const FormatException('加密同步记录超出容量，上一份有效记录已保留');
      }
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(contents, flush: true);
      await tmp.rename(file.path);
    });
  }
}

Future<List<int>> _encodeCompressedStore(List<int> bytes) =>
    Isolate.run(() => gzip.encode(bytes));

Future<List<int>> _decodeCompressedStore(List<int> bytes, int limit) =>
    Isolate.run(() {
      final output = _BoundedStoreBytes(limit);
      final decoder = gzip.decoder.startChunkedConversion(output);
      decoder.add(bytes);
      decoder.close();
      return output.bytes.takeBytes();
    });

class _BoundedStoreBytes implements Sink<List<int>> {
  _BoundedStoreBytes(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('解压后的同步记录过大，原记录已保留');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}

class MemoryProgressSyncStore implements ProgressSyncStore {
  Map<String, dynamic>? value;
  @override
  Future<Map<String, dynamic>?> read() async => value == null
      ? null
      : Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  @override
  Future<void> write(Map<String, dynamic> value) async {
    this.value = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(value)) as Map,
    );
  }
}
