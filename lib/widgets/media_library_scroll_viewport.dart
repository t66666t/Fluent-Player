import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../services/settings_service.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/page_shortcut_keys.dart';
import 'media_library_layout_profile.dart';
import 'media_library_shell.dart';
import 'playback_source_viewport.dart';

/// Shared browsing frame. The gutters stay reserved when the content fits,
/// so adding or removing a row never shifts the cards sideways.
class MediaLibraryScrollViewport extends StatefulWidget {
  const MediaLibraryScrollViewport({
    super.key,
    required this.controller,
    required this.child,
    this.isActive = true,
    this.keyboardScrolling = true,
    this.bottomObstruction = 0,
    this.contentInsetFraction = 0,
    this.layoutIdentity,
  }) : assert(bottomObstruction >= 0),
       assert(contentInsetFraction >= 0 && contentInsetFraction < .5);

  /// Account for the grid's own padding instead of adding a second gutter.
  factory MediaLibraryScrollViewport.library({
    Key? key,
    required SettingsService settings,
    required Size screenSize,
    required ScrollController controller,
    required Widget child,
    bool isActive = true,
    bool keyboardScrolling = true,
    double bottomObstruction = 0,
  }) {
    final cards = settings.homeCardStyleFor(screenSize);
    final rows = settings.listStyleFor(screenSize);
    final layoutIdentity = settings.mediaLibraryUsesRowPipeline
        ? (1, rows.layoutIdentity)
        : (
            0,
            cards.crossAxisCount,
            cards.heightScale,
            cards.titleScale,
            cards.mainSpacingScale,
            cards.crossSpacingScale,
            cards.reserveTwoTitleLines,
          );
    return MediaLibraryScrollViewport(
      key: key,
      controller: controller,
      isActive: isActive,
      keyboardScrolling: keyboardScrolling,
      bottomObstruction: bottomObstruction,
      contentInsetFraction: libraryInsetFraction(settings, screenSize),
      layoutIdentity: layoutIdentity,
      child: child,
    );
  }

  final ScrollController controller;
  final Widget child;
  final bool isActive;
  final bool keyboardScrolling;

  /// Existing horizontal content padding as a fraction of its viewport width.
  final double contentInsetFraction;
  final Object? layoutIdentity;

  /// Overlay space where a playback card or selection actions cover the list.
  final double bottomObstruction;

  static const thumbKey = ValueKey('media-library-scroll-thumb');

  static double sideGutterFor(double width) =>
      math.min(width / 8, width < 600 ? 12 : (width < 1024 ? 16 : 20));

  static double libraryInsetFraction(
    SettingsService settings,
    Size screenSize, {
    bool? useList,
  }) {
    final list = useList ?? settings.mediaLibraryUsesRowPipeline;
    final cards = settings.homeCardStyleFor(screenSize);
    final rows = settings.listStyleFor(screenSize);
    // Pixel row styles carry their own padding instead of a width fraction.
    final rowPadding = rows.outerPadding;
    if (list && rowPadding != null) {
      return screenSize.width <= 0
          ? 0
          : (rowPadding / screenSize.width).clamp(0.0, .45);
    }
    return MediaLibraryLayoutDefaults.distributeWidth(
      availableWidth: 1,
      columns: list ? rows.crossAxisCount : cards.crossAxisCount,
      spacingScale: list ? rows.crossSpacingScale : cards.crossSpacingScale,
    ).outerPadding;
  }

  /// Preserve deliberately large user spacing, but never stack extra padding
  /// on top of it. This is also the header's alignment and thumb hit width.
  static double cardEdgeFor(double width, double contentInsetFraction) =>
      math.max(sideGutterFor(width), width * contentInsetFraction);

  /// Pane width after gutters, without changing device/orientation presets.
  static double contentWidthOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ViewportWidth>()?.width ??
      MediaQuery.sizeOf(context).width;

  @override
  State<MediaLibraryScrollViewport> createState() =>
      _MediaLibraryScrollViewportState();
}

class _MediaLibraryScrollViewportState
    extends State<MediaLibraryScrollViewport> {
  final _metrics = ValueNotifier<ScrollMetrics?>(null);
  final _androidKeys = AndroidHardwareKeyDeduplicator();
  bool _refreshScheduled = false;
  bool _hovered = false;
  bool _dragging = false;
  double _dragY = 0;
  double _dragPixels = 0;
  double _dragScale = 0;
  double? _keyboardTarget;
  int _keyboardGeneration = 0;

  ScrollPosition? get _position => widget.controller.positions.length == 1
      ? widget.controller.position
      : null;

  bool get _active =>
      widget.isActive &&
      TickerMode.valuesOf(context).enabled &&
      (context
              .getInheritedWidgetOfExactType<PlaybackViewportActivity>()
              ?.active ??
          true) &&
      mediaLibraryRouteIsCurrent(context) != false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refreshMetrics);
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidKey);
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(MediaLibraryScrollViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive &&
        oldWidget.controller == widget.controller &&
        oldWidget.layoutIdentity != widget.layoutIdentity) {
      PlaybackScrollController.preserveForRelayout(widget.controller);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refreshMetrics);
      widget.controller.addListener(_refreshMetrics);
      _keyboardTarget = null;
      _keyboardGeneration++;
      _dragging = false;
    }
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) _refreshMetrics();
    });
  }

  void _refreshMetrics() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _scheduleRefresh();
      return;
    }
    final position = _position;
    final next = position != null && position.hasContentDimensions
        ? position.copyWith()
        : null;
    final old = _metrics.value;
    if (old?.pixels == next?.pixels &&
        old?.minScrollExtent == next?.minScrollExtent &&
        old?.maxScrollExtent == next?.maxScrollExtent &&
        old?.viewportDimension == next?.viewportDimension &&
        old?.axisDirection == next?.axisDirection) {
      return;
    }
    _metrics.value = next;
  }

  bool _scrollable(ScrollMetrics? metrics) =>
      metrics != null &&
      metrics.axis == Axis.vertical &&
      metrics.viewportDimension > 0 &&
      metrics.maxScrollExtent.isFinite &&
      metrics.minScrollExtent.isFinite &&
      metrics.maxScrollExtent - metrics.minScrollExtent > .5;

  void _handleAndroidKey(AndroidHardwareKeyMessage message) {
    _handleKey(
      message.toKeyEvent(),
      fromNativeBridge: true,
      blockingModifier: message.hasBlockingModifier || message.isShiftPressed,
    );
  }

  KeyEventResult _handleKey(
    KeyEvent event, {
    bool fromNativeBridge = false,
    bool? blockingModifier,
  }) {
    final key = event.logicalKey;
    if (!mounted ||
        !widget.keyboardScrolling ||
        (key != LogicalKeyboardKey.arrowUp &&
            key != LogicalKeyboardKey.arrowDown) ||
        !supportsNativeHardwareKeyboardShortcuts ||
        !_active ||
        (blockingModifier ??
            (hasBlockingKeyboardModifier() ||
                HardwareKeyboard.instance.isShiftPressed)) ||
        isEditableTextFocused()) {
      return KeyEventResult.ignored;
    }
    // Preserve arrow-key adjustments on the mini player's seek/volume sliders.
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus?.findAncestorWidgetOfExactType<Slider>() != null ||
        focus?.findAncestorWidgetOfExactType<RangeSlider>() != null) {
      return KeyEventResult.ignored;
    }
    final position = _position;
    if (position == null ||
        !position.hasContentDimensions ||
        !_scrollable(position)) {
      return KeyEventResult.ignored;
    }
    if (currentNativeTargetPlatform == TargetPlatform.android &&
        !_androidKeys.shouldDispatch(
          event,
          fromNativeBridge: fromNativeBridge,
        )) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _scrollStep(key == LogicalKeyboardKey.arrowDown ? 1 : -1);
    }
    return KeyEventResult.handled;
  }

  void _scrollStep(int direction) {
    final position = _position;
    if (position == null || !_scrollable(position)) return;
    final reverse = position.axisDirection == AxisDirection.up ? -1 : 1;
    final step = (position.viewportDimension * .18).clamp(48.0, 120.0);
    final target =
        ((_keyboardTarget ?? position.pixels) + step * direction * reverse)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    _keyboardTarget = target;
    final generation = ++_keyboardGeneration;
    if (MediaQuery.disableAnimationsOf(context)) {
      position.jumpTo(target);
      _keyboardTarget = null;
    } else {
      unawaited(
        position
            .animateTo(
              target,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() {
              if (mounted && generation == _keyboardGeneration) {
                _keyboardTarget = null;
              }
            }),
      );
    }
  }

  void _pointerSignal(PointerSignalEvent event) {
    final position = _position;
    if (event is! PointerScrollEvent ||
        position == null ||
        !_scrollable(position) ||
        !_active) {
      return;
    }
    // The descendant scrollable wins over this fallback. The fallback also
    // makes the wheel work over the otherwise empty gutters and the thumb.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _keyboardTarget = null;
      final reverse = position.axisDirection == AxisDirection.up ? -1 : 1;
      position.pointerScroll(event.scrollDelta.dy * reverse);
    });
  }

  Widget _thumb(ScrollMetrics? metrics, double height, double gutter) {
    if (!_scrollable(metrics) || height <= 16) {
      return const SizedBox.shrink();
    }
    final m = metrics!;
    final range = m.maxScrollExtent - m.minScrollExtent;
    final track = height - 16;
    final length = math.min(
      track,
      (track * m.viewportDimension / (range + m.viewportDimension)).clamp(
        56.0,
        88.0,
      ),
    );
    final travel = track - length;
    var fraction = ((m.pixels - m.minScrollExtent) / range).clamp(0.0, 1.0);
    final reverse = m.axisDirection == AxisDirection.up;
    if (reverse) fraction = 1 - fraction;
    final emphasized = _hovered || _dragging;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 140);
    return Positioned(
      left: 0,
      top: 8 + fraction * travel,
      width: gutter,
      height: length,
      child: Semantics(
        label: '页面滚动位置',
        value: '${(fraction * 100).round()}%',
        increasedValue: '${math.min(100, (fraction * 100).round() + 10)}%',
        decreasedValue: '${math.max(0, (fraction * 100).round() - 10)}%',
        onIncrease: () => _scrollStep(1),
        onDecrease: () => _scrollStep(-1),
        child: MouseRegion(
          cursor: _dragging
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            key: MediaLibraryScrollViewport.thumbKey,
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragStart: (details) {
              final position = _position;
              if (position == null || !_active || travel <= 0) return;
              _keyboardTarget = null;
              _keyboardGeneration++;
              _dragY = details.globalPosition.dy;
              _dragPixels = position.pixels;
              _dragScale = range / travel * (reverse ? -1 : 1);
              position.jumpTo(position.pixels);
              setState(() => _dragging = true);
            },
            onVerticalDragUpdate: (details) {
              final position = _position;
              if (!_dragging || position == null || !_active) return;
              position.jumpTo(
                (_dragPixels +
                        (details.globalPosition.dy - _dragY) * _dragScale)
                    .clamp(position.minScrollExtent, position.maxScrollExtent),
              );
            },
            onVerticalDragEnd: (_) => setState(() => _dragging = false),
            onVerticalDragCancel: () => setState(() => _dragging = false),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: duration,
              builder: (_, opacity, child) =>
                  Opacity(opacity: opacity, child: child),
              child: Center(
                child: AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  width: emphasized ? 6 : 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurface.withValues(
                      alpha: emphasized ? .55 : .28,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) _scheduleRefresh();
        return false;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          _keyboardTarget = null;
          _keyboardGeneration++;
        },
        onPointerSignal: _pointerSignal,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final edge = MediaLibraryScrollViewport.cardEdgeFor(
              constraints.maxWidth,
              widget.contentInsetFraction,
            );
            final gutter = math.max(
              0.0,
              (edge - constraints.maxWidth * widget.contentInsetFraction) /
                  (1 - 2 * widget.contentInsetFraction),
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: gutter),
                  child: _ViewportWidth(
                    width: math.max(0, constraints.maxWidth - gutter * 2),
                    child: RepaintBoundary(child: widget.child),
                  ),
                ),
                ValueListenableBuilder<ScrollMetrics?>(
                  valueListenable: _metrics,
                  builder: (_, metrics, _) => _thumb(
                    metrics,
                    math.max(
                      0,
                      constraints.maxHeight - widget.bottomObstruction,
                    ),
                    edge,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  @override
  void dispose() {
    widget.controller.removeListener(_refreshMetrics);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    AndroidHardwareInputBridge.removeKeyListener(_handleAndroidKey);
    _metrics.dispose();
    super.dispose();
  }
}

class _ViewportWidth extends InheritedWidget {
  const _ViewportWidth({required this.width, required super.child});

  final double width;

  @override
  bool updateShouldNotify(_ViewportWidth oldWidget) => width != oldWidget.width;
}
