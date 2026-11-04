import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/media_playback_service.dart';
import '../utils/stable_system_ui_insets.dart';
import 'media_library_shell.dart';
import 'playback_card_layout.dart';

/// Safe area for pages beneath the shell's mini player, including fixed footers.
/// Root routes that cover the shell reserve only the system navigation area.
class MediaLibrarySafeArea extends StatefulWidget {
  const MediaLibrarySafeArea({
    super.key,
    required this.child,
    this.top = false,
  });

  final Widget child;
  final bool top;

  @override
  State<MediaLibrarySafeArea> createState() => _MediaLibrarySafeAreaState();
}

class _MediaLibrarySafeAreaState extends State<MediaLibrarySafeArea> {
  late final _insets = StableSystemUiInsetController(
    includeSystemGestureInsets: true,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void dispose() {
    _insets.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stableBottomInset =
        MediaLibraryShell.stableBottomInsetOf(context) ??
        _insets
            .observe(
              MediaQueryData.fromView(View.of(context)),
              active: ModalRoute.isCurrentOf(context) ?? true,
            )
            .bottom;
    final inShell = MediaLibraryShell.maybeOf(context) != null;
    final isCardVisible =
        inShell &&
        context.select<MediaPlaybackService, bool>(
          (playback) => playback.shouldShowMiniPlaybackCard,
        );
    final obstruction = PlaybackCardOverlayLayout.contentBottomPadding(
      stableBottomInset: stableBottomInset,
      selectionBarHeight: inShell
          ? MediaLibraryShell.selectionBarObstructionOf(context)
          : 0,
      cardHeight: PlaybackCardLayout.calculate(context).height,
      isCardVisible: isCardVisible,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // Scaffold removes consumed viewInsets from the body's MediaQuery.
        // Read the window's keyboard inset during layout instead, so resizing
        // the body never adds the mini-player reservation a second time.
        final keyboard = MediaQueryData.fromView(
          View.of(context),
        ).viewInsets.bottom;
        final bottom = math.max(0.0, obstruction - keyboard);
        return SafeArea(
          top: widget.top,
          minimum: EdgeInsets.only(bottom: bottom),
          child: widget.child,
        );
      },
    );
  }
}
