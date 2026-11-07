import 'dart:convert';

import 'package:flutter/material.dart';

import 'subtitle_font.dart';
import 'subtitle_style.dart';
import '../utils/subtitle_font_resolver.dart';

/// Music-player lyric faces. Kept apart from the video subtitle style so a
/// font chosen on one screen does not restyle the other.
class MusicLyricFont {
  /// Matches the lyric view's previous built-in pairing: Chinese stays
  /// Source Han Sans at 600, Latin stays Inter ExtraBold.
  static const defaultStyle = SubtitleTextStyle(
    defaultFontFamily: 'Noto Sans SC',
    defaultFontWeight: 600,
    languageFonts: {
      'zh': SubtitleFontChoice('Noto Sans SC', 600),
      'en': SubtitleFontChoice('Inter', 800),
    },
  );

  static final String defaultStorage = jsonEncode(defaultStyle.toJson());

  static SubtitleTextStyle decode(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is Map) {
        return SubtitleTextStyle.fromJson(value.cast<String, dynamic>());
      }
    } catch (_) {
      // A damaged preference falls back to the built-in lyric faces.
    }
    return defaultStyle;
  }

  static String normalizeStorage(String raw) => jsonEncode(decode(raw).toJson());

  /// The face used when the line is a single script. Mixed lines still use
  /// this for the parent style, then override each run.
  static TextStyle face(
    String text,
    TextStyle base,
    SubtitleTextStyle style, {
    String? language,
  }) {
    final runs = resolveSubtitleFontRuns(text, style, language: language);
    return paint(base, runs.isEmpty ? style.defaultFont : runs.first.font);
  }

  /// Null keeps the single-style text path. More than one script needs a run
  /// per face so a Latin word inside a Chinese line can change independently.
  static List<TextSpan>? runs(
    String text,
    TextStyle base,
    SubtitleTextStyle style, {
    String? language,
  }) {
    final resolved = resolveSubtitleFontRuns(text, style, language: language);
    if (resolved.length <= 1) return null;
    return [
      for (final run in resolved)
        TextSpan(text: run.text, style: paint(base, run.font)),
    ];
  }

  static TextStyle paint(TextStyle base, SubtitleFontChoice choice) {
    final family = choice.family == 'System'
        ? null
        : normalizeBundledFontFamily(choice.family);
    return TextStyle(
      inherit: base.inherit,
      fontFamily: family,
      fontFamilyFallback: const ['Noto Sans SC', 'Noto Sans CJK Fallback'],
      fontWeight: choice.fontWeight,
      fontVariations: choice.fontVariations,
      fontSize: base.fontSize,
      color: base.color,
      height: base.height,
      letterSpacing: base.letterSpacing,
      leadingDistribution: base.leadingDistribution,
      fontStyle: base.fontStyle,
      decoration: base.decoration,
    );
  }
}
