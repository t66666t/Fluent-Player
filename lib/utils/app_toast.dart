import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'page_cover_route_observer.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

enum AppToastType { info, success, error }

class AppToastAction {
  final String label;
  final VoidCallback onPressed;

  const AppToastAction({required this.label, required this.onPressed});
}

/// A reference to one specific toast presentation.
///
/// Dismissing the handle is intentionally a no-op after another toast has
/// replaced it. This lets asynchronous work clean up its own loading toast
/// without accidentally removing a newer success or error message.
class AppToastHandle {
  final int _presentationId;

  const AppToastHandle._(this._presentationId);

  Future<void> dismiss({bool immediate = false, bool fromSwipe = false}) {
    return AppToast._dismissIfCurrent(
      _presentationId,
      immediate: immediate,
      fromSwipe: fromSwipe,
    );
  }

  void updateProgress({String? message, double? progress, AppToastType? type}) {
    AppToast._updateProgressIfCurrent(
      _presentationId,
      message: message,
      progress: progress,
      type: type,
    );
  }
}

class AppToast {
  static const Duration _maximumVisibleDuration = Duration(seconds: 8);
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static final NavigatorObserver observer = _ToastNavigatorObserver();

  /// Another observer that dismisses toasts on route changes, for a navigator
  /// nested inside the app navigator. An observer serves one navigator only.
  static NavigatorObserver createRouteChangeObserver() =>
      _ToastNavigatorObserver();
  static final PageCoverRouteObserver routeObserver = PageCoverRouteObserver();

  static OverlayEntry? _entry;
  static final Set<OverlayEntry> _retiringEntries = <OverlayEntry>{};
  static Timer? _dismissTimer;
  static _ToastOverlayController? _controller;
  static ValueNotifier<_ToastViewData>? _contentNotifier;
  static int _nextPresentationId = 0;
  static int? _currentPresentationId;

  static AppToastHandle show(
    String message, {
    AppToastType type = AppToastType.info,
    Duration duration = const Duration(milliseconds: 1500),
    AppToastAction? action,
  }) {
    return _showEntry(
      _ToastContent(
        message: message,
        type: type,
        showSpinner: false,
        action: action,
      ),
      autoDismissAfter: duration > _maximumVisibleDuration
          ? _maximumVisibleDuration
          : duration,
    );
  }

  static AppToastHandle showLoading(String message) {
    final presentationId = _showEntryData(
      const _ToastViewData(
        message: '',
        type: AppToastType.info,
        showSpinner: true,
      ).copyWith(message: message),
      autoDismissAfter: const Duration(seconds: 8),
    );
    return AppToastHandle._(presentationId);
  }

  static AppToastHandle showProgress(
    String message, {
    double? progress,
    AppToastType type = AppToastType.info,
  }) {
    final presentationId = _showEntryData(
      _ToastViewData(
        message: message,
        type: type,
        showSpinner: progress == null,
        progress: progress,
      ),
      autoDismissAfter: const Duration(seconds: 8),
    );
    return AppToastHandle._(presentationId);
  }

  static void updateProgress({
    String? message,
    double? progress,
    AppToastType? type,
  }) {
    final presentationId = _currentPresentationId;
    if (presentationId == null) {
      if (message != null) {
        showProgress(
          message,
          progress: progress,
          type: type ?? AppToastType.info,
        );
      }
      return;
    }
    _updateProgressIfCurrent(
      presentationId,
      message: message,
      progress: progress,
      type: type,
    );
  }

  static void _updateProgressIfCurrent(
    int presentationId, {
    String? message,
    double? progress,
    AppToastType? type,
  }) {
    if (_currentPresentationId != presentationId) return;
    final notifier = _contentNotifier;
    final current = notifier?.value;
    if (notifier == null || current == null) {
      if (message != null) {
        showProgress(
          message,
          progress: progress,
          type: type ?? AppToastType.info,
        );
      }
      return;
    }

    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(seconds: 8), () {
      _dismissIfCurrent(presentationId);
    });
    notifier.value = current.copyWith(
      message: message,
      progress: progress,
      type: type,
      showSpinner: progress == null,
      action: null,
    );
  }

  static Future<void> dismiss({
    bool immediate = false,
    bool fromSwipe = false,
  }) async {
    _dismissTimer?.cancel();
    _dismissTimer = null;

    if (immediate) {
      for (final retiringEntry in _retiringEntries.toList()) {
        retiringEntry.remove();
      }
      _retiringEntries.clear();
    }

    final controller = _controller;
    final entry = _entry;
    _controller = null;
    _entry = null;
    final contentNotifier = _contentNotifier;
    _contentNotifier = null;
    _currentPresentationId = null;

    if (entry == null) {
      contentNotifier?.dispose();
      return;
    }

    if (immediate || controller == null) {
      // An inserted entry may not have built yet: mounted is not membership.
      entry.remove();
      contentNotifier?.dispose();
      return;
    }

    _retiringEntries.add(entry);
    try {
      await controller
          .hide(animateSwipeAway: fromSwipe)
          .timeout(const Duration(milliseconds: 400), onTimeout: () {});
    } finally {
      if (_retiringEntries.remove(entry)) {
        entry.remove();
      }
      contentNotifier?.dispose();
    }
  }

  static Future<void> _dismissIfCurrent(
    int presentationId, {
    bool immediate = false,
    bool fromSwipe = false,
  }) async {
    if (_currentPresentationId != presentationId) {
      return;
    }
    await dismiss(immediate: immediate, fromSwipe: fromSwipe);
  }

  static bool isCurrentRoute(String routeName) {
    return observer is _ToastNavigatorObserver &&
        (observer as _ToastNavigatorObserver).currentRouteName == routeName;
  }

  static AppToastHandle _showEntry(
    _ToastContent content, {
    Duration? autoDismissAfter,
  }) {
    final presentationId = _showEntryData(
      _ToastViewData(
        message: content.message,
        type: content.type,
        showSpinner: content.showSpinner,
        action: content.action,
        progress: content.progress,
      ),
      autoDismissAfter: autoDismissAfter,
    );
    return AppToastHandle._(presentationId);
  }

  static int _showEntryData(
    _ToastViewData content, {
    Duration? autoDismissAfter,
  }) {
    final presentationId = ++_nextPresentationId;
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return presentationId;

    _currentPresentationId = presentationId;

    _dismissTimer?.cancel();
    _dismissTimer = null;

    final existingNotifier = _contentNotifier;
    final existingEntry = _entry;
    if (existingNotifier != null &&
        existingEntry != null &&
        existingEntry.mounted) {
      existingNotifier.value = content;
      if (autoDismissAfter != null) {
        _dismissTimer = Timer(autoDismissAfter, () {
          _dismissIfCurrent(presentationId);
        });
      }
      return presentationId;
    }

    final oldEntry = _entry;
    final oldNotifier = _contentNotifier;
    _entry = null;
    _controller = null;
    _contentNotifier = null;
    if (oldEntry != null) {
      oldEntry.remove();
    }
    oldNotifier?.dispose();

    final contentNotifier = ValueNotifier<_ToastViewData>(content);

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) {
        return _ToastOverlayHost(
          onControllerReady: (controller) {
            if (_entry == entry) {
              _controller = controller;
            }
          },
          child: ValueListenableBuilder<_ToastViewData>(
            valueListenable: contentNotifier,
            builder: (context, data, _) {
              return _ToastContent(
                message: data.message,
                type: data.type,
                showSpinner: data.showSpinner,
                action: data.action,
                progress: data.progress,
              );
            },
          ),
        );
      },
    );

    _entry = entry;
    _contentNotifier = contentNotifier;
    overlay.insert(entry);

    if (autoDismissAfter != null) {
      _dismissTimer = Timer(autoDismissAfter, () {
        _dismissIfCurrent(presentationId);
      });
    }
    return presentationId;
  }
}

class _ToastNavigatorObserver extends NavigatorObserver {
  String? currentRouteName;

  void _dismissForRouteChange() {
    // A toast belongs to the route/flow that created it. Route transitions
    // must not carry an old overlay into the next flow.
    unawaited(AppToast.dismiss(immediate: true));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _dismissForRouteChange();
    currentRouteName = route.settings.name;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _dismissForRouteChange();
    currentRouteName = previousRoute?.settings.name;
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _dismissForRouteChange();
    currentRouteName = newRoute?.settings.name;
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _dismissForRouteChange();
    currentRouteName = previousRoute?.settings.name;
    super.didRemove(route, previousRoute);
  }
}

class _ToastOverlayHost extends StatelessWidget {
  final Widget child;
  final ValueChanged<_ToastOverlayController> onControllerReady;

  const _ToastOverlayHost({
    required this.child,
    required this.onControllerReady,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final horizontalPadding = (size.width * 0.04).clamp(12.0, 24.0);
    final topPadding = (size.height * 0.014).clamp(8.0, 18.0);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(
              top: topPadding,
              left: horizontalPadding,
              right: horizontalPadding,
            ),
            child: _ToastAnimatedContainer(
              onControllerReady: onControllerReady,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastAnimatedContainer extends StatefulWidget {
  final Widget child;
  final ValueChanged<_ToastOverlayController> onControllerReady;

  const _ToastAnimatedContainer({
    required this.child,
    required this.onControllerReady,
  });

  @override
  State<_ToastAnimatedContainer> createState() =>
      _ToastAnimatedContainerState();
}

class _ToastAnimatedContainerState extends State<_ToastAnimatedContainer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  late final Animation<Offset> _slide;
  final GlobalKey _toastKey = GlobalKey();
  double _dragOffsetY = 0;
  double _toastHeight = 0;
  double _toastTop = 0;
  bool _isDragging = false;
  bool _isHiding = false;
  bool _hasUpwardDrag = false;
  int? _trackedPointer;
  double? _pointerStartY;
  bool _pointerDismissTriggered = false;

  static const double _quickSwipeDistance = 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 140),
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _opacity = curved;
    _scale = Tween<double>(begin: 0.965, end: 1).animate(curved);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.08),
      end: Offset.zero,
    ).animate(curved);
    widget.onControllerReady(_ToastOverlayController(_hide));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateToastMetrics();
      _controller.forward();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(AppToast.dismiss(immediate: true));
    }
  }

  void _updateToastMetrics() {
    final context = _toastKey.currentContext;
    if (context == null) return;
    final nextHeight = context.size?.height;
    if (nextHeight != null && nextHeight > 0) {
      _toastHeight = nextHeight;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      _toastTop = renderObject.localToGlobal(Offset.zero).dy;
    }
  }

  double _dismissTargetOffset() {
    final effectiveHeight = _toastHeight > 0 ? _toastHeight : 72.0;
    // Include the SafeArea inset and host padding. Moving only by the toast's
    // own height leaves a visible strip at the top on tablets with a larger
    // status-bar inset.
    return -(_toastTop + effectiveHeight + 24);
  }

  Future<void> _hide({bool animateSwipeAway = false}) async {
    if (!mounted || _isHiding) return;
    _isHiding = true;

    // Keep a swiped toast near the release point and fade it away. It is
    // removed from the overlay immediately after the reverse animation, so it
    // cannot remain invisibly attached to the top edge of the screen.
    if (animateSwipeAway) {
      setState(() {
        _isDragging = false;
        _dragOffsetY = _dismissTargetOffset();
      });
    }
    try {
      await _controller.reverse().orCancel;
    } on TickerCanceled {
      // The immediate-removal fallback can dispose this widget while its
      // swipe animation is running. The owning dismiss() still performs its
      // idempotent Overlay cleanup in finally.
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_isHiding || _trackedPointer != null) return;
    _updateToastMetrics();
    _trackedPointer = event.pointer;
    _pointerStartY = event.position.dy;
    _pointerDismissTriggered = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_isHiding ||
        _trackedPointer != event.pointer ||
        _pointerDismissTriggered) {
      return;
    }
    final startY = _pointerStartY;
    if (startY == null || startY - event.position.dy < _quickSwipeDistance) {
      return;
    }
    _pointerDismissTriggered = true;
    unawaited(AppToast.dismiss(fromSwipe: true));
  }

  void _clearTrackedPointer(PointerEvent event) {
    if (_trackedPointer != event.pointer) return;
    _trackedPointer = null;
    _pointerStartY = null;
    _pointerDismissTriggered = false;
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_isHiding) return;
    if (details.delta.dy < 0) {
      _hasUpwardDrag = true;
    }
    // 以 toast 实际高度作为向上拖动的上限，保证整条通知都能被完整拖出
    // 屏幕，而不是只有上半部分能划出去、下半部分卡在屏幕顶端。
    final maxUpward = _dismissTargetOffset();
    final nextOffset = (_dragOffsetY + details.delta.dy).clamp(maxUpward, 0.0);
    if (nextOffset == _dragOffsetY) return;
    setState(() {
      _isDragging = true;
      _dragOffsetY = nextOffset;
    });
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    if (_isHiding) return;
    final velocity = details.primaryVelocity ?? 0;
    // Any intentional upward movement dismisses every AppToast variant. Do
    // not require a distance/velocity threshold that can leave a toast stuck.
    final shouldDismiss = _hasUpwardDrag || velocity < 0;
    if (shouldDismiss) {
      AppToast.dismiss(fromSwipe: true);
      return;
    }
    _hasUpwardDrag = false;
    if (_dragOffsetY == 0 && !_isDragging) return;
    setState(() {
      _isDragging = false;
      _dragOffsetY = 0;
    });
  }

  void _handleVerticalDragCancel() {
    if (_isHiding) return;
    if (_hasUpwardDrag) {
      unawaited(AppToast.dismiss(fromSwipe: true));
      return;
    }
    if (!_isDragging && _dragOffsetY == 0) return;
    _hasUpwardDrag = false;
    setState(() {
      _isDragging = false;
      _dragOffsetY = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _clearTrackedPointer,
      onPointerCancel: _clearTrackedPointer,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: _handleVerticalDragUpdate,
        onVerticalDragEnd: _handleVerticalDragEnd,
        onVerticalDragCancel: _handleVerticalDragCancel,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _dragOffsetY),
          duration: _isDragging
              ? Duration.zero
              : const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          builder: (context, dragOffsetY, child) {
            final dragProgress = (-dragOffsetY / 120).clamp(0.0, 1.0);
            final animatedOpacity = 1 - (dragProgress * 0.32);
            final animatedScale = 1 - (dragProgress * 0.02);

            return Transform.translate(
              offset: Offset(0, dragOffsetY),
              child: Transform.scale(
                scale: animatedScale,
                alignment: Alignment.topCenter,
                child: Opacity(opacity: animatedOpacity, child: child),
              ),
            );
          },
          child: FadeTransition(
            opacity: _opacity,
            child: SlideTransition(
              position: _slide,
              child: ScaleTransition(
                scale: _scale,
                alignment: Alignment.topCenter,
                child: KeyedSubtree(key: _toastKey, child: widget.child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastOverlayController {
  final Future<void> Function({bool animateSwipeAway}) hide;

  _ToastOverlayController(this.hide);
}

class _ToastContent extends StatelessWidget {
  final String message;
  final AppToastType type;
  final bool showSpinner;
  final AppToastAction? action;
  final double? progress;

  const _ToastContent({
    required this.message,
    required this.type,
    required this.showSpinner,
    required this.action,
    this.progress,
  });

  Color _accentColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (type) {
      case AppToastType.success:
        return const Color(0xFF62D394);
      case AppToastType.error:
        return scheme.error;
      case AppToastType.info:
        return const Color(0xFF8BC3FF);
    }
  }

  IconData _iconData() {
    switch (type) {
      case AppToastType.success:
        return Icons.check_rounded;
      case AppToastType.error:
        return Icons.error_outline_rounded;
      case AppToastType.info:
        return Icons.info_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _accentColor(context);
    final size = MediaQuery.sizeOf(context);
    final scale = (size.shortestSide / 390).clamp(0.9, 1.16);
    final maxWidth = size.width * 0.68;
    final isDark = theme.brightness == Brightness.dark;
    final backgroundColor = isDark
        ? const Color(0xFF1E1F22).withValues(alpha: 0.78)
        : Colors.white.withValues(alpha: 0.88);
    final textColor = theme.colorScheme.onSurface.withValues(alpha: 0.9);
    final iconSize = 17.5 * scale;
    final iconContainerSize = 27.5 * scale;
    final basePadding = 13.5 * scale;
    final verticalPadding = 10.5 * scale;
    final gap = 10 * scale;
    final fontSize = 13.6 * scale;
    final actionFontSize = 12.9 * scale;
    final hasProgress = progress != null;
    final progressValue = progress?.clamp(0.0, 1.0).toDouble();
    final progressText = progressValue == null
        ? null
        : '${(progressValue * 100).round()}%';

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: IntrinsicWidth(
        child: Material(
          color: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18 * scale),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(18 * scale),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.2),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.18 : 0.08,
                      ),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: basePadding,
                    vertical: verticalPadding,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: iconContainerSize,
                            height: iconContainerSize,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            alignment: Alignment.center,
                            child: hasProgress && progressValue != null
                                ? Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      SizedBox(
                                        width: iconContainerSize,
                                        height: iconContainerSize,
                                        child: CircularProgressIndicator(
                                          value: progressValue,
                                          strokeWidth: 2.1,
                                          backgroundColor: accent.withValues(
                                            alpha: 0.18,
                                          ),
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                accent,
                                              ),
                                        ),
                                      ),
                                      Text(
                                        progressText!,
                                        style: TextStyle(
                                          fontSize: 8.4 * scale,
                                          fontWeight: FontWeight.w700,
                                          color: accent,
                                        ),
                                      ),
                                    ],
                                  )
                                : showSpinner
                                ? SizedBox(
                                    width: iconSize,
                                    height: iconSize,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.1,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        accent,
                                      ),
                                    ),
                                  )
                                : Icon(
                                    _iconData(),
                                    size: iconSize,
                                    color: accent,
                                  ),
                          ),
                          SizedBox(width: gap),
                          Flexible(
                            fit: FlexFit.loose,
                            child: Text(
                              message,
                              style: TextStyle(
                                fontSize: fontSize,
                                height: 1.28,
                                fontWeight: FontWeight.w500,
                                color: textColor,
                              ),
                              maxLines: hasProgress
                                  ? 3
                                  : (action == null ? 2 : 3),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (action != null) ...[
                            SizedBox(width: gap * 0.85),
                            DesktopButtonClickRegion(child: TextButton(
                              onPressed: () {
                                AppToast.dismiss();
                                action!.onPressed();
                              },
                              style: TextButton.styleFrom(
                                minimumSize: Size.zero,
                                padding: EdgeInsets.symmetric(
                                  horizontal: 11.5 * scale,
                                  vertical: 5.5 * scale,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                foregroundColor: accent,
                                backgroundColor: accent.withValues(alpha: 0.12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                              child: Text(
                                action!.label,
                                style: TextStyle(
                                  fontSize: actionFontSize,
                                  fontWeight: FontWeight.w600,
                                  color: accent,
                                ),
                              ),
                            )),
                          ],
                        ],
                      ),
                      if (hasProgress && progressValue != null) ...[
                        SizedBox(height: 8 * scale),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: progressValue,
                            minHeight: 4 * scale,
                            backgroundColor: accent.withValues(alpha: 0.14),
                            valueColor: AlwaysStoppedAnimation<Color>(accent),
                          ),
                        ),
                      ],
                    ],
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

class _ToastViewData {
  final String message;
  final AppToastType type;
  final bool showSpinner;
  final AppToastAction? action;
  final double? progress;

  const _ToastViewData({
    required this.message,
    required this.type,
    required this.showSpinner,
    this.action,
    this.progress,
  });

  _ToastViewData copyWith({
    String? message,
    AppToastType? type,
    bool? showSpinner,
    AppToastAction? action,
    double? progress,
  }) {
    return _ToastViewData(
      message: message ?? this.message,
      type: type ?? this.type,
      showSpinner: showSpinner ?? this.showSpinner,
      action: action,
      progress: progress,
    );
  }
}
