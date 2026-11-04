import 'package:flutter/material.dart';
import 'desktop_button_click_region.dart';

/// A small rounded tab attached to the sidebar edge, over the video.
/// The larger transparent tap target ends where the resize target begins.
class PlayerSubtitleSidebarToggle extends StatefulWidget {
  const PlayerSubtitleSidebarToggle({
    super.key,
    required this.expanded,
    required this.onPressed,
    this.onLeft = false,
    this.visible = true,
    this.outerInset = 0,
    this.sidebarLabel = '字幕边栏',
  });

  static double widthFor(Size viewport, {bool touch = false}) =>
      touch || viewport.height < 600 || viewport.width < 720 ? 48 : 32;

  final bool expanded;
  final VoidCallback? onPressed;
  final bool onLeft;
  final bool visible;
  final double outerInset;
  final String sidebarLabel;

  @override
  State<PlayerSubtitleSidebarToggle> createState() =>
      _PlayerSubtitleSidebarToggleState();
}

class _PlayerSubtitleSidebarToggleState
    extends State<PlayerSubtitleSidebarToggle> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final width = PlayerSubtitleSidebarToggle.widthFor(
      MediaQuery.sizeOf(context),
      touch:
          platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS ||
          platform == TargetPlatform.fuchsia,
    );
    final touch = width == 48;
    final disabledAnimations = MediaQuery.disableAnimationsOf(context);
    final duration = disabledAnimations
        ? Duration.zero
        : const Duration(milliseconds: 120);
    final label = '${widget.expanded ? '收起' : '展开'}${widget.sidebarLabel}';
    final active = _hovered || _focused;
    final enabled = widget.visible && widget.onPressed != null;
    final direction = widget.expanded ? 1.0 : -1.0;

    final button = SizedBox(
      width: width,
      height: touch ? 48 : 40,
      child: Semantics(
        key: const ValueKey('player-subtitle-sidebar-toggle'),
        button: true,
        enabled: enabled,
        expanded: widget.expanded,
        label: label,
        onTap: enabled ? widget.onPressed : null,
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          waitDuration: const Duration(milliseconds: 650),
          child: Material(
            type: MaterialType.transparency,
            child: DesktopButtonClickRegion(
              enabled: enabled,
              child: InkWell(
                onTap: enabled ? widget.onPressed : null,
                excludeFromSemantics: true,
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                splashFactory: NoSplash.splashFactory,
                mouseCursor: enabled
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                onHover: (value) => setState(() => _hovered = value),
                onFocusChange: (value) => setState(() => _focused = value),
                onHighlightChanged: (value) => setState(() => _pressed = value),
                child: Align(
                  alignment: widget.onLeft
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: direction, end: direction),
                    duration: disabledAnimations
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    builder: (context, fold, child) =>
                        TweenAnimationBuilder<double>(
                          tween: Tween(
                            end: _pressed ? 1.0 : (active ? 0.35 : 0.0),
                          ),
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          builder: (context, emphasis, child) => CustomPaint(
                            key: const ValueKey('player-subtitle-sidebar-fold'),
                            size: touch
                                ? const Size(16, 40)
                                : const Size(10, 28),
                            painter: _AttachedTabPainter(
                              direction: fold,
                              onLeft: widget.onLeft,
                              emphasis: emphasis,
                              focused: _focused,
                            ),
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

    return AnimatedPadding(
      duration: disabledAnimations
          ? Duration.zero
          : const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(
        left: widget.onLeft ? widget.outerInset : 0,
        right: widget.onLeft ? 0 : widget.outerInset,
      ),
      child: SizedBox(
        width: width,
        child: ExcludeSemantics(
          excluding: !widget.visible,
          child: ExcludeFocus(
            excluding: !enabled,
            child: IgnorePointer(
              ignoring: !enabled,
              child: AnimatedOpacity(
                opacity: widget.visible ? 1 : 0,
                duration: duration,
                curve: Curves.easeOutCubic,
                child: Center(child: button),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Path _tabPath(Size size) {
  double x(double value) => size.width * value / 10;
  double y(double value) => size.height * value / 28;
  return Path()
    ..moveTo(x(10), 0)
    ..lineTo(x(3), 0)
    ..quadraticBezierTo(x(0), 0, x(0), y(3))
    ..lineTo(x(0), y(25))
    ..quadraticBezierTo(x(0), size.height, x(3), size.height)
    ..lineTo(x(10), size.height)
    ..close();
}

class _AttachedTabPainter extends CustomPainter {
  const _AttachedTabPainter({
    required this.direction,
    required this.onLeft,
    required this.emphasis,
    required this.focused,
  });

  final double direction;
  final bool onLeft;
  final double emphasis;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (onLeft) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.scale(size.width / 10, size.height / 28);
    // Flat against the divider; only the two video-side corners are rounded.
    final tab = _tabPath(const Size(10, 28));
    canvas.drawPath(
      tab,
      Paint()
        ..color = Color.lerp(
          const Color(0xcc1e1e1e),
          const Color(0xe0383838),
          emphasis,
        )!,
    );
    canvas.drawPath(
      tab,
      Paint()
        ..color = focused
            ? const Color(0xff9edbff)
            : Color.lerp(
                const Color(0x1affffff),
                const Color(0x30ffffff),
                emphasis,
              )!
        ..style = PaintingStyle.stroke
        ..strokeWidth = focused ? 1.2 : 0.55,
    );
    final arrow = Path()
      ..moveTo(5.5 - direction * 1.5, 11)
      ..lineTo(5.5 + direction * 1.5, 14)
      ..lineTo(5.5 - direction * 1.5, 17);
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Color.lerp(
          const Color(0xa6ffffff),
          const Color(0xd9ffffff),
          emphasis,
        )!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AttachedTabPainter oldDelegate) =>
      oldDelegate.direction != direction ||
      oldDelegate.onLeft != onLeft ||
      oldDelegate.emphasis != emphasis ||
      oldDelegate.focused != focused;
}
