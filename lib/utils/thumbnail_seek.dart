/// Seek offset for library cover frames (avoid black/fade-in at t=0).
///
/// Uses ~15% of duration, floored at 5 seconds, and never past the last
/// second of the media when duration is known.
double thumbnailSeekSeconds({int? durationMs}) {
  if (durationMs == null || durationMs <= 0) {
    return 5.0;
  }
  final durationSec = durationMs / 1000.0;
  if (durationSec <= 1.0) {
    return 0.0;
  }
  final preferred = durationSec * 0.15;
  final seek = preferred < 5.0 ? 5.0 : preferred;
  final maxSeek = durationSec - 1.0;
  if (seek > maxSeek) {
    return maxSeek < 0 ? 0.0 : maxSeek;
  }
  return seek;
}
