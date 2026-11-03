import 'dart:convert';
import 'dart:typed_data';

class ParsedSubtitleFont {
  final String family;
  final List<int> weights;
  final List<List<int>> coverage;
  const ParsedSubtitleFont(this.family, this.weights, this.coverage);
}

/// Reads the OpenType tables used by the library. All offsets are bounded by
/// their containing table before accessing untrusted imported font bytes.
ParsedSubtitleFont parseSubtitleFont(Uint8List bytes) {
  Never invalid() => throw const FormatException('字体文件损坏或格式不支持');
  if (bytes.length < 12 || bytes.length > 64 * 1024 * 1024) invalid();
  final data = ByteData.sublistView(bytes);
  final signature = data.getUint32(0);
  if (signature != 0x00010000 && signature != 0x4f54544f) invalid();
  final count = data.getUint16(4);
  if (count == 0 || count > 512 || 12 + count * 16 > bytes.length) invalid();
  final tables = <String, (int, int)>{};
  for (var i = 0; i < count; i++) {
    final entry = 12 + 16 * i;
    final tag = ascii.decode(
      bytes.sublist(entry, entry + 4),
      allowInvalid: true,
    );
    final start = data.getUint32(entry + 8),
        length = data.getUint32(entry + 12);
    if (start > bytes.length || length > bytes.length - start) invalid();
    tables[tag] = (start, length);
  }
  ByteData table(String name, int minimum) {
    final t = tables[name];
    if (t == null || t.$2 < minimum) invalid();
    return ByteData.sublistView(bytes, t.$1, t.$1 + t.$2);
  }

  table('head', 54);
  table('maxp', 6);
  if (!tables.containsKey('glyf') &&
      !tables.containsKey('CFF ') &&
      !tables.containsKey('CFF2')) {
    invalid();
  }
  final names = table('name', 6);
  final records = names.getUint16(2), storage = names.getUint16(4);
  if (6 + records * 12 > names.lengthInBytes) invalid();
  var family = '', priority = -1;
  for (var i = 0; i < records; i++) {
    final r = 6 + i * 12;
    final platform = names.getUint16(r), language = names.getUint16(r + 4);
    final id = names.getUint16(r + 6);
    if (id != 1 && id != 16) continue;
    final length = names.getUint16(r + 8),
        offset = storage + names.getUint16(r + 10);
    if (offset + length > names.lengthInBytes) invalid();
    final raw = names.buffer.asUint8List(names.offsetInBytes + offset, length);
    String value;
    if (platform == 0 || platform == 3) {
      if (length.isOdd) invalid();
      value = String.fromCharCodes(
        List.generate(length ~/ 2, (j) => raw[j * 2] * 256 + raw[j * 2 + 1]),
      );
    } else {
      value = latin1.decode(raw);
    }
    value = value.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    final score =
        (id == 16 ? 10 : 0) +
        (platform == 3 ? 4 : 0) +
        (language == 0x409 ? 2 : 0);
    if (value.isNotEmpty && score > priority) {
      family = value;
      priority = score;
    }
  }
  if (family.isEmpty ||
      family.length > 200 ||
      RegExp(r'[{},\\]').hasMatch(family)) {
    invalid();
  }
  var weight = 400;
  if (tables.containsKey('OS/2')) {
    weight = table('OS/2', 6).getUint16(4).clamp(100, 900);
  }
  var weights = [((weight / 100).round() * 100).clamp(100, 900)];
  if (tables.containsKey('fvar')) {
    final f = table('fvar', 16);
    final start = f.getUint16(4), n = f.getUint16(8), size = f.getUint16(10);
    if (size < 20 || start + n * size > f.lengthInBytes) invalid();
    for (var i = 0; i < n; i++) {
      final a = start + i * size;
      if (f.getUint32(a) == 0x77676874) {
        final min = f.getInt32(a + 4) / 65536, max = f.getInt32(a + 12) / 65536;
        weights = [
          for (var w = 100; w <= 900; w += 100)
            if (w >= min && w <= max) w,
        ];
        if (weights.isEmpty) weights = [weight];
      }
    }
  }
  final cmap = table('cmap', 4);
  final maps = cmap.getUint16(2);
  if (4 + maps * 8 > cmap.lengthInBytes) invalid();
  if (maps > 64) invalid();
  final processed = <int>{};
  var work = 0;
  final points = <int>{};
  for (var i = 0; i < maps; i++) {
    final platform = cmap.getUint16(4 + 8 * i);
    if (platform != 0 && platform != 3) continue;
    final start = cmap.getUint32(8 + 8 * i);
    if (start + 2 > cmap.lengthInBytes) invalid();
    if (!processed.add(start)) continue;
    final format = cmap.getUint16(start);
    if (format == 12) {
      if (start + 16 > cmap.lengthInBytes) invalid();
      final length = cmap.getUint32(start + 4), n = cmap.getUint32(start + 12);
      if (length < 16 ||
          start + length > cmap.lengthInBytes ||
          16 + n * 12 > length) {
        invalid();
      }
      for (var j = 0; j < n; j++) {
        final a = start + 16 + j * 12;
        final from = cmap.getUint32(a),
            to = cmap.getUint32(a + 4),
            glyph = cmap.getUint32(a + 8);
        if (from > to || to > 0x10ffff) invalid();
        work += to - from + 1;
        if (work > 4 * 0x110000) invalid();
        for (var cp = from; cp <= to; cp++) {
          if (glyph + cp - from != 0) points.add(cp);
        }
      }
    } else if (format == 4) {
      if (start + 14 > cmap.lengthInBytes) invalid();
      final length = cmap.getUint16(start + 2),
          n = cmap.getUint16(start + 6) ~/ 2;
      if (n == 0 ||
          length < 16 + n * 8 ||
          start + length > cmap.lengthInBytes) {
        invalid();
      }
      for (var j = 0; j < n; j++) {
        final end = cmap.getUint16(start + 14 + 2 * j);
        final from = cmap.getUint16(start + 16 + n * 2 + 2 * j);
        final delta = cmap.getInt16(start + 16 + n * 4 + 2 * j);
        final r = start + 16 + n * 6 + 2 * j, offset = cmap.getUint16(r);
        if (from > end) invalid();
        work += end - from + 1;
        if (work > 4 * 0x110000) invalid();
        for (var cp = from; cp <= end && cp < 0xffff; cp++) {
          var glyph = (cp + delta) & 0xffff;
          if (offset != 0) {
            final at = r + offset + (cp - from) * 2;
            if (at + 2 > start + length) invalid();
            glyph = cmap.getUint16(at);
            if (glyph != 0) glyph = (glyph + delta) & 0xffff;
          }
          if (glyph != 0) points.add(cp);
        }
      }
    }
  }
  if (points.isEmpty) invalid();
  final sorted = points.toList()..sort();
  final ranges = <List<int>>[];
  for (final cp in sorted) {
    if (ranges.isNotEmpty && ranges.last[1] + 1 == cp) {
      ranges.last[1] = cp;
    } else {
      ranges.add([cp, cp]);
    }
  }
  return ParsedSubtitleFont(family, weights, ranges);
}
