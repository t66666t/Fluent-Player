import 'package:flutter/widgets.dart';

import '../features/ai_chat/ai_chat_layout.dart';

/// Adapt the playback geometry without rebuilding the video, controls or
/// reading surface for every keyboard frame. These children are built by the
/// owning page only when its playback/panel state actually changes.
class PortraitPlaybackLayout extends StatefulWidget {
  const PortraitPlaybackLayout({
    super.key,
    required this.panel,
    this.video,
    this.controls,
    this.videoHeightFraction,
    this.keyboardVideoHeightFraction,
    this.overlays = const [],
  });

  final Widget? video;
  final Widget? controls;
  final Widget panel;
  final double? videoHeightFraction;
  final double? keyboardVideoHeightFraction;
  final List<Widget> overlays;

  @override
  State<PortraitPlaybackLayout> createState() => _PortraitPlaybackLayoutState();
}

class _PortraitPlaybackLayoutState extends State<PortraitPlaybackLayout> {
  Size? _screenSize;
  double? _unobstructedHeight;

  @override
  Widget build(BuildContext context) {
    // Subscribe here, so every portrait tool shares this behavior without
    // rebuilding the player page or its video for native IME frames.
    final keyboardVisible = AiPlaybackKeyboardBoundary.isKeyboardVisibleOf(
      context,
    );
    final screenSize = MediaQuery.sizeOf(context);
    if (_screenSize != screenSize) {
      _screenSize = screenSize;
      _unobstructedHeight = null;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!keyboardVisible) _unobstructedHeight = constraints.maxHeight;
        final fullHeight = _unobstructedHeight ?? screenSize.height;
        final keyboardProgress = keyboardVisible && fullHeight > 0
            ? ((1 - constraints.maxHeight / fullHeight) / .35).clamp(0.0, 1.0)
            : 0.0;
        // Keep a usable panel below tall portrait videos, including when the
        // keyboard is dismissed. Ordinary landscape videos retain their size.
        final normalVideoFraction = widget.videoHeightFraction ?? .58;
        final compactVideoFraction = normalVideoFraction.clamp(
          0.0,
          widget.keyboardVideoHeightFraction ?? .26,
        );
        final videoFraction =
            normalVideoFraction +
            (compactVideoFraction - normalVideoFraction) * keyboardProgress;
        final controlsScale = 1 - .22 * keyboardProgress;
        return Stack(
          children: [
            Column(
              children: [
                if (widget.video != null)
                  Container(
                    color: const Color(0xFF000000),
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * videoFraction,
                    ),
                    child: RepaintBoundary(child: widget.video!),
                  ),
                if (widget.controls != null)
                  ColoredBox(
                    color: const Color(0xFF1E1E1E),
                    child: Align(
                      heightFactor: controlsScale,
                      child: Transform.scale(
                        scale: controlsScale,
                        child: RepaintBoundary(child: widget.controls!),
                      ),
                    ),
                  ),
                Expanded(child: widget.panel),
              ],
            ),
            ...widget.overlays,
          ],
        );
      },
    );
  }
}
