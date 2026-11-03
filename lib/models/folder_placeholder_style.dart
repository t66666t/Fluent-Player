import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// How an empty folder cover is painted. Shared by grid cards and list tiles.
enum FolderPlaceholderPaintStyle {
  /// Solid hashed color with a large centered glyph.
  letterBlock,

  /// Dark field, tinted folder icon, letter badge in the corner.
  tintedIcon,

  /// Two-stop gradient, faint folder silhouette, centered glyph.
  gradientGhost,
}

/// Which pre-baked palette the id hash indexes into.
enum FolderPlaceholderColorStyle { muted, vivid, pastel }

/// Tunables for folder placeholder covers.
///
/// Size fields are fractions of the cover's **shortest side**. Using width on a
/// 16:9 card made letters and folder glyphs taller than the cover itself.
class FolderPlaceholderSettings {
  const FolderPlaceholderSettings({
    required this.paintStyle,
    required this.colorStyle,
    required this.showCoverText,
    required this.maxCoverTextLength,
    required this.letterScale,
    required this.letterOpacity,
    required this.cornerBadgeScale,
    required this.folderIconScale,
    required this.letterBadgeScale,
    required this.letterBadgeGlyphScale,
    required this.iconOpacity,
    required this.gradientLetterScale,
    required this.gradientLetterOpacity,
    required this.silhouetteScale,
    required this.silhouetteOpacity,
  });

  /// Bump when stored size fields change meaning (v1 fractions → v2 multipliers).
  static const int schemaVersion = 2;

  static const FolderPlaceholderSettings defaults = FolderPlaceholderSettings(
    paintStyle: FolderPlaceholderPaintStyle.gradientGhost,
    colorStyle: FolderPlaceholderColorStyle.muted,
    showCoverText: false,
    maxCoverTextLength: 2,
    letterScale: 1.0,
    letterOpacity: 0.94,
    cornerBadgeScale: 0.16,
    folderIconScale: 0.64,
    letterBadgeScale: 1.0,
    letterBadgeGlyphScale: 1.0,
    iconOpacity: 0.92,
    gradientLetterScale: 1.0,
    gradientLetterOpacity: 0.94,
    // 0–100 slider 58, with curve center still at 0.70 (slider 50).
    silhouetteScale: 0.834,
    silhouetteOpacity: 0.30,
  );

  /// First shipped defaults were fractions of cover **width**, which overflowed
  /// 16:9 cards. Matching snapshots migrate onto [defaults] on load.
  static const FolderPlaceholderSettings legacyWidthBasedDefaults =
      FolderPlaceholderSettings(
        paintStyle: FolderPlaceholderPaintStyle.gradientGhost,
        colorStyle: FolderPlaceholderColorStyle.muted,
        showCoverText: true,
        maxCoverTextLength: 2,
        letterScale: 0.42,
        letterOpacity: 0.92,
        cornerBadgeScale: 0.15,
        folderIconScale: 0.55,
        letterBadgeScale: 0.22,
        letterBadgeGlyphScale: 1.0,
        iconOpacity: 0.90,
        gradientLetterScale: 0.40,
        gradientLetterOpacity: 0.94,
        silhouetteScale: 0.72,
        silhouetteOpacity: 0.22,
      );

  static const int maxCoverTextLengthMin = 1;
  static const int maxCoverTextLengthMax = 4;
  static const double letterScaleMin = 0.08;
  static const double letterScaleMax = 2.6;
  static const double letterOpacityMin = 0.0;
  static const double letterOpacityMax = 1.0;
  static const double cornerBadgeScaleMin = 0.0;
  static const double cornerBadgeScaleMax = 0.62;
  static const double folderIconScaleMin = 0.04;
  static const double folderIconScaleMax = 2.4;
  static const double letterBadgeScaleMin = 0.04;
  static const double letterBadgeScaleMax = 3.2;
  static const double letterBadgeGlyphScaleMin = 0.08;
  static const double letterBadgeGlyphScaleMax = 2.8;
  static const double iconOpacityMin = 0.0;
  static const double iconOpacityMax = 1.0;
  static const double gradientLetterScaleMin = 0.08;
  static const double gradientLetterScaleMax = 2.6;
  static const double gradientLetterOpacityMin = 0.0;
  static const double gradientLetterOpacityMax = 1.0;
  static const double silhouetteScaleMin = 0.04;
  static const double silhouetteScaleMax = 2.80;
  /// Slider 50 on the 0–100 curve. The shipped default sits slightly above it.
  static const double silhouetteScaleCurveCenter = 0.70;
  static const double silhouetteOpacityMin = 0.0;
  static const double silhouetteOpacityMax = 1.0;

  final FolderPlaceholderPaintStyle paintStyle;
  final FolderPlaceholderColorStyle colorStyle;

  /// When false, every paint style keeps color/icon only.
  final bool showCoverText;

  /// Auto and custom cover labels are clipped to this many graphemes.
  final int maxCoverTextLength;

  /// Multiplier on the per-character baseline. 1.0 is the designed size.
  final double letterScale;
  final double letterOpacity;

  /// Letter-block corner folder badge. Near 0 hides it.
  final double cornerBadgeScale;

  /// Tinted-icon folder glyph size as a fraction of the cover shortest side.
  final double folderIconScale;

  /// Multiplier on the designed corner badge diameter (about 0.34 of the
  /// shortest side at 1.0). Independent of how many letters sit inside.
  final double letterBadgeScale;

  /// Multiplier on the designed glyph fill inside that badge. 1.0 fits the
  /// letters; larger values overflow and get clipped by the circle.
  final double letterBadgeGlyphScale;
  final double iconOpacity;

  /// Multiplier on the per-character baseline for gradient-ghost letters.
  final double gradientLetterScale;
  final double gradientLetterOpacity;

  /// Folder silhouette size as a fraction of the cover shortest side.
  /// Can exceed 1.0 so the icon is cropped by the card.
  final double silhouetteScale;
  final double silhouetteOpacity;

  String get paintStyleLabel {
    switch (paintStyle) {
      case FolderPlaceholderPaintStyle.letterBlock:
        return '色块大字';
      case FolderPlaceholderPaintStyle.tintedIcon:
        return '染色图标';
      case FolderPlaceholderPaintStyle.gradientGhost:
        return '渐变剪影';
    }
  }

  String get colorStyleLabel {
    switch (colorStyle) {
      case FolderPlaceholderColorStyle.muted:
        return '柔和';
      case FolderPlaceholderColorStyle.vivid:
        return '鲜艳';
      case FolderPlaceholderColorStyle.pastel:
        return '淡彩';
    }
  }

  FolderPlaceholderSettings copyWith({
    FolderPlaceholderPaintStyle? paintStyle,
    FolderPlaceholderColorStyle? colorStyle,
    bool? showCoverText,
    int? maxCoverTextLength,
    double? letterScale,
    double? letterOpacity,
    double? cornerBadgeScale,
    double? folderIconScale,
    double? letterBadgeScale,
    double? letterBadgeGlyphScale,
    double? iconOpacity,
    double? gradientLetterScale,
    double? gradientLetterOpacity,
    double? silhouetteScale,
    double? silhouetteOpacity,
  }) {
    return FolderPlaceholderSettings(
      paintStyle: paintStyle ?? this.paintStyle,
      colorStyle: colorStyle ?? this.colorStyle,
      showCoverText: showCoverText ?? this.showCoverText,
      maxCoverTextLength: maxCoverTextLength ?? this.maxCoverTextLength,
      letterScale: letterScale ?? this.letterScale,
      letterOpacity: letterOpacity ?? this.letterOpacity,
      cornerBadgeScale: cornerBadgeScale ?? this.cornerBadgeScale,
      folderIconScale: folderIconScale ?? this.folderIconScale,
      letterBadgeScale: letterBadgeScale ?? this.letterBadgeScale,
      letterBadgeGlyphScale:
          letterBadgeGlyphScale ?? this.letterBadgeGlyphScale,
      iconOpacity: iconOpacity ?? this.iconOpacity,
      gradientLetterScale: gradientLetterScale ?? this.gradientLetterScale,
      gradientLetterOpacity:
          gradientLetterOpacity ?? this.gradientLetterOpacity,
      silhouetteScale: silhouetteScale ?? this.silhouetteScale,
      silhouetteOpacity: silhouetteOpacity ?? this.silhouetteOpacity,
    ).normalized();
  }

  /// Restores only the sliders that belong to the active paint style.
  FolderPlaceholderSettings resetCurrentPaintDefaults() {
    const d = defaults;
    switch (paintStyle) {
      case FolderPlaceholderPaintStyle.letterBlock:
        return copyWith(
          letterScale: d.letterScale,
          letterOpacity: d.letterOpacity,
          cornerBadgeScale: d.cornerBadgeScale,
        );
      case FolderPlaceholderPaintStyle.tintedIcon:
        return copyWith(
          folderIconScale: d.folderIconScale,
          letterBadgeScale: d.letterBadgeScale,
          letterBadgeGlyphScale: d.letterBadgeGlyphScale,
          iconOpacity: d.iconOpacity,
        );
      case FolderPlaceholderPaintStyle.gradientGhost:
        return copyWith(
          gradientLetterScale: d.gradientLetterScale,
          gradientLetterOpacity: d.gradientLetterOpacity,
          silhouetteScale: d.silhouetteScale,
          silhouetteOpacity: d.silhouetteOpacity,
        );
    }
  }

  FolderPlaceholderSettings normalized() {
    return FolderPlaceholderSettings(
      paintStyle: paintStyle,
      colorStyle: colorStyle,
      showCoverText: showCoverText,
      maxCoverTextLength: maxCoverTextLength.clamp(
        maxCoverTextLengthMin,
        maxCoverTextLengthMax,
      ),
      letterScale: letterScale.clamp(letterScaleMin, letterScaleMax),
      letterOpacity: letterOpacity.clamp(letterOpacityMin, letterOpacityMax),
      cornerBadgeScale: cornerBadgeScale.clamp(
        cornerBadgeScaleMin,
        cornerBadgeScaleMax,
      ),
      folderIconScale: folderIconScale.clamp(
        folderIconScaleMin,
        folderIconScaleMax,
      ),
      letterBadgeScale: letterBadgeScale.clamp(
        letterBadgeScaleMin,
        letterBadgeScaleMax,
      ),
      letterBadgeGlyphScale: letterBadgeGlyphScale.clamp(
        letterBadgeGlyphScaleMin,
        letterBadgeGlyphScaleMax,
      ),
      iconOpacity: iconOpacity.clamp(iconOpacityMin, iconOpacityMax),
      gradientLetterScale: gradientLetterScale.clamp(
        gradientLetterScaleMin,
        gradientLetterScaleMax,
      ),
      gradientLetterOpacity: gradientLetterOpacity.clamp(
        gradientLetterOpacityMin,
        gradientLetterOpacityMax,
      ),
      silhouetteScale: silhouetteScale.clamp(
        silhouetteScaleMin,
        silhouetteScaleMax,
      ),
      silhouetteOpacity: silhouetteOpacity.clamp(
        silhouetteOpacityMin,
        silhouetteOpacityMax,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'paintStyle': paintStyle.name,
      'colorStyle': colorStyle.name,
      'showCoverText': showCoverText,
      'maxCoverTextLength': maxCoverTextLength,
      'letterScale': letterScale,
      'letterOpacity': letterOpacity,
      'cornerBadgeScale': cornerBadgeScale,
      'folderIconScale': folderIconScale,
      'letterBadgeScale': letterBadgeScale,
      'letterBadgeGlyphScale': letterBadgeGlyphScale,
      'iconOpacity': iconOpacity,
      'gradientLetterScale': gradientLetterScale,
      'gradientLetterOpacity': gradientLetterOpacity,
      'silhouetteScale': silhouetteScale,
      'silhouetteOpacity': silhouetteOpacity,
    };
  }

  String toJsonString() => json.encode(toJson());

  factory FolderPlaceholderSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    final parsed = FolderPlaceholderSettings(
      paintStyle: _paintStyleFrom(json['paintStyle']) ?? defaults.paintStyle,
      colorStyle: _colorStyleFrom(json['colorStyle']) ?? defaults.colorStyle,
      showCoverText: json.containsKey('showCoverText')
          ? _readBool(json['showCoverText'], true)
          : true,
      maxCoverTextLength: _readInt(
        json['maxCoverTextLength'],
        defaults.maxCoverTextLength,
      ),
      letterScale: _readDouble(json['letterScale'], defaults.letterScale),
      letterOpacity: _readDouble(json['letterOpacity'], defaults.letterOpacity),
      cornerBadgeScale: _readDouble(
        json['cornerBadgeScale'],
        defaults.cornerBadgeScale,
      ),
      folderIconScale: _readDouble(
        json['folderIconScale'],
        defaults.folderIconScale,
      ),
      letterBadgeScale: _readDouble(
        json['letterBadgeScale'],
        defaults.letterBadgeScale,
      ),
      letterBadgeGlyphScale: _readDouble(
        json['letterBadgeGlyphScale'],
        defaults.letterBadgeGlyphScale,
      ),
      iconOpacity: _readDouble(json['iconOpacity'], defaults.iconOpacity),
      gradientLetterScale: _readDouble(
        json['gradientLetterScale'],
        defaults.gradientLetterScale,
      ),
      gradientLetterOpacity: _readDouble(
        json['gradientLetterOpacity'],
        defaults.gradientLetterOpacity,
      ),
      silhouetteScale: _readDouble(
        json['silhouetteScale'],
        defaults.silhouetteScale,
      ),
      silhouetteOpacity: _readDouble(
        json['silhouetteOpacity'],
        defaults.silhouetteOpacity,
      ),
    ).normalized();
    if (parsed == legacyWidthBasedDefaults) return defaults;
    // v1 stored letter sizes as cover-fraction; v2 stores multipliers on the
    // per-character baseline so 1.0 always means "the designed size".
    final version = _readInt(json['schemaVersion'], 1);
    if (version < schemaVersion) {
      return parsed.copyWith(
        letterScale: parsed.letterScale / 0.50,
        letterBadgeScale: parsed.letterBadgeScale / 0.20,
        gradientLetterScale: parsed.gradientLetterScale / 0.36,
      );
    }
    return parsed;
  }

  factory FolderPlaceholderSettings.fromJsonString(String raw) {
    if (raw.trim().isEmpty) return defaults;
    try {
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) {
        return FolderPlaceholderSettings.fromJson(decoded);
      }
      if (decoded is Map) {
        return FolderPlaceholderSettings.fromJson(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
    } catch (_) {
      return defaults;
    }
    return defaults;
  }

  @override
  bool operator ==(Object other) {
    return other is FolderPlaceholderSettings &&
        other.paintStyle == paintStyle &&
        other.colorStyle == colorStyle &&
        other.showCoverText == showCoverText &&
        other.maxCoverTextLength == maxCoverTextLength &&
        other.letterScale == letterScale &&
        other.letterOpacity == letterOpacity &&
        other.cornerBadgeScale == cornerBadgeScale &&
        other.folderIconScale == folderIconScale &&
        other.letterBadgeScale == letterBadgeScale &&
        other.letterBadgeGlyphScale == letterBadgeGlyphScale &&
        other.iconOpacity == iconOpacity &&
        other.gradientLetterScale == gradientLetterScale &&
        other.gradientLetterOpacity == gradientLetterOpacity &&
        other.silhouetteScale == silhouetteScale &&
        other.silhouetteOpacity == silhouetteOpacity;
  }

  @override
  int get hashCode => Object.hash(
    paintStyle,
    colorStyle,
    showCoverText,
    maxCoverTextLength,
    letterScale,
    letterOpacity,
    cornerBadgeScale,
    folderIconScale,
    letterBadgeScale,
    letterBadgeGlyphScale,
    iconOpacity,
    gradientLetterScale,
    gradientLetterOpacity,
    silhouetteScale,
    silhouetteOpacity,
  );

  static FolderPlaceholderSliderSpec get letterScaleSpec =>
      FolderPlaceholderSliderSpec(
        min: letterScaleMin,
        max: letterScaleMax,
        comfort: defaults.letterScale,
      );
  static FolderPlaceholderSliderSpec get letterOpacitySpec =>
      FolderPlaceholderSliderSpec(
        min: letterOpacityMin,
        max: letterOpacityMax,
        comfort: defaults.letterOpacity,
      );
  static FolderPlaceholderSliderSpec get cornerBadgeScaleSpec =>
      FolderPlaceholderSliderSpec(
        min: cornerBadgeScaleMin,
        max: cornerBadgeScaleMax,
        comfort: defaults.cornerBadgeScale,
      );
  static FolderPlaceholderSliderSpec get folderIconScaleSpec =>
      FolderPlaceholderSliderSpec(
        min: folderIconScaleMin,
        max: folderIconScaleMax,
        comfort: defaults.folderIconScale,
      );
  static FolderPlaceholderSliderSpec get letterBadgeScaleSpec =>
      FolderPlaceholderSliderSpec(
        min: letterBadgeScaleMin,
        max: letterBadgeScaleMax,
        comfort: defaults.letterBadgeScale,
      );
  static FolderPlaceholderSliderSpec get letterBadgeGlyphScaleSpec =>
      FolderPlaceholderSliderSpec(
        min: letterBadgeGlyphScaleMin,
        max: letterBadgeGlyphScaleMax,
        comfort: defaults.letterBadgeGlyphScale,
      );
  static FolderPlaceholderSliderSpec get iconOpacitySpec =>
      FolderPlaceholderSliderSpec(
        min: iconOpacityMin,
        max: iconOpacityMax,
        comfort: defaults.iconOpacity,
      );
  static FolderPlaceholderSliderSpec get gradientLetterScaleSpec =>
      FolderPlaceholderSliderSpec(
        min: gradientLetterScaleMin,
        max: gradientLetterScaleMax,
        comfort: defaults.gradientLetterScale,
      );
  static FolderPlaceholderSliderSpec get gradientLetterOpacitySpec =>
      FolderPlaceholderSliderSpec(
        min: gradientLetterOpacityMin,
        max: gradientLetterOpacityMax,
        comfort: defaults.gradientLetterOpacity,
      );
  static FolderPlaceholderSliderSpec get silhouetteScaleSpec =>
      FolderPlaceholderSliderSpec(
        min: silhouetteScaleMin,
        max: silhouetteScaleMax,
        comfort: silhouetteScaleCurveCenter,
      );
  static FolderPlaceholderSliderSpec get silhouetteOpacitySpec =>
      FolderPlaceholderSliderSpec(
        min: silhouetteOpacityMin,
        max: silhouetteOpacityMax,
        comfort: defaults.silhouetteOpacity,
      );
}

/// Stable hashed accent plus a darker sibling used for gradients.
class FolderPlaceholderSwatch {
  const FolderPlaceholderSwatch({required this.accent, required this.shadow});

  final Color accent;
  final Color shadow;
}

/// Resolves a folder's visual identity without reading its contents.
class FolderPlaceholderLook {
  /// FNV-1a 32-bit over UTF-16 code units. Portable (unlike [String.hashCode])
  /// and avalanches well, so similar ids do not collapse to the same hue.
  static int colorSeed(String folderId) {
    const fnvOffset = 0x811c9dc5;
    const fnvPrime = 0x01000193;
    var hash = fnvOffset;
    for (final unit in folderId.codeUnits) {
      hash ^= unit & 0xff;
      hash = (hash * fnvPrime) & 0xffffffff;
      if (unit > 0xff) {
        hash ^= (unit >> 8) & 0xff;
        hash = (hash * fnvPrime) & 0xffffffff;
      }
    }
    return hash;
  }

  static FolderPlaceholderSwatch swatchFor({
    required String folderId,
    required FolderPlaceholderColorStyle colorStyle,
  }) {
    final accent = _accentFor(colorSeed(folderId), colorStyle);
    final hsl = HSLColor.fromColor(accent);
    final shadow = hsl
        .withLightness((hsl.lightness * 0.46).clamp(0.08, 0.32))
        .withSaturation((hsl.saturation * 0.85).clamp(0.0, 1.0))
        .toColor();
    return FolderPlaceholderSwatch(accent: accent, shadow: shadow);
  }

  /// Maps a 32-bit seed onto HSL. Hue uses a golden-ratio fold so ids are
  /// spread around the wheel instead of 12 palette slots; sat/light stay in
  /// the band that used to live in each style's 12 swatches.
  static Color _accentFor(int seed, FolderPlaceholderColorStyle style) {
    final hue = (((seed & 0xffffffff) * 0.618033988749895) % 1.0) * 360.0;
    final satT = ((seed >> 8) & 0xff) / 255.0;
    final litT = ((seed >> 16) & 0xff) / 255.0;
    late final double sat;
    late final double light;
    switch (style) {
      case FolderPlaceholderColorStyle.muted:
        sat = 0.36 + satT * 0.18;
        light = 0.26 + litT * 0.12;
      case FolderPlaceholderColorStyle.vivid:
        sat = 0.56 + satT * 0.22;
        light = 0.46 + litT * 0.14;
      case FolderPlaceholderColorStyle.pastel:
        sat = 0.26 + satT * 0.16;
        light = 0.56 + litT * 0.14;
    }
    return HSLColor.fromAHSL(1, hue, sat, light).toColor();
  }

  /// Cover text shown on a folder. [coverLabel] wins when the user set one;
  /// otherwise [autoLabelFor] derives a short label from the folder name.
  static String displayLabel({
    required String folderName,
    String? coverLabel,
    required bool showCoverText,
    int maxLength = 2,
  }) {
    if (!showCoverText) return '';
    if (coverLabel != null) {
      return clampLabel(coverLabel, maxLength: maxLength);
    }
    return autoLabelFor(folderName, maxLength: maxLength);
  }

  /// Peel wrapping punctuation, then keep a short readable token.
  /// Cap is [maxLength]: 数学→数学, 《三国演义》→三国 when max is 2.
  static String autoLabelFor(String name, {int maxLength = 2}) {
    final cap = maxLength.clamp(1, 4);
    final core = _stripDecorators(name);
    if (core.isEmpty) return '';
    final chars = core.characters.toList();

    if (chars.every(_isDigit)) {
      return chars.take(cap).join();
    }
    // "2024数学" should not become "20"; peel the year prefix first.
    if (_isDigit(chars.first)) {
      return autoLabelFor(chars.skipWhile(_isDigit).join(), maxLength: cap);
    }

    if (chars.length >= 2 && chars.every(_isUpperLatin)) {
      return chars.take(cap).join();
    }

    if (_isCjk(chars.first)) {
      final taken = <String>[];
      for (final grapheme in chars) {
        if (!_isCjk(grapheme) || taken.length >= cap) break;
        taken.add(grapheme);
      }
      return taken.join();
    }

    final words = core
        .split(RegExp(r'[\s_\-./]+'))
        .where((word) => word.trim().isNotEmpty)
        .toList();
    final meaningful = words
        .skipWhile((word) => RegExp(r'^[\d.]+$').hasMatch(word))
        .toList();
    if (meaningful.isNotEmpty &&
        meaningful.first.characters.isNotEmpty &&
        _isCjk(meaningful.first.characters.first)) {
      return autoLabelFor(meaningful.join(), maxLength: cap);
    }
    if (words.length >= 2) {
      return words
          .take(math.min(3, cap))
          .map((word) => _upperLatin(word.characters.first))
          .join();
    }

    final latinCap = math.min(2, cap);
    if (chars.length <= 4 &&
        chars.every((grapheme) => _isLatinLetter(grapheme) || _isDigit(grapheme))) {
      return _upperLatin(chars.first) + chars.skip(1).take(latinCap - 1).join();
    }
    if (chars.length >= 2 && latinCap >= 2) {
      return _upperLatin(chars[0]) + chars[1];
    }
    return _upperLatin(chars.first);
  }

  static String clampLabel(String raw, {int maxLength = 2}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.characters.take(maxLength.clamp(1, 4)).toString();
  }

  /// One em size for every label: the 4-character fit. Shorter labels use the
  /// same type, not a larger point size.
  static double glyphBaseline({
    required int graphemes,
    required FolderPlaceholderPaintStyle paintStyle,
  }) {
    switch (paintStyle) {
      case FolderPlaceholderPaintStyle.letterBlock:
        return 0.338;
      case FolderPlaceholderPaintStyle.tintedIcon:
        return 0.131;
      case FolderPlaceholderPaintStyle.gradientGhost:
        return 0.142;
    }
  }

  /// Latin letters look louder than CJK at the same em; digits are skinny ink
  /// and need a slight boost. Tuned against a 16-card sheet of real labels.
  static double glyphScriptScale(String glyph) {
    if (glyph.isEmpty) return 1;
    final chars = glyph.characters.toList();
    final allDigits = chars.every(_isDigit);
    if (allDigits) return 1.06;
    final allLatin = chars.every(_isLatinLetter);
    if (allLatin) return 0.96;
    final allAlnum = chars.every(
      (grapheme) => _isLatinLetter(grapheme) || _isDigit(grapheme),
    );
    if (allAlnum) return 1.02;
    return 1;
  }

  static bool glyphIsMostlyCjk(String glyph) {
    if (glyph.isEmpty) return false;
    var cjk = 0;
    for (final grapheme in glyph.characters) {
      if (_isCjk(grapheme)) cjk += 1;
    }
    return cjk * 2 >= glyph.characters.length;
  }

  static double glyphSize({
    required double basis,
    required String glyph,
    required double multiplier,
    required FolderPlaceholderPaintStyle paintStyle,
  }) {
    final n = glyph.characters.isEmpty ? 1 : glyph.characters.length;
    return basis *
        glyphBaseline(graphemes: n, paintStyle: paintStyle) *
        glyphScriptScale(glyph) *
        multiplier;
  }

  /// Material [Icons.folder_rounded] has a left tab, so the visual center of
  /// the pocket sits below (and a hair right of) the ink bounding box. Cover
  /// text in gradient-ghost mode is shifted by this, as a fraction of the
  /// silhouette size. The folder itself stays put.
  static const double gradientGhostGlyphNudgeX = 0.0;
  static const double gradientGhostGlyphNudgeY = 0.05;

  static Offset gradientGhostGlyphNudge(double silhouetteSize) {
    return Offset(
      silhouetteSize * gradientGhostGlyphNudgeX,
      silhouetteSize * gradientGhostGlyphNudgeY,
    );
  }

  /// Designed letter-badge diameter at scale 1.0, as a fraction of the cover
  /// shortest side. Matches the old 2-character circle.
  static const double letterBadgeDesignedDiameter = 0.34;

  static double letterBadgeDiameter({
    required double basis,
    required double badgeScale,
  }) {
    return basis * letterBadgeDesignedDiameter * badgeScale;
  }

  /// Fraction of the badge diameter occupied by each letter at glyph-scale 1.0.
  /// Locked to the 4-character fit so 1–4 letters share one type size.
  static double letterBadgeGlyphFill(int graphemes) {
    return 0.385;
  }

  static double letterBadgeGlyphSize({
    required double badgeDiameter,
    required String glyph,
    required double glyphScale,
  }) {
    final n = glyph.characters.isEmpty ? 1 : glyph.characters.length;
    return badgeDiameter *
        letterBadgeGlyphFill(n) *
        glyphScriptScale(glyph) *
        glyphScale;
  }

  static String _stripDecorators(String name) {
    var value = name.trim();
    const wrappers =
        '《》〈〉「」『』【】〔〕［］（）()[]{}<>""\'\'“”‘’·•、，。！？：；—–-…#*~`';
    var changed = true;
    while (changed && value.isNotEmpty) {
      changed = false;
      final chars = value.characters;
      if (wrappers.contains(chars.first)) {
        value = chars.skip(1).toString().trim();
        changed = true;
        continue;
      }
      if (wrappers.contains(chars.last)) {
        value = chars.skipLast(1).toString().trim();
        changed = true;
      }
    }
    return value;
  }

  static bool _isCjk(String grapheme) {
    if (grapheme.isEmpty) return false;
    final code = grapheme.runes.first;
    return (code >= 0x3040 && code <= 0x30FF) ||
        (code >= 0x3400 && code <= 0x9FFF) ||
        (code >= 0xAC00 && code <= 0xD7AF) ||
        (code >= 0xF900 && code <= 0xFAFF) ||
        (code >= 0x20000 && code <= 0x2CEAF);
  }

  static bool _isDigit(String grapheme) {
    if (grapheme.length != 1) return false;
    final code = grapheme.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  static bool _isLatinLetter(String grapheme) {
    if (grapheme.length != 1) return false;
    final code = grapheme.codeUnitAt(0);
    return (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
  }

  static bool _isUpperLatin(String grapheme) {
    if (grapheme.length != 1) return false;
    final code = grapheme.codeUnitAt(0);
    return code >= 0x41 && code <= 0x5A;
  }

  static String _upperLatin(String grapheme) {
    if (grapheme.length == 1) {
      final code = grapheme.codeUnitAt(0);
      if (code >= 0x61 && code <= 0x7A) {
        return grapheme.toUpperCase();
      }
    }
    return grapheme;
  }
}

String folderPlaceholderPaintStyleLabel(FolderPlaceholderPaintStyle style) {
  switch (style) {
    case FolderPlaceholderPaintStyle.letterBlock:
      return '色块大字';
    case FolderPlaceholderPaintStyle.tintedIcon:
      return '染色图标';
    case FolderPlaceholderPaintStyle.gradientGhost:
      return '渐变剪影';
  }
}

String folderPlaceholderColorStyleLabel(FolderPlaceholderColorStyle style) {
  switch (style) {
    case FolderPlaceholderColorStyle.muted:
      return '柔和';
    case FolderPlaceholderColorStyle.vivid:
      return '鲜艳';
    case FolderPlaceholderColorStyle.pastel:
      return '淡彩';
  }
}

FolderPlaceholderPaintStyle? _paintStyleFrom(Object? raw) {
  if (raw is! String) return null;
  for (final value in FolderPlaceholderPaintStyle.values) {
    if (value.name == raw) return value;
  }
  return null;
}

FolderPlaceholderColorStyle? _colorStyleFrom(Object? raw) {
  if (raw is! String) return null;
  for (final value in FolderPlaceholderColorStyle.values) {
    if (value.name == raw) return value;
  }
  return null;
}

double _readDouble(Object? raw, double fallback) {
  if (raw is num && raw.isFinite) return raw.toDouble();
  if (raw is String) {
    final parsed = double.tryParse(raw);
    if (parsed != null && parsed.isFinite) return parsed;
  }
  return fallback;
}

bool _readBool(Object? raw, bool fallback) {
  if (raw is bool) return raw;
  if (raw is String) {
    if (raw == 'true') return true;
    if (raw == 'false') return false;
  }
  return fallback;
}

int _readInt(Object? raw, int fallback) {
  if (raw is int) return raw;
  if (raw is num && raw.isFinite) return raw.round();
  if (raw is String) {
    final parsed = int.tryParse(raw);
    if (parsed != null) return parsed;
  }
  return fallback;
}

/// Maps a 0–100 slider onto a real value. The middle is the designed default
/// and moves in small steps; the ends cover a much wider range more quickly.
class FolderPlaceholderSliderCurve {
  const FolderPlaceholderSliderCurve._();

  static const double sliderMin = 0;
  static const double sliderMax = 100;

  /// Steeper sinh = finer around 50, coarser at 0/100. 2.6 stays usable.
  static const double _k = 2.6;

  static double fromSlider({
    required double slider,
    required double min,
    required double max,
    required double comfort,
  }) {
    final t = slider.clamp(sliderMin, sliderMax) / sliderMax;
    final u = (t - 0.5) * 2;
    final shaped = _sinh(_k * u) / _sinh(_k);
    if (shaped <= 0) {
      return comfort + shaped * (comfort - min);
    }
    return comfort + shaped * (max - comfort);
  }

  static double toSlider({
    required double value,
    required double min,
    required double max,
    required double comfort,
  }) {
    final clamped = value.clamp(min, max);
    double shaped;
    if (clamped <= comfort) {
      final span = comfort - min;
      shaped = span <= 1e-9 ? 0.0 : -((comfort - clamped) / span).clamp(0.0, 1.0);
    } else {
      final span = max - comfort;
      shaped = span <= 1e-9 ? 0.0 : ((clamped - comfort) / span).clamp(0.0, 1.0);
    }
    final u = _asinh(shaped * _sinh(_k)) / _k;
    return ((u + 1) / 2 * sliderMax).clamp(sliderMin, sliderMax);
  }

  static double _sinh(double x) {
    final e = math.exp(x);
    return (e - 1 / e) / 2;
  }

  static double _asinh(double x) {
    return math.log(x + math.sqrt(x * x + 1));
  }
}

class FolderPlaceholderSliderSpec {
  const FolderPlaceholderSliderSpec({
    required this.min,
    required this.max,
    required this.comfort,
  });

  final double min;
  final double max;
  final double comfort;

  double fromSlider(double slider) => FolderPlaceholderSliderCurve.fromSlider(
    slider: slider,
    min: min,
    max: max,
    comfort: comfort,
  );

  double toSlider(double value) => FolderPlaceholderSliderCurve.toSlider(
    value: value,
    min: min,
    max: max,
    comfort: comfort,
  );
}
