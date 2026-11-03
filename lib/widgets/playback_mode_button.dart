import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/playback_mode.dart';
import 'playback_mode_icon.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import '../theme/app_tokens.dart';

/// All entry points edit the active queue's mode, without touching transport.
class PlaybackModeButton extends StatelessWidget {
  const PlaybackModeButton({
    super.key,
    this.size = const Size.square(36),
    this.iconSize = 20,
    this.backgroundColor = Colors.transparent,
    this.foregroundColor = Colors.white70,
  });

  final Size size;
  final double iconSize;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final manager =
        context.read<PlaylistManager?>() ??
        context.read<MediaPlaybackService?>()?.playlistManager ??
        MediaPlaybackService().playlistManager;
    return ListenableBuilder(
      listenable: manager ?? const AlwaysStoppedAnimation(0),
      builder: (context, _) {
        final mode = manager?.playbackMode ?? PlaybackMode.sequential;
        final enabled = manager != null && manager.playlist.isNotEmpty;
        final VoidCallback? advance = enabled
            ? manager.cyclePlaybackMode
            : null;

        return Semantics(
          button: true,
          enabled: enabled,
          label: '播放模式',
          value: mode.label,
          hint: '切换到${mode.next.label}',
          onTap: advance,
          excludeSemantics: true,
          child: Tooltip(
            message: '${mode.label} · 点击切换${mode.next.label}',
            waitDuration: const Duration(milliseconds: 450),
            excludeFromSemantics: true,
            child: SizedBox.fromSize(
              size: size,
              child: Material(
                color: backgroundColor,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkResponse(
                  onTap: advance,
                  containedInkWell: true,
                  highlightShape: BoxShape.circle,
                  radius: size.shortestSide / 2,
                  hoverColor: Colors.white.withValues(alpha: 0.055),
                  highlightColor: Colors.white.withValues(alpha: 0.09),
                  focusColor: AppTokens.accent.withValues(alpha: 0.16),
                  child: Center(
                    child: SizedBox.square(
                      dimension: iconSize,
                      child: AnimatedSwitcher(
                        duration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 160),
                        reverseDuration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 160),
                        switchInCurve: Curves.easeInOut,
                        switchOutCurve: Curves.easeInOut,
                        transitionBuilder: (child, animation) =>
                            FadeTransition(opacity: animation, child: child),
                        child: CustomPaint(
                          key: ValueKey(mode),
                          size: Size.square(iconSize),
                          painter: PlaybackModeIconPainter(
                            mode: mode,
                            color: foregroundColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
