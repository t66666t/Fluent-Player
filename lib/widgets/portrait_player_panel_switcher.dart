import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'visibility_input_gate.dart';

/// Keep the reading surface mounted at its final bounds while tools change.
/// One element per panel also makes interrupted A -> B -> A transitions safe.
/// An active tool is opaque from its first frame; only outgoing tools fade.
class PortraitPlayerPanelSwitcher extends StatefulWidget {
  const PortraitPlayerPanelSwitcher({
    super.key,
    required this.readingPanel,
    required this.panelId,
    required this.panel,
    this.readingReady,
    this.returnPanelIds = const <Object>{},
  }) : assert(panelId == null || panel != null);

  final Widget readingPanel;
  final Object? panelId;
  final Widget? panel;
  final ValueListenable<bool>? readingReady;
  final Set<Object> returnPanelIds;

  @override
  State<PortraitPlayerPanelSwitcher> createState() =>
      _PortraitPlayerPanelSwitcherState();
}

class _PanelEntry {
  _PanelEntry(this.child);

  Widget child;
  bool presented = false;
  bool hidden = false;
}

class _PortraitPlayerPanelSwitcherState
    extends State<PortraitPlayerPanelSwitcher> {
  final _panels = <Object, _PanelEntry>{};
  Size? _readingSize;
  MediaQueryData? _readingEnvironment;
  Object? _returnCoverId;
  bool _readingIsReady = true;

  @override
  void initState() {
    super.initState();
    _attachReadiness();
    _updatePanel();
  }

  @override
  void didUpdateWidget(PortraitPlayerPanelSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readingReady != widget.readingReady) {
      oldWidget.readingReady?.removeListener(_handleReadiness);
      _attachReadiness();
    }
    if (oldWidget.panelId != widget.panelId) {
      _returnCoverId = widget.panelId == null && oldWidget.panelId != null
          ? oldWidget.panelId
          : null;
    }
    _updatePanel();
  }

  void _attachReadiness() {
    _readingIsReady = widget.readingReady?.value ?? true;
    widget.readingReady?.addListener(_handleReadiness);
  }

  void _handleReadiness() {
    if (!mounted) return;
    setState(() => _readingIsReady = widget.readingReady?.value ?? true);
  }

  bool _holdsReturnCover(Object id) =>
      widget.panelId == null && id == _returnCoverId && !_readingIsReady;

  void _updatePanel() {
    final id = widget.panelId;
    // A surface removed before its first build has no outgoing animation/onEnd.
    _panels.removeWhere(
      (key, entry) =>
          key != id &&
          !widget.returnPanelIds.contains(key) &&
          (!entry.presented || entry.hidden),
    );
    if (id == null) return;
    final existing = _panels[id];
    if (existing != null) {
      existing.child = widget.panel!;
      existing.hidden = false;
      return;
    }
    _panels[id] = _PanelEntry(widget.panel!);
  }

  void _finishPanel(Object id) {
    if (!mounted) return;
    if (_holdsReturnCover(id)) return;
    if (id != widget.panelId) {
      setState(() {
        if (widget.returnPanelIds.contains(id)) {
          _panels[id]?.hidden = true;
        } else {
          _panels.remove(id);
        }
        if (_returnCoverId == id) _returnCoverId = null;
      });
    }
  }

  Widget _surface(
    Widget child, {
    required bool active,
    bool interactive = true,
  }) => VisibilityInputGate(
    enabled: active && interactive,
    child: TickerMode(enabled: active, child: child),
  );

  Widget _panel(Object id, _PanelEntry entry, bool reducedMotion) {
    final active = id == widget.panelId;
    final visible = _holdsReturnCover(id) || active;
    entry.presented |= visible;
    return Positioned.fill(
      key: ValueKey(id),
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        // Input switches synchronously with panelId. Deferring opacity=1 to
        // another frame let an invisible manager intercept the reading UI.
        // Reopened retained tools must also become opaque immediately.
        duration: active || reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        onEnd: () => _finishPanel(id),
        child: _surface(
          ColoredBox(color: const Color(0xFF1E1E1E), child: entry.child),
          active: active,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    if (reducedMotion) {
      _panels.removeWhere(
        (id, _) =>
            id != widget.panelId &&
            !_holdsReturnCover(id) &&
            !widget.returnPanelIds.contains(id),
      );
    }
    final readingActive = widget.panelId == null;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (readingActive || _readingSize == null) {
          _readingSize = constraints.biggest;
          _readingEnvironment = MediaQuery.of(context);
        }
        // A retained, hidden document must not adopt a tool's keyboard geometry
        // or temporary text scaling. Keep its last reading layout until return.
        final readingSize = _readingSize!;
        final activeEntry = _panels[widget.panelId];
        return ClipRect(
          child: ColoredBox(
            color: const Color(0xFF1E1E1E),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Offstage(
                  key: const ValueKey('portrait-reading-surface'),
                  offstage: !readingActive,
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minWidth: readingSize.width,
                    maxWidth: readingSize.width,
                    minHeight: readingSize.height,
                    maxHeight: readingSize.height,
                    child: SizedBox.fromSize(
                      size: readingSize,
                      child: MediaQuery(
                        data: _readingEnvironment!,
                        child: _surface(
                          widget.readingPanel,
                          active: readingActive,
                          interactive: _readingIsReady,
                        ),
                      ),
                    ),
                  ),
                ),
                for (final entry in _panels.entries)
                  if (entry.key != widget.panelId)
                    _panel(entry.key, entry.value, reducedMotion),
                // A retained tool can precede the outgoing tool in map order.
                // Paint the input owner last so an old fade cannot cover it.
                if (activeEntry != null)
                  _panel(widget.panelId!, activeEntry, reducedMotion),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    widget.readingReady?.removeListener(_handleReadiness);
    super.dispose();
  }
}
