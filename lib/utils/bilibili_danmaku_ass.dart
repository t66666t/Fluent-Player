import 'dart:math' as math;

import '../models/danmaku_model.dart';

class BilibiliDanmakuAss {
  static const double referenceWidth = 1920;
  static const double referenceHeight = 1080;
  static const double baseFontSize = 40;
  static const double scrollDurationSeconds = 8;
  static const double fixedDurationSeconds = 4;

  static String xmlToAss(String xml) {
    final sourceItems = <_XmlDanmaku>[];
    final expression = RegExp(
      r'<d\s+[^>]*p="([^"]+)"[^>]*>([\s\S]*?)</d>',
      caseSensitive: false,
    );
    for (final match in expression.allMatches(xml)) {
      final fields = match.group(1)!.split(',');
      if (fields.length < 4) continue;
      final start = double.tryParse(fields[0]);
      final mode = int.tryParse(fields[1]);
      final color = int.tryParse(fields[3]);
      if (start == null || mode == null || color == null) continue;
      final text = _decodeXml(match.group(2) ?? '').trim();
      if (text.isEmpty) continue;
      sourceItems.add(
        _XmlDanmaku(start: start, mode: mode, color: color, text: text),
      );
    }
    if (sourceItems.isEmpty &&
        RegExp(r'<d(?:\s|>)', caseSensitive: false).hasMatch(xml)) {
      throw const FormatException('Bilibili danmaku XML could not be parsed.');
    }
    sourceItems.sort((a, b) => a.start.compareTo(b.start));

    final lanes = _LaneAllocator();
    final output = StringBuffer()
      ..writeln('[Script Info]')
      ..writeln('Script Updated By: Fluent Player')
      ..writeln('ScriptType: v4.00+')
      ..writeln('PlayResX: ${referenceWidth.toInt()}')
      ..writeln('PlayResY: ${referenceHeight.toInt()}')
      ..writeln('Collisions: Normal')
      ..writeln('WrapStyle: 2')
      ..writeln('ScaledBorderAndShadow: yes')
      ..writeln()
      ..writeln('[V4+ Styles]')
      ..writeln(
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
      )
      ..writeln(
        'Style: Danmaku,Arial,40,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,7,0,0,0,1',
      )
      ..writeln()
      ..writeln('[Events]')
      ..writeln(
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
      );

    for (final item in sourceItems) {
      final type = item.mode == 4
          ? DanmakuType.bottom
          : item.mode == 5
          ? DanmakuType.top
          : DanmakuType.scroll;
      final duration = type == DanmakuType.scroll
          ? scrollDurationSeconds
          : fixedDurationSeconds;
      final lane = lanes.allocate(
        type: type,
        start: item.start,
        duration: duration,
        textLength: item.text.runes.length,
      );
      if (lane < 0) continue;
      final y = type == DanmakuType.bottom
          ? referenceHeight - baseFontSize - lane * baseFontSize
          : lane * baseFontSize;
      final effect = switch (type) {
        DanmakuType.scroll =>
          '\\move(${referenceWidth.toInt()},${y.toStringAsFixed(0)},'
              '${(-math.max(1, item.text.runes.length) * baseFontSize).toStringAsFixed(0)},${y.toStringAsFixed(0)})',
        DanmakuType.top || DanmakuType.bottom =>
          '\\an8\\pos(${(referenceWidth / 2).toStringAsFixed(0)},${y.toStringAsFixed(0)})',
      };
      final colorTag = item.color == 0xFFFFFF
          ? ''
          : '\\c&H${_rgbToAss(item.color)}&';
      output.writeln(
        'Dialogue: 0,${_assTime(item.start)},${_assTime(item.start + duration)},Danmaku,,0,0,0,,{$effect$colorTag}${_escapeAss(item.text)}',
      );
    }
    return output.toString();
  }

  static String _assTime(double seconds) {
    final centiseconds = (seconds * 100).round();
    final hours = centiseconds ~/ 360000;
    final minutes = (centiseconds ~/ 6000) % 60;
    final secs = (centiseconds ~/ 100) % 60;
    final cs = centiseconds % 100;
    return '$hours:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
  }

  static String _rgbToAss(int rgb) {
    final red = (rgb >> 16) & 0xFF;
    final green = (rgb >> 8) & 0xFF;
    final blue = rgb & 0xFF;
    return '${blue.toRadixString(16).padLeft(2, '0')}${green.toRadixString(16).padLeft(2, '0')}${red.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
  }

  static String _escapeAss(String value) => value
      .replaceAll('\\', '/')
      .replaceAll('{', '(')
      .replaceAll('}', ')')
      .replaceAll('\r', '')
      .replaceAll('\n', r'\N');

  static String _decodeXml(String value) {
    var result = value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
    result = result.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final code = int.tryParse(match.group(1)!);
      return code == null ? match.group(0)! : String.fromCharCode(code);
    });
    result = result.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
      final code = int.tryParse(match.group(1)!, radix: 16);
      return code == null ? match.group(0)! : String.fromCharCode(code);
    });
    return result;
  }
}

class _XmlDanmaku {
  final double start;
  final int mode;
  final int color;
  final String text;

  const _XmlDanmaku({
    required this.start,
    required this.mode,
    required this.color,
    required this.text,
  });
}

class _LaneAllocator {
  static const int laneCount = 13;
  final scroll = List<double>.filled(laneCount, 0);
  final top = List<double>.filled(laneCount, 0);
  final bottom = List<double>.filled(laneCount, 0);

  int allocate({
    required DanmakuType type,
    required double start,
    required double duration,
    required int textLength,
  }) {
    final lanes = switch (type) {
      DanmakuType.scroll => scroll,
      DanmakuType.top => top,
      DanmakuType.bottom => bottom,
    };
    final occupancy = type == DanmakuType.scroll
        ? duration *
              (textLength + 5) *
              BilibiliDanmakuAss.baseFontSize /
              (BilibiliDanmakuAss.referenceWidth + textLength * duration)
        : duration;
    for (var i = 0; i < lanes.length; i++) {
      if (start >= lanes[i]) {
        lanes[i] = start + occupancy;
        return i;
      }
    }
    return -1;
  }
}
