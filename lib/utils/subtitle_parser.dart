import 'dart:convert';
import 'package:fast_gbk/fast_gbk.dart';
import '../models/subtitle_model.dart';
import 'timed_subtitle_parser.dart';
import 'lyric_file_codec.dart';

/// 字幕格式枚举，包含文件扩展名和显示名称
enum SubtitleFormat {
  srt('.srt', 'SRT'),
  vtt('.vtt', 'WebVTT'),
  ass('.ass', 'ASS/SSA'),
  lrc('.lrc', 'LRC');

  final String extension;
  final String displayName;
  const SubtitleFormat(this.extension, this.displayName);
}

class SubtitleParser {
  static String decodeBytes(List<int> bytes, {String? sourcePath}) {
    if (bytes.isEmpty) return '';
    final envelope = LyricFileCodec.decode(bytes);
    if (envelope != null) return _normalizeContent(envelope);
    if ((sourcePath?.toLowerCase().endsWith('.qrc') ?? false) &&
        !_hasUtf8Bom(bytes) &&
        !_hasUtf16LeBom(bytes) &&
        !_hasUtf16BeBom(bytes) &&
        !utf8.decode(bytes, allowMalformed: true).trimLeft().startsWith('[') &&
        !utf8.decode(bytes, allowMalformed: true).trimLeft().startsWith('<')) {
      return _normalizeContent(LyricFileCodec.decryptQrc(bytes));
    }

    if (_hasUtf8Bom(bytes)) {
      return _normalizeContent(utf8.decode(bytes.sublist(3)));
    }
    if (_hasUtf16LeBom(bytes)) {
      return _normalizeContent(
        _decodeUtf16(bytes.sublist(2), littleEndian: true),
      );
    }
    if (_hasUtf16BeBom(bytes)) {
      return _normalizeContent(
        _decodeUtf16(bytes.sublist(2), littleEndian: false),
      );
    }

    final utf16Guess = _detectUtf16(bytes);
    if (utf16Guess != null) {
      return _normalizeContent(_decodeUtf16(bytes, littleEndian: utf16Guess));
    }

    String? utf8Content;
    try {
      utf8Content = utf8.decode(bytes);
    } catch (_) {}

    if (utf8Content != null && _containsSubtitleMarkers(utf8Content)) {
      return _normalizeContent(utf8Content);
    }

    String? gbkContent;
    try {
      gbkContent = gbk.decode(bytes);
    } catch (_) {}

    if (gbkContent != null && _containsSubtitleMarkers(gbkContent)) {
      return _normalizeContent(gbkContent);
    }

    final utf16Le = _decodeUtf16(bytes, littleEndian: true);
    if (_containsSubtitleMarkers(utf16Le)) {
      return _normalizeContent(utf16Le);
    }

    final utf16Be = _decodeUtf16(bytes, littleEndian: false);
    if (_containsSubtitleMarkers(utf16Be)) {
      return _normalizeContent(utf16Be);
    }

    if (utf8Content != null) return _normalizeContent(utf8Content);
    if (gbkContent != null) return _normalizeContent(gbkContent);
    return '';
  }

  static String _normalizeContent(String content) {
    if (content.isEmpty) return content;
    return content.replaceAll('\uFEFF', '').replaceAll('\u0000', '');
  }

  static bool _hasUtf8Bom(List<int> bytes) {
    return bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF;
  }

  static bool _hasUtf16LeBom(List<int> bytes) {
    return bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE;
  }

  static bool _hasUtf16BeBom(List<int> bytes) {
    return bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF;
  }

  static bool? _detectUtf16(List<int> bytes) {
    final sample = bytes.length > 200 ? 200 : bytes.length;
    if (sample < 4) return null;
    int evenZero = 0;
    int oddZero = 0;
    for (int i = 0; i < sample; i++) {
      if (bytes[i] == 0) {
        if (i.isEven) {
          evenZero++;
        } else {
          oddZero++;
        }
      }
    }
    final zeroCount = evenZero + oddZero;
    if (zeroCount < sample / 10) return null;
    if (oddZero > evenZero * 2) return true;
    if (evenZero > oddZero * 2) return false;
    return null;
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    if (bytes.isEmpty) return '';
    final length = bytes.length.isEven ? bytes.length : bytes.length - 1;
    final codeUnits = <int>[];
    for (int i = 0; i < length; i += 2) {
      final int unit = littleEndian
          ? (bytes[i] | (bytes[i + 1] << 8))
          : ((bytes[i] << 8) | bytes[i + 1]);
      codeUnits.add(unit);
    }
    return String.fromCharCodes(codeUnits);
  }

  static bool _containsSubtitleMarkers(String content) {
    if (content.isEmpty) return false;
    if (content.contains('-->')) return true;
    if (content.contains('[Script Info]') || content.contains('[Events]')) {
      return true;
    }
    if (content.contains('WEBVTT')) return true;
    if (content.contains('Dialogue:')) return true;
    if (RegExp(r'\[\d{2}:\d{2}').hasMatch(content)) return true;
    return false;
  }

  static String _stripStyleTokens(String text) {
    if (text.isEmpty) return text;
    String cleaned = text.replaceAll(RegExp(r'\{\\[^}]*\}'), '');
    cleaned = cleaned.replaceAll(
      RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false),
      '\n',
    );
    cleaned = cleaned.replaceAll(RegExp(r'</?[^>]+>'), '');
    cleaned = cleaned.replaceAll('&nbsp;', ' ');
    cleaned = cleaned.replaceAll('&amp;', '&');
    cleaned = cleaned.replaceAll('&lt;', '<');
    cleaned = cleaned.replaceAll('&gt;', '>');
    cleaned = cleaned.replaceAll('&quot;', '"');
    cleaned = cleaned.replaceAll('&#39;', "'");
    cleaned = cleaned.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    cleaned = cleaned.replaceAll(RegExp(r'\n[ \t]+'), '\n');
    cleaned = cleaned.split('\n').map((line) => line.trim()).join('\n');
    return cleaned.trim();
  }

  /// 自动解析字幕内容 (根据内容特征)
  static List<SubtitleItem> parse(
    String content, {
    String? sourcePath,
    Duration? mediaDuration,
  }) {
    final normalized = _normalizeContent(content);
    final input = sourcePath?.toLowerCase().endsWith('.lyl') == true
        ? '[type:LyricifyLines]\n$normalized'
        : normalized;
    final timed = TimedSubtitleParser.tryParse(
      input,
      mediaDuration: mediaDuration,
    );
    if (timed != null) return timed;
    final head = normalized.trimLeft();
    if (head.startsWith('WEBVTT') || normalized.contains('WEBVTT')) {
      return parseVtt(normalized);
    } else if (normalized.contains('[Script Info]') ||
        normalized.contains('[Events]')) {
      return parseAss(normalized);
    } else if (normalized.contains('-->')) {
      return parseSrt(normalized);
    } else if (RegExp(r'\[\d{2}:\d{2}').hasMatch(normalized)) {
      return parseLrc(normalized);
    }
    return []; // 未知格式
  }

  /// 根据纯文本内容特征推断字幕格式（不依赖文件扩展名）
  /// 检测优先级: WEBVTT > [Script Info]/[Events]/Dialogue: > --> > [mm:ss > 默认SRT
  static SubtitleFormat detectFormat(String content) {
    final normalized = _normalizeContent(content).trim();
    if (normalized.isEmpty) return SubtitleFormat.srt;

    // ① WEBVTT 头标识 → VTT
    if (normalized.contains('WEBVTT')) {
      return SubtitleFormat.vtt;
    }
    // ② ASS/SSA 段落头或对话行标记 → ASS
    if (normalized.contains('[Script Info]') ||
        normalized.contains('[Events]') ||
        normalized.contains('Dialogue:')) {
      return SubtitleFormat.ass;
    }
    // ③ 时间箭头 → SRT (VTT 已在 ① 排除)
    if (normalized.contains('-->')) {
      return SubtitleFormat.srt;
    }
    // ④ [mm:ss 时间标签 → LRC
    if (RegExp(r'\[\d{2}:\d{2}').hasMatch(normalized)) {
      return SubtitleFormat.lrc;
    }
    // ⑤ 无法识别，默认 SRT
    return SubtitleFormat.srt;
  }

  /// 解析 WebVTT 格式
  static List<SubtitleItem> parseVtt(String vttContent) {
    List<SubtitleItem> subtitles = [];
    final String content = _normalizeContent(
      vttContent,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = content.split('\n');

    int index = 0;
    final RegExp timeReg = RegExp(
      r'((\d{1,2}:)?\d{2}:\d{2}\.\d{1,3})\s*-->\s*((\d{1,2}:)?\d{2}:\d{2}\.\d{1,3})',
    );
    while (index < lines.length) {
      String line = lines[index].replaceAll('\uFEFF', '').trim();
      // Skip header or empty lines
      if (line.isEmpty || line == 'WEBVTT') {
        index++;
        continue;
      }

      // VTT might have an ID line before the timestamp
      // Check if current line is timestamp or next line is timestamp
      String? timestampLine;

      if (line.contains('-->')) {
        timestampLine = line;
      } else if (index + 1 < lines.length && lines[index + 1].contains('-->')) {
        index++; // Skip ID line
        timestampLine = lines[index].replaceAll('\uFEFF', '').trim();
      }

      if (timestampLine != null && timestampLine.contains('-->')) {
        final match = timeReg.firstMatch(timestampLine);
        if (match != null) {
          Duration start = _parseVttDuration(match.group(1)!.trim());
          Duration end = _parseVttDuration(match.group(3)!.trim());

          index++;
          StringBuffer textBuffer = StringBuffer();
          while (index < lines.length) {
            String textLine = lines[index].trim();
            if (textLine.isEmpty) break;
            final cleaned = _stripStyleTokens(textLine);
            if (cleaned.isNotEmpty) {
              if (textBuffer.isNotEmpty) textBuffer.write('\n');
              textBuffer.write(cleaned);
            }
            index++;
          }

          subtitles.add(
            SubtitleItem(
              index: subtitles.length + 1,
              startTime: start,
              endTime: end,
              text: textBuffer.toString(),
            ),
          );
        } else {
          index++;
        }
      } else {
        index++;
      }
    }
    return TimedSubtitleParser.attachVtt(vttContent, subtitles);
  }

  /// 解析 ASS/SSA 格式
  static List<SubtitleItem> parseAss(String assContent) {
    List<SubtitleItem> subtitles = [];
    final String content = _normalizeContent(
      assContent,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = content.split('\n');

    bool inEvents = false;
    List<String> format = [];
    int startIndex = -1;
    int endIndex = -1;
    int textIndex = -1;

    for (var line in lines) {
      line = line.replaceAll('\uFEFF', '').trim();
      if (line.isEmpty) continue;

      if (line.toLowerCase().startsWith('[events]')) {
        inEvents = true;
        continue;
      }

      if (!inEvents) continue;

      if (line.toLowerCase().startsWith('format:')) {
        final formatStr = line.substring(line.indexOf(':') + 1).trim();
        format = formatStr
            .split(',')
            .map((e) => e.trim().toLowerCase())
            .toList();
        startIndex = format.indexOf('start');
        endIndex = format.indexOf('end');
        textIndex = format.indexOf('text');
        continue;
      }

      if (line.toLowerCase().startsWith('dialogue:')) {
        if (startIndex == -1 || endIndex == -1 || textIndex == -1) {
          // Without a Format declaration, use the standard ASS field order:
          // Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
          startIndex = 1;
          endIndex = 2;
          textIndex = 9;
        }

        final rawParts = line.substring(line.indexOf(':') + 1).trim();
        final int formatLen = format.isNotEmpty ? format.length : 10;
        final List<String> parts = [];
        // Split only the metadata separators; the final ASS Text field may
        // itself contain commas. Field indices come from Format or its default.
        String remaining = rawParts;
        for (int i = 0; i < formatLen - 1; i++) {
          int commaIndex = remaining.indexOf(',');
          if (commaIndex == -1) break;
          parts.add(remaining.substring(0, commaIndex));
          remaining = remaining.substring(commaIndex + 1);
        }
        parts.add(remaining); // The rest is the last field (Text)

        if (parts.length >= 3) {
          // At least Start, End, Text
          // Use detected indices, mapped to our parts list.
          // Note: Format indices are 0-based.

          if (startIndex < parts.length &&
              endIndex < parts.length &&
              textIndex < parts.length) {
            try {
              Duration start = _parseAssDuration(parts[startIndex].trim());
              Duration end = _parseAssDuration(parts[endIndex].trim());
              final rawText = parts[textIndex];
              String text = rawText;

              // Remove ASS tags like {\pos(400,570)} or {\c&HFFFFFF&}
              text = text.replaceAll(RegExp(r'\{.*?\}'), '');
              text = text.replaceAll(r'\N', '\n').replaceAll(r'\n', '\n');
              text = _stripStyleTokens(text);

              subtitles.add(
                SubtitleItem(
                  index: subtitles.length + 1,
                  startTime: start,
                  endTime: end,
                  text: text,
                  timedSpans: TimedSubtitleParser.assSpans(
                    rawText,
                    text,
                    start,
                  ),
                ),
              );
            } catch (e) {
              // ignore parse error
            }
          }
        }
      }
    }
    return subtitles..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  /// 解析 SRT 格式
  static List<SubtitleItem> parseSrt(String srtContent) {
    List<SubtitleItem> subtitles = [];
    final String content = _normalizeContent(
      srtContent,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = content.split('\n');

    int index = 0;
    final RegExp timeReg = RegExp(
      r'(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})',
    );
    while (index < lines.length) {
      String line = lines[index].replaceAll('\uFEFF', '').trim();
      if (line.isEmpty) {
        index++;
        continue;
      }

      int? seqNum = int.tryParse(line);
      if (seqNum != null) {
        index++;
        if (index >= lines.length) break;
        line = lines[index].trim();
      }

      if (line.contains('-->')) {
        final match = timeReg.firstMatch(line);
        if (match != null) {
          Duration start = _parseSrtDuration(match.group(1)!.trim());
          Duration end = _parseSrtDuration(match.group(2)!.trim());

          index++;
          StringBuffer textBuffer = StringBuffer();
          while (index < lines.length) {
            String textLine = lines[index].trim();
            if (textLine.isEmpty) break;
            final cleaned = _stripStyleTokens(textLine);
            if (cleaned.isNotEmpty) {
              if (textBuffer.isNotEmpty) textBuffer.write('\n');
              textBuffer.write(cleaned);
            }
            index++;
          }

          subtitles.add(
            SubtitleItem(
              index: subtitles.length + 1,
              startTime: start,
              endTime: end,
              text: textBuffer.toString(),
            ),
          );
        } else {
          index++;
        }
      } else {
        index++;
      }
    }
    return subtitles;
  }

  /// 解析 LRC 格式
  /// 格式: [mm:ss.xx]歌词内容
  static List<SubtitleItem> parseLrc(String lrcContent) {
    final timed = TimedSubtitleParser.tryParse(lrcContent);
    if (timed != null) return timed;
    List<SubtitleItem> subtitles = [];
    final String content = _normalizeContent(
      lrcContent,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = content.split('\n');

    // 正则匹配时间标签 [mm:ss.xx] 或 [mm:ss]
    // 支持一行有多个时间标签的情况，如 [00:12.00][00:24.00]重复歌词
    final RegExp timeTagRegExp = RegExp(r'\[(\d{2}):(\d{2})(\.(\d{2,3}))?\]');

    List<_LrcTempItem> tempItems = [];

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      // 提取所有时间标签
      final matches = timeTagRegExp.allMatches(line);
      if (matches.isEmpty) continue;

      // 提取歌词文本 (去掉时间标签剩下的部分)
      String text = line.replaceAll(timeTagRegExp, '').trim();
      text = _stripStyleTokens(text);
      if (text.isEmpty) continue; // 跳过只有时间没歌词的行

      for (var match in matches) {
        int minutes = int.parse(match.group(1)!);
        int seconds = int.parse(match.group(2)!);
        int milliseconds = 0;
        if (match.group(4) != null) {
          String msStr = match.group(4)!;
          // LRC 的毫秒通常是 2位 (10ms单位) 或 3位 (1ms单位)
          if (msStr.length == 2) {
            milliseconds = int.parse(msStr) * 10;
          } else {
            milliseconds = int.parse(msStr);
          }
        }

        Duration startTime = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        );

        tempItems.add(_LrcTempItem(startTime, text));
      }
    }

    // 按时间排序
    tempItems.sort((a, b) => a.startTime.compareTo(b.startTime));

    // 生成最终的 SubtitleItem (推断 endTime)
    for (int i = 0; i < tempItems.length; i++) {
      final current = tempItems[i];
      Duration endTime;

      if (i < tempItems.length - 1) {
        // 结束时间 = 下一句的开始时间
        endTime = tempItems[i + 1].startTime;
      } else {
        // 最后一句，默认显示 3 秒
        endTime = current.startTime + const Duration(seconds: 3);
      }

      subtitles.add(
        SubtitleItem(
          index: i + 1,
          startTime: current.startTime,
          endTime: endTime,
          text: current.text,
        ),
      );
    }

    return subtitles;
  }

  static Duration _parseSrtDuration(String timestamp) {
    try {
      final normalized = timestamp.replaceAll(',', '.');
      var parts = normalized.split('.');
      var timeParts = parts[0].split(':');

      int hours = int.parse(timeParts[0]);
      int minutes = int.parse(timeParts[1]);
      int seconds = int.parse(timeParts[2]);
      int milliseconds = 0;
      if (parts.length > 1) {
        final msRaw = parts[1].padRight(3, '0');
        milliseconds = int.parse(msRaw.substring(0, 3));
      }

      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: milliseconds,
      );
    } catch (e) {
      return Duration.zero;
    }
  }

  static Duration _parseVttDuration(String timestamp) {
    try {
      var parts = timestamp.split('.');
      var timeParts = parts[0].split(':');

      int hours = 0;
      int minutes = 0;
      int seconds = 0;

      if (timeParts.length == 3) {
        hours = int.parse(timeParts[0]);
        minutes = int.parse(timeParts[1]);
        seconds = int.parse(timeParts[2]);
      } else if (timeParts.length == 2) {
        minutes = int.parse(timeParts[0]);
        seconds = int.parse(timeParts[1]);
      }

      int milliseconds = 0;
      if (parts.length > 1) {
        final msRaw = parts[1].padRight(3, '0');
        milliseconds = int.parse(msRaw.substring(0, 3));
      }

      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: milliseconds,
      );
    } catch (e) {
      return Duration.zero;
    }
  }

  static Duration _parseAssDuration(String timestamp) {
    try {
      // Format: h:mm:ss.cs (centiseconds)
      var parts = timestamp.split('.');
      var timeParts = parts[0].split(':');

      int hours = int.parse(timeParts[0]);
      int minutes = int.parse(timeParts[1]);
      int seconds = int.parse(timeParts[2]);
      int centiseconds = parts.length > 1 ? int.parse(parts[1]) : 0;

      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: centiseconds * 10,
      );
    } catch (e) {
      return Duration.zero;
    }
  }
}

class _LrcTempItem {
  final Duration startTime;
  final String text;
  _LrcTempItem(this.startTime, this.text);
}
