import 'package:flutter/painting.dart';

/// One weight for every transcript view, independent of playback orientation.
abstract final class TranscriptTypography {
  static const defaultFontWeight = 450.0;
  static const minFontWeight = 100.0;
  static const maxFontWeight = 900.0;

  static double normalizeFontWeight(double value) => value.isFinite
      ? value.clamp(minFontWeight, maxFontWeight).roundToDouble()
      : defaultFontWeight;

  static TextStyle style(double value) {
    final weight = normalizeFontWeight(value);
    return TextStyle(
      fontStyle: FontStyle.normal,
      fontWeight: FontWeight.values[(weight / 100).round() - 1],
      // The bundled variable face supports fine changes such as 400 -> 450.
      fontVariations: [FontVariation('wght', weight)],
    );
  }
}
