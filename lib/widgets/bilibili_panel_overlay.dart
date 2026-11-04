import 'package:flutter/material.dart';

import 'sidebar_surface_transition.dart';
import 'player_sidebar_motion.dart';
import 'visibility_input_gate.dart';

/// The landscape Bilibili panel on a phone: it slides in over the video from
/// the side the page keeps its panels on (the right, the left in left-handed
/// mode), with a dimmed video behind it; a tap on the video closes it.
class BilibiliPanelOverlay extends StatefulWidget {
  const BilibiliPanelOverlay({
    super.key,
    required this.panel,
    required this.fromLeft,
    required this.width,
    required this.onDismiss,
    this.padding = EdgeInsets.zero,
    this.motion,
  });

  /// The panel, or null while it is closed.
  final Widget? panel;
  final bool fromLeft;
  final double width;
  final VoidCallback onDismiss;

  /// Kept free inside the panel (notch, gesture areas).
  final EdgeInsets padding;
  final PlayerSidebarMotion? motion;

  static const Duration duration = PlayerSidebarMotion.openDuration;

  @override
  State<BilibiliPanelOverlay> createState() => _BilibiliPanelOverlayState();
}

class _BilibiliPanelOverlayState extends State<BilibiliPanelOverlay>
    with SingleTickerProviderStateMixin {
  PlayerSidebarMotion? _localMotion;
  PlayerSidebarMotion get _motion =>
      widget.motion ?? (_localMotion ??= PlayerSidebarMotion(vsync: this));
  late Widget? _lastPanel = widget.panel;
  final PageStorageBucket _scrollPositions = PageStorageBucket();

  @override
  void dispose() {
    _localMotion?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(BilibiliPanelOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.panel != null) _lastPanel = widget.panel;
  }

  void _releaseHidden() {
    if (widget.panel == null && _lastPanel != null) {
      setState(() => _lastPanel = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.panel != null;
    if (widget.motion == null) {
      _motion.configure(
        target: open ? PlayerSidebarMotion.overlaySurface : null,
        dockExtent: 0,
        visibleSurfaces: {if (open) PlayerSidebarMotion.overlaySurface},
        immediate:
            MediaQuery.disableAnimationsOf(context) ||
            !TickerMode.valuesOf(context).enabled,
      );
    }
    final opacity = _motion.opacityFor(PlayerSidebarMotion.overlaySurface);
    return Stack(
      children: [
        Positioned.fill(
          child: FadeInputGate(
            enabled: open,
            opacity: opacity,
            child: GestureDetector(
              key: const ValueKey('bilibili-panel-overlay-scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.onDismiss,
              child: FadeTransition(
                opacity: opacity,
                child: const ColoredBox(color: Color(0x66000000)),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          left: widget.fromLeft ? 0 : null,
          right: widget.fromLeft ? null : 0,
          width: widget.width,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(widget.fromLeft ? -1 : 1, 0),
              end: Offset.zero,
            ).animate(opacity),
            child: SidebarSurfaceTransition(
              opacity: opacity,
              visible: open,
              onHidden: _releaseHidden,
              child: PageStorage(
                bucket: _scrollPositions,
                child: KeyedSubtree(
                  key: const PageStorageKey('bilibili-overlay-scroll'),
                  child: PrimaryScrollController.none(
                    child: Material(
                      key: const ValueKey('bilibili-panel-overlay'),
                      elevation: 8,
                      color: Colors.transparent,
                      child: Padding(
                        padding: widget.padding,
                        child: _lastPanel ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
