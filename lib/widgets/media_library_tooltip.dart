import 'package:flutter/material.dart';

/// Marks the library frame whose hints must clear its shared mini player.
class MediaLibraryTooltipScope extends InheritedWidget {
  const MediaLibraryTooltipScope({
    super.key,
    required this.isCurrent,
    required super.child,
  });

  final bool isCurrent;

  @override
  bool updateShouldNotify(MediaLibraryTooltipScope oldWidget) =>
      isCurrent != oldWidget.isCurrent;
}

/// Keeps library hints above the shared mini player, but below covering routes.
///
/// The library navigator paints below the mini player. Its ordinary tooltips
/// therefore disappear behind the player even when their buttons clear it.
/// Keep Material's pointer/touch handling and move only the hint to the app
/// overlay. Outside the library this behaves like an ordinary [Tooltip].
class MediaLibraryTooltip extends Tooltip {
  const MediaLibraryTooltip({
    super.key,
    required super.message,
    required super.child,
    super.waitDuration,
    super.excludeFromSemantics,
    super.preferBelow,
  });

  @override
  TooltipState createState() => _MediaLibraryTooltipState();
}

class _MediaLibraryTooltipState extends TooltipState {
  final _trigger = GlobalKey<RawTooltipState>();
  bool _isCurrent = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = context
        .dependOnInheritedWidgetOfExactType<MediaLibraryTooltipScope>();
    final current =
        scope == null ||
        (scope.isCurrent && (ModalRoute.isCurrentOf(context) ?? true));
    if (_isCurrent && !current) Tooltip.dismissAllToolTips();
    _isCurrent = current;
  }

  @override
  bool ensureTooltipVisible() =>
      _trigger.currentState?.ensureTooltipVisible() ??
      super.ensureTooltipVisible();

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<MediaLibraryTooltipScope>();
    if (scope == null ||
        !TooltipVisibility.of(context) ||
        widget.message!.isEmpty) {
      return super.build(context);
    }

    final theme = TooltipTheme.of(context);
    final exclude =
        widget.excludeFromSemantics ?? theme.excludeFromSemantics ?? false;
    final material = Theme.of(context);
    final desktop = switch (material.platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    final dark = material.brightness == Brightness.dark;
    final style =
        theme.textStyle ??
        material.textTheme.bodyMedium!.copyWith(
          color: dark ? Colors.black : Colors.white,
          fontSize: desktop ? 12 : 14,
        );
    final hint = ConstrainedBox(
      constraints:
          theme.constraints ?? BoxConstraints(minHeight: desktop ? 24 : 32),
      child: Container(
        decoration:
            theme.decoration ??
            BoxDecoration(
              color: dark
                  ? Colors.white.withValues(alpha: 0.9)
                  : Colors.grey[700],
              borderRadius: BorderRadius.circular(4),
            ),
        padding:
            theme.padding ??
            EdgeInsets.symmetric(horizontal: desktop ? 8 : 16, vertical: 4),
        margin: theme.margin ?? EdgeInsets.zero,
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Text(
            widget.message!,
            style: style,
            textAlign: theme.textAlign ?? TextAlign.start,
          ),
        ),
      ),
    );
    return RawTooltip(
      key: _trigger,
      semanticsTooltip: exclude ? null : widget.message,
      hoverDelay: widget.waitDuration ?? theme.waitDuration ?? Duration.zero,
      touchDelay: theme.showDuration ?? const Duration(milliseconds: 1500),
      dismissDelay: theme.exitDuration ?? const Duration(milliseconds: 100),
      triggerMode: theme.triggerMode ?? TooltipTriggerMode.longPress,
      enableFeedback: theme.enableFeedback ?? true,
      ignorePointer: true,
      // The local tooltip is only a zero-sized anchor at the button's center.
      // Its portal supplies a current layout transform to the app overlay.
      positionDelegate: (position) => position.target,
      // Hide only the hint when a route covers the page. Replacing RawTooltip
      // would dispose the button beneath it while its popup is awaiting input.
      tooltipBuilder: (context, animation) => _isCurrent
          ? _LibraryHintOverlay(
              verticalOffset: theme.verticalOffset ?? 24,
              preferBelow: widget.preferBelow ?? theme.preferBelow ?? true,
              child: FadeTransition(opacity: animation, child: hint),
            )
          : const SizedBox.shrink(),
      child: widget.child!,
    );
  }
}

class _LibraryHintOverlay extends StatefulWidget {
  const _LibraryHintOverlay({
    required this.verticalOffset,
    required this.preferBelow,
    required this.child,
  });

  final double verticalOffset;
  final bool preferBelow;
  final Widget child;

  @override
  State<_LibraryHintOverlay> createState() => _LibraryHintOverlayState();
}

class _LibraryHintOverlayState extends State<_LibraryHintOverlay> {
  final _portal = OverlayPortalController()..show();

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _portal,
    overlayLocation: OverlayChildLocation.rootOverlay,
    overlayChildBuilder: (context, layout) {
      return Positioned.fill(
        child: IgnorePointer(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: CustomSingleChildLayout(
              delegate: _LibraryHintPosition(
                target: MatrixUtils.transformPoint(
                  layout.childPaintTransform,
                  Offset.zero,
                ),
                verticalOffset: widget.verticalOffset,
                preferBelow: widget.preferBelow,
              ),
              child: widget.child,
            ),
          ),
        ),
      );
    },
    child: const SizedBox.shrink(),
  );
}

class _LibraryHintPosition extends SingleChildLayoutDelegate {
  _LibraryHintPosition({
    required this.target,
    required this.verticalOffset,
    required this.preferBelow,
  });

  final Offset target;
  final double verticalOffset;
  final bool preferBelow;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return positionDependentBox(
      size: size,
      childSize: childSize,
      target: target,
      verticalOffset: verticalOffset,
      preferBelow: preferBelow,
    );
  }

  @override
  bool shouldRelayout(_LibraryHintPosition oldDelegate) =>
      target != oldDelegate.target ||
      verticalOffset != oldDelegate.verticalOffset ||
      preferBelow != oldDelegate.preferBelow;
}
