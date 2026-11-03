import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'podcast_models.dart';
import 'podcast_store.dart';

/// Bounded, independently authenticated fragments fit both LAN and WebDAV.
class PodcastSyncCodec {
  static final _cipher = AesGcm.with256bits();
  static const chunkBytes = 150 * 1024;
  static String _aad(Map<String, dynamic> record) =>
      'podcast|${record['groupId']}|${record['digest']}|${record['index']}|${record['count']}|${record['nodeId']}|${record['channelId']}';
  static Future<List<Map<String, dynamic>>> encode({
    required Map<String, dynamic> data,
    required String groupId,
    required String nodeId,
    required List<int> key,
  }) async {
    final raw = utf8.encode(jsonEncode(data));
    if (raw.length > 32 * 1024 * 1024) {
      throw const FormatException('频道同步数据过大，请使用导出包迁移');
    }
    final digest = podcastHash(jsonEncode(data)),
        count = (raw.length / chunkBytes).ceil();
    final records = <Map<String, dynamic>>[];
    for (var index = 0; index < count; index++) {
      final record = <String, dynamic>{
        'kind': 'podcast-event',
        'version': 1,
        'eventId':
            'pc-${podcastHash('$groupId|$digest').substring(0, 48)}-$index',
        'groupId': groupId,
        'digest': digest,
        'index': index,
        'count': count,
        'nodeId': nodeId,
        'channelId': (data['channel'] as Map)['id'],
      };
      final box = await _cipher.encrypt(
        raw.sublist(
          index * chunkBytes,
          min(raw.length, (index + 1) * chunkBytes),
        ),
        secretKey: SecretKey(key),
        aad: utf8.encode(_aad(record)),
      );
      record.addAll({
        'nonce': base64Encode(box.nonce),
        'cipherText': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
      records.add(record);
    }
    return records;
  }

  static Future<Map<String, dynamic>?> receive(
    Map<String, dynamic> record,
    List<int> key,
    PodcastStore store,
  ) async {
    final index = record['index'],
        count = record['count'],
        digest = record['digest'];
    if (record['version'] != 1 ||
        index is! int ||
        count is! int ||
        count < 1 ||
        count > 220 ||
        index < 0 ||
        index >= count ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        record['nodeId'] is! String ||
        record['channelId'] is! String) {
      throw const FormatException('播客同步分片无效');
    }
    final prefix = '${record['groupId']}:$digest';
    if (store.read('syncApplied', prefix) != null) return null;
    final plaintext = await _cipher.decrypt(
      SecretBox(
        base64Decode(record['cipherText']),
        nonce: base64Decode(record['nonce']),
        mac: Mac(base64Decode(record['mac'])),
      ),
      secretKey: SecretKey(key),
      aad: utf8.encode(_aad(record)),
    );
    if (plaintext.length > chunkBytes) throw const FormatException('播客同步分片过大');
    store.write('syncFragment', '$prefix:$index', {
      'bytes': base64Encode(plaintext),
    });
    final bytes = <int>[];
    for (var part = 0; part < count; part++) {
      final saved = store.read('syncFragment', '$prefix:$part');
      if (saved == null) return null;
      bytes.addAll(base64Decode(saved['bytes']));
    }
    final source = utf8.decode(bytes);
    if (podcastHash(source) != digest) {
      throw const FormatException('播客同步完整性校验失败');
    }
    final data = Map<String, dynamic>.from(jsonDecode(source));
    if ((data['channel'] as Map?)?['id'] != record['channelId']) {
      throw const FormatException('播客频道身份不匹配');
    }
    store.transaction(() {
      store.write('syncPending', prefix, {
        'id': prefix,
        'groupId': record['groupId'],
        'nodeId': record['nodeId'],
        'data': data,
      });
      store.write('syncApplied', prefix, {
        'at': DateTime.now().millisecondsSinceEpoch,
      });
      for (var part = 0; part < count; part++) {
        store.remove('syncFragment', '$prefix:$part');
      }
    });
    return data;
  }
}
