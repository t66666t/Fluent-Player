import 'package:flutter/widgets.dart';

/// Noto Sans CJK's font box is visually bottom-heavy next to Inter even when
/// both runs are mathematically baseline-aligned. Keep layout metrics intact
/// and adjust only the painted CJK glyph block on the music-player surface.
@visibleForTesting
const double musicCjkOpticalRaiseEm = 0.055;

@visibleForTesting
double musicCjkOpticalRaise(double fontSize) =>
    fontSize * musicCjkOpticalRaiseEm;

bool musicTextContainsCjk(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0xF900 && rune <= 0xFAFF)) {
      return true;
    }
  }
  return false;
}

class MusicTextOpticalAlignment extends StatelessWidget {
  final bool applyCjkRaise;
  final double fontSize;
  final Widget child;

  const MusicTextOpticalAlignment({
    super.key,
    required this.applyCjkRaise,
    required this.fontSize,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!applyCjkRaise) return child;
    return Transform.translate(
      offset: Offset(0, -musicCjkOpticalRaise(fontSize)),
      child: child,
    );
  }
}
