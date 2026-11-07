import 'package:flutter/painting.dart';

/// Shared by lyric painting, row measurement and the page settings controls.
class MusicLyricTypography {
  static const double defaultFontSizeScale = 1;
  static const double minFontSizeScale = 0.4;
  static const double maxFontSizeScale = 3;
  static const double defaultSpacingScale = 1;
  static const double minSpacingScale = 0;
  static const double maxSpacingScale = 4;

  /// 1 keeps the historical secondary size. The slider is continuous and wide
  /// enough to go well below or above that pairing.
  static const double defaultSecondaryRatio = 1;
  static const double minSecondaryRatio = 0.35;
  static const double maxSecondaryRatio = 2.8;

  final double primaryFontSize;
  final double secondaryFontSize;

  /// Painted geometry uses the same resolved size as text, including the
  /// system text scaler. Custom painters do not receive that scale implicitly.
  final double interludeSize;
  final double stanzaGap;
  final double supportGap;

  const MusicLyricTypography._({
    required this.primaryFontSize,
    required this.secondaryFontSize,
    required this.interludeSize,
    required this.stanzaGap,
    required this.supportGap,
  });

  factory MusicLyricTypography.resolve({
    required Size viewport,
    double fontSizeScale = defaultFontSizeScale,
    double spacingScale = defaultSpacingScale,
    double secondaryRatio = defaultSecondaryRatio,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    // Bound the responsive default, then apply the user's scale. Clamping the
    // final size would create dead zones at both ends of a continuous slider.
    final baseSize = (viewport.height * 0.045).clamp(20.0, 44.0);
    final scale = normalizeFontSizeScale(fontSizeScale);
    final primarySize = baseSize * scale;
    final gapUnit =
        textScaler.scale(primarySize) * normalizeSpacingScale(spacingScale);
    return MusicLyricTypography._(
      primaryFontSize: primarySize,
      secondaryFontSize:
          (baseSize * 0.48).clamp(12.0, 22.0) *
          scale *
          normalizeSecondaryRatio(secondaryRatio),
      interludeSize: textScaler.scale(primarySize),
      stanzaGap: gapUnit * 0.8,
      supportGap: gapUnit * 0.25,
    );
  }

  static double normalizeFontSizeScale(double value) => value.isFinite
      ? value.clamp(minFontSizeScale, maxFontSizeScale)
      : defaultFontSizeScale;

  static double normalizeSpacingScale(double value) => value.isFinite
      ? value.clamp(minSpacingScale, maxSpacingScale)
      : defaultSpacingScale;

  static double normalizeSecondaryRatio(double value) => value.isFinite
      ? value.clamp(minSecondaryRatio, maxSecondaryRatio)
      : defaultSecondaryRatio;
}
