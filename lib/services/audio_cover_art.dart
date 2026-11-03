import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Reads album art that travels with an audio file.
///
/// Apple ALAC/M4A keeps the cover in `moov/udta/meta/ilst/covr`, often in
/// addition to an attached picture stream. Re-encoding that stream with the
/// mjpeg encoder fails on some platforms, and a folder import used to skip
/// audio entirely. Parsing the container here keeps the original JPEG/PNG
/// bytes and does not depend on ffmpeg.
class AudioCoverArt {
  AudioCoverArt._();

  static const int maxImageBytes = 32 * 1024 * 1024;

  static const List<String> _sidecarBasenames = <String>[
    'cover',
    'folder',
    'album',
    'front',
    'albumart',
    'albumartsmall',
    'folderart',
  ];

  static const List<String> _sidecarExtensions = <String>[
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
    '.gif',
  ];

  /// True when [bytes] begin with a still-image signature Flutter can decode.
  static bool looksLikeImage(List<int> bytes) {
    if (bytes.length < 3) return false;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return true;
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    return false;
  }

  /// Embedded front-cover bytes, or null when the file has no readable art.
  static Future<Uint8List?> readEmbedded(String path) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length < 16 || length > 1 << 34) return null;
      raf = await file.open();
      final head = await _readExact(raf, 16);
      if (head.length < 12) return null;
      final readers = _readersFor(p.extension(path).toLowerCase(), head);
      for (final reader in readers) {
        await raf.setPosition(0);
        final image = await reader(raf, length);
        if (image != null && looksLikeImage(image)) return image;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// `cover.jpg` / `folder.jpg` / `{track}.jpg` sitting next to [audioPath].
  static Future<String?> findSidecar(String audioPath) async {
    final matches = await _sidecarCandidates(<String>[audioPath]);
    if (matches.isEmpty) return null;
    return matches.first;
  }

  /// Writes embedded art, or a sibling image, to [outputPath].
  ///
  /// [sidecarHintPaths] are the pre-copy locations. A private-storage copy no
  /// longer sits next to `cover.jpg`, but the source folder still does.
  static Future<String?> writeCover({
    required String audioPath,
    required String outputPath,
    Iterable<String> sidecarHintPaths = const <String>[],
  }) async {
    Uint8List? bytes = await readEmbedded(audioPath);
    if (bytes == null) {
      final candidates = await _sidecarCandidates(<String>[
        audioPath,
        ...sidecarHintPaths,
      ]);
      for (final candidate in candidates) {
        bytes = await _readImageFile(candidate);
        if (bytes != null) break;
      }
    }
    if (bytes == null || !looksLikeImage(bytes)) return null;
    final out = File(outputPath);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(bytes, flush: true);
    return outputPath;
  }

  static List<Future<Uint8List?> Function(RandomAccessFile raf, int length)>
  _readersFor(String ext, Uint8List head) {
    final ftyp = _fourCC(head, 4) == 'ftyp';
    switch (ext) {
      case '.m4a':
      case '.m4b':
      case '.mp4':
      case '.m4v':
      case '.mov':
      case '.alac':
        return <Future<Uint8List?> Function(RandomAccessFile, int)>[_readMp4];
      case '.aac':
        return ftyp
            ? <Future<Uint8List?> Function(RandomAccessFile, int)>[_readMp4]
            : <Future<Uint8List?> Function(RandomAccessFile, int)>[
                _readId3,
                _readMp4,
              ];
      case '.mp3':
      case '.mp2':
        return <Future<Uint8List?> Function(RandomAccessFile, int)>[_readId3];
      case '.flac':
        return <Future<Uint8List?> Function(RandomAccessFile, int)>[_readFlac];
      case '.ogg':
      case '.oga':
      case '.opus':
        return <Future<Uint8List?> Function(RandomAccessFile, int)>[_readOgg];
      case '.wav':
        return <Future<Uint8List?> Function(RandomAccessFile, int)>[
          _readId3,
          _readWav,
        ];
      case '.aiff':
      case '.aif':
      case '.aifc':
        return <Future<Uint8List?> Function(RandomAccessFile, int)>[
          _readId3,
          _readAiff,
        ];
      case '.wma':
      case '.asf':
        return <Future<Uint8List?> Function(RandomAccessFile, int)>[_readAsf];
      case '.ape':
      case '.wv':
      case '.tta':
        return <Future<Uint8List?> Function(RandomAccessFile, int)>[
          _readApe,
          _readId3,
        ];
      default:
        if (ftyp) {
          return <Future<Uint8List?> Function(RandomAccessFile, int)>[_readMp4];
        }
        if (_startsWith(head, 'ID3')) {
          return <Future<Uint8List?> Function(RandomAccessFile, int)>[_readId3];
        }
        if (_startsWith(head, 'fLaC')) {
          return <Future<Uint8List?> Function(RandomAccessFile, int)>[
            _readFlac,
          ];
        }
        if (_startsWith(head, 'OggS')) {
          return <Future<Uint8List?> Function(RandomAccessFile, int)>[_readOgg];
        }
        if (_startsWith(head, 'RIFF')) {
          return <Future<Uint8List?> Function(RandomAccessFile, int)>[_readWav];
        }
        if (_startsWith(head, 'FORM')) {
          return <Future<Uint8List?> Function(RandomAccessFile, int)>[
            _readAiff,
          ];
        }
        return <Future<Uint8List?> Function(RandomAccessFile, int)>[
          _readMp4,
          _readId3,
          _readFlac,
          _readOgg,
          _readApe,
          _readAsf,
        ];
    }
  }

  static Future<Uint8List?> _readMp4(RandomAccessFile raf, int length) async {
    final images = <_Picture>[];
    await _walkMp4(raf: raf, start: 0, end: length, depth: 0, images: images);
    return _best(images);
  }

  static const Set<String> _mp4Containers = <String>{
    'moov',
    'trak',
    'mdia',
    'minf',
    'stbl',
    'udta',
    'ilst',
    'edts',
  };

  static Future<void> _walkMp4({
    required RandomAccessFile raf,
    required int start,
    required int end,
    required int depth,
    required List<_Picture> images,
  }) async {
    if (depth > 12 || images.isNotEmpty) return;
    var pos = start;
    var guard = 0;
    while (pos + 8 <= end && guard < 100000) {
      guard++;
      await raf.setPosition(pos);
      final header = await _readExact(raf, 8);
      if (header.length < 8) return;
      var size = _be32(header, 0);
      final type = _fourCC(header, 4);
      var headerSize = 8;
      if (size == 1) {
        final extended = await _readExact(raf, 8);
        if (extended.length < 8) return;
        size = _be64(extended);
        headerSize = 16;
      } else if (size == 0) {
        size = end - pos;
      }
      if (size < headerSize || pos + size > end) return;
      final next = pos + size;
      final childStart = pos + headerSize;
      if (type == 'covr') {
        await _readCovr(raf, childStart, next, images);
        if (images.isNotEmpty) return;
      } else if (type == 'meta') {
        // `meta` stores a 4-byte version/flags field before its children.
        // Apple ALAC puts ilst/covr behind that field.
        final versioned = childStart + 4;
        final nestedStart =
            versioned + 4 <= next && await _looksLikeAtom(raf, versioned, next)
            ? versioned
            : childStart;
        await _walkMp4(
          raf: raf,
          start: nestedStart,
          end: next,
          depth: depth + 1,
          images: images,
        );
      } else if (_mp4Containers.contains(type)) {
        await _walkMp4(
          raf: raf,
          start: childStart,
          end: next,
          depth: depth + 1,
          images: images,
        );
      }
      if (images.isNotEmpty) return;
      if (next <= pos) return;
      pos = next;
    }
  }

  static Future<bool> _looksLikeAtom(
    RandomAccessFile raf,
    int pos,
    int end,
  ) async {
    if (pos + 8 > end) return false;
    await raf.setPosition(pos);
    final header = await _readExact(raf, 8);
    if (header.length < 8) return false;
    final type = _fourCC(header, 4);
    if (type.length != 4) return false;
    for (final unit in type.codeUnits) {
      final printable = unit >= 0x20 && unit <= 0x7e;
      if (!printable) return false;
    }
    return true;
  }

  static Future<void> _readCovr(
    RandomAccessFile raf,
    int start,
    int end,
    List<_Picture> images,
  ) async {
    final span = end - start;
    if (span > 16 && span <= maxImageBytes) {
      await raf.setPosition(start);
      final sniff = await _readExact(raf, span < 16 ? span : 16);
      if (looksLikeImage(sniff)) {
        await raf.setPosition(start);
        final raw = await _readExact(raf, span);
        if (looksLikeImage(raw)) {
          images.add(_Picture(3, raw));
          return;
        }
      }
    }
    var pos = start;
    while (pos + 8 <= end) {
      await raf.setPosition(pos);
      final header = await _readExact(raf, 8);
      if (header.length < 8) return;
      final size = _be32(header, 0);
      final type = _fourCC(header, 4);
      if (size < 8 || pos + size > end) return;
      if (type == 'data' && size > 16 && size - 16 <= maxImageBytes) {
        // data atom: 4-byte image kind (13 = JPEG, 14 = PNG) + 4-byte locale.
        await raf.setPosition(pos + 16);
        final payload = await _readExact(raf, size - 16);
        if (looksLikeImage(payload)) {
          images.add(_Picture(3, payload));
        } else if (size > 8) {
          await raf.setPosition(pos + 8);
          final raw = await _readExact(raf, size - 8);
          if (looksLikeImage(raw) && raw.length <= maxImageBytes) {
            images.add(_Picture(3, raw));
          }
        }
      }
      pos += size;
    }
  }

  static Future<Uint8List?> _readId3(RandomAccessFile raf, int length) async {
    await raf.setPosition(0);
    final header = await _readExact(raf, 10);
    if (header.length < 10 || !_startsWith(header, 'ID3')) return null;
    final pictures = _parseId3Tag(header, await _id3Body(raf, header, length));
    return _best(pictures);
  }

  static Future<Uint8List> _id3Body(
    RandomAccessFile raf,
    Uint8List header,
    int length,
  ) async {
    final tagSize = _synchsafe(header, 6);
    if (tagSize <= 0 || tagSize > maxImageBytes || 10 + tagSize > length) {
      return Uint8List(0);
    }
    await raf.setPosition(10);
    return _readExact(raf, tagSize);
  }

  static List<_Picture> _parseId3Tag(Uint8List header, Uint8List body) {
    if (body.isEmpty || header.length < 10) return const <_Picture>[];
    final major = header[3];
    if (major != 2 && major != 3 && major != 4) return const <_Picture>[];
    var offset = 0;
    final flags = header[5];
    if ((flags & 0x40) != 0) {
      if (major == 4) {
        if (body.length < 4) return const <_Picture>[];
        final extended = _synchsafe(body, 0);
        if (extended < 4 || extended > body.length) return const <_Picture>[];
        offset = extended;
      } else if (body.length >= 4) {
        final extended = _be32(body, 0);
        final skip = 4 + extended;
        if (skip < 4 || skip > body.length) return const <_Picture>[];
        offset = skip;
      }
    }
    final tagUnsync = (flags & 0x80) != 0;
    final pictures = <_Picture>[];
    final frameHeaderSize = major == 2 ? 6 : 10;
    while (offset + frameHeaderSize <= body.length) {
      final id = major == 2
          ? _fourCC(body, offset).substring(0, 3)
          : _fourCC(body, offset);
      if (id.trim().isEmpty || id.contains('\u0000')) break;
      final frameSize = major == 2
          ? (body[offset + 3] << 16) |
                (body[offset + 4] << 8) |
                body[offset + 5]
          : major == 4
          ? _synchsafe(body, offset + 4)
          : _be32(body, offset + 4);
      if (frameSize <= 0 ||
          offset + frameHeaderSize + frameSize > body.length) {
        break;
      }
      var frame = body.sublist(
        offset + frameHeaderSize,
        offset + frameHeaderSize + frameSize,
      );
      var unsync = tagUnsync;
      var skip = 0;
      if (major == 4 && frameHeaderSize == 10) {
        final formatFlags = body[offset + 9];
        unsync = unsync || (formatFlags & 0x02) != 0;
        final compressed = (formatFlags & 0x08) != 0;
        final encrypted = (formatFlags & 0x04) != 0;
        if ((body[offset + 8] & 0x40) != 0 && frame.isNotEmpty) {
          skip = 1;
        }
        if ((formatFlags & 0x01) != 0) skip += 4;
        if (compressed || encrypted) {
          offset += frameHeaderSize + frameSize;
          continue;
        }
      } else if (major == 3) {
        final formatFlags = body[offset + 9];
        if ((formatFlags & 0x80) != 0 || (formatFlags & 0x40) != 0) {
          offset += frameHeaderSize + frameSize;
          continue;
        }
        if ((formatFlags & 0x20) != 0 && frame.isNotEmpty) skip = 1;
      }
      if (unsync) frame = _deunsync(frame);
      if (skip > 0 && skip < frame.length) {
        frame = frame.sublist(skip);
      }
      if (id == 'APIC' || id == 'PIC') {
        final picture = id == 'PIC' ? _parsePic(frame) : _parseApic(frame);
        if (picture != null) pictures.add(picture);
      }
      offset += frameHeaderSize + frameSize;
    }
    return pictures;
  }

  static _Picture? _parseApic(Uint8List frame) {
    if (frame.length < 4) return null;
    final encoding = frame[0];
    final mimeEnd = frame.indexOf(0, 1);
    if (mimeEnd < 0 || mimeEnd + 2 >= frame.length) return null;
    final type = frame[mimeEnd + 1];
    final descEnd = _terminatedEnd(frame, mimeEnd + 2, encoding);
    if (descEnd >= frame.length) return null;
    final image = frame.sublist(descEnd);
    if (!looksLikeImage(image) || image.length > maxImageBytes) return null;
    return _Picture(type, image);
  }

  static _Picture? _parsePic(Uint8List frame) {
    if (frame.length < 6) return null;
    final encoding = frame[0];
    final type = frame[4];
    final descEnd = _terminatedEnd(frame, 5, encoding);
    if (descEnd >= frame.length) return null;
    final image = frame.sublist(descEnd);
    if (!looksLikeImage(image) || image.length > maxImageBytes) return null;
    return _Picture(type, image);
  }

  static Future<Uint8List?> _readFlac(RandomAccessFile raf, int length) async {
    await raf.setPosition(0);
    final magic = await _readExact(raf, 4);
    if (!_startsWith(magic, 'fLaC')) return null;
    final pictures = <_Picture>[];
    var pos = 4;
    while (pos + 4 <= length) {
      await raf.setPosition(pos);
      final header = await _readExact(raf, 4);
      if (header.length < 4) break;
      final last = (header[0] & 0x80) != 0;
      final type = header[0] & 0x7f;
      final size = (header[1] << 16) | (header[2] << 8) | header[3];
      final dataPos = pos + 4;
      if (size < 0 || dataPos + size > length || size > maxImageBytes) break;
      if (type == 6) {
        final block = await _readExact(raf, size);
        final picture = _decodePictureBlock(block);
        if (picture != null) pictures.add(picture);
      } else if (type == 4) {
        final block = await _readExact(raf, size);
        pictures.addAll(_picturesFromVorbisComments(block, vendorFirst: true));
      }
      pos = dataPos + size;
      if (last || pictures.isNotEmpty && type == 6) break;
    }
    return _best(pictures);
  }

  static Future<Uint8List?> _readOgg(RandomAccessFile raf, int length) async {
    final window = _min(length, 8 * 1024 * 1024);
    await raf.setPosition(0);
    final bytes = await _readExact(raf, window);
    final packets = _oggPackets(bytes);
    final pictures = <_Picture>[];
    for (final packet in packets) {
      if (packet.length >= 7 &&
          packet[0] == 0x03 &&
          _startsWith(packet.sublist(1), 'vorbis')) {
        pictures.addAll(
          _picturesFromVorbisComments(packet.sublist(7), vendorFirst: true),
        );
      } else if (packet.length > 8 && _startsWith(packet, 'OpusTags')) {
        pictures.addAll(
          _picturesFromVorbisComments(packet.sublist(8), vendorFirst: true),
        );
      }
    }
    return _best(pictures);
  }

  static List<Uint8List> _oggPackets(Uint8List data) {
    final packets = <Uint8List>[];
    final current = BytesBuilder(copy: false);
    var offset = 0;
    while (offset + 27 <= data.length && packets.length < 8) {
      if (!_startsWith(data.sublist(offset, offset + 4), 'OggS')) break;
      final segments = data[offset + 26];
      final table = offset + 27;
      if (table + segments > data.length) break;
      var body = table + segments;
      for (var i = 0; i < segments; i++) {
        final size = data[table + i];
        if (body + size > data.length) return packets;
        current.add(data.sublist(body, body + size));
        body += size;
        if (size < 255) {
          packets.add(current.toBytes());
          current.clear();
          if (packets.length >= 8) return packets;
        }
      }
      offset = body;
    }
    return packets;
  }

  static List<_Picture> _picturesFromVorbisComments(
    Uint8List block, {
    required bool vendorFirst,
  }) {
    if (block.length < 8) return const <_Picture>[];
    final data = ByteData.sublistView(block);
    var offset = 0;
    if (vendorFirst) {
      final vendorLength = data.getUint32(offset, Endian.little);
      offset += 4 + vendorLength;
      if (vendorLength < 0 || offset + 4 > block.length) {
        return const <_Picture>[];
      }
    }
    final count = data.getUint32(offset, Endian.little);
    offset += 4;
    final pictures = <_Picture>[];
    for (var i = 0; i < count; i++) {
      if (offset + 4 > block.length) break;
      final commentLength = data.getUint32(offset, Endian.little);
      offset += 4;
      if (commentLength < 0 || offset + commentLength > block.length) break;
      final comment = utf8.decode(
        block.sublist(offset, offset + commentLength),
        allowMalformed: true,
      );
      offset += commentLength;
      final split = comment.indexOf('=');
      if (split <= 0) continue;
      final key = comment.substring(0, split).toUpperCase();
      if (key != 'METADATA_BLOCK_PICTURE') continue;
      try {
        final decoded = base64Decode(
          comment.substring(split + 1).replaceAll(RegExp(r'\s+'), ''),
        );
        final picture = _decodePictureBlock(decoded);
        if (picture != null) pictures.add(picture);
      } catch (_) {}
    }
    return pictures;
  }

  static _Picture? _decodePictureBlock(Uint8List block) {
    if (block.length < 32) return null;
    final data = ByteData.sublistView(block);
    var offset = 0;
    final type = data.getUint32(offset);
    offset += 4;
    final mimeLength = data.getUint32(offset);
    offset += 4;
    if (mimeLength < 0 || offset + mimeLength + 4 > block.length) return null;
    offset += mimeLength;
    final descLength = data.getUint32(offset);
    offset += 4;
    if (descLength < 0 || offset + descLength + 20 > block.length) return null;
    offset += descLength + 16;
    final dataLength = data.getUint32(offset);
    offset += 4;
    if (dataLength <= 0 || offset + dataLength > block.length) return null;
    if (dataLength > maxImageBytes) return null;
    final image = Uint8List.sublistView(block, offset, offset + dataLength);
    if (!looksLikeImage(image)) return null;
    return _Picture(type, Uint8List.fromList(image));
  }

  static Future<Uint8List?> _readWav(RandomAccessFile raf, int length) {
    return _readRiff(raf, length, bigEndian: false, form: 'WAVE');
  }

  static Future<Uint8List?> _readAiff(RandomAccessFile raf, int length) async {
    final aiff = await _readRiff(raf, length, bigEndian: true, form: 'AIFF');
    if (aiff != null) return aiff;
    return _readRiff(raf, length, bigEndian: true, form: 'AIFC');
  }

  static Future<Uint8List?> _readRiff(
    RandomAccessFile raf,
    int length, {
    required bool bigEndian,
    required String form,
  }) async {
    await raf.setPosition(0);
    final head = await _readExact(raf, 12);
    if (head.length < 12) return null;
    final magic = bigEndian ? 'FORM' : 'RIFF';
    if (_fourCC(head, 0) != magic || _fourCC(head, 8) != form) return null;
    var pos = 12;
    while (pos + 8 <= length) {
      await raf.setPosition(pos);
      final header = await _readExact(raf, 8);
      if (header.length < 8) break;
      final id = _fourCC(header, 0);
      final size = bigEndian ? _be32(header, 4) : _le32(header, 4);
      final dataPos = pos + 8;
      if (size < 0 || dataPos + size > length) break;
      if (id == 'id3 ' || id == 'ID3 ') {
        final payload = await _readExact(raf, size);
        if (payload.length >= 10 && _startsWith(payload, 'ID3')) {
          final tagSize = _synchsafe(payload, 6);
          final bodyEnd = _min(payload.length, 10 + tagSize);
          final image = _best(
            _parseId3Tag(payload.sublist(0, 10), payload.sublist(10, bodyEnd)),
          );
          if (image != null) return image;
        }
      }
      final padded = size + (size.isOdd ? 1 : 0);
      final next = dataPos + padded;
      if (next <= pos) break;
      pos = next;
    }
    return null;
  }

  static Future<Uint8List?> _readApe(RandomAccessFile raf, int length) async {
    Future<Uint8List?> at(int footerPos) async {
      if (footerPos < 0 || footerPos + 32 > length) return null;
      await raf.setPosition(footerPos);
      final footer = await _readExact(raf, 32);
      if (footer.length < 32 || !_startsWith(footer, 'APETAGEX')) return null;
      final version = _le32(footer, 8);
      if (version != 2000 && version != 1000) return null;
      final size = _le32(footer, 12);
      final count = _le32(footer, 16);
      if (size < 32 || count < 0 || count > 100000) return null;
      final tagStart = footerPos - (size - 32);
      if (tagStart < 0 || tagStart >= footerPos) return null;
      await raf.setPosition(tagStart);
      final tag = await _readExact(raf, size - 32);
      return _best(_parseApeItems(tag, count));
    }

    if (length >= 128 + 32) {
      await raf.setPosition(length - 128);
      final tail = await _readExact(raf, 3);
      if (_startsWith(tail, 'TAG')) {
        final image = await at(length - 128 - 32);
        if (image != null) return image;
      }
    }
    return at(length - 32);
  }

  static List<_Picture> _parseApeItems(Uint8List tag, int count) {
    final pictures = <_Picture>[];
    var offset = 0;
    for (var i = 0; i < count && offset + 8 <= tag.length; i++) {
      final valueLength = _le32(tag, offset);
      offset += 8;
      final keyEnd = tag.indexOf(0, offset);
      if (keyEnd < 0 || valueLength < 0) break;
      final key = latin1.decode(tag.sublist(offset, keyEnd)).toLowerCase();
      offset = keyEnd + 1;
      if (offset + valueLength > tag.length) break;
      final value = tag.sublist(offset, offset + valueLength);
      offset += valueLength;
      if (key == 'cover art (front)' || key == 'cover art (back)') {
        final zero = value.indexOf(0);
        final image = zero >= 0 ? value.sublist(zero + 1) : value;
        if (looksLikeImage(image)) {
          pictures.add(_Picture(key.contains('front') ? 3 : 4, image));
        }
      }
    }
    return pictures;
  }

  static Future<Uint8List?> _readAsf(RandomAccessFile raf, int length) async {
    await raf.setPosition(0);
    final header = await _readExact(raf, 30);
    if (header.length < 30 || !_matchesGuid(header, 0, _asfHeaderGuid)) {
      return null;
    }
    final headerSize = _le64(header, 16);
    if (headerSize < 30 || headerSize > length || headerSize > maxImageBytes) {
      return null;
    }
    await raf.setPosition(0);
    final blob = await _readExact(raf, headerSize);
    final pictures = <_Picture>[];
    var pos = 30;
    while (pos + 24 <= blob.length) {
      final objectSize = _le64(blob, pos + 16);
      if (objectSize < 24 || pos + objectSize > blob.length) break;
      final object = blob.sublist(pos, pos + objectSize);
      if (_matchesGuid(object, 0, _asfExtendedContentGuid)) {
        pictures.addAll(_asfExtendedPictures(object));
      } else if (_matchesGuid(object, 0, _asfMetadataLibraryGuid)) {
        pictures.addAll(_asfLibraryPictures(object));
      }
      pos += objectSize;
    }
    return _best(pictures);
  }

  static List<_Picture> _asfExtendedPictures(Uint8List object) {
    if (object.length < 26) return const <_Picture>[];
    final count = _le16(object, 24);
    var offset = 26;
    final pictures = <_Picture>[];
    for (var i = 0; i < count && offset + 6 <= object.length; i++) {
      final nameLength = _le16(object, offset);
      offset += 2;
      if (nameLength < 0 || offset + nameLength + 4 > object.length) break;
      final name = _utf16le(object.sublist(offset, offset + nameLength));
      offset += nameLength;
      final valueType = _le16(object, offset);
      final valueLength = _le16(object, offset + 2);
      offset += 4;
      if (valueLength < 0 || offset + valueLength > object.length) break;
      final value = object.sublist(offset, offset + valueLength);
      offset += valueLength;
      if (valueType == 1 && name.toLowerCase() == 'wm/picture') {
        final picture = _parseWmPicture(value);
        if (picture != null) pictures.add(picture);
      }
    }
    return pictures;
  }

  static List<_Picture> _asfLibraryPictures(Uint8List object) {
    if (object.length < 26) return const <_Picture>[];
    final count = _le16(object, 24);
    var offset = 26;
    final pictures = <_Picture>[];
    for (var i = 0; i < count && offset + 12 <= object.length; i++) {
      final nameLength = _le16(object, offset + 4);
      final dataType = _le16(object, offset + 6);
      final dataLength = _le32(object, offset + 8);
      offset += 12;
      if (nameLength < 0 ||
          dataLength < 0 ||
          offset + nameLength + dataLength > object.length) {
        break;
      }
      final name = _utf16le(object.sublist(offset, offset + nameLength));
      offset += nameLength;
      final value = object.sublist(offset, offset + dataLength);
      offset += dataLength;
      if (dataType == 1 && name.toLowerCase() == 'wm/picture') {
        final picture = _parseWmPicture(value);
        if (picture != null) pictures.add(picture);
      }
    }
    return pictures;
  }

  static _Picture? _parseWmPicture(Uint8List value) {
    if (value.length < 6) return null;
    final type = value[0];
    final dataLength = _le32(value, 1);
    var offset = 5;
    final mimeEnd = _utf16zEnd(value, offset);
    if (mimeEnd < 0) return null;
    offset = mimeEnd;
    final descEnd = _utf16zEnd(value, offset);
    if (descEnd < 0) return null;
    offset = descEnd;
    if (dataLength <= 0 || offset + dataLength > value.length) return null;
    final image = value.sublist(offset, offset + dataLength);
    if (!looksLikeImage(image)) return null;
    return _Picture(type, image);
  }

  static Future<List<String>> _sidecarCandidates(
    Iterable<String> audioPaths,
  ) async {
    final found = <String>[];
    final seenDirs = <String>{};
    for (final audioPath in audioPaths) {
      if (audioPath.trim().isEmpty) continue;
      final dirPath = p.dirname(audioPath);
      final dirKey = Platform.isWindows ? dirPath.toLowerCase() : dirPath;
      if (!seenDirs.add(dirKey)) continue;
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;
      final files = <String, String>{};
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          files[p.basename(entity.path).toLowerCase()] = entity.path;
        }
      } catch (_) {
        continue;
      }
      final base = p.basenameWithoutExtension(audioPath).toLowerCase();
      final names = <String>[
        for (final name in _sidecarBasenames)
          for (final ext in _sidecarExtensions) '$name$ext',
        for (final ext in _sidecarExtensions) '$base$ext',
        for (final ext in _sidecarExtensions) '$base.cover$ext',
      ];
      for (final name in names) {
        final match = files[name];
        if (match == null || found.contains(match)) continue;
        if (await _readImageFile(match) != null) found.add(match);
      }
    }
    return found;
  }

  static Future<Uint8List?> _readImageFile(String path) async {
    try {
      final file = File(path);
      final length = await file.length();
      if (length < 4 || length > maxImageBytes) return null;
      final bytes = await file.readAsBytes();
      if (!looksLikeImage(bytes)) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _best(List<_Picture> pictures) {
    if (pictures.isEmpty) return null;
    _Picture? front;
    _Picture? other;
    for (final picture in pictures) {
      if (!looksLikeImage(picture.bytes)) continue;
      if (picture.type == 3) {
        if (front == null || picture.bytes.length > front.bytes.length) {
          front = picture;
        }
      } else if (other == null || picture.bytes.length > other.bytes.length) {
        other = picture;
      }
    }
    return (front ?? other)?.bytes;
  }

  static int _terminatedEnd(Uint8List data, int offset, int encoding) {
    if (encoding == 1 || encoding == 2) {
      for (var i = offset; i + 1 < data.length; i += 2) {
        if (data[i] == 0 && data[i + 1] == 0) return i + 2;
      }
      return data.length;
    }
    final zero = data.indexOf(0, offset);
    return zero < 0 ? data.length : zero + 1;
  }

  static int _utf16zEnd(Uint8List data, int offset) {
    for (var i = offset; i + 1 < data.length; i += 2) {
      if (data[i] == 0 && data[i + 1] == 0) return i + 2;
    }
    return -1;
  }

  static String _utf16le(Uint8List bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final unit = bytes[i] | (bytes[i + 1] << 8);
      if (unit == 0) break;
      units.add(unit);
    }
    return String.fromCharCodes(units);
  }

  static Uint8List _deunsync(Uint8List data) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < data.length; i++) {
      out.addByte(data[i]);
      if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0x00) {
        i++;
      }
    }
    return out.toBytes();
  }

  static bool _matchesGuid(Uint8List bytes, int offset, List<int> guid) {
    if (offset + guid.length > bytes.length) return false;
    for (var i = 0; i < guid.length; i++) {
      if (bytes[offset + i] != guid[i]) return false;
    }
    return true;
  }

  static bool _startsWith(List<int> bytes, String text) {
    if (bytes.length < text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static String _fourCC(List<int> bytes, int offset) {
    if (offset + 4 > bytes.length) return '';
    return String.fromCharCodes(bytes.sublist(offset, offset + 4));
  }

  static int _be32(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _le32(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static int _le16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _le64(List<int> bytes, int offset) {
    var value = 0;
    for (var i = 7; i >= 0; i--) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }

  static int _be64(List<int> bytes) {
    var value = 0;
    for (final byte in bytes) {
      value = (value << 8) | byte;
    }
    return value;
  }

  static int _synchsafe(List<int> bytes, int offset) =>
      ((bytes[offset] & 0x7f) << 21) |
      ((bytes[offset + 1] & 0x7f) << 14) |
      ((bytes[offset + 2] & 0x7f) << 7) |
      (bytes[offset + 3] & 0x7f);

  static Future<Uint8List> _readExact(RandomAccessFile raf, int count) async {
    if (count <= 0) return Uint8List(0);
    final out = Uint8List(count);
    var filled = 0;
    while (filled < count) {
      final chunk = await raf.read(count - filled);
      if (chunk.isEmpty) return out.sublist(0, filled);
      out.setRange(filled, filled + chunk.length, chunk);
      filled += chunk.length;
    }
    return out;
  }
}

int _min(int a, int b) => a < b ? a : b;

class _Picture {
  const _Picture(this.type, this.bytes);

  /// ID3 / FLAC picture type. 3 is the front cover.
  final int type;
  final Uint8List bytes;
}

/// ASF Header Object.
const List<int> _asfHeaderGuid = <int>[
  0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, //
  0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
];

/// ASF Extended Content Description Object.
const List<int> _asfExtendedContentGuid = <int>[
  0x40, 0xA4, 0xD0, 0xD2, 0x07, 0xE3, 0xD2, 0x11, //
  0x97, 0xF0, 0x00, 0xA0, 0xC9, 0x5E, 0xA8, 0x50,
];

/// ASF Metadata Library Object.
const List<int> _asfMetadataLibraryGuid = <int>[
  0x94, 0x1C, 0x23, 0x44, 0x98, 0x94, 0xD1, 0x49, //
  0xA1, 0x41, 0x1D, 0x13, 0x4E, 0x45, 0x70, 0x54,
];
