/// Keyboard volume steps aligned with mature players (YouTube / VLC / Chrome).
///
/// Short presses use a 5% notch so one tap is noticeable but never jumps from
/// quiet to loud. Holds switch to smaller 2% ticks after a delay so OS key
/// repeat (often 30–50ms) cannot slam volume to 0 or 100.
class PlayerVolumeKeyboard {
  const PlayerVolumeKeyboard._();

  /// YouTube, VLC, and HTML5 video all step arrow-key volume by 5%.
  static const double shortPressStep = 0.05;

  /// mpv / Windows volume-key granularity while a key is held.
  static const double holdStep = 0.02;

  /// Wait for a real hold before ticking. Shorter than typical OS repeat
  /// delay so holding still feels continuous, long enough that a slow tap
  /// does not become a burst of hold ticks.
  static const Duration holdStartDelay = Duration(milliseconds: 320);

  /// ~22% per second after the hold delay: 0→100% takes several seconds,
  /// similar to a controlled vertical swipe rather than a flick.
  static const Duration holdTickInterval = Duration(milliseconds: 90);

  /// Last key/wheel tick → hide. Long enough to read the percent, short
  /// enough that the card does not cover the video after adjusting.
  static const Duration overlayVisibleDuration = Duration(milliseconds: 600);

  /// Snap one short-press notch in [direction] (`1` up, `-1` down).
  ///
  /// Snapping onto a 5% grid keeps consecutive taps predictable when the
  /// current value came from a swipe or a 2% hold tick (e.g. 53% → 55%).
  static double applyShortPress(double current, int direction) {
    final int sign = direction >= 0 ? 1 : -1;
    final int percent = (current.clamp(0.0, 1.0) * 100).round();
    final int nextPercent;
    if (sign > 0) {
      nextPercent = ((percent ~/ 5) + 1) * 5;
    } else {
      final int ceilStep = (percent + 4) ~/ 5;
      nextPercent = (ceilStep - 1) * 5;
    }
    return (nextPercent / 100).clamp(0.0, 1.0);
  }

  /// One held-key tick. Stays on a 1% grid so the HUD does not jitter.
  static double applyHoldTick(double current, int direction) {
    final int sign = direction >= 0 ? 1 : -1;
    final int percent = (current.clamp(0.0, 1.0) * 100).round();
    return ((percent + sign * (holdStep * 100).round()) / 100).clamp(0.0, 1.0);
  }
}
