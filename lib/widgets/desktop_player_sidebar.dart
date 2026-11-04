import 'package:flutter/material.dart';

import 'sidebar_surface_transition.dart';
import 'player_sidebar_motion.dart';

/// A shared sidebar slot beside a live player on phones, tablets and desktops.
/// Width includes the splitter,
/// and each panel is laid out at its final width while the slot animates.
/// Retaining the subtitle panel avoids rebuilding its document on every visit.
/// One element per panel key also makes interrupted A -> B -> A transitions safe.
class DesktopPlayerSidebar extends StatefulWidget {
  const DesktopPlayerSidebar({
    super.key,
    required this.panelId,
    required this.panel,
    required this.width,
    required this.retainedId,
    required this.retainedPanel,
    required this.retainedWidth,
    required this.viewportSize,
    this.divider,
    this.dividerWidth = 0,
    this.onLeft = false,
    this.resizing = false,
    this.dividerLink,
    this.backgroundColor = Colors.black,
    this.returnPanelIds = const <Object>{},
    this.motion,
    this.navigationId,
  });

  final Object? panelId;
  final Widget? panel;
  final double width;
  final Object retainedId;
  final Widget retainedPanel;
  final double retainedWidth;
  final Size viewportSize;
  final Widget? divider;
  final double dividerWidth;
  final bool onLeft;
  final bool resizing;
  final LayerLink? dividerLink;

  /// Paint continuously behind the divider and the content. Separate surfaces
  /// can leave a partially covered pixel at fractional widths or display scales.
  final Color backgroundColor;

  /// Tools on the return path keep their drafts and scroll positions alive.
  final Set<Object> returnPanelIds;
  final PlayerSidebarMotion? motion;
  final Object? navigationId;

  @override
  State<DesktopPlayerSidebar> createState() => _DesktopPlayerSidebarState();
}

class _Panel {
  _Panel(
    this.child,
    this.width,
    this.divider,
    this.dividerWidth, {
    required this.animateInitial,
  });
  Widget child;
  double width;
  Widget? divider;
  double dividerWidth;
  final bool animateInitial;
  bool hidden = false;
}

class _DesktopPlayerSidebarState extends State<DesktopPlayerSidebar>
    with SingleTickerProviderStateMixin {
  PlayerSidebarMotion? _localMotion;
  PlayerSidebarMotion get _motion =>
      widget.motion ?? (_localMotion ??= PlayerSidebarMotion(vsync: this));
  final Map<Object, _Panel> _panels = {};
  final PageStorageBucket _scrollPositions = PageStorageBucket();
  bool _viewportChanged = false;

  void _updatePanels({bool initial = false}) {
    final id = widget.panelId;
    _panels.removeWhere(
      (key, panel) =>
          panel.hidden &&
          key != id &&
          key != widget.retainedId &&
          !widget.returnPanelIds.contains(key),
    );
    if (id != null) {
      final previous = _panels[id];
      _panels[id] = _Panel(
        id == widget.retainedId ? widget.retainedPanel : widget.panel!,
        widget.width,
        widget.divider,
        widget.dividerWidth,
        animateInitial: previous?.animateInitial ?? !initial,
      );
    }
    final retained = _panels[widget.retainedId];
    if (retained != null) {
      // Even while hidden, deliver new media/subtitles and visibility changes.
      retained.child = widget.retainedPanel;
      // Preserve its last width through the outgoing fade. In particular,
      // leaving chat must not rewrap it at the subtitle list's width.
      if (_viewportChanged && id != widget.retainedId) {
        retained.width = widget.retainedWidth;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _updatePanels(initial: true);
  }

  @override
  void didUpdateWidget(DesktopPlayerSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _viewportChanged = oldWidget.viewportSize != widget.viewportSize;
    _updatePanels();
  }

  void _removeHidden(Object id) {
    if (!mounted || id == widget.panelId) return;
    final panel = _panels[id];
    if (panel == null) return;
    panel.hidden = true;
    if (id != widget.retainedId && !widget.returnPanelIds.contains(id)) {
      setState(() => _panels.remove(id));
    }
  }

  @override
  void dispose() {
    _localMotion?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final immediate =
        disableAnimations ||
        widget.resizing ||
        _viewportChanged ||
        !TickerMode.valuesOf(context).enabled;
    final extent = widget.panelId == null
        ? 0.0
        : widget.width + widget.dividerWidth;
    if (widget.motion == null) {
      _motion.configure(
        target: widget.navigationId ?? widget.panelId,
        dockExtent: extent,
        visibleSurfaces: {if (widget.panelId != null) widget.panelId!},
        immediate: immediate,
      );
    }
    return AnimatedBuilder(
      animation: _motion.extent,
      builder: (context, child) =>
          SizedBox(width: _motion.extent.value, child: child),
      child: PageStorage(
        bucket: _scrollPositions,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: ColoredBox(
                color: widget.backgroundColor,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final entry in _panels.entries)
                      Positioned.fill(
                        key: ValueKey(entry.key),
                        child: OverflowBox(
                          alignment: widget.onLeft
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          minWidth:
                              entry.value.width + entry.value.dividerWidth,
                          maxWidth:
                              entry.value.width + entry.value.dividerWidth,
                          child: SidebarSurfaceTransition(
                            opacity: _motion.opacityFor(entry.key),
                            visible: entry.key == widget.panelId,
                            animateInitial: entry.value.animateInitial,
                            onHidden: () => _removeHidden(entry.key),
                            child: PrimaryScrollController.none(
                              child: KeyedSubtree(
                                // Tools can release their widgets after the fade while
                                // keeping each scrollable's position across many visits.
                                key: PageStorageKey<Object>(entry.key),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (!widget.onLeft &&
                                        entry.value.divider != null)
                                      SizedBox(
                                        key: const ValueKey('panel-divider'),
                                        width: entry.value.dividerWidth,
                                        child: entry.value.divider,
                                      ),
                                    SizedBox(
                                      key: const ValueKey('panel-content'),
                                      width: entry.value.width,
                                      child: entry.value.child,
                                    ),
                                    if (widget.onLeft &&
                                        entry.value.divider != null)
                                      SizedBox(
                                        key: const ValueKey('panel-divider'),
                                        width: entry.value.dividerWidth,
                                        child: entry.value.divider,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (widget.dividerLink != null && widget.dividerWidth > 0)
              Positioned(
                top: 0,
                bottom: 0,
                left: widget.onLeft ? null : 0,
                right: widget.onLeft ? 0 : null,
                width: widget.dividerWidth,
                child: CompositedTransformTarget(
                  link: widget.dividerLink!,
                  child: const SizedBox.expand(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
