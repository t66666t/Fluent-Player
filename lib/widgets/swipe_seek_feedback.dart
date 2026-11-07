import 'package:flutter/material.dart';

import '../models/media_chapter.dart';
import 'chapter_slider_track_shape.dart';
import 'player_control_metrics.dart';

const _seekAccent = Color(0xFF42A5F5);
const _cancelAccent = Color(0xFFFFB4AB);

Duration _motionDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 160);

/// Original player seek card, retained by its parent while fading on release.
class SwipeSeekFeedback extends StatelessWidget {
  const SwipeSeekFeedback({
    super.key,
    required this.visible,
    required this.canceling,
    required this.difference,
    required this.timeLabel,
  });

  final bool visible;
  final bool canceling;
  final String difference;
  final String timeLabel;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        excluding: !visible,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: canceling
                  ? Colors.red.withValues(alpha: 0.8)
                  : Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canceling) ...[
                  const Icon(Icons.undo, color: Colors.white, size: 48),
                  const SizedBox(height: 8),
                  const Text(
                    "松手取消跳转",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ] else ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        difference.startsWith('+')
                            ? Icons.fast_forward
                            : Icons.fast_rewind,
                        color: Colors.white70,
                        size: 32,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        difference,
                        style: const TextStyle(
                          color: Colors.blueAccent,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    timeLabel,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A passive copy of the normal track, at exactly the same coordinates. It
/// never changes the chrome's visibility, layout or gesture arena.
class SwipeSeekProgressRail extends StatelessWidget {
  const SwipeSeekProgressRail({
    super.key,
    required this.visible,
    required this.canceling,
    required this.position,
    required this.duration,
    required this.metrics,
    required this.chapters,
    required this.padding,
  });

  final bool visible;
  final bool canceling;
  final Duration position;
  final Duration duration;
  final PlayerControlMetrics metrics;
  final List<MediaChapter> chapters;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final max = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedOpacity(
          key: const ValueKey('swipe-seek-progress-reveal'),
          opacity: visible ? 1 : 0,
          duration: _motionDuration(context),
          curve: Curves.easeOutCubic,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0x99000000), Colors.transparent],
              ),
            ),
            child: Padding(
              padding: padding,
              child: SizedBox(
                height: metrics.progressHitHeight,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: canceling ? _cancelAccent : _seekAccent,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.28),
                    thumbColor: canceling ? _cancelAccent : _seekAccent,
                    trackHeight: metrics.trackHeight * 1.35,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: metrics.thumbRadius * 1.2,
                      elevation: 0,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: metrics.overlayRadius,
                    ),
                    trackShape: chapters.length > 1
                        ? ChapterSliderTrackShape(
                            chapters: chapters,
                            durationMs: duration.inMilliseconds,
                          )
                        : const RoundedRectSliderTrackShape(),
                  ),
                  child: ExcludeFocus(
                    child: Slider(
                      key: const ValueKey('swipe-seek-progress-slider'),
                      min: 0,
                      max: max,
                      value: position.inMilliseconds.toDouble().clamp(0, max),
                      padding: EdgeInsets.symmetric(
                        horizontal: metrics.overlayRadius,
                      ),
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
