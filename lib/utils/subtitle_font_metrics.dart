import 'dart:typed_data';

/// Distance from the alphabetic baseline to the middle of the cap/x-height
/// band, in em. It is independent of the current sentence's descenders.
double? bundledSubtitleLatinBodyCenter(String family, int weight) =>
    switch (family) {
      'Swei Gothic CJK SC' => .32525,
      'Noto Sans SC' => .319,
      'Noto Serif CJK SC' => .31075,
      'Inter' => 1304 / 4096,
      'Roboto' => 1269 / 4096,
      'Comic Relief' => 2659 / 8192,
      'Brawler' =>
        weight >= 700
            ? .31
            : weight >= 600
            ? .308
            : weight >= 500
            ? .3065
            : .305,
      _ => null,
    };

/// Reads OS/2 cap/x heights, or the H/x TrueType outlines in older fonts.
/// No outline conversion, font modification, or raster readback is needed.
({int weight, double bodyCenter})? parseSubtitleLatinMetrics(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  Never invalid() => throw const FormatException('Invalid font metrics');
  if (bytes.length < 12 || bytes.length > 64 * 1024 * 1024) invalid();
  final signature = d.getUint32(0);
  if (signature != 0x00010000 && signature != 0x4f54544f) invalid();
  final count = d.getUint16(4);
  if (count == 0 || count > 512 || 12 + count * 16 > bytes.length) invalid();
  final tables = <int, ByteData>{};
  for (var i = 0; i < count; i++) {
    final p = 12 + i * 16,
        start = d.getUint32(p + 8),
        length = d.getUint32(p + 12);
    if (start > bytes.length || length > bytes.length - start) invalid();
    tables[d.getUint32(p)] = ByteData.sublistView(bytes, start, start + length);
  }
  final head = tables[0x68656164],
      os2 = tables[0x4f532f32],
      cmap = tables[0x636d6170];
  if (head == null ||
      head.lengthInBytes < 54 ||
      cmap == null ||
      cmap.lengthInBytes < 4) {
    return null;
  }
  final units = head.getUint16(18);
  if (units < 16 || units > 16384) return null;
  final maps = cmap.getUint16(2);
  if (maps > 64 || 4 + maps * 8 > cmap.lengthInBytes) invalid();
  int glyph(int cp) {
    final processed = <int>{};
    var work = 0;
    for (var i = 0; i < maps; i++) {
      final platform = cmap.getUint16(4 + i * 8);
      if (platform != 0 && platform != 3) continue;
      final start = cmap.getUint32(8 + i * 8);
      if (start > cmap.lengthInBytes - 2) invalid();
      if (!processed.add(start)) continue;
      final format = cmap.getUint16(start);
      if (format == 12) {
        if (start + 16 > cmap.lengthInBytes) invalid();
        final length = cmap.getUint32(start + 4),
            n = cmap.getUint32(start + 12);
        if (length < 16 ||
            length > cmap.lengthInBytes - start ||
            n > (length - 16) ~/ 12) {
          invalid();
        }
        work += n;
        if (work > 4 * 0x110000) invalid();
        for (var j = 0; j < n; j++) {
          final p = start + 16 + j * 12,
              from = cmap.getUint32(p),
              to = cmap.getUint32(p + 4);
          if (from <= cp && cp <= to) return cmap.getUint32(p + 8) + cp - from;
        }
      } else if (format == 4) {
        if (start + 14 > cmap.lengthInBytes) invalid();
        final length = cmap.getUint16(start + 2),
            n = cmap.getUint16(start + 6) ~/ 2;
        if (n == 0 ||
            length < 16 + n * 8 ||
            length > cmap.lengthInBytes - start) {
          invalid();
        }
        work += n;
        if (work > 4 * 0x110000) invalid();
        for (var j = 0; j < n; j++) {
          final end = cmap.getUint16(start + 14 + 2 * j),
              from = cmap.getUint16(start + 16 + 2 * n + 2 * j);
          if (cp < from || cp > end) continue;
          final delta = cmap.getInt16(start + 16 + 4 * n + 2 * j),
              p = start + 16 + 6 * n + 2 * j;
          final offset = cmap.getUint16(p);
          if (offset == 0) return (cp + delta) & 0xffff;
          final at = p + offset + 2 * (cp - from);
          if (at + 2 > start + length) invalid();
          final value = cmap.getUint16(at);
          return value == 0 ? 0 : (value + delta) & 0xffff;
        }
      }
    }
    return 0;
  }

  final h = glyph(0x48), x = glyph(0x78);
  if (h == 0 || x == 0) return null;
  double? outlineHeight(int index) {
    final loca = tables[0x6c6f6361],
        glyf = tables[0x676c7966],
        maxp = tables[0x6d617870];
    if (loca == null ||
        glyf == null ||
        maxp == null ||
        maxp.lengthInBytes < 6 ||
        index >= maxp.getUint16(4)) {
      return null;
    }
    final format = head.getInt16(50);
    if (format != 0 && format != 1) return null;
    final stride = format == 0 ? 2 : 4;
    if ((index + 2) * stride > loca.lengthInBytes) invalid();
    final start = format == 0
        ? loca.getUint16(index * 2) * 2
        : loca.getUint32(index * 4);
    final end = format == 0
        ? loca.getUint16((index + 1) * 2) * 2
        : loca.getUint32((index + 1) * 4);
    if (start > end || end > glyf.lengthInBytes) invalid();
    return end - start >= 10 ? glyf.getInt16(start + 8).toDouble() : null;
  }

  double? xHeight, capHeight;
  if (os2 != null && os2.lengthInBytes >= 90 && os2.getUint16(0) >= 2) {
    xHeight = os2.getInt16(86).toDouble();
    capHeight = os2.getInt16(88).toDouble();
  }
  if (xHeight == null || xHeight <= 0) xHeight = outlineHeight(x);
  if (capHeight == null || capHeight <= 0) capHeight = outlineHeight(h);
  if (xHeight == null ||
      capHeight == null ||
      xHeight <= 0 ||
      capHeight < xHeight ||
      capHeight > units * 2) {
    return null;
  }
  return (
    weight: os2 != null && os2.lengthInBytes >= 6
        ? os2.getUint16(4).clamp(1, 1000)
        : 400,
    bodyCenter: (capHeight + xHeight) / (4 * units),
  );
}
