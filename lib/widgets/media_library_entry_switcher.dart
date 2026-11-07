import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../utils/media_library_entry_shortcuts.dart';
import '../utils/keyboard_focus_visibility.dart';

import '../models/media_library_root_entry.dart';
import '../models/media_library_root_entry_order.dart';
import '../models/media_library_root_swipe_policy.dart';
import 'media_library_compact_app_bar.dart';

/// Compact root-entry switcher intended to replace the "我的媒体库" title.
///
/// All destinations are mounted on the root page. A disabled chip only
/// appears when the host has not yet listed that entry as available.
/// Drag a title to reorder; a short press still only switches.
class MediaLibraryEntrySwitcher extends StatelessWidget {
  const MediaLibraryEntrySwitcher({
    super.key,
    required this.selected,
    required this.availableEntries,
    required this.onSelected,
    this.compact = false,
    this.highlightIndex,
    this.entries = MediaLibraryRootEntryOrder.defaults,
    this.reorderEnabled = false,
    this.onReorder,
  });

  final MediaLibraryRootEntry selected;
  final Set<MediaLibraryRootEntry> availableEntries;
  final ValueChanged<MediaLibraryRootEntry> onSelected;
  final bool compact;

  /// Fractional chip index while a page swipe is in flight. Discrete
  /// [selected] still owns taps and commit; this drives both the highlight
  /// and the scrolling viewport so the titles follow the moving page.
  final double? highlightIndex;

  final List<MediaLibraryRootEntry> entries;

  /// Chip reorder is off while a page is mid-swipe or mid-fade.
  final bool reorderEnabled;

  final void Function(int oldIndex, int newIndex)? onReorder;

  /// Follow the finger even after it has crossed more than one page.
  /// [selected] can still be the page the gesture started on.
  double get _visualHighlight {
    final selectedIndex = entries.indexOf(selected).toDouble();
    final incoming = highlightIndex;
    final last = (entries.length - 1).toDouble();
    if (incoming == null || !incoming.isFinite || last < 0) {
      return selectedIndex < 0 ? 0 : selectedIndex;
    }
    return incoming.clamp(0.0, last);
  }

  @override
  Widget build(BuildContext context) {
    final style = compact
        ? mediaLibraryCompactTitleStyle.copyWith(fontSize: 13)
        : mediaLibraryCompactTitleStyle;
    final highlight = _visualHighlight;
    final ordered = MediaLibraryRootEntryOrder.normalize(entries);
    // Keep one chip row widget for the whole swipe. Swapping
    // ReorderableListView ↔ Row when [reorderEnabled] flips is what
    // made the titles jump mid-gesture.
    final useReorderableRow = onReorder != null && ordered.length > 1;
    final canDragReorder = useReorderableRow && reorderEnabled;

    return LayoutBuilder(
      builder: (context, constraints) {
        // On a narrow screen the titles do not fit beside the toolbar
        // actions. Shrinking them that far would make them unreadable, so
        // the row scrolls instead and keeps the selected title in view.
        // This depends on the width only, so it never flips mid-swipe.
        final geometry = _measureChips(context, ordered, style);
        final scrollable =
            constraints.hasBoundedWidth &&
            geometry.width > constraints.maxWidth + 0.5;
        final chips = <Widget>[
          for (var i = 0; i < ordered.length; i++)
            _chip(
              index: i,
              ordered: ordered,
              highlight: highlight,
              style: style,
              useReorderableRow: useReorderableRow,
              canDragReorder: canDragReorder,
              scrollable: scrollable,
            ),
        ];

        final row = _EntryChipRow(
          selected: selected,
          entries: ordered,
          highlightIndex: highlight,
          chipCenters: geometry.centers,
          viewportWidth: constraints.maxWidth,
          scrollable: scrollable,
          onReorder: useReorderableRow ? onReorder : null,
          children: chips,
        );

        final translated = Transform.translate(
          offset: const Offset(0, mediaLibraryCompactTitleOpticalOffset),
          child: SizedBox(height: compact ? 32 : 36, child: row),
        );

        if (useReorderableRow || scrollable) {
          return Align(alignment: Alignment.centerLeft, child: translated);
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: translated,
          ),
        );
      },
    );
  }

  /// Full-size row width and chip centers, including hit padding and gaps.
  ({double width, List<double> centers}) _measureChips(
    BuildContext context,
    List<MediaLibraryRootEntry> ordered,
    TextStyle style,
  ) {
    final textStyle = DefaultTextStyle.of(
      context,
    ).style.merge(style.copyWith(fontWeight: FontWeight.w500));
    final scaler = MediaQuery.textScalerOf(context);
    var total = 0.0;
    final centers = <double>[];
    for (var i = 0; i < ordered.length; i++) {
      final painter = TextPainter(
        text: TextSpan(text: ordered[i].label, style: textStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final padding = _EntryChip.hitPadding(compact, isLeading: i == 0);
      final width = painter.width + padding.horizontal;
      centers.add(total + padding.left + painter.width / 2);
      total += width;
      painter.dispose();
      if (i < ordered.length - 1) total += _EntryChip.gapAfter(compact);
    }
    return (width: total, centers: centers);
  }

  Widget _chip({
    required int index,
    required List<MediaLibraryRootEntry> ordered,
    required double highlight,
    required TextStyle style,
    required bool useReorderableRow,
    required bool canDragReorder,
    required bool scrollable,
  }) {
    final entry = ordered[index];
    final chip = _EntryChip(
      entry: entry,
      isLeading: index == 0,
      selected: entry == selected,
      highlightWeight: MediaLibraryRootSwipePolicy.chipWeight(
        entryIndex: index,
        highlightIndex: highlight,
      ),
      enabled: availableEntries.contains(entry),
      compact: compact,
      style: style,
      onSelected: onSelected,
      trailingGap: index == ordered.length - 1
          ? 0
          : _EntryChip.gapAfter(compact),
      canDragReorder: canDragReorder,
      scrollable: scrollable,
    );
    final labeledChip = Tooltip(
      message: mediaLibraryEntryShortcutTooltip(entry.label, index),
      triggerMode: TooltipTriggerMode.manual,
      waitDuration: const Duration(milliseconds: 500),
      child: chip,
    );
    if (!useReorderableRow) return labeledChip;
    return _EntryReorderDragStartListener(
      key: ValueKey<MediaLibraryRootEntry>(entry),
      index: index,
      enabled: canDragReorder,
      child: labeledChip,
    );
  }

  static Widget _proxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    // Same lifted size as the press animation, with no second scale-up.
    // Starting another grow here is what made a short click swell, stall,
    // then snap back when the page changed.
    // Keep hover overlays out of the proxy while the chip changes parents.
    return TooltipVisibility(
      visible: false,
      child: Transform.scale(scale: _kChipPressScale, child: child),
    );
  }
}

/// Owns one scroll position for the entire swipe, including its final commit.
class _EntryChipRow extends StatefulWidget {
  const _EntryChipRow({
    required this.selected,
    required this.entries,
    required this.highlightIndex,
    required this.chipCenters,
    required this.viewportWidth,
    required this.scrollable,
    required this.onReorder,
    required this.children,
  });

  final MediaLibraryRootEntry selected;
  final List<MediaLibraryRootEntry> entries;
  final double highlightIndex;
  final List<double> chipCenters;
  final double viewportWidth;
  final bool scrollable;
  final void Function(int oldIndex, int newIndex)? onReorder;
  final List<Widget> children;

  @override
  State<_EntryChipRow> createState() => _EntryChipRowState();
}

class _EntryChipRowState extends State<_EntryChipRow> {
  final ScrollController _scroll = ScrollController(keepScrollOffset: false);
  bool _followScheduled = false;
  int _followGeneration = 0;
  bool _animateFollow = false;
  bool _hasBefore = false, _hasAfter = false, _edgesScheduled = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scheduleEdges);
    _scheduleFollow(animate: false);
    _scheduleEdges();
  }

  @override
  void didUpdateWidget(covariant _EntryChipRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleEdges();
    final selectionChanged = oldWidget.selected != widget.selected;
    if (!selectionChanged && !listEquals(oldWidget.entries, widget.entries)) {
      // Reordering changes chip centers and the selected page's index, but
      // it is not navigation. Keep the viewport where the drag left it.
      _followScheduled = false;
      _followGeneration++;
      return;
    }
    final geometryChanged =
        oldWidget.scrollable != widget.scrollable ||
        oldWidget.viewportWidth != widget.viewportWidth ||
        !listEquals(oldWidget.chipCenters, widget.chipCenters);
    if (!geometryChanged &&
        !selectionChanged &&
        oldWidget.highlightIndex == widget.highlightIndex) {
      // An unrelated rebuild must preserve a manual scroll of the titles.
      return;
    }
    _scheduleFollow(
      animate:
          !geometryChanged &&
          selectionChanged &&
          oldWidget.highlightIndex ==
              oldWidget.highlightIndex.roundToDouble() &&
          widget.highlightIndex == widget.highlightIndex.roundToDouble(),
    );
  }

  void _scheduleEdges() {
    if (_edgesScheduled) return;
    _edgesScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _edgesScheduled = false;
      if (!mounted ||
          !_scroll.hasClients ||
          !_scroll.position.hasContentDimensions) {
        return;
      }
      final before =
          widget.scrollable &&
          _scroll.offset > _scroll.position.minScrollExtent + .5;
      final after =
          widget.scrollable &&
          _scroll.offset < _scroll.position.maxScrollExtent - .5;
      if (before != _hasBefore || after != _hasAfter) {
        setState(() {
          _hasBefore = before;
          _hasAfter = after;
        });
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _scheduleFollow({required bool animate}) {
    if (_followScheduled) {
      _animateFollow = _animateFollow && animate;
      return;
    }
    _followScheduled = true;
    _animateFollow = animate;
    final generation = ++_followGeneration;
    // Wait for the scroll extents after a resize or font change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _followGeneration) return;
      _followScheduled = false;
      if (!mounted || !widget.scrollable || !_scroll.hasClients) return;
      final position = _scroll.position;
      if (!position.hasContentDimensions || widget.chipCenters.isEmpty) return;
      final index = widget.highlightIndex.clamp(
        0.0,
        (widget.chipCenters.length - 1).toDouble(),
      );
      double offsetFor(int i) =>
          (widget.chipCenters[i] - position.viewportDimension / 2).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
      final lower = index.floor();
      final upper = index.ceil();
      final start = offsetFor(lower);
      // Clamp each destination before interpolating. Otherwise the first
      // part of a swipe at either end would leave the titles standing still.
      final target = start + (offsetFor(upper) - start) * (index - lower);
      final atTarget = (position.pixels - target).abs() < 0.01;
      if (_animateFollow && !MediaQuery.disableAnimationsOf(context)) {
        if (!atTarget) {
          unawaited(
            _scroll.animateTo(
              target,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
            ),
          );
        }
      } else if (!atTarget || position.isScrollingNotifier.value) {
        // The page already supplies the finger/snap animation. Adding a
        // second animation here would lag behind it, especially on reversal.
        _scroll.jumpTo(target);
      }
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_scheduleEdges);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = _buildRow(context);
    if (!widget.scrollable) return row;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _scheduleEdges();
        return false;
      },
      child: Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent || !_scroll.hasClients) return;
          final delta = event.scrollDelta.dx != 0
              ? event.scrollDelta.dx
              : event.scrollDelta.dy;
          final position = _scroll.position;
          final target = (position.pixels + delta).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          if (target == position.pixels) return;
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {
            _scroll.jumpTo(target);
          });
        },
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) {
            final fade = (12 / bounds.width).clamp(0.0, 0.5);
            return LinearGradient(
              colors: [
                _hasBefore ? Colors.transparent : Colors.white,
                Colors.white,
                Colors.white,
                _hasAfter ? Colors.transparent : Colors.white,
              ],
              stops: [0, fade, 1 - fade, 1],
            ).createShader(bounds);
          },
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                ...ScrollConfiguration.of(context).dragDevices,
                PointerDeviceKind.mouse,
              },
              scrollbars: false,
            ),
            child: row,
          ),
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context) {
    if (widget.onReorder != null) {
      return ReorderableListView(
        scrollController: _scroll,
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        primary: false,
        padding: EdgeInsets.zero,
        buildDefaultDragHandles: false,
        physics: widget.scrollable
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        proxyDecorator: MediaLibraryEntrySwitcher._proxyDecorator,
        onReorderItem: widget.onReorder!,
        children: widget.children,
      );
    }
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: widget.children,
    );
    if (!widget.scrollable) return row;
    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      primary: false,
      child: row,
    );
  }
}

class _EntryChip extends StatefulWidget {
  const _EntryChip({
    required this.entry,
    required this.isLeading,
    required this.selected,
    required this.highlightWeight,
    required this.enabled,
    required this.compact,
    required this.style,
    required this.onSelected,
    required this.trailingGap,
    required this.canDragReorder,
    this.scrollable = false,
  });

  final MediaLibraryRootEntry entry;
  final bool isLeading;
  final bool selected;
  final double highlightWeight;
  final bool enabled;
  final bool compact;
  final TextStyle style;
  final ValueChanged<MediaLibraryRootEntry> onSelected;
  final double trailingGap;
  final bool canDragReorder;

  /// The chip row scrolls (narrow screen): a press selects on release so a
  /// scroll that starts on a title does not switch to it.
  final bool scrollable;

  /// Inner padding is the clickable box. Keep a 4px dead strip between chips
  /// so a slightly larger target cannot select the neighbor.
  static EdgeInsets hitPadding(bool compact, {required bool isLeading}) {
    final inset = compact ? 6.0 : 8.0;
    // Keep the first chip's existing width while centering its label inside
    // the focus outline. This also preserves narrow-row reorder geometry.
    return EdgeInsets.symmetric(horizontal: isLeading ? inset / 2 : inset);
  }

  static double gapAfter(bool compact) => compact ? 4 : 6;

  @override
  State<_EntryChip> createState() => _EntryChipState();
}

const double _kChipPressScale = 1.05;
const double _kMouseReorderSlop = 6;

class _EntryChipState extends State<_EntryChip>
    with SingleTickerProviderStateMixin {
  bool _hasFocus = false;
  int? _pointer;
  Offset? _downPosition;
  bool _passedDragSlop = false;
  Timer? _reorderHold;
  late final AnimationController _press;
  late final CurvedAnimation _pressCurve;
  late final Animation<double> _pressScale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      reverseDuration: const Duration(milliseconds: 140),
    );
    _pressCurve = CurvedAnimation(
      parent: _press,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic,
    );
    _pressScale = Tween<double>(
      begin: 1,
      end: _kChipPressScale,
    ).animate(_pressCurve);
  }

  bool _isPrimaryPress(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return true;
    return event.buttons == kPrimaryButton;
  }

  double _dragSlop(PointerEvent event) {
    final settings = MediaQuery.maybeGestureSettingsOf(context);
    if (event.kind == PointerDeviceKind.mouse) {
      return widget.canDragReorder
          ? _kMouseReorderSlop
          : computeHitSlop(event.kind, settings);
    }
    return math.max(kTouchSlop, computeHitSlop(event.kind, settings));
  }

  void _select() {
    if (!widget.enabled || widget.selected) return;
    widget.onSelected(widget.entry);
  }

  void _beginPress() {
    if (MediaQuery.disableAnimationsOf(context)) return;
    _press.forward();
  }

  void _endPress() {
    if (_passedDragSlop) return;
    _press.reverse();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled || widget.selected || !_isPrimaryPress(event)) return;
    _beginPress();
    // No reorder is possible, so a press can switch immediately.
    if (!widget.canDragReorder && !widget.scrollable) {
      _select();
      _endPress();
      return;
    }
    // Reorder uses the same press. Wait until release before switching, and
    // skip the switch once the pointer has moved far enough to reorder.
    _pointer = event.pointer;
    _downPosition = event.position;
    _passedDragSlop = false;
    if (widget.canDragReorder && event.kind != PointerDeviceKind.mouse) {
      _reorderHold = Timer(kLongPressTimeout, () {
        _passedDragSlop = true;
        _press.reverse();
      });
    }
    GestureBinding.instance.pointerRouter.addRoute(
      event.pointer,
      _routePointer,
      event.transform,
    );
  }

  void _routePointer(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _onPointerMove(event);
    } else if (event is PointerUpEvent) {
      _onPointerUp(event);
    } else if (event is PointerCancelEvent) {
      _onPointerCancel(event);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _downPosition == null || _passedDragSlop) {
      return;
    }
    if ((event.position - _downPosition!).distance > _dragSlop(event)) {
      _passedDragSlop = true;
      // The reorder proxy owns the lift from here. Leaving the press scale
      // running makes the chip swell, stall, then snap when the drag ends.
      if (widget.canDragReorder && event.kind == PointerDeviceKind.mouse) {
        _press.reset();
      } else {
        _press.reverse();
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final switchOnRelease = !_passedDragSlop;
    _clearPointer();
    if (switchOnRelease) {
      _select();
      _endPress();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _clearPointer();
    _press.reverse();
  }

  void _clearPointer() {
    _reorderHold?.cancel();
    _reorderHold = null;
    final pointer = _pointer;
    if (pointer != null) {
      GestureBinding.instance.pointerRouter.removeRoute(pointer, _routePointer);
    }
    _pointer = null;
    _downPosition = null;
    _passedDragSlop = false;
  }

  @override
  void dispose() {
    _clearPointer();
    _pressCurve.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = !widget.enabled
        ? AppTokens.text4
        : Color.lerp(AppTokens.text3, AppTokens.text1, widget.highlightWeight)!;
    // One weight for every chip. Swapping w300 and w500 when a swipe
    // commits changes the glyph color's apparent brightness in one frame,
    // so the highlight looks like it jumps instead of crossfading.
    final canSelect = widget.enabled && !widget.selected;
    return FocusableActionDetector(
      enabled: widget.enabled,
      onFocusChange: (focused) {
        if (mounted && _hasFocus != focused) {
          setState(() => _hasFocus = focused);
        }
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (canSelect) _select();
            return null;
          },
        ),
      },
      child: Semantics(
        excludeSemantics: true,
        button: true,
        selected: widget.selected,
        enabled: widget.enabled,
        label: widget.entry.label,
        hint: widget.canDragReorder ? '鼠标按住拖动可调整顺序，触屏长按后拖动' : null,
        onTap: canSelect ? _select : null,
        child: Padding(
          padding: EdgeInsets.only(right: widget.trailingGap),
          child: MouseRegion(
            cursor: widget.canDragReorder
                ? SystemMouseCursors.grab
                : canSelect
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            opaque: true,
            hitTestBehavior: HitTestBehavior.opaque,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: canSelect ? _onPointerDown : null,
              child: RepaintBoundary(
                child: ScaleTransition(
                  scale: _pressScale,
                  child: KeyboardFocusHighlight(
                    focused: _hasFocus,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.lightBlueAccent,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: SizedBox(
                      height: widget.compact ? 32 : 36,
                      child: Padding(
                        padding: _EntryChip.hitPadding(
                          widget.compact,
                          isLeading: widget.isLeading,
                        ),
                        child: Column(
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.center,
                                child: Text(
                                  widget.entry.label,
                                  maxLines: 1,
                                  style: widget.style.copyWith(
                                    color: color,
                                    fontWeight: widget.enabled
                                        ? FontWeight.w500
                                        : widget.style.fontWeight,
                                  ),
                                ),
                              ),
                            ),
                            Container(
                              height: 2,
                              color: Color.lerp(
                                Colors.transparent,
                                AppTokens.text1,
                                widget.enabled ? widget.highlightWeight : 0,
                              ),
                            ),
                          ],
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
  }
}

/// Mouse sorting starts on deliberate movement; touch keeps long-press sorting
/// so a quick swipe can still scroll the titles.
class _EntryReorderDragStartListener extends ReorderableDragStartListener {
  const _EntryReorderDragStartListener({
    super.key,
    required super.child,
    required super.index,
    super.enabled,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      _EntryReorderGestureRecognizer(debugOwner: this);
}

class _EntryReorderGestureRecognizer extends DelayedMultiDragGestureRecognizer {
  _EntryReorderGestureRecognizer({super.debugOwner});

  final _mouseStates = <int, _MouseEntryDragState>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      // Track position before MultiDrag reads the move. Windows can report
      // a large delta even though the cursor has not actually moved.
      GestureBinding.instance.pointerRouter.addRoute(
        event.pointer,
        _trackMousePosition,
      );
    }
    super.addAllowedPointer(event);
    // Reserve mouse presses on a title before the row's scroll recognizer
    // can claim them. The proxy still waits for deliberate movement.
    _mouseStates[event.pointer]?.reserveForReorder();
  }

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) {
      return super.createNewPointerState(event);
    }
    return _mouseStates[event.pointer] = _MouseEntryDragState(
      event.position,
      event.kind,
      gestureSettings,
    );
  }

  void _trackMousePosition(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _mouseStates[event.pointer]?.position = event.position;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      GestureBinding.instance.pointerRouter.removeRoute(
        event.pointer,
        _trackMousePosition,
      );
      _mouseStates.remove(event.pointer);
    }
  }

  @override
  void dispose() {
    for (final pointer in _mouseStates.keys) {
      GestureBinding.instance.pointerRouter.removeRoute(
        pointer,
        _trackMousePosition,
      );
    }
    _mouseStates.clear();
    super.dispose();
  }
}

class _MouseEntryDragState extends MultiDragPointerState {
  _MouseEntryDragState(super.initialPosition, super.kind, super.gestureSettings)
    : position = initialPosition;

  Offset position;
  GestureMultiDragStartCallback? _starter;
  bool _started = false;
  bool _cancelled = false;

  Offset get _travel => position - initialPosition;

  // Also use real displacement for the first proxy update, rather than
  // replaying a spurious Windows delta when the threshold is crossed.
  @override
  Offset? get pendingDelta => super.pendingDelta == null ? null : _travel;

  bool get _horizontalIntent =>
      _travel.dx.abs() > _kMouseReorderSlop &&
      _travel.dx.abs() >= _travel.dy.abs();

  void reserveForReorder() => resolve(GestureDisposition.accepted);

  @override
  void checkForResolutionAfterMove() {
    if (_cancelled) return;
    if (_travel.dy.abs() > _kMouseReorderSlop &&
        _travel.dy.abs() > _travel.dx.abs()) {
      _cancelled = true;
      if (_starter == null) resolve(GestureDisposition.rejected);
      return;
    }
    if (!_horizontalIntent) return;
    if (_starter == null) {
      resolve(GestureDisposition.accepted);
    } else {
      _tryStart();
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    // The arena can accept a lone recognizer on pointer down. A stationary
    // press must still remain a click, even when it is held for a long time.
    _starter = starter;
    _tryStart();
  }

  void _tryStart() {
    if (_started || _cancelled || _starter == null || !_horizontalIntent) {
      return;
    }
    _started = true;
    _starter!(initialPosition);
  }
}
