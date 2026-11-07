import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_interaction_theme.dart';
import '../utils/keyboard_focus_visibility.dart';

import '../utils/media_library_range_selection.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import 'card_context_menu.dart';

/// Opt-in directional navigation for browsing pages with several regions.
/// Text editing, sliders and routes outside this subtree retain their own keys.
class MediaLibrarySpatialNavigation extends StatefulWidget {
  const MediaLibrarySpatialNavigation({super.key, required this.child});
  final Widget child;

  static void focusInitial(BuildContext context) {
    context
        .findAncestorStateOfType<_MediaLibrarySpatialNavigationState>()
        ?._requestInitial(ModalRoute.of(context));
  }

  @override
  State<MediaLibrarySpatialNavigation> createState() =>
      _MediaLibrarySpatialNavigationState();
}

/// Leaves embedded native content in control of its own keyboard events.
class MediaLibrarySpatialNavigationExcluded extends StatelessWidget {
  const MediaLibrarySpatialNavigationExcluded({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Floating controls are a separate layer from the content beneath them.
/// They remain in normal Tab traversal, but are not arrow-key destinations.
class MediaLibrarySpatialNavigationOverlay extends StatelessWidget {
  const MediaLibrarySpatialNavigationOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Treats separated parts of one toolbar as horizontal neighbours, even when
/// the layout places them on different rows or inside a scrollable.
class MediaLibrarySpatialNavigationGroup extends StatelessWidget {
  const MediaLibrarySpatialNavigationGroup({
    super.key,
    required this.group,
    required this.child,
  });

  final Object group;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (node, event) =>
        context
            .findAncestorStateOfType<_MediaLibrarySpatialNavigationState>()
            ?._onKey(node, event) ??
        KeyEventResult.ignored,
    child: child,
  );
}

class _MediaLibrarySpatialNavigationState
    extends State<MediaLibrarySpatialNavigation> {
  bool _pendingInitial = false;
  bool _initialScheduled = false;
  FocusNode? _initialAnchor;
  ModalRoute<dynamic>? _initialRoute;
  int _pendingVisibilityFrames = 0;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_cancelOnKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaLibraryKeyboardRegionState._claimKeyboardTransition(context)) {
      _requestInitial(ModalRoute.of(context));
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_cancelOnKey);
    super.dispose();
  }

  KeyEventResult _cancelOnKey(KeyEvent event) {
    if (_pendingInitial && event is KeyDownEvent) _pendingInitial = false;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (event is KeyDownEvent &&
        focused != null &&
        focused
                .findAncestorStateOfType<
                  _MediaLibrarySpatialNavigationState
                >() ==
            this) {
      final item = focused
          .findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
      final activation =
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter ||
          event.logicalKey == LogicalKeyboardKey.space;
      if (activation &&
          item?.widget.selectionMode != true &&
          !_ownsEditableKeys(focused)) {
        MediaLibraryKeyboardRegionState._markKeyboardActivation(focused);
      } else {
        MediaLibraryKeyboardRegionState._clearKeyboardActivation();
      }
    }
    return KeyEventResult.ignored;
  }

  void _requestInitial(ModalRoute<dynamic>? route) {
    _pendingInitial = true;
    _initialAnchor = null;
    _initialRoute = route;
    _pendingVisibilityFrames = 0;
    _scheduleInitial();
  }

  void _scheduleInitial() {
    if (!_pendingInitial || _initialScheduled) return;
    _initialScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialScheduled = false;
      if (!mounted || !_pendingInitial) return;
      final current = FocusManager.instance.primaryFocus;
      final currentContext = current?.context;
      if (_initialAnchor != null && current != _initialAnchor) {
        _pendingInitial = false;
        return;
      }
      if (currentContext != null && _ownsEditableKeys(currentContext)) {
        _pendingInitial = false;
        return;
      }
      final route =
          _initialRoute ??
          (currentContext == null ? null : ModalRoute.of(currentContext));
      _initialRoute = route;
      final cards = _candidates(route: route).where((node) {
        final item = node.context
            ?.findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
        return item != null && node == item._node && item._isVisible;
      }).toList();
      cards.sort((a, b) {
        bool remembered(FocusNode node) {
          final item = node.context!
              .findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
          final region = item?._region;
          return item != null &&
              region != null &&
              region._lastFocused[region.widget.surface()] ==
                  item.widget.itemId;
        }

        final aRemembered = remembered(a);
        final bRemembered = remembered(b);
        if (aRemembered != bRemembered) return aRemembered ? -1 : 1;
        final ar = _focusRect(a)!;
        final br = _focusRect(b)!;
        final vertical = ar.top.compareTo(br.top);
        return vertical != 0 ? vertical : ar.left.compareTo(br.left);
      });
      if (cards.isNotEmpty) {
        _pendingInitial = false;
        cards.first.requestFocus();
        unawaitedEnsureVisible(cards.first.context!);
      } else {
        // Keep a real control focused while asynchronous cards load.
        if (_initialAnchor == null) {
          final controls = _candidates(route: route).toList();
          controls.sort((a, b) {
            final ar = _focusRect(a)!;
            final br = _focusRect(b)!;
            final vertical = ar.top.compareTo(br.top);
            return vertical != 0 ? vertical : ar.left.compareTo(br.left);
          });
          final keepCurrent = current != null && controls.contains(current);
          _initialAnchor = keepCurrent ? current : controls.firstOrNull;
          _initialAnchor?.requestFocus();
        }
        // Newly mounted rows may be temporarily excluded during their reveal
        // animation. Retry only while such rows exist, not while loading is
        // idle, and stop as soon as the user moves focus or presses a key.
        if (_pendingVisibilityFrames < 40 && _hasWaitingCard(route)) {
          _pendingVisibilityFrames++;
          _scheduleInitial();
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _hasWaitingCard(ModalRoute<dynamic>? route) {
    for (final node in FocusManager.instance.rootScope.descendants) {
      final target = node.context;
      if (target == null ||
          node.canRequestFocus ||
          target
                  .findAncestorStateOfType<
                    _MediaLibrarySpatialNavigationState
                  >() !=
              this ||
          (route != null && ModalRoute.of(target) != route) ||
          !TickerMode.valuesOf(target).enabled) {
        continue;
      }
      final item = target
          .findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
      if (item != null && node == item._node && item._isVisible) return true;
    }
    return false;
  }

  Iterable<FocusNode> _candidates({
    ModalRoute<dynamic>? route,
    bool includeOverlays = false,
  }) sync* {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    for (final node in FocusManager.instance.rootScope.traversalDescendants) {
      final target = node.context;
      if (target == null ||
          node is FocusScopeNode ||
          !node.canRequestFocus ||
          node.skipTraversal ||
          target
                  .findAncestorWidgetOfExactType<
                    MediaLibrarySpatialNavigationExcluded
                  >() !=
              null ||
          (!includeOverlays &&
              target
                      .findAncestorWidgetOfExactType<
                        MediaLibrarySpatialNavigationOverlay
                      >() !=
                  null) ||
          target
                  .findAncestorStateOfType<
                    _MediaLibrarySpatialNavigationState
                  >() !=
              this ||
          !TickerMode.valuesOf(target).enabled) {
        continue;
      }
      final targetRoute = ModalRoute.of(target);
      if (targetRoute?.isCurrent == false ||
          (route != null &&
              targetRoute != route &&
              target
                      .findAncestorWidgetOfExactType<
                        MediaLibraryKeyboardMiniPlayer
                      >() ==
                  null)) {
        continue;
      }
      final rect = _focusRect(node);
      final item = target
          .findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
      final allowOffscreenOverlay =
          includeOverlays &&
          target
                  .findAncestorWidgetOfExactType<
                    MediaLibrarySpatialNavigationOverlay
                  >() !=
              null;
      if (rect == null ||
          (!allowOffscreenOverlay &&
              !_visibleInViewport(
                target,
                rect,
                allowHorizontalScroll: item == null,
              ))) {
        continue;
      }
      if (item != null && node != item._node) continue;
      if (item == null && !_isInteractiveFocus(target)) continue;
      yield node;
    }
  }

  bool _move(FocusNode from, TraversalDirection direction) {
    final origin = _focusRect(from);
    final originContext = from.context;
    if (origin == null || originContext == null) return false;
    final route = ModalRoute.of(originContext);
    final horizontal =
        direction == TraversalDirection.left ||
        direction == TraversalDirection.right;
    final group = horizontal
        ? originContext
              .findAncestorWidgetOfExactType<
                MediaLibrarySpatialNavigationGroup
              >()
              ?.group
        : null;
    FocusNode? best;
    var bestScore = double.infinity;
    var bestInGroup = false;
    for (final candidate in _candidates(route: route)) {
      if (candidate == from) continue;
      final rect = _focusRect(candidate)!;
      final score = _directionScore(origin, rect, direction);
      if (score == null) continue;
      final inGroup =
          group != null &&
          identical(
            candidate.context
                ?.findAncestorWidgetOfExactType<
                  MediaLibrarySpatialNavigationGroup
                >()
                ?.group,
            group,
          );
      if (bestInGroup && !inGroup) continue;
      if ((inGroup && !bestInGroup) || score < bestScore) {
        best = candidate;
        bestScore = score;
        bestInGroup = inGroup;
      }
    }
    if (best == null) return false;
    best.requestFocus();
    unawaitedEnsureVisible(best.context!, direction: direction);
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final direction = _keyDirection(event.logicalKey);
    final focused = FocusManager.instance.primaryFocus;
    if (direction == null ||
        focused?.context == null ||
        focused!.context!
                .findAncestorWidgetOfExactType<
                  MediaLibrarySpatialNavigationExcluded
                >() !=
            null ||
        (!_isInteractiveFocus(focused.context!) &&
            focused.context!
                    .findAncestorStateOfType<
                      _MediaLibraryKeyboardItemState
                    >() ==
                null) ||
        _ownsEditableKeys(focused.context!)) {
      return KeyEventResult.ignored;
    }
    if (_move(focused, direction)) return KeyEventResult.handled;
    // At a content edge, Flutter's default directional traversal would
    // otherwise fall through and select a floating control over the page.
    final origin = _focusRect(focused);
    if (origin != null &&
        _candidates(
          route: ModalRoute.of(focused.context!),
          includeOverlays: true,
        ).any((candidate) {
          final target = candidate.context!;
          return target
                      .findAncestorWidgetOfExactType<
                        MediaLibrarySpatialNavigationOverlay
                      >() !=
                  null &&
              _directionScore(origin, _focusRect(candidate)!, direction) !=
                  null;
        })) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => KeyboardFocusTheme(
    child: Listener(
      onPointerDown: (_) {
        _pendingInitial = false;
        MediaLibraryKeyboardRegionState._clearKeyboardActivation();
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: widget.child,
      ),
    ),
  );
}

TraversalDirection? _keyDirection(LogicalKeyboardKey key) => switch (key) {
  LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
  LogicalKeyboardKey.arrowRight => TraversalDirection.right,
  LogicalKeyboardKey.arrowUp => TraversalDirection.up,
  LogicalKeyboardKey.arrowDown => TraversalDirection.down,
  _ => null,
};

Rect? _focusRect(FocusNode node) {
  final render = node.context?.findRenderObject();
  if (render is! RenderBox ||
      !render.attached ||
      !render.hasSize ||
      render.size.isEmpty) {
    return null;
  }
  return render.localToGlobal(Offset.zero) & render.size;
}

bool _visibleInViewport(
  BuildContext context,
  Rect rect, {
  bool allowHorizontalScroll = false,
}) {
  final size = MediaQuery.maybeSizeOf(context);
  final scrollState = Scrollable.maybeOf(context);
  final scrollable = scrollState?.context.findRenderObject();
  if (allowHorizontalScroll &&
      scrollState?.position.axis == Axis.horizontal &&
      scrollable is RenderBox &&
      scrollable.attached &&
      scrollable.hasSize) {
    final viewport = scrollable.localToGlobal(Offset.zero) & scrollable.size;
    return (size == null || (Offset.zero & size).overlaps(viewport)) &&
        rect.bottom > viewport.top &&
        rect.top < viewport.bottom;
  }
  if (size != null && !(Offset.zero & size).overlaps(rect)) return false;
  if (scrollable is RenderBox && scrollable.attached && scrollable.hasSize) {
    return (scrollable.localToGlobal(Offset.zero) & scrollable.size).overlaps(
      rect,
    );
  }
  return true;
}

bool _ownsEditableKeys(BuildContext context) =>
    context.findAncestorWidgetOfExactType<EditableText>() != null ||
    context.findAncestorWidgetOfExactType<Slider>() != null ||
    context.findAncestorWidgetOfExactType<RangeSlider>() != null;

bool _isInteractiveFocus(BuildContext context) {
  var interactive = false;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is InkResponse ||
        widget is ButtonStyleButton ||
        widget is FocusableActionDetector ||
        widget is EditableText) {
      interactive = true;
      return false;
    }
    if (widget is MediaLibrarySpatialNavigation) return false;
    return true;
  });
  return interactive;
}

double? _directionScore(
  Rect origin,
  Rect target,
  TraversalDirection direction,
) {
  final horizontal =
      direction == TraversalDirection.left ||
      direction == TraversalDirection.right;
  final delta = target.center - origin.center;
  final primary = switch (direction) {
    TraversalDirection.left => -delta.dx,
    TraversalDirection.right => delta.dx,
    TraversalDirection.up => -delta.dy,
    TraversalDirection.down => delta.dy,
  };
  if (primary <= 1) return null;
  final cross = horizontal ? delta.dy.abs() : delta.dx.abs();
  final onAxis = horizontal
      ? target.top < origin.bottom && target.bottom > origin.top
      : target.left < origin.right && target.right > origin.left;
  // Rank by the facing edge, not the center. A wide progress bar can sit
  // closer to a card's center than the title above it, and the old
  // center-weighted score then skipped that nearer row.
  final leading = switch (direction) {
    TraversalDirection.left => origin.left - target.right,
    TraversalDirection.right => target.left - origin.right,
    TraversalDirection.up => origin.top - target.bottom,
    TraversalDirection.down => target.top - origin.bottom,
  };
  final band = (leading / 24).floor();
  return (onAxis ? 0 : 1000000000) + band * 100000 + cross;
}

/// Keyboard navigation shared by the library's grid and list presentations.
/// Selection remains owned by the page, rather than by the focus widgets.
class MediaLibraryKeyboardRegion extends StatefulWidget {
  const MediaLibraryKeyboardRegion({
    super.key,
    required this.child,
    required this.surface,
    required this.orderedIds,
    required this.selectionMode,
    required this.selectedIds,
    required this.onSelectionChanged,
  });

  final Widget child;
  final Object Function() surface;
  final List<String> Function() orderedIds;
  final bool Function() selectionMode;
  final Set<String> Function() selectedIds;
  final ValueChanged<Set<String>> onSelectionChanged;

  static bool enabledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MediaLibraryKeyboardScope>() !=
      null;

  static bool focusInitialOf(
    BuildContext context, {
    KeyEvent? event,
    bool fromNativeBridge = false,
  }) =>
      context
          .getInheritedWidgetOfExactType<_MediaLibraryKeyboardScope>()
          ?.state
          .focusInitial(event: event, fromNativeBridge: fromNativeBridge) ??
      false;

  static bool get primaryFocusContainsCards {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    return focus.descendants.any((node) {
      final item = node.context
          ?.findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
      return item != null && node == item._node && node.canRequestFocus;
    });
  }

  @override
  MediaLibraryKeyboardRegionState createState() =>
      MediaLibraryKeyboardRegionState();
}

/// Lets a projected card retain the identity used by its own selection model.
class MediaLibraryKeyboardIdentity extends InheritedWidget {
  const MediaLibraryKeyboardIdentity({
    super.key,
    required this.itemId,
    required super.child,
  });

  final String itemId;

  static String? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MediaLibraryKeyboardIdentity>()
      ?.itemId;

  @override
  bool updateShouldNotify(MediaLibraryKeyboardIdentity oldWidget) =>
      itemId != oldWidget.itemId;
}

class MediaLibraryKeyboardRegionState
    extends State<MediaLibraryKeyboardRegion> {
  static ModalRoute<dynamic>? _activationRoute;
  static ModalRoute<dynamic>? _activationHostRoute;
  static DateTime? _activationTime;

  static void _markKeyboardActivation(BuildContext context) {
    _activationRoute = ModalRoute.of(context);
    final scope = context
        .findAncestorStateOfType<_MediaLibrarySpatialNavigationState>();
    _activationHostRoute = scope == null ? null : ModalRoute.of(scope.context);
    _activationTime = DateTime.now();
  }

  static void _clearKeyboardActivation() {
    _activationRoute = null;
    _activationHostRoute = null;
    _activationTime = null;
  }

  static bool _claimKeyboardTransition(BuildContext context) {
    final route = ModalRoute.of(context);
    final activated = _activationTime;
    if (route == null ||
        route == _activationRoute ||
        activated == null ||
        DateTime.now().difference(activated) >= const Duration(seconds: 2) ||
        (_activationRoute?.isCurrent != false &&
            _activationHostRoute?.isCurrent != false)) {
      return false;
    }
    _clearKeyboardActivation();
    return true;
  }

  final Set<_MediaLibraryKeyboardItemState> _items = {};
  final Map<Object, String> _lastFocused = {};
  final Map<Object, int> _lastIndex = {};
  final _androidKeys = AndroidHardwareKeyDeduplicator();
  String? _rangeAnchor;
  Set<String>? _rangeSnapshot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_claimKeyboardTransition(context)) {
      MediaLibrarySpatialNavigation.focusInitial(context);
    }
  }

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidKey);
  }

  @override
  void dispose() {
    AndroidHardwareInputBridge.removeKeyListener(_handleAndroidKey);
    super.dispose();
  }

  bool _acceptKey(KeyEvent event, {required bool fromNativeBridge}) =>
      currentNativeTargetPlatform != TargetPlatform.android ||
      _androidKeys.shouldDispatch(event, fromNativeBridge: fromNativeBridge);

  void _handleAndroidKey(AndroidHardwareKeyMessage message) {
    if (!mounted || message.hasBlockingModifier) return;
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    final item = focusedContext
        ?.findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
    if (item == null || item._region != this || !item._node.hasPrimaryFocus) {
      return;
    }
    item._handleKey(
      message.toKeyEvent(),
      fromNativeBridge: true,
      shiftOverride: message.isShiftPressed,
      blockingOverride: message.hasBlockingModifier,
    );
  }

  Iterable<_MediaLibraryKeyboardItemState> get _available => _items.where(
    (item) =>
        item.mounted &&
        item._node.canRequestFocus &&
        TickerMode.valuesOf(item.context).enabled &&
        item._rect != null,
  );

  /// Called when the page itself has focus and an arrow starts navigation.
  bool focusInitial({KeyEvent? event, bool fromNativeBridge = false}) {
    final items = _available.toList();
    if (items.isEmpty) return false;
    if (event != null &&
        !_acceptKey(event, fromNativeBridge: fromNativeBridge)) {
      return true;
    }
    final remembered = _lastFocused[widget.surface()];
    final order = widget.orderedIds();
    final previousIndex = _lastIndex[widget.surface()];
    items.sort((a, b) {
      final aRemembered = a.widget.itemId == remembered;
      final bRemembered = b.widget.itemId == remembered;
      if (aRemembered != bRemembered) return aRemembered ? -1 : 1;
      final aVisible = a._isVisible;
      final bVisible = b._isVisible;
      if (aVisible != bVisible) return aVisible ? -1 : 1;
      if (previousIndex != null && !order.contains(remembered)) {
        final ai = order.indexOf(a.widget.itemId);
        final bi = order.indexOf(b.widget.itemId);
        if (ai >= 0 && bi >= 0) {
          final byDistance = (ai - previousIndex).abs().compareTo(
            (bi - previousIndex).abs(),
          );
          if (byDistance != 0) return byDistance;
        }
      }
      final ar = a._rect!;
      final br = b._rect!;
      final vertical = ar.top.compareTo(br.top);
      return vertical != 0 ? vertical : ar.left.compareTo(br.left);
    });
    _focus(items.first);
    return true;
  }

  void _focus(
    _MediaLibraryKeyboardItemState item, {
    TraversalDirection? direction,
  }) {
    item._node.requestFocus();
    unawaitedEnsureVisible(item.context, direction: direction);
  }

  void _remember(_MediaLibraryKeyboardItemState item) {
    final surface = widget.surface();
    _lastFocused[surface] = item.widget.itemId;
    final index = widget.orderedIds().indexOf(item.widget.itemId);
    if (index >= 0) _lastIndex[surface] = index;
  }

  void _clearRange() {
    _rangeAnchor = null;
    _rangeSnapshot = null;
  }

  bool _move(
    _MediaLibraryKeyboardItemState from,
    TraversalDirection direction, {
    required bool extend,
  }) {
    final origin = from._rect;
    if (origin == null) return false;
    final best = _nearestCard(origin, direction, exclude: from);
    if (best == null) {
      if (_scrollToUnbuiltNeighbor(from, origin, direction, extend: extend)) {
        return true;
      }
      if (!extend &&
          direction == TraversalDirection.down &&
          context
                  .findAncestorStateOfType<
                    _MediaLibrarySpatialNavigationState
                  >() ==
              null) {
        if (MediaLibraryKeyboardMiniPlayer.focusFrom(origin)) return true;
      }
      return !extend && _focusControlInDirection(from, origin, direction);
    }

    _applyRange(from.widget.itemId, best.widget.itemId, extend: extend);
    _focus(best, direction: direction);
    return true;
  }

  _MediaLibraryKeyboardItemState? _nearestCard(
    Rect origin,
    TraversalDirection direction, {
    _MediaLibraryKeyboardItemState? exclude,
  }) {
    _MediaLibraryKeyboardItemState? best;
    double bestScore = double.infinity;
    for (final candidate in _available) {
      if (identical(candidate, exclude)) continue;
      final rect = candidate._rect!;
      // Cards in the same row can have slightly different heights. They are
      // neighbours horizontally, not a previous/next row vertically.
      final separated = switch (direction) {
        TraversalDirection.left => rect.right <= origin.left + 2,
        TraversalDirection.right => rect.left >= origin.right - 2,
        TraversalDirection.up => rect.bottom <= origin.top + 2,
        TraversalDirection.down => rect.top >= origin.bottom - 2,
      };
      if (!separated) continue;
      final delta = rect.center - origin.center;
      final primary = switch (direction) {
        TraversalDirection.left => -delta.dx,
        TraversalDirection.right => delta.dx,
        TraversalDirection.up => -delta.dy,
        TraversalDirection.down => delta.dy,
      };
      if (primary <= 1) continue;
      final horizontal =
          direction == TraversalDirection.left ||
          direction == TraversalDirection.right;
      final cross = horizontal ? delta.dy.abs() : delta.dx.abs();
      // Prefer the next row/column, then the closest aligned card.
      final extent = horizontal ? origin.height : origin.width;
      final score = primary + math.max(0.0, cross - extent * .45) * 4;
      if (score < bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  void _applyRange(String fromId, String toId, {required bool extend}) {
    if (extend && widget.selectionMode()) {
      final ids = widget.orderedIds();
      final start = ids.indexOf(_rangeAnchor ?? fromId);
      final end = ids.indexOf(toId);
      if (start >= 0 && end >= 0) {
        _rangeAnchor ??= fromId;
        _rangeSnapshot ??= Set<String>.of(widget.selectedIds());
        widget.onSelectionChanged(
          MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
            snapshot: _rangeSnapshot!,
            startIndex: start,
            currentIndex: end,
            itemCount: ids.length,
            idAt: (index) => ids[index],
          ),
        );
      }
    } else {
      _clearRange();
    }
  }

  bool _scrollToUnbuiltNeighbor(
    _MediaLibraryKeyboardItemState from,
    Rect origin,
    TraversalDirection direction, {
    required bool extend,
  }) {
    if (direction != TraversalDirection.up &&
        direction != TraversalDirection.down) {
      return false;
    }
    final position = Scrollable.maybeOf(from.context)?.position;
    if (position == null ||
        !position.hasContentDimensions ||
        position.axis != Axis.vertical) {
      return false;
    }
    final ids = widget.orderedIds();
    final index = ids.indexOf(from.widget.itemId);
    if (index < 0) return false;
    final forward =
        (direction == TraversalDirection.down) ==
        (position.axisDirection == AxisDirection.down);
    if ((forward && position.pixels >= position.maxScrollExtent) ||
        (!forward && position.pixels <= position.minScrollExtent)) {
      return false;
    }
    if ((forward && index >= ids.length - 1) || (!forward && index == 0)) {
      return false;
    }
    final surface = widget.surface();
    final fromId = from.widget.itemId;
    final route = ModalRoute.of(context);

    bool canContinue() {
      if (!mounted ||
          widget.surface() != surface ||
          ModalRoute.of(context)?.isCurrent == false) {
        return false;
      }
      final current = FocusManager.instance.primaryFocus;
      final currentContext = current?.context;
      if (currentContext != null && ModalRoute.of(currentContext) != route) {
        return false;
      }
      if (current != null &&
          current != from._node &&
          (MediaLibraryKeyboardItem.hasPrimaryFocus ||
              MediaLibraryKeyboardItem.interactiveControlHasFocus)) {
        return false;
      }
      return true;
    }

    void advance(Rect oldOrigin, int attempts) {
      if (!canContinue() || attempts >= 32) return;
      final next =
          (position.pixels +
                  (forward ? 1 : -1) * position.viewportDimension * .8)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      final moved = next - position.pixels;
      if (moved == 0) {
        if (!extend && direction == TraversalDirection.down) {
          MediaLibraryKeyboardMiniPlayer.focusFrom(oldOrigin);
        }
        return;
      }
      position.jumpTo(next);
      final shifted = oldOrigin.shift(
        Offset(
          0,
          position.axisDirection == AxisDirection.down ? -moved : moved,
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!canContinue()) return;
        final best = _nearestCard(shifted, direction, exclude: from);
        if (best == null) {
          advance(shifted, attempts + 1);
          return;
        }
        _applyRange(fromId, best.widget.itemId, extend: extend);
        _focus(best, direction: direction);
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }

    advance(origin, 0);
    return true;
  }

  bool _focusControlInDirection(
    _MediaLibraryKeyboardItemState from,
    Rect origin,
    TraversalDirection direction,
  ) {
    final scope = context
        .findAncestorStateOfType<_MediaLibrarySpatialNavigationState>();
    if (scope != null) return scope._move(from._node, direction);
    FocusNode? best;
    var bestScore = double.infinity;
    final route = ModalRoute.of(from.context);
    for (final node in FocusManager.instance.rootScope.traversalDescendants) {
      final target = node.context;
      if (target == null || node is FocusScopeNode || !node.canRequestFocus) {
        continue;
      }
      if (ModalRoute.of(target) != route ||
          ModalRoute.of(target)?.isCurrent == false) {
        continue;
      }
      final containingCard = target
          .findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
      if (containingCard != null && containingCard != from) continue;
      final render = target.findRenderObject();
      if (render is! RenderBox || !render.attached || !render.hasSize) continue;
      final rect = render.localToGlobal(Offset.zero) & render.size;
      final delta = rect.center - origin.center;
      final primary = switch (direction) {
        TraversalDirection.left => -delta.dx,
        TraversalDirection.right => delta.dx,
        TraversalDirection.up => -delta.dy,
        TraversalDirection.down => delta.dy,
      };
      if (primary <= 1) continue;
      final cross =
          direction == TraversalDirection.left ||
              direction == TraversalDirection.right
          ? delta.dy.abs()
          : delta.dx.abs();
      final score = primary + cross * 2;
      if (score < bestScore) {
        best = node;
        bestScore = score;
      }
    }
    if (best == null) return false;
    best.requestFocus();
    final focusedContext = best.context;
    if (focusedContext != null) {
      unawaitedEnsureVisible(focusedContext, direction: direction);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) =>
      _MediaLibraryKeyboardScope(state: this, child: widget.child);
}

void unawaitedEnsureVisible(
  BuildContext context, {
  TraversalDirection? direction,
}) {
  final position = Scrollable.maybeOf(context)?.position;
  final render = context.findRenderObject();
  final oversized =
      position != null &&
      position.hasViewportDimension &&
      render is RenderBox &&
      render.hasSize &&
      render.size.height > position.viewportDimension;
  Scrollable.ensureVisible(
    context,
    duration: Duration.zero,
    alignment: direction == TraversalDirection.up ? 1 : 0,
    alignmentPolicy: oversized && direction != null
        ? ScrollPositionAlignmentPolicy.explicit
        : direction == TraversalDirection.down ||
              direction == TraversalDirection.right
        ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
        : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
  );
}

class _MediaLibraryKeyboardScope extends InheritedWidget {
  const _MediaLibraryKeyboardScope({required this.state, required super.child});
  final MediaLibraryKeyboardRegionState state;

  @override
  bool updateShouldNotify(_MediaLibraryKeyboardScope oldWidget) =>
      state != oldWidget.state;
}

/// An action within a row that should also participate in arrow navigation.
class MediaLibraryKeyboardDirectionalAction extends StatefulWidget {
  const MediaLibraryKeyboardDirectionalAction({super.key, required this.child});

  final Widget child;

  @override
  State<MediaLibraryKeyboardDirectionalAction> createState() =>
      _MediaLibraryKeyboardDirectionalActionState();
}

class _MediaLibraryKeyboardDirectionalActionState
    extends State<MediaLibraryKeyboardDirectionalAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (focused) {
      if (_focused != focused && mounted) setState(() => _focused = focused);
    },
    child: KeyboardFocusHighlight(
      focused: _focused,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.lightBlueAccent, width: 2),
      ),
      child: widget.child,
    ),
  );
}

/// The keyboard focus target for a card. Its nested action buttons remain
/// independent tab stops, while arrow keys on the card move between cards.
class MediaLibraryKeyboardItem extends StatefulWidget {
  const MediaLibraryKeyboardItem({
    super.key,
    required this.itemId,
    required this.selected,
    required this.selectionMode,
    required this.onActivate,
    required this.child,
  });

  final String itemId;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onActivate;
  final Widget child;

  static bool get hasPrimaryFocus {
    final context = FocusManager.instance.primaryFocus?.context;
    return context
            ?.findAncestorStateOfType<_MediaLibraryKeyboardItemState>()
            ?._node
            .hasPrimaryFocus ??
        false;
  }

  static bool handlesNativeKey(LogicalKeyboardKey key, {required bool shift}) {
    final context = FocusManager.instance.primaryFocus?.context;
    final item = context
        ?.findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
    if (item == null || !item._node.hasPrimaryFocus || item._region == null) {
      return false;
    }
    return key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 && shift) ||
        (key == LogicalKeyboardKey.space && item.widget.selectionMode);
  }

  /// A focused control must receive its own Space and arrow keys.
  static bool get interactiveControlHasFocus {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    var found = false;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is InkResponse ||
          widget is Slider ||
          widget is ButtonStyleButton ||
          widget is EditableText ||
          widget is FocusableActionDetector ||
          widget is MediaLibraryKeyboardMiniPlayer) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  @override
  State<MediaLibraryKeyboardItem> createState() =>
      _MediaLibraryKeyboardItemState();
}

class _MediaLibraryKeyboardItemState extends State<MediaLibraryKeyboardItem> {
  final FocusNode _node = FocusNode(debugLabel: 'library card');
  MediaLibraryKeyboardRegionState? _region;
  bool _primaryFocus = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocusNodeChanged);
  }

  void _onFocusNodeChanged() {
    final primary = _node.hasPrimaryFocus;
    if (primary == _primaryFocus) return;
    _primaryFocus = primary;
    if (primary) _region?._remember(this);
    if (mounted) setState(() {});
  }

  Rect? get _rect {
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    return render.localToGlobal(Offset.zero) & render.size;
  }

  bool get _isVisible {
    final rect = _rect;
    if (rect == null) return false;
    final scrollable = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (scrollable is RenderBox && scrollable.attached && scrollable.hasSize) {
      final viewport = scrollable.localToGlobal(Offset.zero) & scrollable.size;
      return viewport.overlaps(rect);
    }
    return (Offset.zero & MediaQuery.sizeOf(context)).overlaps(rect);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final region = context
        .dependOnInheritedWidgetOfExactType<_MediaLibraryKeyboardScope>()
        ?.state;
    if (region == _region) return;
    _region?._items.remove(this);
    _region = region;
    _region?._items.add(this);
    context
        .findAncestorStateOfType<_MediaLibrarySpatialNavigationState>()
        ?._scheduleInitial();
  }

  @override
  void didUpdateWidget(covariant MediaLibraryKeyboardItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectionMode != widget.selectionMode) _region?._clearRange();
  }

  @override
  void dispose() {
    _region?._items.remove(this);
    _node.removeListener(_onFocusNodeChanged);
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_region == null) return KeyEventResult.ignored;
    if (!node.hasPrimaryFocus) {
      final direction = _keyDirection(event.logicalKey);
      final keyboard = HardwareKeyboard.instance;
      final focused = FocusManager.instance.primaryFocus;
      final isDirectionalAction =
          focused?.context
              ?.findAncestorWidgetOfExactType<
                MediaLibraryKeyboardDirectionalAction
              >() !=
          null;
      if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
          direction != null &&
          !keyboard.isShiftPressed &&
          !keyboard.isControlPressed &&
          !keyboard.isAltPressed &&
          !keyboard.isMetaPressed &&
          isDirectionalAction) {
        if (!_region!._acceptKey(event, fromNativeBridge: false)) {
          return KeyEventResult.handled;
        }
        if (_moveDirectionalAction(focused, direction)) {
          return KeyEventResult.handled;
        }
      }
      if (event is! KeyDownEvent ||
          event.logicalKey != LogicalKeyboardKey.tab ||
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isAltPressed ||
          HardwareKeyboard.instance.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      final current = FocusManager.instance.primaryFocus;
      if (current?.context == null || _ownsEditableKeys(current!.context!)) {
        return KeyEventResult.ignored;
      }
      final actions = _keyboardActions();
      final index = actions.indexOf(current);
      if (index < 0) return KeyEventResult.ignored;
      if (HardwareKeyboard.instance.isShiftPressed) {
        final previous = index == 0 ? _node : actions[index - 1];
        previous.requestFocus();
        if (previous.context != null) {
          unawaitedEnsureVisible(
            previous.context!,
            direction: TraversalDirection.up,
          );
        }
        return KeyEventResult.handled;
      }
      if (index + 1 < actions.length) {
        final next = actions[index + 1];
        next.requestFocus();
        if (next.context != null) {
          unawaitedEnsureVisible(
            next.context!,
            direction: TraversalDirection.down,
          );
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    return _handleKey(event);
  }

  List<FocusNode> _keyboardActions() {
    final actions = _node.traversalDescendants.where((node) {
      final target = node.context;
      final rect = _focusRect(node);
      return target != null &&
          node.canRequestFocus &&
          !node.skipTraversal &&
          rect != null &&
          (_visibleInViewport(target, rect) ||
              target
                      .findAncestorWidgetOfExactType<
                        MediaLibraryKeyboardDirectionalAction
                      >() !=
                  null) &&
          _isInteractiveFocus(target);
    }).toList();
    actions.sort((a, b) {
      final ar = _focusRect(a)!;
      final br = _focusRect(b)!;
      final vertical = ar.top.compareTo(br.top);
      return vertical != 0 ? vertical : ar.left.compareTo(br.left);
    });
    return actions;
  }

  bool _moveDirectionalAction(
    FocusNode? current,
    TraversalDirection direction,
  ) {
    if (widget.selectionMode || current?.context == null) return false;
    // An expanded row can be taller than the viewport. Its buttons are still
    // reachable: focusing one will scroll it into view.
    final actions = _node.traversalDescendants.where((action) {
      final target = action.context;
      return target != null &&
          action.canRequestFocus &&
          !action.skipTraversal &&
          _focusRect(action) != null &&
          TickerMode.valuesOf(target).enabled &&
          _isInteractiveFocus(target) &&
          target
                  .findAncestorWidgetOfExactType<
                    MediaLibraryKeyboardDirectionalAction
                  >() !=
              null;
    }).toList();
    if (actions.isEmpty) return false;
    if (current == _node) {
      if (direction != TraversalDirection.right) return false;
      actions.sort((a, b) {
        final ar = _focusRect(a)!;
        final br = _focusRect(b)!;
        final horizontal = ar.left.compareTo(br.left);
        return horizontal != 0 ? horizontal : ar.top.compareTo(br.top);
      });
      actions.first.requestFocus();
      unawaitedEnsureVisible(actions.first.context!, direction: direction);
      return true;
    }
    if (!actions.contains(current)) return false;
    final origin = _focusRect(current!);
    if (origin == null) return false;
    FocusNode? best;
    var bestScore = double.infinity;
    for (final candidate in actions) {
      if (candidate == current) continue;
      final score = _directionScore(origin, _focusRect(candidate)!, direction);
      if (score != null && score < bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    if (best != null) {
      best.requestFocus();
      unawaitedEnsureVisible(best.context!, direction: direction);
      return true;
    }
    if (direction == TraversalDirection.left) {
      _node.requestFocus();
    } else if (direction == TraversalDirection.up ||
        direction == TraversalDirection.down) {
      _region!._move(this, direction, extend: false);
    }
    return true;
  }

  KeyEventResult _handleKey(
    KeyEvent event, {
    bool fromNativeBridge = false,
    bool? shiftOverride,
    bool? blockingOverride,
  }) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (blockingOverride ??
        (keyboard.isControlPressed ||
            keyboard.isAltPressed ||
            keyboard.isMetaPressed)) {
      return KeyEventResult.ignored;
    }
    final shift = shiftOverride ?? keyboard.isShiftPressed;
    final key = event.logicalKey;
    if (event is KeyDownEvent && !shift && key == LogicalKeyboardKey.tab) {
      final actions = _keyboardActions();
      if (actions.isNotEmpty) {
        actions.first.requestFocus();
        unawaitedEnsureVisible(
          actions.first.context!,
          direction: TraversalDirection.down,
        );
        return KeyEventResult.handled;
      }
    }
    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      _ => null,
    };
    if (direction != null) {
      if (!_region!._acceptKey(event, fromNativeBridge: fromNativeBridge)) {
        return KeyEventResult.handled;
      }
      if (!shift && _moveDirectionalAction(_node, direction)) {
        return KeyEventResult.handled;
      }
      _region!._move(this, direction, extend: shift);
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;
    if ((key == LogicalKeyboardKey.contextMenu && !shift) ||
        (key == LogicalKeyboardKey.f10 && shift)) {
      if (!_region!._acceptKey(event, fromNativeBridge: fromNativeBridge)) {
        return KeyEventResult.handled;
      }
      return CardContextMenu.openVisibleTarget(context)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (!shift &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            (key == LogicalKeyboardKey.space && widget.selectionMode))) {
      if (!_region!._acceptKey(event, fromNativeBridge: fromNativeBridge)) {
        return KeyEventResult.handled;
      }
      _region!._clearRange();
      if (!widget.selectionMode) {
        MediaLibraryKeyboardRegionState._markKeyboardActivation(context);
      }
      widget.onActivate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (_region == null) return widget.child;
    context
        .findAncestorStateOfType<_MediaLibrarySpatialNavigationState>()
        ?._scheduleInitial();
    return Focus(
      focusNode: _node,
      onKeyEvent: _onKey,
      child: Semantics(
        button: true,
        selected: widget.selectionMode ? widget.selected : null,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: KeyboardFocusVisibilityBuilder(
                  builder: (context, visible, child) => AnimatedOpacity(
                    opacity: _node.hasPrimaryFocus && visible ? 1 : 0,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : KeyboardFocusVisibility.fadeDuration,
                    curve: Curves.easeOut,
                    child: child,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.lightBlueAccent,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Marks the mini player as a separate focus region, including its buttons.
class MediaLibraryKeyboardMiniPlayer extends StatelessWidget {
  const MediaLibraryKeyboardMiniPlayer({super.key, required this.child});
  final Widget child;

  static bool get hasFocus {
    final context = FocusManager.instance.primaryFocus?.context;
    return context
            ?.findAncestorWidgetOfExactType<MediaLibraryKeyboardMiniPlayer>() !=
        null;
  }

  static bool focusFrom(Rect origin) {
    FocusNode? best;
    var distance = double.infinity;
    for (final node in FocusManager.instance.rootScope.traversalDescendants) {
      final context = node.context;
      if (context == null ||
          node is FocusScopeNode ||
          context
                  .findAncestorWidgetOfExactType<
                    MediaLibraryKeyboardMiniPlayer
                  >() ==
              null) {
        continue;
      }
      final render = context.findRenderObject();
      if (render is! RenderBox || !render.attached || !render.hasSize) continue;
      final rect = render.localToGlobal(Offset.zero) & render.size;
      if (rect.center.dy <= origin.center.dy) continue;
      final score = _directionScore(origin, rect, TraversalDirection.down);
      if (score != null && score < distance) {
        best = node;
        distance = score;
      }
    }
    if (best == null) return false;
    best.requestFocus();
    return true;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (node, event) {
      if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
          HardwareKeyboard.instance.isShiftPressed ||
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isAltPressed ||
          HardwareKeyboard.instance.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      final direction = _keyDirection(event.logicalKey);
      final focusContext = FocusManager.instance.primaryFocus?.context;
      if (direction == null ||
          focusContext == null ||
          focusContext.findAncestorWidgetOfExactType<EditableText>() != null) {
        return KeyEventResult.ignored;
      }
      final isSlider =
          focusContext.findAncestorWidgetOfExactType<Slider>() != null ||
          focusContext.findAncestorWidgetOfExactType<RangeSlider>() != null;
      if (isSlider &&
          (direction == TraversalDirection.left ||
              direction == TraversalDirection.right)) {
        return KeyEventResult.ignored;
      }
      final focused = FocusManager.instance.primaryFocus?.context
          ?.findRenderObject();
      if (focused is! RenderBox || !focused.attached || !focused.hasSize) {
        return KeyEventResult.ignored;
      }
      final origin = focused.localToGlobal(Offset.zero) & focused.size;
      FocusNode? best;
      var distance = double.infinity;
      for (final candidate
          in FocusManager.instance.rootScope.traversalDescendants) {
        final candidateContext = candidate.context;
        if (candidateContext == null ||
            candidate is FocusScopeNode ||
            !candidate.canRequestFocus ||
            candidate.skipTraversal ||
            candidate == FocusManager.instance.primaryFocus ||
            !identical(
              candidateContext
                  .findAncestorWidgetOfExactType<
                    MediaLibraryKeyboardMiniPlayer
                  >(),
              this,
            ) ||
            !_isInteractiveFocus(candidateContext)) {
          continue;
        }
        final rect = _focusRect(candidate);
        if (rect == null || !_visibleInViewport(candidateContext, rect)) {
          continue;
        }
        final score = _directionScore(origin, rect, direction);
        if (score == null) continue;
        final horizontal =
            direction == TraversalDirection.left ||
            direction == TraversalDirection.right;
        final aligned = horizontal
            ? rect.top < origin.bottom && rect.bottom > origin.top
            : rect.left < origin.right && rect.right > origin.left;
        final alignedScore = score + (aligned ? 0 : 1000000);
        if (alignedScore < distance) {
          best = candidate;
          distance = alignedScore;
        }
      }
      if (best != null) {
        best.requestFocus();
        return KeyEventResult.handled;
      }
      if (direction != TraversalDirection.up) return KeyEventResult.ignored;
      distance = double.infinity;
      for (final candidate
          in FocusManager.instance.rootScope.traversalDescendants) {
        final itemContext = candidate.context;
        final item = itemContext
            ?.findAncestorStateOfType<_MediaLibraryKeyboardItemState>();
        if (item == null ||
            candidate != item._node ||
            !candidate.canRequestFocus ||
            !item._isVisible ||
            ModalRoute.of(itemContext!)?.isCurrent == false) {
          continue;
        }
        final rect = item._rect;
        if (rect == null || rect.center.dy >= origin.center.dy) continue;
        final score = (rect.center - origin.center).distanceSquared;
        if (score < distance) {
          best = candidate;
          distance = score;
        }
      }
      if (best == null) return KeyEventResult.ignored;
      best.requestFocus();
      final focusedContext = best.context;
      if (focusedContext != null) {
        unawaitedEnsureVisible(
          focusedContext,
          direction: TraversalDirection.up,
        );
      }
      return KeyEventResult.handled;
    },
    child: child,
  );
}
