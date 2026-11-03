import 'dart:typed_data';
import 'dart:convert';
import '../../debug/developer_log.dart' as developer;

/// Simple manual Protobuf writer/reader for specific Bilibili messages.
/// Avoids heavy dependencies.

class DmViewReq {
  final int pid; // aid
  final int oid; // cid
  final int type;
  final String spmid;

  DmViewReq({
    required this.pid,
    required this.oid,
    this.type = 1,
    this.spmid = "main.ugc-video-detail.0.0",
  });

  Uint8List toBytes() {
    final buffer = BytesBuilder();
    
    // Field 1: pid (int64) -> Varint
    _writeVarint(buffer, (1 << 3) | 0);
    _writeVarint(buffer, pid);

    // Field 2: oid (int64) -> Varint
    _writeVarint(buffer, (2 << 3) | 0);
    _writeVarint(buffer, oid);

    // Field 3: type (int32) -> Varint
    _writeVarint(buffer, (3 << 3) | 0);
    _writeVarint(buffer, type);

    // Field 4: spmid (string) -> Length Delimited
    if (spmid.isNotEmpty) {
      _writeVarint(buffer, (4 << 3) | 2);
      final bytes = utf8.encode(spmid);
      _writeVarint(buffer, bytes.length);
      buffer.add(bytes);
    }

    return buffer.toBytes();
  }

  void _writeVarint(BytesBuilder buffer, int value) {
    while (true) {
      if ((value & ~0x7F) == 0) {
        buffer.addByte(value);
        return;
      } else {
        buffer.addByte((value & 0x7F) | 0x80);
        value = value >>> 7;
      }
    }
  }
}

// Header Models for x-bili-*-bin

class Metadata {
  final String accessKey;
  final String mobiApp;
  final String build;
  final String channel;
  final String buvid;
  final String platform;

  Metadata({
    this.accessKey = "",
    this.mobiApp = "android",
    this.build = "6100500",
    this.channel = "bili",
    this.buvid = "",
    this.platform = "android",
  });

  Uint8List toBytes() {
    final buffer = BytesBuilder();
    if (accessKey.isNotEmpty) { _writeString(buffer, 1, accessKey); }
    _writeString(buffer, 2, mobiApp);
    _writeString(buffer, 3, "android"); // device
    _writeVarint(buffer, (4 << 3) | 0); _writeVarint(buffer, int.parse(build)); // build (int)
    _writeString(buffer, 5, channel);
    _writeString(buffer, 6, buvid);
    _writeString(buffer, 7, platform);
    return buffer.toBytes();
  }
}

class Device {
  final int appId;
  final int build;
  final String buvid;
  final String mobiApp;
  final String platform;
  final String channel;
  final String brand;
  final String model;
  final String osver;

  Device({
    this.appId = 1,
    this.build = 6100500,
    this.buvid = "",
    this.mobiApp = "android",
    this.platform = "android",
    this.channel = "bili",
    this.brand = "oneplus",
    this.model = "oneplus a5010",
    this.osver = "6.0.1",
  });

  Uint8List toBytes() {
    final buffer = BytesBuilder();
    _writeVarint(buffer, (1 << 3) | 0); _writeVarint(buffer, appId);
    _writeVarint(buffer, (2 << 3) | 0); _writeVarint(buffer, build);
    _writeString(buffer, 3, buvid);
    _writeString(buffer, 4, mobiApp);
    _writeString(buffer, 5, platform);
    _writeString(buffer, 6, channel);
    _writeString(buffer, 7, brand);
    _writeString(buffer, 8, model);
    _writeString(buffer, 9, osver);
    return buffer.toBytes();
  }
}

class Network {
  final int type;
  final String oid;

  Network({this.type = 2, this.oid = "46007"}); // 2 = WIFI

  Uint8List toBytes() {
    final buffer = BytesBuilder();
    _writeVarint(buffer, (1 << 3) | 0); _writeVarint(buffer, type); // Type enum
    // Field 2 contains the network operator identifier.
    _writeString(buffer, 2, oid);
    return buffer.toBytes();
  }
}

class Locale {
  final String language;
  final String region;

  Locale({this.language = "zh", this.region = "CN"});

  Uint8List toBytes() {
    final buffer = BytesBuilder();
    // c_locale = 1 (message)
    final nested = BytesBuilder();
    _writeString(nested, 1, language);
    _writeString(nested, 2, region);
    
    _writeVarint(buffer, (1 << 3) | 2);
    final nb = nested.toBytes();
    _writeVarint(buffer, nb.length);
    buffer.add(nb);
    return buffer.toBytes();
  }
}

class FawkesReq {
  final String appkey;
  final String env;
  final String sessionId;

  FawkesReq({this.appkey = "android64", this.env = "prod", this.sessionId = "dedf8669"});

  Uint8List toBytes() {
    final buffer = BytesBuilder();
    _writeString(buffer, 1, appkey);
    _writeString(buffer, 2, env);
    _writeString(buffer, 3, sessionId);
    return buffer.toBytes();
  }
}

void _writeString(BytesBuilder buffer, int field, String value) {
  if (value.isEmpty) return;
  _writeVarint(buffer, (field << 3) | 2);
  final bytes = utf8.encode(value);
  _writeVarint(buffer, bytes.length);
  buffer.add(bytes);
}

void _writeVarint(BytesBuilder buffer, int value) {
  while (true) {
    if ((value & ~0x7F) == 0) {
      buffer.addByte(value);
      return;
    } else {
      buffer.addByte((value & 0x7F) | 0x80);
      value = value >>> 7;
    }
  }
}

class SubtitleItem {
  final String lan;
  final String lanDoc;
  final String subtitleUrl;

  SubtitleItem({required this.lan, required this.lanDoc, required this.subtitleUrl});
}

class DmViewReply {
  List<SubtitleItem> subtitles = [];

  static DmViewReply parse(Uint8List bytes) {
    final reply = DmViewReply();
    final reader = ProtoReader(bytes);
    
    developer.log('  [Parser] Starting DmViewReply parse, total bytes: ${bytes.length}');
    
    while (reader.hasMore()) {
      final tag = reader.readTag();
      developer.log('  [Parser] Tag: field=${tag.field}, wireType=${tag.wireType}');
      
      if (tag.field == 2) { 
        final subBytes = reader.readBytes();
        developer.log('  [Parser] Found field 2 (VideoSubtitle?), bytes: ${subBytes.length}');
        _parseVideoSubtitle(subBytes, reply);
      } else if (tag.field == 1) {
         developer.log('  [Parser] Skipping field 1 (closed?)');
         reader.skip(tag.wireType); 
      } else {
        developer.log('  [Parser] Skipping unknown field ${tag.field}');
        reader.skip(tag.wireType);
      }
    }
    
    if (reply.subtitles.isEmpty) {
        developer.log('  [Parser] Warning: Subtitles list is empty after standard parsing. Trying heuristic scan...');
        final reader2 = ProtoReader(bytes);
        while(reader2.hasMore()) {
             final tag = reader2.readTag();
             if (tag.wireType == 2) {
                 final payload = reader2.readBytes();
                 try {
                     developer.log('  [Parser] Heuristic: Trying to parse field ${tag.field} as SubtitleItem...');
                     final item = _parseSubtitleItem(payload);
                     if (item != null) {
                        developer.log('  [Parser] Heuristic success! Found item: ${item.lan}');
                        reply.subtitles.add(item);
                     }
                 } catch (e) {
                     // Ignore
                 }
             } else {
                 reader2.skip(tag.wireType);
             }
        }
    }
    
    return reply;
  }
  
  static void _parseVideoSubtitle(Uint8List bytes, DmViewReply reply) {
    final reader = ProtoReader(bytes);
    developer.log('  [Parser] Parsing VideoSubtitle...');
    while (reader.hasMore()) {
      final tag = reader.readTag();
      developer.log('  [Parser] VideoSubtitle Tag: field=${tag.field}, wireType=${tag.wireType}');
      
      if (tag.field == 1) { 
         try {
             final itemBytes = reader.readBytes(); 
             developer.log('  [Parser] Found field 1, trying to parse as SubtitleItem (${itemBytes.length} bytes)...');
             final item = _parseSubtitleItem(itemBytes);
             if (item != null) {
                developer.log('  [Parser] Success! Added subtitle: ${item.lan}');
                reply.subtitles.add(item);
             } else {
                developer.log('  [Parser] Failed to parse item.');
             }
         } catch(e) {
             developer.log('  [Parser] Error reading field 1', error: e);
         }
      } else {
        reader.skip(tag.wireType);
      }
    }
  }
  
  static SubtitleItem? _parseSubtitleItem(Uint8List bytes) {
    final reader = ProtoReader(bytes);
    String lan = "";
    String lanDoc = "";
    String url = "";
    
    // Safety check: if bytes are too small, ignore
    if (bytes.length < 2) return null;

    try {
        while (reader.hasMore()) {
          final tag = reader.readTag();
          // Read language, display label and URL; skip unused fields.
          switch (tag.field) {
            case 3: lan = reader.readString(); break;
            case 4: lanDoc = reader.readString(); break;
            case 5: url = reader.readString(); break;
            default: reader.skip(tag.wireType);
          }
        }
    } catch (e) {
        return null;
    }
    
    if (url.isNotEmpty && url.startsWith("http")) {
      return SubtitleItem(lan: lan, lanDoc: lanDoc, subtitleUrl: url);
    }
    return null;
  }
}

class ProtoReader {
  final Uint8List _bytes;
  int _offset = 0;

  ProtoReader(this._bytes);

  bool hasMore() => _offset < _bytes.length;

  Tag readTag() {
    final value = _readVarint();
    return Tag(value >> 3, value & 0x07);
  }

  int _readVarint() {
    int value = 0;
    int shift = 0;
    while (true) {
      if (_offset >= _bytes.length) throw Exception("Buffer underflow");
      final byte = _bytes[_offset++];
      value |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return value;
      shift += 7;
    }
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0: // Varint
        _readVarint();
        break;
      case 2: // Length Delimited
        final len = _readVarint();
        _offset += len;
        break;
      case 1: _offset += 8; break;
      case 5: _offset += 4; break;
      default: throw Exception("Unsupported wire type: $wireType");
    }
  }

  String readString() {
    final len = _readVarint();
    final str = utf8.decode(_bytes.sublist(_offset, _offset + len));
    _offset += len;
    return str;
  }
  
  Uint8List readBytes() {
    final len = _readVarint();
    final sub = _bytes.sublist(_offset, _offset + len);
    _offset += len;
    return sub;
  }
}

class Tag {
  final int field;
  final int wireType;
  Tag(this.field, this.wireType);
}
