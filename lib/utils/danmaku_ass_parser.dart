import '../models/danmaku_model.dart';

class DanmakuAssParser {
  static DanmakuDocument parse(String content) {
    var referenceWidth = 1920.0;
    var referenceHeight = 1080.0;
    final widthMatch = RegExp(
      r'^PlayResX:\s*([\d.]+)',
      multiLine: true,
    ).firstMatch(content);
    final heightMatch = RegExp(
      r'^PlayResY:\s*([\d.]+)',
      multiLine: true,
    ).firstMatch(content);
    referenceWidth =
        double.tryParse(widthMatch?.group(1) ?? '') ?? referenceWidth;
    referenceHeight =
        double.tryParse(heightMatch?.group(1) ?? '') ?? referenceHeight;

    final items = <DanmakuItem>[];
    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      if (!rawLine.trimLeft().toLowerCase().startsWith('dialogue:')) continue;
      final fields = _splitDialogue(
        rawLine.substring(rawLine.indexOf(':') + 1),
      );
      if (fields.length < 10) continue;
      final start = _parseTime(fields[1]);
      final end = _parseTime(fields[2]);
      if (start == null || end == null || end <= start) continue;
      final rawText = fields[9];
      final tagMatch = RegExp(r'^\{([^}]*)\}').firstMatch(rawText);
      final tags = tagMatch?.group(1) ?? '';
      final move = RegExp(
        r'\\move\(\s*[-\d.]+\s*,\s*([-\d.]+)\s*,\s*[-\d.]+\s*,\s*([-\d.]+)',
        caseSensitive: false,
      ).firstMatch(tags);
      final position = RegExp(
        r'\\pos\(\s*[-\d.]+\s*,\s*([-\d.]+)',
        caseSensitive: false,
      ).firstMatch(tags);
      final isScrolling = move != null;
      final sourceY =
          double.tryParse(move?.group(1) ?? position?.group(1) ?? '0') ?? 0;
      final type = isScrolling
          ? DanmakuType.scroll
          : sourceY >= referenceHeight / 2
          ? DanmakuType.bottom
          : DanmakuType.top;
      final colorMatch = RegExp(
        r'\\(?:1c|c)&H([0-9A-Fa-f]{1,8})&',
      ).firstMatch(tags);
      final text = rawText
          .replaceFirst(RegExp(r'^\{[^}]*\}'), '')
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .trim();
      if (text.isEmpty) continue;
      items.add(
        DanmakuItem(
          index: items.length,
          startTime: start,
          duration: end - start,
          text: text,
          type: type,
          colorValue: _assColorToArgb(colorMatch?.group(1)),
          sourceY: sourceY.clamp(0, referenceHeight),
        ),
      );
    }
    items.sort((a, b) => a.startTime.compareTo(b.startTime));
    return DanmakuDocument(
      items: List<DanmakuItem>.unmodifiable(items),
      referenceWidth: referenceWidth,
      referenceHeight: referenceHeight,
    );
  }

  static List<String> _splitDialogue(String value) {
    final result = <String>[];
    var remaining = value;
    for (var i = 0; i < 9; i++) {
      final comma = remaining.indexOf(',');
      if (comma < 0) return result;
      result.add(remaining.substring(0, comma).trim());
      remaining = remaining.substring(comma + 1);
    }
    result.add(remaining);
    return result;
  }

  static Duration? _parseTime(String value) {
    final match = RegExp(
      r'^(\d+):(\d{1,2}):(\d{1,2})[.](\d{1,3})$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final fraction = match.group(4)!.padRight(3, '0').substring(0, 3);
    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
      milliseconds: int.parse(fraction),
    );
  }

  static int _assColorToArgb(String? value) {
    if (value == null || value.isEmpty) return 0xFFFFFFFF;
    final padded = value.padLeft(8, '0');
    final raw = int.tryParse(padded, radix: 16) ?? 0x00FFFFFF;
    final alpha = 0xFF - ((raw >> 24) & 0xFF);
    final blue = (raw >> 16) & 0xFF;
    final green = (raw >> 8) & 0xFF;
    final red = raw & 0xFF;
    return (alpha << 24) | (red << 16) | (green << 8) | blue;
  }
}
