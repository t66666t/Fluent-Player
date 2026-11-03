import 'package:flutter/gestures.dart';

/// Outcome of one lyric pointer transaction. Tap and long-press are mutually
/// exclusive: a consumed transaction cannot commit a second action.
enum MusicLyricPointerCommit { none, tap, longPress }

/// Decides the release outcome from the transaction record, not from whichever
/// callback happens to run first. Moving past the slop permanently cancels
/// both actions, even when the pointer later returns to the origin.
MusicLyricPointerCommit resolveMusicLyricPointerRelease({
  required bool consumed,
  required bool movedBeyondSlop,
  required Duration held,
  Duration longPressTimeout = kLongPressTimeout,
}) {
  if (consumed || movedBeyondSlop) return MusicLyricPointerCommit.none;
  if (held >= longPressTimeout) return MusicLyricPointerCommit.longPress;
  return MusicLyricPointerCommit.tap;
}
