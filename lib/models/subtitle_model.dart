import 'dart:typed_data';
import 'subtitle_asr_info.dart';

/// Timing of an existing range of the cue's UTF-16 text, not a new cue.
/// Ranges must end on grapheme boundaries; times are absolute media times.
class SubtitleTimedSpan {
  final int textStart;
  final int textEnd;
  final Duration startTime;
  final Duration endTime;
  final String? role;
  final String? agentId;

  const SubtitleTimedSpan({
    required this.textStart,
    required this.textEnd,
    required this.startTime,
    required this.endTime,
    this.role,
    this.agentId,
  });

  bool isValidFor(String text) =>
      textStart >= 0 &&
      textEnd > textStart &&
      textEnd <= text.length &&
      startTime >= Duration.zero &&
      endTime > startTime;

  @override
  bool operator ==(Object other) =>
      other is SubtitleTimedSpan &&
      textStart == other.textStart &&
      textEnd == other.textEnd &&
      startTime == other.startTime &&
      endTime == other.endTime &&
      role == other.role &&
      agentId == other.agentId;
  @override
  int get hashCode =>
      Object.hash(textStart, textEnd, startTime, endTime, role, agentId);

  SubtitleTimedSpan shifted(Duration offset, {int textOffset = 0}) =>
      SubtitleTimedSpan(
        textStart: textStart + textOffset,
        textEnd: textEnd + textOffset,
        startTime: startTime + offset,
        endTime: endTime + offset,
        role: role,
        agentId: agentId,
      );

  Map<String, Object?> toJson() => {
    'from': textStart,
    'to': textEnd,
    'startUs': startTime.inMicroseconds,
    'endUs': endTime.inMicroseconds,
    if (role != null) 'role': role,
    if (agentId != null) 'agent': agentId,
  };

  static SubtitleTimedSpan? tryParse(Object? raw, String text) {
    if (raw is! Map ||
        raw['from'] is! num ||
        raw['to'] is! num ||
        raw['startUs'] is! num ||
        raw['endUs'] is! num) {
      return null;
    }
    final span = SubtitleTimedSpan(
      textStart: (raw['from'] as num).toInt(),
      textEnd: (raw['to'] as num).toInt(),
      startTime: Duration(microseconds: (raw['startUs'] as num).round()),
      endTime: Duration(microseconds: (raw['endUs'] as num).round()),
      role: raw['role']?.toString(),
      agentId: raw['agent']?.toString(),
    );
    return span.isValidFor(text) ? span : null;
  }
}

class SubtitleItem {
  final SubtitleAsrInfo asrInfo;
  final int index;
  final Duration startTime;
  final Duration endTime;
  final String text;
  final List<SubtitleTimedSpan> timedSpans;
  final String? lyricAgent;
  final bool isBackgroundLyric;
  final bool isStructuredLyric;
  final String lyricTranslation;
  final String lyricRomanization;
  final List<SubtitleTimedSpan> lyricTranslationSpans;
  final List<SubtitleTimedSpan> lyricRomanizationSpans;
  final Future<Uint8List?> Function()?
  imageLoader; // Lazy loader for bitmap subtitles (PGS/VobSub)

  SubtitleItem({
    required this.index,
    required this.startTime,
    required this.endTime,
    this.text = "",
    this.asrInfo = const SubtitleAsrInfo(),
    List<SubtitleTimedSpan> timedSpans = const [],
    this.lyricAgent,
    this.isBackgroundLyric = false,
    this.isStructuredLyric = false,
    this.lyricTranslation = '',
    this.lyricRomanization = '',
    List<SubtitleTimedSpan> lyricTranslationSpans = const [],
    List<SubtitleTimedSpan> lyricRomanizationSpans = const [],
    this.imageLoader,
  }) : lyricTranslationSpans = lyricTranslationSpans.isEmpty
           ? const []
           : List.unmodifiable(
               lyricTranslationSpans.where(
                 (s) => s.isValidFor(lyricTranslation),
               ),
             ),
       lyricRomanizationSpans = lyricRomanizationSpans.isEmpty
           ? const []
           : List.unmodifiable(
               lyricRomanizationSpans.where(
                 (s) => s.isValidFor(lyricRomanization),
               ),
             ),
       timedSpans = timedSpans.isEmpty
           ? const []
           : List.unmodifiable(
               timedSpans.where((span) => span.isValidFor(text)),
             );

  SubtitleItem copyWith({
    int? index,
    Duration? startTime,
    Duration? endTime,
    String? text,
    List<SubtitleTimedSpan>? timedSpans,
    SubtitleAsrInfo? asrInfo,
  }) => SubtitleItem(
    index: index ?? this.index,
    startTime: startTime ?? this.startTime,
    endTime: endTime ?? this.endTime,
    text: text ?? this.text,
    asrInfo:
        asrInfo ??
        (text == null || text == this.text
            ? this.asrInfo
            : const SubtitleAsrInfo()),
    timedSpans:
        timedSpans ??
        (text == null || text == this.text ? this.timedSpans : const []),
    imageLoader: imageLoader,
    lyricAgent: lyricAgent,
    isBackgroundLyric: isBackgroundLyric,
    isStructuredLyric: isStructuredLyric,
    lyricTranslation: lyricTranslation,
    lyricRomanization: lyricRomanization,
    lyricTranslationSpans: lyricTranslationSpans,
    lyricRomanizationSpans: lyricRomanizationSpans,
  );

  Map<String, Object?> toTimingJson() => {
    // Keep the legacy sentence fields in milliseconds.
    'i': index,
    's': startTime.inMilliseconds,
    'e': endTime.inMilliseconds,
    't': text,
    if (asrInfo.hasData) 'asr': asrInfo.toJson(),
    if (timedSpans.isNotEmpty)
      'spans': timedSpans.map((s) => s.toJson()).toList(),
    if (lyricAgent != null) 'agent': lyricAgent,
    if (isBackgroundLyric) 'bg': true, if (isStructuredLyric) 'lyric': true,
    if (lyricTranslation.isNotEmpty) 'translation': lyricTranslation,
    if (lyricRomanization.isNotEmpty) 'romanization': lyricRomanization,
    if (lyricTranslationSpans.isNotEmpty)
      'translationSpans': lyricTranslationSpans.map((s) => s.toJson()).toList(),
    if (lyricRomanizationSpans.isNotEmpty)
      'romanizationSpans': lyricRomanizationSpans
          .map((s) => s.toJson())
          .toList(),
  };

  SubtitleItem trimmed() {
    final value = text.trim();
    final leading = text.length - text.trimLeft().length;
    return copyWith(
      text: value,
      asrInfo: asrInfo.wordBoundaries.isEmpty
          ? asrInfo
          : asrInfo.copyWith(
              wordBoundaries: [
                for (final at in asrInfo.wordBoundaries)
                  if (at >= leading && at <= leading + value.length)
                    at - leading,
              ],
            ),
      timedSpans: [
        for (final span in timedSpans)
          if (span.textStart >= leading &&
              span.textEnd <= leading + value.length)
            span.shifted(Duration.zero, textOffset: -leading),
      ],
    );
  }

  List<SubtitleTimedSpan> shiftedSpans(
    Duration offset,
    Duration start,
    Duration end,
  ) => [
    for (final span in timedSpans)
      if (span.endTime + offset > start && span.startTime + offset < end)
        SubtitleTimedSpan(
          textStart: span.textStart,
          textEnd: span.textEnd,
          startTime: span.startTime + offset < start
              ? start
              : span.startTime + offset,
          endTime: span.endTime + offset > end ? end : span.endTime + offset,
          role: span.role,
          agentId: span.agentId,
        ),
  ];

  factory SubtitleItem.fromTimingJson(Map raw) {
    final text = raw['t']?.toString() ?? '';
    return SubtitleItem(
      index: (raw['i'] as num?)?.toInt() ?? 0,
      startTime: Duration(milliseconds: (raw['s'] as num?)?.round() ?? 0),
      endTime: Duration(milliseconds: (raw['e'] as num?)?.round() ?? 0),
      text: text,
      asrInfo: SubtitleAsrInfo.fromJson(raw['asr']),
      timedSpans: raw['spans'] is List
          ? (raw['spans'] as List)
                .map((s) => SubtitleTimedSpan.tryParse(s, text))
                .whereType<SubtitleTimedSpan>()
                .toList()
          : const [],
      lyricAgent: raw['agent']?.toString(),
      isBackgroundLyric: raw['bg'] == true,
      isStructuredLyric: raw['lyric'] == true,
      lyricTranslation: raw['translation']?.toString() ?? '',
      lyricRomanization: raw['romanization']?.toString() ?? '',
      lyricTranslationSpans: raw['translationSpans'] is List
          ? (raw['translationSpans'] as List)
                .map(
                  (s) => SubtitleTimedSpan.tryParse(
                    s,
                    raw['translation']?.toString() ?? '',
                  ),
                )
                .whereType<SubtitleTimedSpan>()
                .toList()
          : const [],
      lyricRomanizationSpans: raw['romanizationSpans'] is List
          ? (raw['romanizationSpans'] as List)
                .map(
                  (s) => SubtitleTimedSpan.tryParse(
                    s,
                    raw['romanization']?.toString() ?? '',
                  ),
                )
                .whereType<SubtitleTimedSpan>()
                .toList()
          : const [],
    );
  }

  @override
  String toString() {
    return '[$index] $startTime -> $endTime: ${text.isEmpty ? "[Image]" : text}';
  }
}
