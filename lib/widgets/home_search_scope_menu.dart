import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/home_search_request.dart';
export '../models/home_search_request.dart' show HomeSearchScope;

Future<HomeSearchScope?> showHomeSearchScopeMenu(
  BuildContext context, {
  required Rect anchor,
  required HomeSearchScope selected,
  required Set<String> signedInProviders,
  bool keyboardNavigation = false,
}) {
  final theme = Theme.of(context);
  return showGeneralDialog<HomeSearchScope>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭搜索范围',
    barrierColor: Colors.transparent,
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondaryAnimation) => Theme(
      data: theme,
      child: _HomeSearchScopeMenu(
        anchor: anchor,
        selected: HomeSearchScope.library,
        keyboardNavigation: keyboardNavigation,
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final eased = animation.drive(CurveTween(curve: Curves.easeOutCubic));
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, -0.012),
            end: Offset.zero,
          ).animate(eased),
          child: child,
        ),
      );
    },
  );
}

class _HomeSearchScopeMenu extends StatefulWidget {
  const _HomeSearchScopeMenu({
    required this.anchor,
    required this.selected,
    required this.keyboardNavigation,
  });

  final Rect anchor;
  final HomeSearchScope selected;
  final bool keyboardNavigation;

  @override
  State<_HomeSearchScopeMenu> createState() => _HomeSearchScopeMenuState();
}

class _HomeSearchScopeMenuState extends State<_HomeSearchScopeMenu> {
  static const _scopes = [HomeSearchScope.library];
  late final _nodes = {
    for (final scope in _scopes)
      scope: FocusNode(debugLabel: 'search scope ${scope.name}'),
  };
  late final _keys = {for (final scope in _scopes) scope: GlobalKey()};
  late HomeSearchScope _focused = _scopes.contains(widget.selected)
      ? widget.selected
      : _scopes.first;
  late bool _keyboardNavigation = widget.keyboardNavigation;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusScope(_focused, initial: true);
    });
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _close([HomeSearchScope? scope]) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(scope);
  }

  void _focusScope(
    HomeSearchScope scope, {
    bool forward = true,
    bool initial = false,
  }) {
    _nodes[scope]!.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[scope]!.currentContext;
      if (!mounted ||
          target == null ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      Scrollable.ensureVisible(
        target,
        duration: initial || MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        alignmentPolicy: forward
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  void _onFocus(HomeSearchScope scope) {
    if (mounted && _focused != scope) setState(() => _focused = scope);
  }

  KeyEventResult _handleKey(KeyEvent event, List<List<HomeSearchScope>> rows) {
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (keyboard.isAltPressed) {
      if (key != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
      if (event is KeyDownEvent) _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) _close();
      return KeyEventResult.handled;
    }
    if (_closing) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.tab) {
      if (!_keyboardNavigation) setState(() => _keyboardNavigation = true);
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) _close(_focused);
      return KeyEventResult.handled;
    }
    if (![
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.end,
    ].contains(key)) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (!_keyboardNavigation) setState(() => _keyboardNavigation = true);
    final row = rows.indexWhere((row) => row.contains(_focused));
    final column = rows[row].indexOf(_focused);
    HomeSearchScope next = _focused;
    if (key == LogicalKeyboardKey.home) {
      next = _scopes.first;
    } else if (key == LogicalKeyboardKey.end) {
      next = _scopes.last;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      // Up from the first visual row folds the picker back into the input.
      if (row == 0) {
        _close();
        return KeyEventResult.handled;
      }
      next = rows[row - 1][math.min(column, rows[row - 1].length - 1)];
    } else if (key == LogicalKeyboardKey.arrowDown) {
      if (row < rows.length - 1) {
        next = rows[row + 1][math.min(column, rows[row + 1].length - 1)];
      }
    } else if (rows.every((row) => row.length == 1)) {
      // On a narrow single-column menu, Left/Right act as previous/next.
      final index = _scopes.indexOf(_focused);
      final delta = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      next = _scopes[(index + delta).clamp(0, _scopes.length - 1)];
    } else if (key == LogicalKeyboardKey.arrowLeft && column > 0) {
      next = rows[row][column - 1];
    } else if (key == LogicalKeyboardKey.arrowRight &&
        column < rows[row].length - 1) {
      next = rows[row][column + 1];
    }
    _focusScope(
      next,
      forward:
          key != LogicalKeyboardKey.arrowUp &&
          key != LogicalKeyboardKey.arrowLeft &&
          key != LogicalKeyboardKey.home,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final width = math.min(420.0, constraints.maxWidth - 24);
      final left = widget.anchor.left.clamp(
        12.0,
        constraints.maxWidth - width - 12,
      );
      final availableBottom =
          constraints.maxHeight -
          math.max(media.viewInsets.bottom, media.padding.bottom) -
          12;
      final top = math.min(
        widget.anchor.bottom + 10,
        math.max(media.padding.top + 12, availableBottom - 120),
      );
      final height = math.max(0.0, availableBottom - top);
      final columns = width - 24 >= 360 && media.textScaler.scale(13) <= 17
          ? 2
          : 1;
      final rows = <List<HomeSearchScope>>[
        for (final group in [_scopes])
          for (var i = 0; i < group.length; i += columns)
            group.sublist(i, math.min(i + columns, group.length)),
      ];
      Widget group(List<HomeSearchScope> scopes) => _ScopeGroup(
        scopes: scopes,
        selected: widget.selected,
        columns: columns,
        nodes: _nodes,
        tileKeys: _keys,
        focused: _keyboardNavigation ? _focused : null,
        onFocus: _onFocus,
        onSelected: _close,
      );
      return FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Focus(
          onKeyEvent: (_, event) => _handleKey(event, rows),
          child: Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                width: width,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: height),
                  child: Material(
                    key: const ValueKey('home-search-scope-menu'),
                    color: const Color(0xFF242426),
                    elevation: 20,
                    shadowColor: Colors.black54,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                      side: const BorderSide(color: Color(0x24FFFFFF)),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Padding(
                            padding: EdgeInsets.fromLTRB(6, 4, 6, 12),
                            child: Text(
                              '搜索范围',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          group(_scopes),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ScopeGroup extends StatelessWidget {
  const _ScopeGroup({
    required this.scopes,
    required this.selected,
    required this.columns,
    required this.nodes,
    required this.tileKeys,
    required this.focused,
    required this.onFocus,
    required this.onSelected,
  });
  final List<HomeSearchScope> scopes;
  final HomeSearchScope selected;
  final int columns;
  final Map<HomeSearchScope, FocusNode> nodes;
  final Map<HomeSearchScope, GlobalKey> tileKeys;
  final HomeSearchScope? focused;
  final ValueChanged<HomeSearchScope> onFocus, onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = columns == 2
          ? (constraints.maxWidth - 8) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final scope in scopes)
            SizedBox(
              key: tileKeys[scope],
              width: width,
              child: Semantics(
                selected: scope == selected,
                child: Material(
                  animationDuration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 120),
                  color: scope == selected
                      ? const Color(0xFF233B55)
                      : scope == focused
                      ? const Color(0xFF2B3440)
                      : const Color(0xFF2D2D30),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: scope == focused
                          ? const Color(0xFF88BEFF)
                          : scope == selected
                          ? const Color(0xFF507CAB)
                          : Colors.transparent,
                      width: scope == focused ? 1.5 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    focusNode: nodes[scope],
                    focusColor: Colors.transparent,
                    onFocusChange: (hasFocus) {
                      if (hasFocus) onFocus(scope);
                    },
                    onTap: () => onSelected(scope),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              scope.icon,
                              size: 19,
                              color: scope == selected || scope == focused
                                  ? const Color(0xFF88BEFF)
                                  : Colors.white60,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                scope.label,
                                style: TextStyle(
                                  color: scope == selected || scope == focused
                                      ? const Color(0xFFD5E8FF)
                                      : Colors.white.withValues(alpha: .85),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.check_rounded,
                              size: 15,
                              color: scope == selected
                                  ? const Color(0xFF88BEFF)
                                  : Colors.transparent,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
