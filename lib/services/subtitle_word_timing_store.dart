import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import '../models/subtitle_model.dart';
import '../utils/subtitle_parser.dart';

/// Private companion of a sentence subtitle, never an independently selected track.
class SubtitleWordTimingStore {
  /// A static scope keeps the task manager and its timers out of the isolate
  /// message when encoding the final (potentially long) timing companion.
  static Future<String?> writeInBackground(
    String path,
    List<SubtitleItem> cues,
  ) => Isolate.run(() => write(path, cues));
  static const suffix = '.wordtiming.json';
  static String pathFor(String subtitlePath) => subtitlePath + suffix;
  static bool isCompanion(String path) =>
      path.toLowerCase().endsWith(suffix) ||
      path.toLowerCase().endsWith('$suffix.partial');
  static String fingerprint(String text) =>
      sha256.convert(utf8.encode(text)).toString();
  static String cueKey(SubtitleItem cue) => [
    cue.index,
    cue.startTime.inMilliseconds,
    cue.endTime.inMilliseconds,
    cue.text,
  ].join('|');

  static String encode(String sourceText, List<SubtitleItem> cues) =>
      jsonEncode({
        'version': 1,
        'sourceSha256': fingerprint(sourceText),
        'cues': [
          for (final cue in cues)
            if (cue.timedSpans.isNotEmpty ||
                cue.isStructuredLyric ||
                cue.asrInfo.hasData)
              {'key': fingerprint(cueKey(cue)), ...cue.toTimingJson()},
        ],
      });

  static List<SubtitleItem> decode(
    String sourceText,
    String companion,
    List<SubtitleItem> cues,
  ) {
    try {
      final data = jsonDecode(companion);
      if (data is! Map ||
          data['version'] != 1 ||
          data['sourceSha256'] != fingerprint(sourceText) ||
          data['cues'] is! List) {
        return cues;
      }
      final byKey = <String, Map>{
        for (final item in (data['cues'] as List).whereType<Map>())
          if (item['key'] is String) item['key'] as String: item,
      };
      return [
        for (final cue in cues)
          if (byKey.containsKey(fingerprint(cueKey(cue))))
            _attachCue(cue, byKey[fingerprint(cueKey(cue))]!)
          else
            cue,
      ];
    } catch (_) {
      return cues;
    }
  }

  static SubtitleItem _attachCue(SubtitleItem cue, Map raw) {
    final saved = SubtitleItem.fromTimingJson(raw);
    if (saved.index != cue.index ||
        saved.text != cue.text ||
        saved.startTime != cue.startTime ||
        saved.endTime != cue.endTime) {
      return cue;
    }
    return saved;
  }

  static Future<String?> write(
    String sourcePath,
    List<SubtitleItem> cues,
  ) async {
    final path = pathFor(sourcePath);
    if (!cues.any(
      (c) =>
          c.timedSpans.isNotEmpty || c.isStructuredLyric || c.asrInfo.hasData,
    )) {
      if (await File(path).exists()) await File(path).delete();
      return null;
    }
    final sourceText = SubtitleParser.decodeBytes(
      await File(sourcePath).readAsBytes(),
      sourcePath: sourcePath,
    );
    final normalized = sourcePath.toLowerCase().endsWith('.srt')
        ? [for (var i = 0; i < cues.length; i++) cues[i].copyWith(index: i + 1)]
        : cues;
    return writeEncoded(sourcePath, encode(sourceText, normalized));
  }

  /// Content already prepared together with its SRT; no reread or rehash on UI.
  static Future<String?> writeEncoded(
    String sourcePath,
    String? content,
  ) async {
    final path = pathFor(sourcePath);
    if (content == null) {
      if (await File(path).exists()) await File(path).delete();
      return null;
    }
    final partial = File('$path.partial');
    try {
      await partial.writeAsString(content, flush: true);
      try {
        await partial.rename(path);
      } on FileSystemException {
        if (await File(path).exists()) await File(path).delete();
        await partial.rename(path);
      }
      return path;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  static Future<List<SubtitleItem>> attach(
    String sourcePath,
    String sourceText,
    List<SubtitleItem> cues, {
    String? companionPath,
  }) async {
    final file = File(companionPath ?? pathFor(sourcePath));
    try {
      if (!await file.exists() || await file.length() > 100 * 1024 * 1024) {
        return cues;
      }
      return decode(sourceText, await file.readAsString(), cues);
    } catch (_) {
      return cues;
    }
  }
}
