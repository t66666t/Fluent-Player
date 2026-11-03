import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/audio_cover_art.dart';

void main() {
  final jpeg = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]);

  test('reads an Apple covr atom from m4a', () async {
    final file = await _writeTemp('song.m4a', _m4a(jpeg));
    final cover = await AudioCoverArt.readEmbedded(file.path);
    expect(cover, jpeg);
  });

  test('reads ID3 APIC and prefers the front cover', () async {
    final other = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD0]);
    final file = await _writeTemp(
      'song.mp3',
      _id3(<_Apic>[_Apic(type: 0, bytes: other), _Apic(type: 3, bytes: jpeg)]),
    );
    expect(await AudioCoverArt.readEmbedded(file.path), jpeg);
  });

  test('reads a FLAC picture block', () async {
    final file = await _writeTemp('song.flac', _flac(jpeg));
    expect(await AudioCoverArt.readEmbedded(file.path), jpeg);
  });

  test('reads an Ogg Vorbis metadata picture', () async {
    final file = await _writeTemp('song.ogg', _ogg(jpeg));
    expect(await AudioCoverArt.readEmbedded(file.path), jpeg);
  });

  test('reads APEv2 front cover', () async {
    final file = await _writeTemp('song.ape', _ape(jpeg));
    expect(await AudioCoverArt.readEmbedded(file.path), jpeg);
  });

  test('reads a WAV id3 chunk', () async {
    final file = await _writeTemp(
      'song.wav',
      _wav(_id3(<_Apic>[_Apic(type: 3, bytes: jpeg)])),
    );
    expect(await AudioCoverArt.readEmbedded(file.path), jpeg);
  });

  test('reads a WMA WM/Picture value', () async {
    final file = await _writeTemp('song.wma', _wma(jpeg));
    expect(await AudioCoverArt.readEmbedded(file.path), jpeg);
  });

  test('uses cover.jpg when the audio file has no embedded art', () async {
    final dir = await Directory.systemTemp.createTemp('audio_cover_sidecar_');
    addTearDown(() => dir.delete(recursive: true));
    final audio = File(p.join(dir.path, 'track.mp3'));
    await audio.writeAsBytes(<int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    await File(p.join(dir.path, 'cover.jpg')).writeAsBytes(jpeg);
    final out = File(p.join(dir.path, 'out.jpg'));
    final written = await AudioCoverArt.writeCover(
      audioPath: audio.path,
      outputPath: out.path,
    );
    expect(written, out.path);
    expect(await out.readAsBytes(), jpeg);
  });

  test('reads the College Dropout ALAC cover', () async {
    const path =
        r"D:\BaiduNetdiskDownload\Kanye West - The College Dropout (ALAC 16bit_44kHz)\02. We Don't Care [L].m4a";
    if (!File(path).existsSync()) return;
    final cover = await AudioCoverArt.readEmbedded(path);
    expect(cover, isNotNull);
    expect(cover!.length, 661467);
    expect(cover[0], 0xFF);
    expect(cover[1], 0xD8);
    expect(cover[2], 0xFF);
  });
}

Future<File> _writeTemp(String name, List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('audio_cover_art_');
  addTearDown(() => dir.delete(recursive: true));
  final file = File(p.join(dir.path, name));
  await file.writeAsBytes(bytes);
  return file;
}

Uint8List _m4a(Uint8List jpeg) {
  return _atom('moov', [
    ..._atom('udta', [
      ..._atom('meta', <int>[
        0,
        0,
        0,
        0,
        ..._atom('ilst', [
          ..._atom(
            'covr',
            _atom('data', <int>[0, 0, 0, 13, 0, 0, 0, 0, ...jpeg]),
          ),
        ]),
      ]),
    ]),
  ]);
}

Uint8List _id3(List<_Apic> pictures) {
  final frames = BytesBuilder(copy: false);
  for (final picture in pictures) {
    final payload = BytesBuilder(copy: false);
    payload.addByte(0);
    payload.add(ascii.encode('image/jpeg'));
    payload.addByte(0);
    payload.addByte(picture.type);
    payload.addByte(0);
    payload.add(picture.bytes);
    final body = payload.toBytes();
    frames.add(ascii.encode('APIC'));
    frames.add(_be32(body.length));
    frames.add(<int>[0, 0]);
    frames.add(body);
  }
  final tagBody = frames.toBytes();
  return Uint8List.fromList(<int>[
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    ..._synchsafe(tagBody.length),
    ...tagBody,
  ]);
}

Uint8List _flac(Uint8List jpeg) {
  final block = _pictureBlock(jpeg);
  return Uint8List.fromList(<int>[
    ...ascii.encode('fLaC'),
    0x80 | 6,
    (block.length >> 16) & 0xff,
    (block.length >> 8) & 0xff,
    block.length & 0xff,
    ...block,
  ]);
}

Uint8List _ogg(Uint8List jpeg) {
  final comment = 'METADATA_BLOCK_PICTURE=${base64Encode(_pictureBlock(jpeg))}';
  final vendor = ascii.encode('test');
  final packet = BytesBuilder(copy: false);
  packet.addByte(0x03);
  packet.add(ascii.encode('vorbis'));
  packet.add(_le32(vendor.length));
  packet.add(vendor);
  packet.add(_le32(1));
  packet.add(_le32(comment.length));
  packet.add(ascii.encode(comment));
  final body = packet.toBytes();
  return Uint8List.fromList(<int>[
    ...ascii.encode('OggS'),
    0,
    0,
    ...List<int>.filled(8, 0),
    ...List<int>.filled(4, 1),
    ...List<int>.filled(4, 0),
    ...List<int>.filled(4, 0),
    1,
    body.length,
    ...body,
  ]);
}

Uint8List _ape(Uint8List jpeg) {
  final value = <int>[...ascii.encode('cover.jpg'), 0, ...jpeg];
  final items = BytesBuilder(copy: false);
  items.add(_le32(value.length));
  items.add(_le32(0));
  items.add(ascii.encode('Cover Art (Front)'));
  items.addByte(0);
  items.add(value);
  final itemBytes = items.toBytes();
  final size = itemBytes.length + 32;
  return Uint8List.fromList(<int>[
    ...itemBytes,
    ...ascii.encode('APETAGEX'),
    ..._le32(2000),
    ..._le32(size),
    ..._le32(1),
    ..._le32(0),
    ...List<int>.filled(8, 0),
  ]);
}

Uint8List _wav(Uint8List id3) {
  final riffSize = 4 + 8 + id3.length + (id3.length.isOdd ? 1 : 0);
  final bytes = BytesBuilder(copy: false);
  bytes.add(ascii.encode('RIFF'));
  bytes.add(_le32(riffSize));
  bytes.add(ascii.encode('WAVE'));
  bytes.add(ascii.encode('id3 '));
  bytes.add(_le32(id3.length));
  bytes.add(id3);
  if (id3.length.isOdd) bytes.addByte(0);
  return bytes.toBytes();
}

Uint8List _wma(Uint8List jpeg) {
  final picture = BytesBuilder(copy: false);
  picture.addByte(3);
  picture.add(_le32(jpeg.length));
  picture.add(_utf16z('image/jpeg'));
  picture.add(_utf16z(''));
  picture.add(jpeg);
  final value = picture.toBytes();
  final name = _utf16z('WM/Picture');
  final descriptor = BytesBuilder(copy: false);
  descriptor.add(_le16(name.length));
  descriptor.add(name);
  descriptor.add(_le16(1));
  descriptor.add(_le16(value.length));
  descriptor.add(value);
  final payload = BytesBuilder(copy: false);
  payload.add(_le16(1));
  payload.add(descriptor.toBytes());
  final payloadBytes = payload.toBytes();
  final objectSize = 24 + payloadBytes.length;
  final object = BytesBuilder(copy: false);
  object.add(const <int>[
    0x40, 0xA4, 0xD0, 0xD2, 0x07, 0xE3, 0xD2, 0x11, //
    0x97, 0xF0, 0x00, 0xA0, 0xC9, 0x5E, 0xA8, 0x50,
  ]);
  object.add(_le64(objectSize));
  object.add(payloadBytes);
  final objectBytes = object.toBytes();
  final headerSize = 30 + objectBytes.length;
  final header = BytesBuilder(copy: false);
  header.add(const <int>[
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, //
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
  ]);
  header.add(_le64(headerSize));
  header.add(_le32(1));
  header.add(<int>[0x01, 0x02]);
  header.add(objectBytes);
  return header.toBytes();
}

Uint8List _pictureBlock(Uint8List jpeg) {
  final mime = ascii.encode('image/jpeg');
  final block = BytesBuilder(copy: false);
  block.add(_be32(3));
  block.add(_be32(mime.length));
  block.add(mime);
  block.add(_be32(0));
  block.add(_be32(1));
  block.add(_be32(1));
  block.add(_be32(24));
  block.add(_be32(0));
  block.add(_be32(jpeg.length));
  block.add(jpeg);
  return block.toBytes();
}

Uint8List _atom(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList(<int>[
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...type.codeUnits,
    ...payload,
  ]);
}

List<int> _be32(int value) => <int>[
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

List<int> _le16(int value) => <int>[value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => <int>[
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

List<int> _le64(int value) {
  final out = <int>[];
  var rest = value;
  for (var i = 0; i < 8; i++) {
    out.add(rest & 0xff);
    rest >>= 8;
  }
  return out;
}

List<int> _synchsafe(int value) => <int>[
  (value >> 21) & 0x7f,
  (value >> 14) & 0x7f,
  (value >> 7) & 0x7f,
  value & 0x7f,
];

Uint8List _utf16z(String text) {
  final out = BytesBuilder(copy: false);
  for (final unit in text.codeUnits) {
    out.addByte(unit & 0xff);
    out.addByte((unit >> 8) & 0xff);
  }
  out.add(<int>[0, 0]);
  return out.toBytes();
}

class _Apic {
  const _Apic({required this.type, required this.bytes});

  final int type;
  final Uint8List bytes;
}
