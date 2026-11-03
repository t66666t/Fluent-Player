import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'subtitle_parser.dart';

int? _structuredSubtitleMaxEnd(Map<String, Object> input) {
  try {
    final path = input['path'] as String;
    final content = SubtitleParser.decodeBytes(input['bytes'] as List<int>, sourcePath: path);
    final cues = SubtitleParser.parse(content, sourcePath: path);
    if (cues.isEmpty) return null;
    return cues.map((cue) => cue.endTime.inMilliseconds).reduce((a, b) => a > b ? a : b);
  } catch (_) { return null; }
}

/// 轻量读取文本字幕文件的"最大结束时间"（毫秒），用于同文件夹匹配的
/// 时长二次校验。
///
/// 只扫描文件头部 [maxBytesToScan] 字节，不做完整解析，避免 IO 开销。
/// 图像/二进制字幕（sup/idx/scc 及 MicroDVD 的 .sub）无法读取时间轴，
/// 一律返回 `null`（信息缺失，按中性处理，不参与否决）。
class SubtitleDurationReader {
  const SubtitleDurationReader();

  static const int maxBytesToScan = 8 * 1024 * 1024; // 8MB 上限

  Future<int?> readMaxEndMs(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    switch (ext) {
      case '.srt':
      case '.vtt':
        return _scanGenericTimeline(file);
      case '.ass':
      case '.ssa':
        return _scanAssDialogue(file);
      case '.lrc':
        return _scanLrc(file);
      case '.alrc':
      case '.elrc':
      case '.spl':
      case '.ttml':
      case '.dfxp':
      case '.xml':
      case '.yrc':
      case '.qrc':
      case '.krc':
      case '.lys':
      case '.lyl':
      case '.json':
        try {
          if (await file.length() > maxBytesToScan) return null;
          return await compute(_structuredSubtitleMaxEnd,
            <String, Object>{'bytes': await file.readAsBytes(), 'path': file.path});
        } catch (_) { return null; }
      default:
        // .sup / .idx / .sub / .scc / 其它：无法安全读取时间轴。
        return null;
    }
  }

  Future<int?> _scanGenericTimeline(File file) async {
    final text = await _readHeadText(file);
    if (text == null) return null;
    // SRT: 00:00:20,000 --> 00:00:24,400
    // VTT: 00:00:20.000 --> 00:00:24.400
    final re = RegExp(
      r'(\d{1,2}):(\d{2}):(\d{2})[.,](\d{1,3})\s*-->\s*'
      r'(\d{1,2}):(\d{2}):(\d{2})[.,](\d{1,3})',
    );
    int? maxEnd;
    for (final match in re.allMatches(text)) {
      final end = _parseTimeMs(match, startOffset: 4);
      if (end != null && (maxEnd == null || end > maxEnd)) {
        maxEnd = end;
      }
    }
    return maxEnd;
  }

  Future<int?> _scanAssDialogue(File file) async {
    final text = await _readHeadText(file);
    if (text == null) return null;
    // Dialogue: 0,0:01:02.03,0:01:05.06,Style,,0,0,0,,Text
    final re = RegExp(
      r'Dialogue:\s*\d+,\s*(\d+):(\d{2}):(\d{2})[.,](\d{1,3}),\s*'
      r'(\d+):(\d{2}):(\d{2})[.,](\d{1,3})',
    );
    int? maxEnd;
    for (final match in re.allMatches(text)) {
      final end = _parseTimeMs(match, startOffset: 4);
      if (end != null && (maxEnd == null || end > maxEnd)) {
        maxEnd = end;
      }
    }
    return maxEnd;
  }

  Future<int?> _scanLrc(File file) async {
    final text = await _readHeadText(file);
    if (text == null) return null;
    // [mm:ss.xx] 或 [mm:ss]
    final re = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.,](\d{1,3}))?\]');
    int? maxEnd;
    for (final match in re.allMatches(text)) {
      final end = _parseTimeMs(match, startOffset: 0);
      if (end != null && (maxEnd == null || end > maxEnd)) {
        maxEnd = end;
      }
    }
    return maxEnd;
  }

  /// [startOffset] 指向时间分组的起始下标（通用时间为 0，ass 结束时间为 4）。
  int? _parseTimeMs(RegExpMatch match, {required int startOffset}) {
    final hours = int.tryParse(match.group(startOffset + 1) ?? '');
    final minutes = int.tryParse(match.group(startOffset + 2) ?? '');
    final seconds = int.tryParse(match.group(startOffset + 3) ?? '');
    if (hours == null || minutes == null || seconds == null) return null;
    return ((hours * 3600 + minutes * 60 + seconds) * 1000) +
        _fractionMs(match.group(startOffset + 4));
  }

  int _fractionMs(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    final value = int.tryParse(raw);
    if (value == null) return 0;
    return switch (raw.length) {
      1 => value * 100,
      2 => value * 10,
      _ => value, // 3 位毫秒
    };
  }

  Future<String?> _readHeadText(File file) async {
    try {
      final length = await file.length();
      if (length <= 0) return null;
      final bytesToRead = length < maxBytesToScan ? length : maxBytesToScan;
      final raf = await file.open();
      try {
        final bytes = await raf.read(bytesToRead);
        // 时间戳均为 ASCII，用 latin1 解码足够，且能容忍任意编码正文。
        return String.fromCharCodes(bytes);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }
}
