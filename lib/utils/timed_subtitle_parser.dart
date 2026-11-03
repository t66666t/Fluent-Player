import 'dart:convert';
import 'dart:math' as math;
import 'package:characters/characters.dart';
import 'package:xml/xml.dart';
import '../models/subtitle_model.dart';
import 'subtitle_parser.dart';

class TimedSubtitleWord {
  final String text;
  final Duration start;
  final Duration end;
  final String? role;
  final String? agent;
  const TimedSubtitleWord(
    this.text,
    this.start,
    this.end, {
    this.role,
    this.agent,
  });
}

/// Input adapters. Output formats and the ordinary SRT import remain unchanged.
class TimedSubtitleParser {
  static const inputExtensions = [
    'srt',
    'vtt',
    'lrc',
    'alrc',
    'elrc',
    'spl',
    'ass',
    'ssa',
    'ttml',
    'dfxp',
    'xml',
    'yrc',
    'qrc',
    'krc',
    'lys',
    'lyl',
    'json',
    'sup',
    'sub',
    'idx',
    'scc',
  ];

  static Duration? time(
    String? raw, {
    double frameRate = 30,
    double tickRate = 1,
  }) {
    if (raw == null) return null;
    final value = raw.trim().replaceAll(',', '.');
    final offset = RegExp(
      r'^(-?\d+(?:\.\d+)?)(h|m|s|ms|f|t)$',
    ).firstMatch(value);
    if (offset != null) {
      final amount = double.tryParse(offset[1]!);
      final factor = switch (offset[2]) {
        'h' => 3600.0,
        'm' => 60.0,
        'ms' => 0.001,
        'f' => 1 / frameRate,
        't' => 1 / tickRate,
        _ => 1.0,
      };
      if (amount == null || !amount.isFinite || !factor.isFinite) return null;
      return Duration(microseconds: (amount * factor * 1000000).round());
    }
    final parts = value.split(':');
    if (parts.length == 4) {
      final frames = double.tryParse(parts.removeLast());
      final base = time(parts.join(':'));
      return frames == null || base == null
          ? null
          : base +
                Duration(microseconds: (frames / frameRate * 1000000).round());
    }
    if (parts.length > 3) return null;
    double seconds = 0;
    for (final part in parts) {
      final n = double.tryParse(part);
      if (n == null || !n.isFinite) return null;
      seconds = seconds * 60 + n;
    }
    return Duration(microseconds: (seconds * 1000000).round());
  }

  /// Match lexical text in order, permitting punctuation/whitespace between
  /// words but never searching across cues or assigning fabricated durations.
  static List<SubtitleTimedSpan> alignWords(
    String text,
    Iterable<TimedSubtitleWord> words,
  ) {
    final boundaries = <int>{0};
    var boundary = 0;
    for (final grapheme in text.characters) {
      boundary += grapheme.length;
      boundaries.add(boundary);
    }
    final out = <SubtitleTimedSpan>[];
    var cursor = 0;
    for (final word in words) {
      final lexical = word.text.trim();
      if (lexical.isEmpty ||
          word.end <= word.start ||
          word.start < Duration.zero) {
        continue;
      }
      var start = text.indexOf(lexical, cursor);
      if (start < 0) {
        // ASR sometimes inserts spaces between CJK tokens or normalizes casing.
        final pattern = RegExp(
          lexical.runes
              .map((r) => RegExp.escape(String.fromCharCode(r)))
              .join(r'\s*'),
          caseSensitive: false,
        );
        final found = pattern.firstMatch(text.substring(cursor));
        if (found == null) return const [];
        start = cursor + found.start;
        final end = cursor + found.end;
        if (RegExp(
          r'[\p{L}\p{N}]',
          unicode: true,
        ).hasMatch(text.substring(cursor, start))) {
          return const [];
        }
        if (!boundaries.contains(start) || !boundaries.contains(end)) {
          return const [];
        }
        out.add(
          SubtitleTimedSpan(
            textStart: start,
            textEnd: end,
            startTime: word.start,
            endTime: word.end,
            role: word.role,
            agentId: word.agent,
          ),
        );
        cursor = end;
        continue;
      }
      final skipped = text.substring(cursor, start);
      if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(skipped)) {
        return const [];
      }
      final end = start + lexical.length;
      if (!boundaries.contains(start) || !boundaries.contains(end)) {
        return const [];
      }
      out.add(
        SubtitleTimedSpan(
          textStart: start,
          textEnd: end,
          startTime: word.start,
          endTime: word.end,
          role: word.role,
          agentId: word.agent,
        ),
      );
      cursor = end;
    }
    return out;
  }

  static String clean(String text) => text
      .replaceAll(RegExp(r'\{[^}]*\}'), '')
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\h', ' ')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</?[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();

  static List<SubtitleItem>? tryParse(
    String content, {
    Duration? mediaDuration,
  }) {
    final head = content.trimLeft();
    if (head.startsWith('{') ||
        head.startsWith('[') && RegExp(r'^\[\s*\{').hasMatch(head)) {
      return parseAsrJson(jsonDecode(head));
    }
    if (RegExp(r'<(?:\w+:)?tt(?:\s|>)').hasMatch(head)) return parseTtml(head);
    if (head.contains('LyricContent=')) {
      final doc = XmlDocument.parse(head);
      final payload = doc.descendants
          .whereType<XmlElement>()
          .expand((e) => e.attributes)
          .where((a) => a.name.local == 'LyricContent');
      return payload.isEmpty ? const [] : parsePlatform(payload.first.value);
    }
    if (RegExp(r'^\s*\[\d+,\d+\]', multiLine: true).hasMatch(content) ||
        RegExp(
          r'^\s*\[\d+\].*\(\d+,\d+\)',
          multiLine: true,
        ).hasMatch(content)) {
      return parsePlatform(content);
    }
    if (RegExp(r'[<\[]\d{1,3}:\d{1,2}(?:[.:]\d+)?[>\]]').hasMatch(content) &&
        (RegExp(r'<\d{1,3}:\d{1,2}').hasMatch(content) ||
            RegExp(r'\]\s*.+\[\d{1,3}:\d{1,2}').hasMatch(content) ||
            content.contains('[offset:'))) {
      return parseLrc(content, mediaDuration: mediaDuration);
    }
    return null;
  }

  static List<SubtitleItem> parseLrc(
    String content, {
    Duration? mediaDuration,
  }) {
    final tag = RegExp(r'[\[<](\d{1,3}:\d{1,2}(?:[.:]\d{1,6})?)[\]>]');
    final offset = Duration(
      milliseconds:
          int.tryParse(
            RegExp(
                  r'\[offset:\s*(-?\d+)\]',
                  caseSensitive: false,
                ).firstMatch(content)?[1] ??
                '',
          ) ??
          0,
    );
    final drafts =
        <
          ({
            Duration start,
            Duration? end,
            String text,
            List<TimedSubtitleWord> words,
          })
        >[];
    for (final line in const LineSplitter().convert(content)) {
      final marks = tag.allMatches(line).toList();
      if (marks.isEmpty) continue;
      Duration stamp(RegExpMatch m) {
        var raw = m[1]!;
        if (':'.allMatches(raw).length == 2) {
          final cut = raw.lastIndexOf(':');
          raw = '${raw.substring(0, cut)}.${raw.substring(cut + 1)}';
        }
        return (time(raw) ?? Duration.zero) - offset;
      }

      final inline =
          marks.any((m) => line[m.start] == '<') ||
          marks
              .skip(1)
              .any(
                (m) =>
                    line.substring(marks.first.end, m.start).trim().isNotEmpty,
              );
      if (!inline) {
        final text = clean(line.substring(marks.last.end));
        if (text.isEmpty) continue;
        for (final mark in marks) {
          drafts.add((start: stamp(mark), end: null, text: text, words: []));
        }
        continue;
      }
      final text = StringBuffer();
      final words = <TimedSubtitleWord>[];
      Duration? explicitEnd;
      for (var i = 0; i < marks.length; i++) {
        final next = i + 1 < marks.length ? marks[i + 1] : null;
        final piece = line.substring(marks[i].end, next?.start ?? line.length);
        text.write(piece);
        if (piece.isEmpty && next == null) explicitEnd = stamp(marks[i]);
        if (piece.trim().isNotEmpty) {
          words.add(
            TimedSubtitleWord(
              piece,
              stamp(marks[i]),
              next == null ? stamp(marks[i]) : stamp(next),
            ),
          );
        }
      }
      final rawText = clean(text.toString());
      if (rawText.isNotEmpty) {
        drafts.add((
          start: stamp(marks.first),
          end: explicitEnd,
          text: rawText,
          words: words,
        ));
      }
    }
    drafts.sort((a, b) => a.start.compareTo(b.start));
    final result = <SubtitleItem>[
      for (var i = 0; i < drafts.length; i++)
        _lrcCue(
          drafts[i],
          i + 1,
          i + 1 < drafts.length ? drafts[i + 1].start : mediaDuration,
        ),
    ].where((cue) => cue.endTime > cue.startTime).toList();
    return [
      for (var i = 0; i < result.length; i++) result[i].copyWith(index: i + 1),
    ];
  }

  static SubtitleItem _lrcCue(
    ({
      Duration start,
      Duration? end,
      String text,
      List<TimedSubtitleWord> words,
    })
    draft,
    int index,
    Duration? next,
  ) {
    final end = draft.end ?? next ?? draft.start + const Duration(seconds: 3);
    final knownEnd = draft.end ?? next;
    // A final token's start can be explicit even when the line lacks an end.
    // Only a known following cue/media end may complete that token.
    final words = draft.words
        .map(
          (word) =>
              word.end <= word.start &&
                  knownEnd != null &&
                  knownEnd > word.start
              ? TimedSubtitleWord(word.text, word.start, knownEnd)
              : word,
        )
        .map(
          (word) => word.start < Duration.zero
              ? TimedSubtitleWord(word.text, Duration.zero, word.end)
              : word,
        )
        .toList();
    return SubtitleItem(
      index: index,
      startTime: draft.start < Duration.zero ? Duration.zero : draft.start,
      endTime: end,
      text: draft.text,
      timedSpans: alignWords(draft.text, words),
      isStructuredLyric: true,
    );
  }

  static List<SubtitleItem> attachVtt(String content, List<SubtitleItem> cues) {
    final blocks = content.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
    var cueIndex = 0;
    final out = <SubtitleItem>[];
    final mark = RegExp(r'<((?:\d+:)?\d{2}:\d{2}\.\d+)>');
    for (final block in blocks) {
      final lines = block.split('\n');
      final timing = lines.indexWhere((l) => l.contains('-->'));
      if (timing < 0 || cueIndex >= cues.length) continue;
      final cue = cues[cueIndex++];
      final body = lines.skip(timing + 1).join('\n');
      final words = <TimedSubtitleWord>[];
      var start = cue.startTime;
      var cursor = 0;
      for (final timestamp in mark.allMatches(body)) {
        final end = time(timestamp[1]);
        if (end != null) {
          words.add(
            TimedSubtitleWord(
              clean(body.substring(cursor, timestamp.start)),
              start,
              end,
            ),
          );
        }
        start = end ?? start;
        cursor = timestamp.end;
      }
      if (cursor > 0) {
        words.add(
          TimedSubtitleWord(clean(body.substring(cursor)), start, cue.endTime),
        );
      }
      out.add(cue.copyWith(timedSpans: alignWords(cue.text, words)));
    }
    return out.length == cues.length ? out : cues;
  }

  static List<SubtitleTimedSpan> assSpans(
    String raw,
    String text,
    Duration cueStart,
  ) {
    final blocks = RegExp(r'\{[^}]*\}');
    final words = <TimedSubtitleWord>[];
    var current = Duration.zero;
    Duration? pendingStart;
    Duration? pendingEnd;
    var cursor = 0;
    for (final block in blocks.allMatches(raw)) {
      final piece = clean(raw.substring(cursor, block.start));
      if (piece.isNotEmpty && pendingStart != null && pendingEnd != null) {
        words.add(
          TimedSubtitleWord(
            piece,
            cueStart + pendingStart,
            cueStart + pendingEnd,
          ),
        );
      }
      final tags = RegExp(r'\\(kt|kf|ko|[kK])(\d+)').allMatches(block[0]!);
      for (final tag in tags) {
        final duration = Duration(milliseconds: int.parse(tag[2]!) * 10);
        if (tag[1] == 'kt') {
          current = duration;
        } else {
          pendingStart = current;
          pendingEnd = current + duration;
          current += duration;
        }
      }
      cursor = block.end;
    }
    final tail = clean(raw.substring(cursor));
    if (tail.isNotEmpty && pendingStart != null && pendingEnd != null) {
      words.add(
        TimedSubtitleWord(tail, cueStart + pendingStart, cueStart + pendingEnd),
      );
    }
    return alignWords(text, words);
  }

  static List<SubtitleItem> parsePlatform(String content) {
    final out = <SubtitleItem>[];
    final offset = Duration(
      milliseconds:
          int.tryParse(
            RegExp(
                  r'\[offset:\s*(-?\d+)\]',
                  caseSensitive: false,
                ).firstMatch(content)?[1] ??
                '',
          ) ??
          0,
    );
    final linesMode = content.contains('[type:LyricifyLines]');
    for (final line in const LineSplitter().convert(content)) {
      final head = RegExp(r'^\s*\[(\d+)(?:,(\d+))?\]').firstMatch(line);
      if (head == null) continue;
      final first = int.parse(head[1]!);
      final second = int.tryParse(head[2] ?? '');
      final body = line.substring(head.end);
      if (linesMode && second != null) {
        out.add(
          SubtitleItem(
            index: out.length + 1,
            startTime: Duration(milliseconds: first) - offset,
            endTime: Duration(milliseconds: second) - offset,
            text: body.trim(),
            isStructuredLyric: true,
          ),
        );
        continue;
      }
      final isYrc = RegExp(r'^\(\d+,\d+,\d+\)').hasMatch(body);
      final isKrc = RegExp(r'^<\d+,\d+,\d+>').hasMatch(body);
      final words = <TimedSubtitleWord>[];
      final text = StringBuffer();
      if (isYrc || isKrc) {
        final marks =
            (isKrc
                    ? RegExp(r'<(\d+),(\d+),\d+>')
                    : RegExp(r'\((\d+),(\d+),\d+\)'))
                .allMatches(body)
                .toList();
        for (var i = 0; i < marks.length; i++) {
          final piece = body.substring(
            marks[i].end,
            i + 1 < marks.length ? marks[i + 1].start : body.length,
          );
          text.write(piece);
          final start =
              Duration(
                milliseconds: int.parse(marks[i][1]!) + (isKrc ? first : 0),
              ) -
              offset;
          words.add(
            TimedSubtitleWord(
              piece,
              start,
              start + Duration(milliseconds: int.parse(marks[i][2]!)),
            ),
          );
        }
      } else {
        var cursor = 0;
        for (final mark in RegExp(r'\((\d+),(\d+)\)').allMatches(body)) {
          final piece = body.substring(cursor, mark.start);
          text.write(piece);
          final start = Duration(milliseconds: int.parse(mark[1]!)) - offset;
          words.add(
            TimedSubtitleWord(
              piece,
              start,
              start + Duration(milliseconds: int.parse(mark[2]!)),
            ),
          );
          cursor = mark.end;
        }
        text.write(body.substring(cursor));
      }
      final value = text.toString().trim();
      if (value.isEmpty || words.isEmpty) continue;
      final start = second != null
          ? Duration(milliseconds: first) - offset
          : words.map((w) => w.start).reduce((a, b) => a < b ? a : b);
      final end = second != null
          ? start + Duration(milliseconds: second)
          : words.map((w) => w.end).reduce((a, b) => a > b ? a : b);
      out.add(
        SubtitleItem(
          index: out.length + 1,
          startTime: start,
          endTime: end,
          text: value,
          timedSpans: alignWords(value, words),
          isStructuredLyric: true,
          isBackgroundLyric: second == null && first >= 6,
          lyricAgent: second == null && first % 3 == 2 ? 'v2' : null,
        ),
      );
    }
    final language = RegExp(r'\[language:([^\]]+)\]').firstMatch(content);
    if (language != null) {
      try {
        final meta = jsonDecode(utf8.decode(base64Decode(language[1]!)));
        for (final track in (meta['content'] as List? ?? [])) {
          final rows = track['lyricContent'];
          if (rows is! List) continue;
          for (var i = 0; i < math.min(out.length, rows.length); i++) {
            final old = out[i];
            final value = rows[i] is List
                ? (rows[i] as List).join(' ')
                : rows[i].toString();
            out[i] = SubtitleItem.fromTimingJson({
              ...old.toTimingJson(),
              if (track['type'] == 1)
                'translation': value
              else
                'romanization': value,
            });
          }
        }
      } catch (_) {
        /* Optional metadata must not discard the lyrics. */
      }
    }
    return out;
  }

  static String? _attr(XmlElement element, String name) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == name) return attribute.value;
    }
    return null;
  }

  static List<SubtitleItem> parseTtml(String content) {
    final document = XmlDocument.parse(content);
    final root = document.rootElement;
    final apple =
        content.contains('music.apple.com') ||
        content.contains('itunes.apple.com') ||
        _attr(root, 'timing') != null;
    var frameRate = double.tryParse(_attr(root, 'frameRate') ?? '') ?? 30;
    final multiplier = (_attr(root, 'frameRateMultiplier') ?? '').split(
      RegExp(r'\s+'),
    );
    if (multiplier.length == 2) {
      final numerator = double.tryParse(multiplier[0]);
      final denominator = double.tryParse(multiplier[1]);
      if (numerator != null && denominator != null && denominator > 0) {
        frameRate *= numerator / denominator;
      }
    }
    final tickRate = double.tryParse(_attr(root, 'tickRate') ?? '') ?? 1;
    Duration? stamp(String? value) =>
        time(value, frameRate: frameRate, tickRate: tickRate);
    final out = <SubtitleItem>[];
    void visit(XmlElement element, Duration parentStart, Duration? parentEnd) {
      final begin = stamp(_attr(element, 'begin'));
      final absolute =
          apple && (_attr(element, 'begin')?.contains(':') ?? false);
      final start = begin == null
          ? parentStart
          : absolute
          ? begin
          : parentStart + begin;
      final rawEnd = stamp(_attr(element, 'end'));
      final duration = stamp(_attr(element, 'dur'));
      final end = rawEnd != null
          ? (apple && (_attr(element, 'end')?.contains(':') ?? false)
                ? rawEnd
                : parentStart + rawEnd)
          : duration != null
          ? start + duration
          : parentEnd;
      if (element.name.local != 'p') {
        var sequentialStart = start;
        for (final child in element.childElements) {
          visit(
            child,
            _attr(element, 'timeContainer') == 'seq' ? sequentialStart : start,
            end,
          );
          if (_attr(element, 'timeContainer') == 'seq') {
            sequentialStart += stamp(_attr(child, 'dur')) ?? Duration.zero;
          }
        }
        return;
      }
      final text = StringBuffer();
      final spans = <SubtitleTimedSpan>[];
      final translation = StringBuffer();
      final romanization = StringBuffer();
      final translationSpans = <SubtitleTimedSpan>[];
      final romanizationSpans = <SubtitleTimedSpan>[];
      void inline(
        XmlNode node,
        Duration currentStart,
        Duration? currentEnd,
        String? inheritedRole,
        String? inheritedAgent,
        bool timed,
      ) {
        if (node is XmlText || node is XmlCDATA) {
          final value = node is XmlText ? node.value : (node as XmlCDATA).value;
          final buffer = inheritedRole == 'x-translation'
              ? translation
              : inheritedRole == 'x-roman'
              ? romanization
              : text;
          final targetSpans = inheritedRole == 'x-translation'
              ? translationSpans
              : inheritedRole == 'x-roman'
              ? romanizationSpans
              : spans;
          final from = buffer.length;
          buffer.write(value);
          if (timed && currentEnd != null && currentEnd > currentStart) {
            targetSpans.add(
              SubtitleTimedSpan(
                textStart: from,
                textEnd: buffer.length,
                startTime: currentStart,
                endTime: currentEnd,
                role: inheritedRole,
                agentId: inheritedAgent,
              ),
            );
          }
          return;
        }
        if (node is! XmlElement) return;
        final role = _attr(node, 'role') ?? inheritedRole;
        if (node.name.local == 'br') {
          (role == 'x-translation'
                  ? translation
                  : role == 'x-roman'
                  ? romanization
                  : text)
              .write('\n');
          return;
        }
        final b = stamp(_attr(node, 'begin'));
        final e = stamp(_attr(node, 'end'));
        final d = stamp(_attr(node, 'dur'));
        final inlineStart = b == null
            ? currentStart
            : apple
            ? b
            : currentStart + b;
        final inlineEnd = e != null
            ? apple
                  ? e
                  : currentStart + e
            : d != null
            ? inlineStart + d
            : currentEnd;
        final agent = _attr(node, 'agent') ?? inheritedAgent;
        for (final child in node.children) {
          inline(
            child,
            inlineStart,
            inlineEnd,
            role,
            agent,
            timed || b != null || e != null || d != null,
          );
        }
      }

      for (final child in element.children) {
        inline(
          child,
          start,
          end,
          _attr(element, 'role'),
          _attr(element, 'agent'),
          false,
        );
      }
      final raw = text.toString();
      final value = raw.trim();
      if (value.isEmpty) return;
      final leading = raw.length - raw.trimLeft().length;
      final validSpans = spans
          .where(
            (s) =>
                s.textStart >= leading && s.textEnd <= leading + value.length,
          )
          .map((s) => s.shifted(Duration.zero, textOffset: -leading))
          .toList();
      final inferredEnd =
          end ??
          (validSpans.isEmpty
              ? start + const Duration(seconds: 3)
              : validSpans
                    .map((s) => s.endTime)
                    .reduce((a, b) => a > b ? a : b));
      List<SubtitleTimedSpan> trimAuxiliary(
        StringBuffer buffer,
        List<SubtitleTimedSpan> items,
      ) {
        final raw = buffer.toString();
        final leading = raw.length - raw.trimLeft().length;
        final length = raw.trim().length;
        return items
            .where(
              (s) => s.textStart >= leading && s.textEnd <= leading + length,
            )
            .map((s) => s.shifted(Duration.zero, textOffset: -leading))
            .toList();
      }

      out.add(
        SubtitleItem(
          index: out.length + 1,
          startTime: start,
          endTime: inferredEnd,
          text: value,
          timedSpans: validSpans,
          isStructuredLyric: true,
          lyricAgent: _attr(element, 'agent'),
          isBackgroundLyric: _attr(element, 'role') == 'x-bg',
          lyricTranslation: translation.toString().trim(),
          lyricRomanization: romanization.toString().trim(),
          lyricTranslationSpans: trimAuxiliary(translation, translationSpans),
          lyricRomanizationSpans: trimAuxiliary(
            romanization,
            romanizationSpans,
          ),
        ),
      );
    }

    visit(root, Duration.zero, null);
    return out;
  }

  static Duration? _numberTime(Object? raw, double microsecondsPerUnit) {
    final value = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '');
    return value == null || !value.isFinite
        ? null
        : Duration(microseconds: (value * microsecondsPerUnit).round());
  }

  static List<SubtitleItem> parseAsrJson(Object? input) {
    if (input is String) input = jsonDecode(input);
    if (input is List) {
      return input
          .expand((item) => parseAsrJson(item))
          .toList()
          .asMap()
          .entries
          .map((e) => e.value.copyWith(index: e.key + 1))
          .toList();
    }
    if (input is! Map) throw const FormatException('不是受支持的转录 JSON');
    final root = input;
    for (final key in [
      'data',
      'Data',
      'result',
      'Result',
      'response',
      'Response',
      'resp',
    ]) {
      if (root[key] is Map || root[key] is String) {
        try {
          return parseAsrJson(root[key]);
        } on FormatException {
          /* Try remaining known shapes. */
        }
      }
    }
    final out = <SubtitleItem>[];
    void add(
      String text,
      Duration? start,
      Duration? end,
      List<TimedSubtitleWord> words, {
      String? speaker,
    }) {
      final value = text.trim();
      start ??= words.isEmpty
          ? null
          : words.map((w) => w.start).reduce((a, b) => a < b ? a : b);
      end ??= words.isEmpty
          ? null
          : words.map((w) => w.end).reduce((a, b) => a > b ? a : b);
      if (value.isEmpty ||
          start == null ||
          end == null ||
          start < Duration.zero ||
          end <= start) {
        return;
      }
      out.add(
        SubtitleItem(
          index: out.length + 1,
          startTime: start,
          endTime: end,
          text: value,
          timedSpans: alignWords(value, words),
          lyricAgent: speaker,
        ),
      );
    }

    List<TimedSubtitleWord> readWords(
      Object? raw,
      double unit, {
      Duration offset = Duration.zero,
    }) {
      if (raw is! List) return [];
      return raw
          .whereType<Map>()
          .map((w) {
            final start = _numberTime(
              w['start'] ??
                  w['start_time'] ??
                  w['BeginTime'] ??
                  w['OffsetStartMs'],
              unit,
            );
            final end = _numberTime(
              w['end'] ?? w['end_time'] ?? w['EndTime'] ?? w['OffsetEndMs'],
              unit,
            );
            return start == null || end == null
                ? null
                : TimedSubtitleWord(
                    (w['word'] ?? w['text'] ?? w['label'] ?? w['Word'] ?? '')
                        .toString(),
                    start + offset,
                    end + offset,
                  );
          })
          .whereType<TimedSubtitleWord>()
          .toList();
    }

    if (root['segments'] is List || root['utterances'] is List) {
      final whisper = root['segments'] is List;
      for (final segment
          in (root[whisper ? 'segments' : 'utterances'] as List)
              .whereType<Map>()) {
        final unit = whisper ? 1000000.0 : 1000.0;
        add(
          (segment['text'] ?? segment['transcript'] ?? '').toString(),
          _numberTime(segment[whisper ? 'start' : 'start_time'], unit),
          _numberTime(segment[whisper ? 'end' : 'end_time'], unit),
          readWords(segment['words'], unit),
          speaker: segment['speaker']?.toString(),
        );
      }
      return out;
    }
    if (root['sentence_info'] is List) {
      for (final sentence in (root['sentence_info'] as List).whereType<Map>()) {
        final parsed = parseAsrJson(sentence);
        out.addAll(
          parsed.map((cue) => cue.copyWith(index: out.length + cue.index)),
        );
      }
      return out;
    }
    if (root['timestamp'] is List && root['text'] is String) {
      final text = root['text'] as String;
      final tokens = (root['raw_text'] ?? text).toString().trim().split(
        RegExp(r'\s+'),
      );
      final stamps = root['timestamp'] as List;
      final pieces = tokens.length == stamps.length
          ? tokens
          : text
                .replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '')
                .characters
                .toList();
      final words = <TimedSubtitleWord>[];
      if (pieces.length == stamps.length) {
        for (var i = 0; i < stamps.length; i++) {
          final pair = stamps[i];
          if (pair is! List || pair.length != 2) continue;
          final start = _numberTime(pair[0], 1000);
          final end = _numberTime(pair[1], 1000);
          if (start != null && end != null) {
            words.add(TimedSubtitleWord(pieces[i], start, end));
          }
        }
      }
      final first =
          stamps.isNotEmpty &&
              stamps.first is List &&
              (stamps.first as List).isNotEmpty
          ? _numberTime((stamps.first as List).first, 1000)
          : null;
      final last =
          stamps.isNotEmpty &&
              stamps.last is List &&
              (stamps.last as List).length == 2
          ? _numberTime((stamps.last as List).last, 1000)
          : null;
      add(
        text,
        _numberTime(root['start'], 1000) ?? first,
        _numberTime(root['end'], 1000) ?? last,
        words,
      );
      return out;
    }
    if (root['ResultDetail'] is List || root['Sentences'] is List) {
      final tencent = root['ResultDetail'] is List;
      for (final s
          in (root[tencent ? 'ResultDetail' : 'Sentences'] as List)
              .whereType<Map>()) {
        final start = _numberTime(s[tencent ? 'StartMs' : 'BeginTime'], 1000);
        final rawWords = s['Words'] ?? root['Words'];
        var words = readWords(
          rawWords,
          1000,
          offset: tencent ? start ?? Duration.zero : Duration.zero,
        );
        final end = _numberTime(s[tencent ? 'EndMs' : 'EndTime'], 1000);
        if (!tencent) {
          words = words
              .where(
                (w) =>
                    start != null &&
                    end != null &&
                    w.start >= start &&
                    w.start < end,
              )
              .toList();
        }
        add(
          (s['FinalSentence'] ?? s['Text'] ?? s['SliceSentence'] ?? '')
              .toString(),
          start,
          end,
          words,
        );
      }
      return out;
    }
    if (root['phrases'] is List) {
      for (final phrase in (root['phrases'] as List).whereType<Map>()) {
        final start = _azureOffset(phrase);
        final duration = _azureDuration(phrase);
        final words = <TimedSubtitleWord>[];
        for (final word in (phrase['words'] as List? ?? []).whereType<Map>()) {
          final wordStart = _azureOffset(word);
          final wordDuration = _azureDuration(word);
          if (wordStart != null && wordDuration != null) {
            words.add(
              TimedSubtitleWord(
                word['text']?.toString() ?? '',
                wordStart,
                wordStart + wordDuration,
              ),
            );
          }
        }
        add(
          phrase['text']?.toString() ?? '',
          start,
          start != null && duration != null ? start + duration : null,
          words,
          speaker: phrase['speaker']?.toString(),
        );
      }
      return out;
    }
    if (root['recognizedPhrases'] is List) {
      for (final phrase
          in (root['recognizedPhrases'] as List).whereType<Map>()) {
        final candidates = phrase['nBest'];
        if (candidates is! List ||
            candidates.isEmpty ||
            candidates.first is! Map) {
          continue;
        }
        final best = candidates.first as Map;
        final words = <TimedSubtitleWord>[];
        for (final w in (best['displayWords'] ?? best['words'] ?? []) as List) {
          if (w is! Map) continue;
          final start = _azureOffset(w);
          final duration = _azureDuration(w);
          if (start != null && duration != null) {
            words.add(
              TimedSubtitleWord(
                (w['displayText'] ?? w['word'] ?? '').toString(),
                start,
                start + duration,
              ),
            );
          }
        }
        final start = _azureOffset(phrase);
        final duration = _azureDuration(phrase);
        add(
          (best['display'] ?? best['lexical'] ?? '').toString(),
          start,
          start != null && duration != null ? start + duration : null,
          words,
        );
      }
      return out;
    }
    if (root['results'] is List) {
      for (final result in (root['results'] as List).whereType<Map>()) {
        final alternatives = result['alternatives'];
        if (alternatives is! List ||
            alternatives.isEmpty ||
            alternatives.first is! Map) {
          continue;
        }
        final best = alternatives.first as Map;
        final words = <TimedSubtitleWord>[];
        for (final w in (best['words'] as List? ?? []).whereType<Map>()) {
          final start = time((w['startTime'] ?? w['startOffset'])?.toString());
          final end = time((w['endTime'] ?? w['endOffset'])?.toString());
          if (start != null && end != null) {
            words.add(
              TimedSubtitleWord(w['word']?.toString() ?? '', start, end),
            );
          }
        }
        add(best['transcript']?.toString() ?? '', null, null, words);
      }
      return out;
    }
    if (root['results'] is Map) return parseAsrJson(root['results']);
    if (root['items'] is List && root['transcripts'] is List) {
      final words = <TimedSubtitleWord>[];
      final text = StringBuffer();
      for (final item in (root['items'] as List).whereType<Map>()) {
        final candidates = item['alternatives'];
        if (candidates is! List || candidates.isEmpty) continue;
        final value = candidates.first['content']?.toString() ?? '';
        if (item['type'] == 'punctuation') {
          text.write(value);
          if (words.isNotEmpty) {
            final previous = words.removeLast();
            words.add(
              TimedSubtitleWord(
                previous.text + value,
                previous.start,
                previous.end,
              ),
            );
          }
          continue;
        }
        if (text.isNotEmpty) text.write(' ');
        text.write(value);
        final start = _numberTime(item['start_time'], 1000000);
        final end = _numberTime(item['end_time'], 1000000);
        if (start != null && end != null) {
          words.add(TimedSubtitleWord(value, start, end));
        }
      }
      final grouped = groupWords(words);
      return grouped;
    }
    if (root['words'] is List &&
        root['text'] == null &&
        (root['words'] as List).whereType<Map>().every(
          (w) => w.containsKey('start') && w.containsKey('end'),
        )) {
      return groupWords(readWords(root['words'], 1000000));
    }
    if (root['words'] is List && root['text'] is String) {
      add(
        root['text'] as String,
        _numberTime(root['start'], 1000000),
        _numberTime(root['end'], 1000000),
        readWords(root['words'], 1000000),
      );
      return out;
    }
    throw const FormatException('无法识别转录 JSON 的时间结构');
  }

  static Duration? _azureOffset(Map value) =>
      _numberTime(value['offsetInTicks'], 0.1) ??
      _numberTime(value['offsetMilliseconds'], 1000) ??
      _isoDuration(value['offset']);
  static Duration? _azureDuration(Map value) =>
      _numberTime(value['durationInTicks'], 0.1) ??
      _numberTime(value['durationMilliseconds'], 1000) ??
      _isoDuration(value['duration']);
  static Duration? _isoDuration(Object? value) {
    final match = RegExp(
      r'^PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$',
    ).firstMatch(value?.toString() ?? '');
    if (match == null) return null;
    return Duration(
      microseconds:
          (((double.tryParse(match[1] ?? '') ?? 0) * 3600 +
                      (double.tryParse(match[2] ?? '') ?? 0) * 60 +
                      (double.tryParse(match[3] ?? '') ?? 0)) *
                  1000000)
              .round(),
    );
  }

  static List<SubtitleItem> parseWordSrt(String content) {
    final cues = SubtitleParser.parseSrt(content);
    if (!RegExp(r'<u>', caseSensitive: false).hasMatch(content)) {
      return groupWords(
        cues
            .map((c) => TimedSubtitleWord(c.text, c.startTime, c.endTime))
            .toList(),
      );
    }
    final rawBlocks = content
        .replaceAll('\r\n', '\n')
        .split(RegExp(r'\n\s*\n'))
        .where((b) => b.contains('-->'))
        .toList();
    final out = <SubtitleItem>[];
    var i = 0;
    while (i < cues.length) {
      final first = cues[i];
      var end = first.endTime;
      final spans = <SubtitleTimedSpan>[];
      var j = i;
      while (j < cues.length &&
          cues[j].text == first.text &&
          (j == i ||
              cues[j].startTime - end < const Duration(milliseconds: 800))) {
        if (j < rawBlocks.length) {
          for (final mark in RegExp(
            r'<u>(.*?)</u>',
            caseSensitive: false,
            dotAll: true,
          ).allMatches(rawBlocks[j])) {
            final block = rawBlocks[j];
            final bodyStart = block.indexOf('\n', block.indexOf('-->')) + 1;
            final prefix = block.substring(bodyStart, mark.start);
            final from = clean(prefix).length + (prefix.endsWith(' ') ? 1 : 0);
            final value = clean(mark[1]!);
            if (from + value.length <= first.text.length &&
                first.text.substring(from, from + value.length) == value) {
              spans.add(
                SubtitleTimedSpan(
                  textStart: from,
                  textEnd: from + value.length,
                  startTime: cues[j].startTime,
                  endTime: cues[j].endTime,
                ),
              );
            }
          }
        }
        if (cues[j].endTime > end) end = cues[j].endTime;
        j++;
      }
      out.add(
        first.copyWith(index: out.length + 1, endTime: end, timedSpans: spans),
      );
      i = j;
    }
    return out;
  }

  static List<SubtitleItem> groupWords(List<TimedSubtitleWord> input) {
    final out = <SubtitleItem>[];
    final group = <TimedSubtitleWord>[];
    final text = StringBuffer();
    void flush() {
      if (group.isEmpty) return;
      final value = text.toString().trim();
      out.add(
        SubtitleItem(
          index: out.length + 1,
          startTime: group.first.start,
          endTime: group.map((w) => w.end).reduce((a, b) => a > b ? a : b),
          text: value,
          timedSpans: alignWords(value, group),
        ),
      );
      group.clear();
      text.clear();
    }

    for (final word in input) {
      if (word.text.trim().isEmpty || word.end <= word.start) continue;
      if (group.isNotEmpty &&
          (word.start - group.last.end >= const Duration(milliseconds: 800) ||
              word.end - group.first.start > const Duration(seconds: 8) ||
              (text.toString() + word.text).characters.length > 48)) {
        flush();
      }
      if (text.isNotEmpty &&
          RegExp(r'[A-Za-z0-9]$').hasMatch(text.toString()) &&
          RegExp(r'^[A-Za-z0-9]').hasMatch(word.text.trimLeft())) {
        text.write(' ');
      }
      text.write(word.text);
      group.add(word);
      if (RegExp(r'[。！？!?]$|(?<!\d)\.$').hasMatch(word.text.trimRight())) {
        flush();
      }
    }
    flush();
    return out;
  }
}
