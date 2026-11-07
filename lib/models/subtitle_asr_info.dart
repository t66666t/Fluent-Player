/// Provenance and review information, kept separate from recognition confidence.
/// Alignment confidence measures an acoustic/text match, not ASR accuracy.
class SubtitleAsrInfo {
  const SubtitleAsrInfo({
    this.language = '',
    this.speaker = '',
    this.alignmentScore,
    this.reviewReason = '',
    this.alternateText = '',
    this.notes = const [],
    this.backend = '',
    this.weights = '',
    this.wordBoundaries = const [],
    this.pauses = const [],
  });
  final String language, speaker, reviewReason, alternateText;
  final double? alignmentScore;
  final List<String> notes;
  final String backend, weights;

  /// Preferred UTF-16 text cuts, with no associated or estimated timestamps.
  final List<int> wordBoundaries;

  /// Absolute low-energy intervals, in microseconds. Display segmentation may
  /// use them, then drops them so saved subtitles stay on the old schema.
  final List<List<int>> pauses;
  bool get hasData =>
      language.isNotEmpty ||
      speaker.isNotEmpty ||
      alignmentScore != null ||
      reviewReason.isNotEmpty ||
      notes.isNotEmpty ||
      backend.isNotEmpty ||
      wordBoundaries.isNotEmpty ||
      pauses.isNotEmpty;

  SubtitleAsrInfo copyWith({
    String? language,
    String? speaker,
    double? alignmentScore,
    String? reviewReason,
    String? alternateText,
    List<String>? notes,
    String? backend,
    String? weights,
    List<int>? wordBoundaries,
    List<List<int>>? pauses,
  }) => SubtitleAsrInfo(
    language: language ?? this.language,
    speaker: speaker ?? this.speaker,
    alignmentScore: alignmentScore ?? this.alignmentScore,
    reviewReason: reviewReason ?? this.reviewReason,
    alternateText: alternateText ?? this.alternateText,
    notes: notes ?? this.notes,
    backend: backend ?? this.backend,
    weights: weights ?? this.weights,
    wordBoundaries: wordBoundaries ?? this.wordBoundaries,
    pauses: pauses ?? this.pauses,
  );
  Map<String, Object?> toJson() => {
    if (language.isNotEmpty) 'language': language,
    if (speaker.isNotEmpty) 'speaker': speaker,
    if (alignmentScore != null) 'alignmentScore': alignmentScore,
    if (reviewReason.isNotEmpty) 'review': reviewReason,
    if (alternateText.isNotEmpty) 'alternate': alternateText,
    if (notes.isNotEmpty) 'notes': notes,
    if (backend.isNotEmpty) 'backend': backend,
    if (weights.isNotEmpty) 'weights': weights,
    if (wordBoundaries.isNotEmpty) 'wordBoundaries': wordBoundaries,
    if (pauses.isNotEmpty) 'pauses': pauses,
  };
  factory SubtitleAsrInfo.fromJson(Object? value) {
    if (value is! Map) return const SubtitleAsrInfo();
    final score = (value['alignmentScore'] as num?)?.toDouble();
    return SubtitleAsrInfo(
      language: value['language'] as String? ?? '',
      speaker: value['speaker'] as String? ?? '',
      alignmentScore: score != null && score.isFinite
          ? score.clamp(0, 1)
          : null,
      reviewReason: value['review'] as String? ?? '',
      alternateText: value['alternate'] as String? ?? '',
      notes: List.unmodifiable(
        (value['notes'] as List? ?? const []).whereType<String>(),
      ),
      backend: value['backend'] as String? ?? '',
      weights: value['weights'] as String? ?? '',
      wordBoundaries: List.unmodifiable(
        (value['wordBoundaries'] as List? ?? const [])
            .whereType<int>()
            .where((n) => n >= 0)
            .toSet()
            .toList()
          ..sort(),
      ),
      pauses: List.unmodifiable([
        for (final raw in value['pauses'] as List? ?? const [])
          if (raw is List &&
              raw.length >= 2 &&
              raw[0] is num &&
              raw[1] is num &&
              (raw[1] as num) >= (raw[0] as num))
            [(raw[0] as num).round(), (raw[1] as num).round()],
      ]),
    );
  }
}
