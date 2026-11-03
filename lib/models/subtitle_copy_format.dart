import 'dart:convert';

/// How consecutive subtitle cues are joined when copying from the sidebar.
enum SubtitleCopyCueJoin {
  /// One or more ASCII spaces. Count is [SubtitleCopyFormat.spaceCount].
  spaces,

  /// A single newline between cues.
  newline,

  /// A blank line (`\n\n`) between cues.
  blankLine,

  /// [SubtitleCopyFormat.customSeparator], with `\n` treated as a newline.
  custom,
}

/// How a bilingual cue's primary and secondary lines are joined.
enum SubtitleCopyBilingualJoin {
  /// Same line, separated by one space. Different cues still use the cue join.
  inline,

  /// Primary and secondary each take their own line.
  newline,
}

/// Persisted copy layout for subtitle-sidebar selections.
///
/// Display in the sidebar stays space-joined; this only affects clipboard
/// output so a user can keep the current look while copying with newlines.
class SubtitleCopyFormat {
  const SubtitleCopyFormat({
    required this.cueJoin,
    required this.spaceCount,
    required this.customSeparator,
    required this.bilingualJoin,
  });

  static const SubtitleCopyFormat defaults = SubtitleCopyFormat(
    cueJoin: SubtitleCopyCueJoin.spaces,
    spaceCount: 1,
    customSeparator: '',
    bilingualJoin: SubtitleCopyBilingualJoin.inline,
  );

  static const int minSpaceCount = 1;
  static const int maxSpaceCount = 8;

  final SubtitleCopyCueJoin cueJoin;
  final int spaceCount;
  final String customSeparator;
  final SubtitleCopyBilingualJoin bilingualJoin;

  /// Separator inserted between cues. Empty custom means glue with nothing.
  String get cueSeparator {
    switch (cueJoin) {
      case SubtitleCopyCueJoin.spaces:
        return ' ' * spaceCount;
      case SubtitleCopyCueJoin.newline:
        return '\n';
      case SubtitleCopyCueJoin.blankLine:
        return '\n\n';
      case SubtitleCopyCueJoin.custom:
        return unescapeCopySeparator(customSeparator);
    }
  }

  bool get isDefault => this == defaults;

  SubtitleCopyFormat copyWith({
    SubtitleCopyCueJoin? cueJoin,
    int? spaceCount,
    String? customSeparator,
    SubtitleCopyBilingualJoin? bilingualJoin,
  }) {
    return SubtitleCopyFormat(
      cueJoin: cueJoin ?? this.cueJoin,
      spaceCount: clampSpaceCount(spaceCount ?? this.spaceCount),
      customSeparator: customSeparator ?? this.customSeparator,
      bilingualJoin: bilingualJoin ?? this.bilingualJoin,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'cueJoin': cueJoin.name,
      'spaceCount': spaceCount,
      'customSeparator': customSeparator,
      'bilingualJoin': bilingualJoin.name,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static SubtitleCopyFormat fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return SubtitleCopyFormat(
      cueJoin: _cueJoinFromName(json['cueJoin']),
      spaceCount: clampSpaceCount(
        _asInt(json['spaceCount'], defaults.spaceCount),
      ),
      customSeparator: json['customSeparator'] is String
          ? json['customSeparator'] as String
          : defaults.customSeparator,
      bilingualJoin: _bilingualJoinFromName(json['bilingualJoin']),
    );
  }

  static SubtitleCopyFormat fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return fromJson(decoded);
      }
      if (decoded is Map) {
        return fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Corrupt prefs must not crash startup; fall back to space-join.
    }
    return defaults;
  }

  static int clampSpaceCount(int value) {
    if (value < minSpaceCount) return minSpaceCount;
    if (value > maxSpaceCount) return maxSpaceCount;
    return value;
  }

  static SubtitleCopyCueJoin _cueJoinFromName(Object? name) {
    return SubtitleCopyCueJoin.values.firstWhere(
      (SubtitleCopyCueJoin value) => value.name == name,
      orElse: () => defaults.cueJoin,
    );
  }

  static SubtitleCopyBilingualJoin _bilingualJoinFromName(Object? name) {
    return SubtitleCopyBilingualJoin.values.firstWhere(
      (SubtitleCopyBilingualJoin value) => value.name == name,
      orElse: () => defaults.bilingualJoin,
    );
  }

  static int _asInt(Object? value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  @override
  bool operator ==(Object other) {
    return other is SubtitleCopyFormat &&
        other.cueJoin == cueJoin &&
        other.spaceCount == spaceCount &&
        other.customSeparator == customSeparator &&
        other.bilingualJoin == bilingualJoin;
  }

  @override
  int get hashCode =>
      Object.hash(cueJoin, spaceCount, customSeparator, bilingualJoin);
}

/// Interprets typed `\n` as a real newline so a one-line field can still
/// insert line breaks. A lone backslash is left unchanged.
String unescapeCopySeparator(String raw) {
  if (raw.isEmpty) return raw;
  return raw.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t');
}
