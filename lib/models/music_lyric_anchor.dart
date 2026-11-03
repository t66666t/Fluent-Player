/// Saved lyric positioning within the reading area of each player layout.
class MusicLyricAnchor {
  /// Keeps the responsive defaults, including compact and detail layouts.
  static const double automatic = -1;
  static const double portraitDefault = 0.28;
  static const double landscapeDefault = 0.30;
  static const double min = 0.10;
  static const double max = 0.70;

  static double normalize(double value) =>
      !value.isFinite || value == automatic ? automatic : value.clamp(min, max);
}
