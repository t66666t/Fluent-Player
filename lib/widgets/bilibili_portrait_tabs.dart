import 'package:flutter/services.dart';
import '../utils/page_shortcut_keys.dart';
import '../utils/keyboard_shortcut_hints.dart';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/theme/app_tokens.dart';

import 'panel_swipe_region.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Minimum height of the shared Bilibili/subtitle tab bar.
const double kBilibiliPortraitTabBarHeight = 32;

/// Shared reading tabs below the portrait video or in the resizable landscape
/// sidebar. Landscape supplies its label, keys and common collapse action.
///
/// Both stay built, so switching keeps the subtitle list's place and the
/// loaded details. Touch can slide between them; child controls keep their
/// gesture arena priority. [onSelect] null disables both taps and swipes.
/// [details] null (not a Bilibili video) shows only the subtitle list, with
/// no switch; the subtitle list stays the same element either way.
class BilibiliPortraitTabs extends StatefulWidget {
  const BilibiliPortraitTabs({
    super.key,
    required this.tab,
    required this.onSelect,
    required this.details,
    required this.subtitles,
    this.canStartSwipe,
    this.detailsLabel = '详情',
    this.keyPrefix = 'bilibili-portrait',
    this.onClose,
  });

  final PortraitBilibiliTab tab;
  final ValueChanged<PortraitBilibiliTab>? onSelect;
  final Widget? details;
  final Widget subtitles;
  final String detailsLabel;
  final String keyPrefix;
  final VoidCallback? onClose;

  /// Checked at pointer down, including selection changes that do not rebuild
  /// the player. Label taps remain available while a reading gesture is active.
  final bool Function()? canStartSwipe;

  @override
  State<BilibiliPortraitTabs> createState() => _BilibiliPortraitTabsState();
}

class _BilibiliPortraitTabsState extends State<BilibiliPortraitTabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _position = AnimationController(
    vsync: this,
    value: _selectedIndex.toDouble(),
  );
  bool _dragging = false;
  double _width = 0;
  double _dragOrigin = 0;
  double _dragDx = 0;
  int? _settlingTo;
  final _surfaceKey = GlobalKey();
  final Set<int> _touchPointers = {};
  bool _multipleTouches = false;

  int get _selectedIndex =>
      widget.details != null && widget.tab == PortraitBilibiliTab.details
      ? 0
      : 1;

  @override
  void didUpdateWidget(BilibiliPortraitTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tab != widget.tab ||
        (oldWidget.details == null) != (widget.details == null) ||
        oldWidget.onSelect != null && widget.onSelect == null) {
      _dragging = false;
      // A swipe already started its own settle before the parent rebuilt.
      // Label taps and keyboard navigation share the same sliding transition.
      if (!_position.isAnimating ||
          _settlingTo != _selectedIndex ||
          widget.details == null ||
          widget.onSelect == null) {
        if (widget.details == null ||
            oldWidget.details == null ||
            widget.onSelect == null) {
          _position.value = _selectedIndex.toDouble();
        } else {
          _settle(_selectedIndex);
        }
      }
    }
  }

  void _startSwipe() {
    _position.stop();
    _dragOrigin = _position.value;
    _dragDx = 0;
    setState(() => _dragging = true);
  }

  void _updateSwipe(double dx) {
    if (!_dragging || _width <= 0) return;
    _dragDx += dx;
    _position.value = (_dragOrigin - _dragDx / _width).clamp(0.0, 1.0);
  }

  void _endSwipe(double velocity) {
    if (!_dragging) return;
    final origin = _selectedIndex;
    var target = origin;
    final opposingFlick = _dragDx * velocity < 0 && velocity.abs() >= 950;
    final committed =
        !opposingFlick &&
        (_dragDx.abs() >= _width * .36 ||
            _dragDx.abs() > 24 && velocity.abs() >= 950);
    if (committed) target = (origin + (_dragDx < 0 ? 1 : -1)).clamp(0, 1);
    setState(() => _dragging = false);
    _settle(target);
    if (target != origin) {
      widget.onSelect?.call(
        target == 0
            ? PortraitBilibiliTab.details
            : PortraitBilibiliTab.subtitles,
      );
    }
  }

  void _cancelSwipe() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    _settle(_selectedIndex);
  }

  void _pointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touchPointers.add(event.pointer);
    if (_touchPointers.length > 1) {
      _multipleTouches = true;
      _cancelSwipe();
    }
  }

  void _pointerEnd(PointerEvent event) {
    _touchPointers.remove(event.pointer);
    if (_touchPointers.isEmpty) _multipleTouches = false;
  }

  bool _readingAllowsSwipe() {
    // SelectableText owns its EditableText selection independently of an
    // enclosing SelectionArea (Bilibili titles and descriptions use it).
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editable = focusContext?.widget is EditableText
        ? focusContext!.widget as EditableText
        : focusContext?.findAncestorWidgetOfExactType<EditableText>();
    if (editable != null &&
        (!editable.readOnly ||
            editable.controller.selection.isValid &&
                !editable.controller.selection.isCollapsed)) {
      return false;
    }
    return widget.canStartSwipe?.call() ?? true;
  }

  void _settle(int index) {
    _settlingTo = index;
    if (MediaQuery.disableAnimationsOf(context)) {
      _position.value = index.toDouble();
    } else {
      _position.animateTo(
        index.toDouble(),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _page(int index, Widget child) {
    final selected = index == _selectedIndex;
    return Offstage(
      offstage: (_position.value - index).abs() >= 1,
      child: FractionalTranslation(
        translation: Offset(index - _position.value, 0),
        child: IgnorePointer(
          ignoring: !selected || _dragging,
          child: ExcludeFocus(
            excluding: !selected,
            child: ExcludeSemantics(
              excluding: !selected,
              child: TickerMode(
                enabled: selected,
                child: RepaintBoundary(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final edges = MediaQuery.systemGestureInsetsOf(context);
    return ColoredBox(
      key: _surfaceKey,
      color: AppTokens.bgPlayerSidebar,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _pointerDown,
        onPointerUp: _pointerEnd,
        onPointerCancel: _pointerEnd,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (_width != constraints.maxWidth && _dragging) {
              _dragging = false;
              _position.value = _selectedIndex.toDouble();
            }
            _width = constraints.maxWidth;
            return PanelSwipeScope(
              enabled: widget.details != null && widget.onSelect != null,
              canStart: (position) {
                final box =
                    _surfaceKey.currentContext!.findRenderObject()!
                        as RenderBox;
                final x = box.globalToLocal(position).dx;
                return !_multipleTouches &&
                    _touchPointers.isEmpty &&
                    x >= math.max(32, edges.left) &&
                    x <= _width - math.max(32, edges.right) &&
                    _readingAllowsSwipe();
              },
              canContinue: () => !_multipleTouches && _readingAllowsSwipe(),
              onStart: _startSwipe,
              onUpdate: _updateSwipe,
              onEnd: _endSwipe,
              onCancel: _cancelSwipe,
              child: PanelSwipeRegion(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.details != null)
                      BilibiliPortraitTabBar(
                        tab: widget.tab,
                        onSelect: widget.onSelect,
                        detailsLabel: widget.detailsLabel,
                        keyPrefix: widget.keyPrefix,
                        onClose: widget.onClose,
                      ),
                    Expanded(
                      child: ClipRect(
                        child: AnimatedBuilder(
                          animation: _position,
                          builder: (context, _) => Stack(
                            fit: StackFit.expand,
                            children: [
                              _page(
                                0,
                                widget.details ?? const SizedBox.shrink(),
                              ),
                              _page(1, widget.subtitles),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _dragging = false;
    _position.dispose();
    super.dispose();
  }
}

/// The 「详情 | 字幕」 switch itself.
class BilibiliPortraitTabBar extends StatelessWidget {
  const BilibiliPortraitTabBar({
    super.key,
    required this.tab,
    required this.onSelect,
    this.detailsLabel = '详情',
    this.keyPrefix = 'bilibili-portrait',
    this.onClose,
  });

  final PortraitBilibiliTab tab;
  final ValueChanged<PortraitBilibiliTab>? onSelect;
  final String detailsLabel;
  final String keyPrefix;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    const fontSize = 14.0;
    const lineHeight = 1.3;
    final height = math.max(
      kBilibiliPortraitTabBarHeight,
      MediaQuery.textScalerOf(context).scale(fontSize) * lineHeight + 8,
    );
    Widget item(PortraitBilibiliTab value, String label) {
      final selected = value == tab;
      final select = onSelect;
      return Expanded(
        child: Tooltip(
          message: shortcutHintLabel(
            context,
            '切换到$label',
            'Alt+${value == PortraitBilibiliTab.details ? '←' : '→'}',
          ),
          waitDuration: const Duration(milliseconds: 350),
          child: Semantics(
            selected: selected,
            button: true,
            child: InkWell(
              key: ValueKey('$keyPrefix-tab-${value.name}'),
              onTap: select == null || selected ? null : () => select(value),
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? AppTokens.brandBilibili : AppTokens.text2,
                    fontSize: fontSize,
                    height: lineHeight,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      key: ValueKey('$keyPrefix-tab-bar'),
      height: height,
      child: Row(
        children: [
          item(PortraitBilibiliTab.details, detailsLabel),
          item(PortraitBilibiliTab.subtitles, '字幕'),
          if (onClose != null)
            DesktopButtonClickRegion(
              child: IconButton(
                key: ValueKey('$keyPrefix-close'),
                tooltip: hoverAwareShortcutTooltip(
                  '收起边栏',
                  LogicalKeyboardKey.keyB,
                  context: context,
                ),
                onPressed: onClose,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tightFor(
                  width: height,
                  height: height,
                ),
                visualDensity: VisualDensity.standard,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.close, size: 18, color: AppTokens.text2),
              ),
            ),
        ],
      ),
    );
  }
}
