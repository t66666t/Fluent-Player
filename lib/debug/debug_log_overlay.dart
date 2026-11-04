import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/settings_service.dart';
import '../utils/app_toast.dart';
import '../widgets/stable_width_label.dart';
import 'debug_log_buffer.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const double _ballDiameter = 48;
const double _dockSnapDistance = 64;
const double _tapSlop = 10;

EdgeInsets _ballObstructionPadding(MediaQueryData media) {
  return EdgeInsets.fromLTRB(
    media.viewPadding.left,
    media.viewPadding.top,
    media.viewPadding.right,
    math.max(media.viewPadding.bottom, media.viewInsets.bottom),
  );
}

enum _DockEdge { left, right, top, bottom }

/// Registers the system-back handler before [WidgetsApp] does.
///
/// [WidgetsBinding.handlePopRoute] walks observers in registration order.
/// Installing this first lets the console consume Android back before a page
/// [PopScope] or the navigator sees it.
void installDebugLogBackHandler() {
  if (_backHandlerInstalled) return;
  _backHandlerInstalled = true;
  WidgetsBinding.instance.addObserver(_DebugLogBackObserver());
}

bool _backHandlerInstalled = false;

/// Long-press on the library settings button. The choice is stored with the
/// other settings and survives restarts.
Future<void> toggleDebugDeveloperMode(BuildContext context) async {
  final settings = Provider.of<SettingsService>(context, listen: false);
  final next = !settings.developerMode;
  await settings.toggleDeveloperMode();
  if (!context.mounted) return;
  AppToast.show(next ? '开发者模式已开启' : '开发者模式已关闭', type: AppToastType.info);
}

/// Floating debug ball and the terminal page it opens.
class DebugLogOverlay extends StatefulWidget {
  const DebugLogOverlay({super.key, required this.child});

  final Widget child;

  static bool isOpen = false;
  static void closePanel() => _closePanel?.call();
  static void Function()? _closePanel;

  @override
  State<DebugLogOverlay> createState() => _DebugLogOverlayState();
}

class _DebugLogOverlayState extends State<DebugLogOverlay> {
  bool _panelOpen = false;
  bool _docked = true;
  bool _dragging = false;
  _DockEdge _edge = _DockEdge.right;
  double _along = 0.5;
  double _freeX = 0.5;
  double _freeY = 0.5;
  double _panDistance = 0;
  bool _dockedAtPanStart = true;
  Offset _dragCenter = Offset.zero;

  ModalRoute<dynamic>? _popRoute;
  _DebugLogPopEntry? _popEntry;

  @override
  void initState() {
    super.initState();
    DebugLogOverlay._closePanel = _closePanel;
  }

  @override
  void dispose() {
    if (DebugLogOverlay._closePanel == _closePanel) {
      DebugLogOverlay._closePanel = null;
    }
    _unregisterPopBlock();
    DebugLogOverlay.isOpen = false;
    DebugLogBuffer.instance.setPanelVisible(false);
    super.dispose();
  }

  void _openPanel() {
    if (_panelOpen) return;
    _registerPopBlock();
    DebugLogBuffer.instance.setPanelVisible(true);
    DebugLogOverlay.isOpen = true;
    setState(() => _panelOpen = true);
  }

  void _closePanel() {
    if (!_panelOpen) return;
    _panelOpen = false;
    DebugLogOverlay.isOpen = false;
    _unregisterPopBlock();
    DebugLogBuffer.instance.setPanelVisible(false);
    if (mounted) setState(() {});
  }

  void _registerPopBlock() {
    _unregisterPopBlock();
    final navigator = AppToast.navigatorKey.currentState;
    if (navigator == null) return;
    ModalRoute<dynamic>? route;
    navigator.popUntil((candidate) {
      if (candidate is ModalRoute<dynamic>) route = candidate;
      return true;
    });
    final modal = route;
    if (modal == null || !modal.isActive) return;
    final entry = _DebugLogPopEntry();
    modal.registerPopEntry(entry);
    _popRoute = modal;
    _popEntry = entry;
  }

  void _unregisterPopBlock() {
    final route = _popRoute;
    final entry = _popEntry;
    _popRoute = null;
    _popEntry = null;
    if (route == null || entry == null) return;
    if (route.isActive) {
      route.unregisterPopEntry(entry);
    }
    entry.dispose();
  }

  Offset _resolvedCenter(Size size, EdgeInsets padding) {
    final safe = _safeRect(size, padding);
    if (!_docked) {
      return _clampFullyInside(
        Offset(_freeX * size.width, _freeY * size.height),
        safe,
      );
    }
    switch (_edge) {
      case _DockEdge.left:
        return Offset(safe.left, _crossCenter(safe.top, safe.bottom, _along));
      case _DockEdge.right:
        return Offset(safe.right, _crossCenter(safe.top, safe.bottom, _along));
      case _DockEdge.top:
        return Offset(_crossCenter(safe.left, safe.right, _along), safe.top);
      case _DockEdge.bottom:
        return Offset(_crossCenter(safe.left, safe.right, _along), safe.bottom);
    }
  }

  Rect _safeRect(Size size, EdgeInsets padding) {
    final left = math.min(math.max(padding.left, 0.0), size.width);
    final top = math.min(math.max(padding.top, 0.0), size.height);
    final right = math.min(
      math.max(size.width - padding.right, left),
      size.width,
    );
    final bottom = math.min(
      math.max(size.height - padding.bottom, top),
      size.height,
    );
    return Rect.fromLTRB(left, top, right, bottom);
  }

  double _crossCenter(double start, double end, double along) {
    final extent = end - start;
    if (extent <= _ballDiameter) return (start + end) / 2;
    final radius = _ballDiameter / 2;
    return start + radius + along.clamp(0.0, 1.0) * (extent - _ballDiameter);
  }

  double _alongFor(double crossCenter, double start, double end) {
    final extent = end - start;
    if (extent <= _ballDiameter) return 0.5;
    final radius = _ballDiameter / 2;
    return ((crossCenter - start - radius) / (extent - _ballDiameter)).clamp(
      0.0,
      1.0,
    );
  }

  Offset _clampFullyInside(Offset center, Rect safe) {
    final radius = _ballDiameter / 2;
    final minX = safe.left + radius;
    final maxX = safe.right - radius;
    final minY = safe.top + radius;
    final maxY = safe.bottom - radius;
    if (minX > maxX || minY > maxY) return safe.center;
    return Offset(center.dx.clamp(minX, maxX), center.dy.clamp(minY, maxY));
  }

  Offset _clampDuringDrag(Offset center, Rect safe) {
    return Offset(
      center.dx.clamp(safe.left, math.max(safe.left, safe.right)),
      center.dy.clamp(safe.top, math.max(safe.top, safe.bottom)),
    );
  }

  void _onPanStart(Size size, EdgeInsets padding) {
    _panDistance = 0;
    _dragging = false;
    _dockedAtPanStart = _docked;
    _dragCenter = _resolvedCenter(size, padding);
  }

  void _onPanUpdate(DragUpdateDetails details, Size size, EdgeInsets padding) {
    _panDistance += details.delta.distance;
    _dragCenter = _clampDuringDrag(
      _dragCenter + details.delta,
      _safeRect(size, padding),
    );
    if (_panDistance < _tapSlop) return;
    _dragging = true;
    setState(() {});
  }

  void _onPanEnd(Size size, EdgeInsets padding) {
    final tapped = _panDistance < _tapSlop;
    final center = _dragging ? _dragCenter : _resolvedCenter(size, padding);
    _dragging = false;
    if (tapped) {
      if (!_dockedAtPanStart) _openPanel();
      setState(() {});
      return;
    }
    _settle(center, size, padding);
  }

  void _settle(Offset center, Size size, EdgeInsets padding) {
    final safe = _safeRect(size, padding);
    final distances = <_DockEdge, double>{
      _DockEdge.left: center.dx - safe.left,
      _DockEdge.right: safe.right - center.dx,
      _DockEdge.top: center.dy - safe.top,
      _DockEdge.bottom: safe.bottom - center.dy,
    };
    _DockEdge? nearest;
    var nearestDistance = double.infinity;
    for (final entry in distances.entries) {
      if (entry.value < nearestDistance) {
        nearest = entry.key;
        nearestDistance = entry.value;
      }
    }
    if (nearest == null || nearestDistance > _dockSnapDistance) {
      final inside = _clampFullyInside(center, safe);
      _docked = false;
      _freeX = size.width == 0 ? 0.5 : inside.dx / size.width;
      _freeY = size.height == 0 ? 0.5 : inside.dy / size.height;
      setState(() {});
      return;
    }
    _docked = true;
    _edge = nearest;
    switch (nearest) {
      case _DockEdge.left:
      case _DockEdge.right:
        _along = _alongFor(center.dy, safe.top, safe.bottom);
      case _DockEdge.top:
      case _DockEdge.bottom:
        _along = _alongFor(center.dx, safe.left, safe.right);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final developerMode = context.select<SettingsService, bool>(
      (settings) => settings.developerMode,
    );
    if (!developerMode && _panelOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_panelOpen) return;
        final stillOff = !Provider.of<SettingsService>(
          context,
          listen: false,
        ).developerMode;
        if (stillOff) _closePanel();
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final padding = _ballObstructionPadding(MediaQuery.of(context));
        final center = _dragging ? _dragCenter : _resolvedCenter(size, padding);
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            widget.child,
            if (developerMode && _panelOpen)
              const Positioned.fill(child: _DebugLogPanel())
            else if (developerMode)
              Positioned(
                left: center.dx - _ballDiameter / 2,
                top: center.dy - _ballDiameter / 2,
                width: _ballDiameter,
                height: _ballDiameter,
                child: Opacity(
                  opacity: _dragging || !_docked ? 1 : 0.35,
                  child: GestureDetector(
                    onPanStart: (_) => _onPanStart(size, padding),
                    onPanUpdate: (details) =>
                        _onPanUpdate(details, size, padding),
                    onPanEnd: (_) => _onPanEnd(size, padding),
                    onPanCancel: () => _onPanEnd(size, padding),
                    child: const _DebugBallFace(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DebugBallFace extends StatelessWidget {
  const _DebugBallFace();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '调试记录',
      child: DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF2F6FED),
          boxShadow: [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 6,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: const Icon(Icons.terminal, size: 22, color: Colors.white),
      ),
    );
  }
}

class _DebugLogPanel extends StatefulWidget {
  const _DebugLogPanel();

  @override
  State<_DebugLogPanel> createState() => _DebugLogPanelState();
}

class _DebugLogPanelState extends State<_DebugLogPanel> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey<SelectionAreaState> _selectionKey =
      GlobalKey<SelectionAreaState>();
  final FocusNode _selectionFocus = FocusNode();
  final DebugLogBuffer _buffer = DebugLogBuffer.instance;
  Timer? _edgeTimer;
  Timer? _copiedTimer;
  bool _follow = true;
  bool _hasTextSelection = false;
  bool _copied = false;
  String? _frozen;
  String _selectedText = '';
  SelectableRegionSelectionStatus _selectionStatus =
      SelectableRegionSelectionStatus.changing;
  ScrollableState? _selectionScrollable;
  OverlayState? _textOverlay;
  OverlayEntry? _toolbarEntry;
  bool _toolbarInsertScheduled = false;
  bool _touchToolbar = false;
  Offset? _toolbarTouchAnchor;
  final Set<int> _downTouchPointers = <int>{};
  final Map<int, Offset> _downTouchPositions = <int, Offset>{};
  int? _latestDownTouchPointer;
  int? _selectionGesturePointer;
  int? _edgePointer;
  double _edgeScrollPixels = 0;
  int _edgeTickCount = 0;
  bool _handleBindCheckScheduled = false;
  Drag? _shieldPan;
  Offset? _shieldTapDown;
  late final OverlayEntry _logEntry = OverlayEntry(
    builder: (BuildContext context) {
      return _LogOverlayCapture(
        onOverlay: _rememberOverlay,
        child: Stack(
          children: [
            _buildLogScroll(),
            if (_hasTextSelection && _isMobileSelectionPlatform)
              _buildSelectionShield(),
          ],
        ),
      );
    },
  );

  static const double _logHorizontalInset = 28;
  static const double _toolbarHandleClearance = 40;
  static const double _edgeEnterZone = 56;
  static const double _edgeExitZone = 72;
  static const double _edgeMinPixelsPerTick = 2;
  static const double _edgeMaxPixelsPerTick = 6.5;
  static const int _edgeAccelerationDelayTicks = 8;
  static const int _edgeAccelerationTicks = 64;

  bool get _isMobileSelectionPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return true;
      default:
        return false;
    }
  }

  bool get _selectionChanging =>
      _selectionStatus == SelectableRegionSelectionStatus.changing;

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _logEntry.markNeedsBuild();
  }

  @override
  void initState() {
    super.initState();
    _buffer.addListener(_onLogs);
    WidgetsBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
  }

  @override
  void dispose() {
    _buffer.removeListener(_onLogs);
    WidgetsBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _removeToolbar();
    _edgeTimer?.cancel();
    _copiedTimer?.cancel();
    _shieldPan?.cancel();
    _selectionFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onLogs() {
    if (!mounted || _hasTextSelection) return;
    setState(() {});
    if (_follow) _jumpToEnd();
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_follow || _hasTextSelection || !_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      if (!position.hasContentDimensions) return;
      if ((position.pixels - position.maxScrollExtent).abs() <= 1) return;
      try {
        position.jumpTo(position.maxScrollExtent);
      } catch (_) {
        // The viewport can detach between this frame and the jump.
      }
    });
  }

  bool _onScroll(ScrollNotification notification) {
    final dragged =
        notification is ScrollStartNotification &&
            notification.dragDetails != null ||
        notification is ScrollUpdateNotification &&
            notification.dragDetails != null;
    if (dragged ||
        (notification is ScrollEndNotification &&
            notification.dragDetails != null)) {
      _syncFollow();
    }
    return false;
  }

  void _syncFollow() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    _follow = position.maxScrollExtent - position.pixels <= 48;
  }

  void _onSelection(SelectedContent? content) {
    final String nextText = content?.plainText ?? '';
    final bool hasSelection = nextText.isNotEmpty;
    final bool textChanged = nextText != _selectedText;
    _selectedText = nextText;

    if (hasSelection && !_hasTextSelection) {
      _frozen = _buffer.displayText;
      if (_isMobileSelectionPlatform) {
        _touchToolbar = true;
        final int? pointer = _activeTouchPointer();
        if (pointer != null) {
          _toolbarTouchAnchor = _downTouchPositions[pointer];
        }
        _selectionGesturePointer ??= pointer;
      }
      _hasTextSelection = true;
      _hideNativeToolbar();
      if (_touchToolbar) _scheduleToolbar();
      if (mounted) setState(() {});
      return;
    }

    if (hasSelection && textChanged) {
      _hideNativeToolbar();
      _toolbarEntry?.markNeedsBuild();
      _tryBindHandlePointer();
      return;
    }

    if (hasSelection == _hasTextSelection) return;
    _clearSelectionChrome(clearRegion: false);
    if (mounted) setState(() {});
    if (_follow) _jumpToEnd();
  }

  void _onSelectionStatus(SelectableRegionSelectionStatus status) {
    _selectionStatus = status;
    if (status == SelectableRegionSelectionStatus.changing) {
      _tryBindHandlePointer();
    }
  }

  void _clearSelectionChrome({required bool clearRegion}) {
    _hasTextSelection = false;
    _selectedText = '';
    _frozen = null;
    _removeToolbar();
    _stopEdgeScroll();
    _selectionGesturePointer = null;
    _shieldPan?.cancel();
    _shieldPan = null;
    if (!clearRegion) return;
    _selectionKey.currentState?.selectableRegion.clearSelection();
    _selectionFocus.unfocus();
  }

  void _onPointer(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    if (event is PointerDownEvent) {
      _downTouchPointers.add(event.pointer);
      _downTouchPositions[event.pointer] = event.position;
      _latestDownTouchPointer = event.pointer;
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _downTouchPointers.remove(event.pointer);
      _downTouchPositions.remove(event.pointer);
      if (_latestDownTouchPointer == event.pointer) {
        _latestDownTouchPointer = _downTouchPointers.isEmpty
            ? null
            : _downTouchPointers.last;
      }
      if (_selectionGesturePointer == event.pointer) {
        _stopEdgeScroll();
        _selectionGesturePointer = null;
      } else if (_edgePointer == event.pointer) {
        _stopEdgeScroll();
      }
      return;
    }
    if (event is! PointerMoveEvent || !_hasTextSelection) return;
    _downTouchPositions[event.pointer] = event.position;
    if (_selectionGesturePointer == null && _selectionChanging) {
      _selectionGesturePointer = event.pointer;
    }
    if (_selectionGesturePointer == null) {
      _scheduleHandleBindCheck();
    }
    if (event.pointer != _selectionGesturePointer) return;
    _updateEdgeForPointer(event.pointer, event.position);
  }

  int? _activeTouchPointer() {
    final int? latest = _latestDownTouchPointer;
    if (latest != null && _downTouchPointers.contains(latest)) return latest;
    if (_downTouchPointers.isEmpty) return null;
    return _downTouchPointers.last;
  }

  void _scheduleHandleBindCheck() {
    if (_handleBindCheckScheduled) return;
    _handleBindCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleBindCheckScheduled = false;
      if (!mounted) return;
      _tryBindHandlePointer();
    });
  }

  void _tryBindHandlePointer() {
    if (!_hasTextSelection ||
        _selectionGesturePointer != null ||
        !_selectionChanging) {
      return;
    }
    final int? pointer = _latestDownTouchPointer;
    if (pointer == null || !_downTouchPointers.contains(pointer)) return;
    final Offset? position = _downTouchPositions[pointer];
    if (position == null) return;
    _selectionGesturePointer = pointer;
    _updateEdgeForPointer(pointer, position);
  }

  void _updateEdgeForPointer(int pointer, Offset position) {
    if (pointer != _selectionGesturePointer) return;
    final RenderObject? object = _viewportKey.currentContext
        ?.findRenderObject();
    if (object is! RenderBox || !object.hasSize || object.size.height <= 0) {
      return;
    }
    final Offset local = object.globalToLocal(position);
    final bool wasScrolling = _edgePointer == pointer;
    final double edgeZone = wasScrolling ? _edgeExitZone : _edgeEnterZone;
    final bool horizontallyNear =
        local.dx >= -_edgeEnterZone &&
        local.dx <= object.size.width + _edgeEnterZone;
    final double topPenetration = edgeZone - local.dy;
    final double bottomPenetration = local.dy - (object.size.height - edgeZone);
    double? signedPixels;
    if (horizontallyNear &&
        bottomPenetration > 0 &&
        local.dy > _edgeEnterZone) {
      signedPixels = _edgePixelsForPenetration(
        local.dy - (object.size.height - _edgeEnterZone),
      );
    } else if (horizontallyNear &&
        topPenetration > 0 &&
        local.dy < object.size.height - _edgeEnterZone) {
      signedPixels = -_edgePixelsForPenetration(_edgeEnterZone - local.dy);
    }
    if (signedPixels == null) {
      if (wasScrolling) _stopEdgeScroll();
      return;
    }
    if (signedPixels < 0) _follow = false;
    final int previousDirection = _edgeScrollPixels.sign.toInt();
    final int nextDirection = signedPixels.sign.toInt();
    if (!wasScrolling || previousDirection != nextDirection) {
      _edgeTickCount = 0;
    }
    _edgePointer = pointer;
    _edgeScrollPixels = signedPixels;
    final bool started = _edgeTimer == null;
    _edgeTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _tickEdgeScroll(),
    );
    if (started) _tickEdgeScroll();
  }

  double _edgePixelsForPenetration(double penetration) {
    final double strength = (penetration / _edgeEnterZone).clamp(0.0, 1.0);
    return (_edgeMinPixelsPerTick + 1.5 * strength).clamp(
      _edgeMinPixelsPerTick,
      _edgeMaxPixelsPerTick,
    );
  }

  double get _acceleratedEdgePixels {
    final double progress =
        ((_edgeTickCount - _edgeAccelerationDelayTicks) /
                _edgeAccelerationTicks)
            .clamp(0.0, 1.0);
    final double eased = progress * progress * (3 - 2 * progress);
    final double dwell =
        _edgeMinPixelsPerTick +
        (_edgeMaxPixelsPerTick - _edgeMinPixelsPerTick) * eased;
    final double requested = _edgeScrollPixels.abs();
    return requested > dwell ? requested : dwell;
  }

  void _tickEdgeScroll() {
    if (!mounted ||
        !_hasTextSelection ||
        _edgePointer == null ||
        _selectionGesturePointer == null) {
      return;
    }
    final ScrollableState? scrollable = _selectionScrollable;
    if (scrollable == null || !scrollable.mounted) return;
    try {
      final position = scrollable.position;
      _edgeTickCount++;
      final double direction = _edgeScrollPixels.sign;
      final double target =
          (position.pixels + direction * _acceleratedEdgePixels).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
      if ((target - position.pixels).abs() < precisionErrorTolerance) {
        if (direction > 0) _follow = true;
        _stopEdgeScroll();
        return;
      }
      position.jumpTo(target);
      if (direction > 0 && position.maxScrollExtent - position.pixels <= 48) {
        _follow = true;
      }
    } catch (_) {
      _stopEdgeScroll();
    }
  }

  void _stopEdgeScroll() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _edgePointer = null;
    _edgeScrollPixels = 0;
    _edgeTickCount = 0;
  }

  void _hideNativeToolbar() {
    ContextMenuController.removeAny();
    _selectionKey.currentState?.selectableRegion.hideToolbar(false);
  }

  void _scheduleToolbar() {
    if (_toolbarEntry != null || _toolbarInsertScheduled) {
      _toolbarEntry?.markNeedsBuild();
      return;
    }
    _toolbarInsertScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _toolbarInsertScheduled = false;
      if (!mounted || !_hasTextSelection || !_touchToolbar) return;
      if (_toolbarEntry != null) return;
      final OverlayState? overlay = _textOverlay;
      if (overlay == null) return;
      final entry = OverlayEntry(builder: _buildToolbar);
      _toolbarEntry = entry;
      overlay.insert(entry);
    });
  }

  Widget _buildToolbar(BuildContext context) {
    if (!mounted || !_hasTextSelection || !_touchToolbar) {
      return const SizedBox.shrink();
    }
    final SelectionAreaState? selection = _selectionKey.currentState;
    final RenderObject? viewportObject = _viewportKey.currentContext
        ?.findRenderObject();
    if (selection == null ||
        viewportObject is! RenderBox ||
        !viewportObject.hasSize) {
      return const SizedBox.shrink();
    }
    final Rect viewport =
        viewportObject.localToGlobal(Offset.zero) & viewportObject.size;
    final TextSelectionToolbarAnchors anchors = _toolbarAnchorsFor(
      selection,
      viewport,
    );
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: <ContextMenuButtonItem>[
        if (_selectedText.isNotEmpty)
          ContextMenuButtonItem(
            type: ContextMenuButtonType.copy,
            onPressed: _copySelection,
          ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: _selectAll,
        ),
      ],
    );
  }

  TextSelectionToolbarAnchors _toolbarAnchorsFor(
    SelectionAreaState selection,
    Rect viewport,
  ) {
    TextSelectionToolbarAnchors? nativeAnchors;
    try {
      final TextSelectionToolbarAnchors candidate =
          selection.selectableRegion.contextMenuAnchors;
      if (_isFinite(candidate.primaryAnchor) &&
          (candidate.secondaryAnchor == null ||
              _isFinite(candidate.secondaryAnchor!))) {
        nativeAnchors = candidate;
      }
    } catch (_) {
      // Handle geometry can be between layout passes. The touch point is enough.
    }
    final Offset requested = _toolbarTouchAnchor ?? viewport.center;
    final Offset above =
        nativeAnchors?.primaryAnchor ?? requested - const Offset(0, 24);
    final Offset below =
        nativeAnchors?.secondaryAnchor ?? requested + const Offset(0, 24);
    final double inset = viewport.width < 32 ? 0 : 16;
    double clampX(double dx) =>
        dx.clamp(viewport.left + inset, viewport.right - inset).toDouble();
    // Android handle knobs sit just outside the selection. The toolbar's
    // bottom edge is the upper anchor and its top edge is the lower one, so
    // the gap has to clear those knobs instead of sitting on them.
    return TextSelectionToolbarAnchors(
      primaryAnchor: Offset(
        clampX(above.dx),
        above.dy - _toolbarHandleClearance,
      ),
      secondaryAnchor: Offset(
        clampX(below.dx),
        below.dy + _toolbarHandleClearance,
      ),
    );
  }

  bool _isFinite(Offset value) => value.dx.isFinite && value.dy.isFinite;

  void _removeToolbar() {
    _toolbarInsertScheduled = false;
    _toolbarEntry?.remove();
    _toolbarEntry?.dispose();
    _toolbarEntry = null;
    _touchToolbar = false;
    _toolbarTouchAnchor = null;
  }

  void _copySelection() {
    if (_selectedText.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: _selectedText)));
    _clearSelectionChrome(clearRegion: true);
    if (mounted) setState(() {});
  }

  void _selectAll() {
    final String full = _buffer.displayText;
    if (full.isEmpty) return;
    _selectedText = full;
    _frozen ??= full;
    _touchToolbar = _isMobileSelectionPlatform;
    _hasTextSelection = true;
    _hideNativeToolbar();
    if (_touchToolbar) _scheduleToolbar();
    if (_selectionFocus.canRequestFocus) _selectionFocus.requestFocus();
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasTextSelection) return;
      _selectionKey.currentState?.selectableRegion.selectAll(
        SelectionChangedCause.toolbar,
      );
    });
  }

  Widget _buildContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    if (_isMobileSelectionPlatform) return const SizedBox.shrink();
    return AdaptiveTextSelectionToolbar.selectableRegion(
      selectableRegionState: selectableRegionState,
    );
  }

  void _rememberScrollable(ScrollableState scrollable) {
    _selectionScrollable = scrollable;
  }

  void _rememberOverlay(OverlayState overlay) {
    _textOverlay = overlay;
  }

  void _startShieldPan(DragStartDetails details) {
    _stopEdgeScroll();
    _hideNativeToolbar();
    _shieldPan?.cancel();
    final ScrollableState? scrollable = _selectionScrollable;
    if (scrollable == null || !scrollable.mounted) return;
    try {
      _shieldPan = scrollable.position.drag(details, () {
        _shieldPan = null;
      });
    } catch (_) {
      _shieldPan = null;
    }
  }

  Widget _buildLogScroll() {
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      interactive: true,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: SingleChildScrollView(
          key: _viewportKey,
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(
            _logHorizontalInset,
            8,
            _logHorizontalInset + 12,
            24,
          ),
          child: _LogScrollableCapture(
            onScrollable: _rememberScrollable,
            child: SelectionArea(
              key: _selectionKey,
              focusNode: _selectionFocus,
              contextMenuBuilder: _buildContextMenu,
              onSelectionChanged: _onSelection,
              child: _LogSelectionStatusObserver(
                onStatusChanged: _onSelectionStatus,
                child: Text(
                  _shown.isEmpty ? ' ' : _shown,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: ['Consolas', 'Courier New', 'Menlo'],
                    fontSize: 13,
                    height: 1.4,
                    color: Color(0xFFE6E6E6),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionShield() {
    return Positioned(
      left: 0,
      top: 0,
      right: 20,
      bottom: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => _shieldTapDown = details.globalPosition,
        onTapUp: (details) {
          final Offset? down = _shieldTapDown;
          _shieldTapDown = null;
          if (down != null && (details.globalPosition - down).distance > 18) {
            return;
          }
          _clearSelectionChrome(clearRegion: true);
          if (mounted) setState(() {});
        },
        onTapCancel: () => _shieldTapDown = null,
        onVerticalDragStart: _startShieldPan,
        onVerticalDragUpdate: (details) => _shieldPan?.update(details),
        onVerticalDragEnd: (details) {
          final Drag? drag = _shieldPan;
          _shieldPan = null;
          drag?.end(details);
        },
        onVerticalDragCancel: () {
          _shieldPan?.cancel();
          _shieldPan = null;
        },
      ),
    );
  }

  void _copyAll() {
    final text = _buffer.displayText;
    if (text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  String get _shown {
    if (_hasTextSelection && _frozen != null) return _frozen!;
    return _buffer.displayText;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF161616),
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  const Text(
                    '运行记录',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const Spacer(),
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _copyAll,
                      // 按「复制全部」的宽度排版，提示已复制时按钮不缩。
                      child: StableWidthLabel(
                        _copied ? '已复制' : '复制全部',
                        variants: const ['复制全部', '已复制'],
                      ),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: IconButton(
                      onPressed: DebugLogOverlay.closePanel,
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            Expanded(child: Overlay(initialEntries: [_logEntry])),
          ],
        ),
      ),
    );
  }
}

class _LogOverlayCapture extends StatelessWidget {
  const _LogOverlayCapture({required this.onOverlay, required this.child});

  final ValueChanged<OverlayState> onOverlay;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    onOverlay(Overlay.of(context));
    return child;
  }
}

class _LogScrollableCapture extends StatelessWidget {
  const _LogScrollableCapture({
    required this.onScrollable,
    required this.child,
  });

  final ValueChanged<ScrollableState> onScrollable;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    onScrollable(Scrollable.of(context));
    return child;
  }
}

class _LogSelectionStatusObserver extends StatefulWidget {
  const _LogSelectionStatusObserver({
    required this.onStatusChanged,
    required this.child,
  });

  final ValueChanged<SelectableRegionSelectionStatus> onStatusChanged;
  final Widget child;

  @override
  State<_LogSelectionStatusObserver> createState() =>
      _LogSelectionStatusObserverState();
}

class _LogSelectionStatusObserverState
    extends State<_LogSelectionStatusObserver> {
  ValueListenable<SelectableRegionSelectionStatus>? _notifier;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ValueListenable<SelectableRegionSelectionStatus>? next =
        SelectableRegionSelectionStatusScope.maybeOf(context);
    if (identical(next, _notifier)) return;
    _notifier?.removeListener(_notifyParent);
    _notifier = next;
    _notifier?.addListener(_notifyParent);
    _notifyParent();
  }

  void _notifyParent() {
    final SelectableRegionSelectionStatus? status = _notifier?.value;
    if (status != null) widget.onStatusChanged(status);
  }

  @override
  void dispose() {
    _notifier?.removeListener(_notifyParent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DebugLogBackObserver extends WidgetsBindingObserver {
  @override
  Future<bool> didPopRoute() async {
    if (!DebugLogOverlay.isOpen) return false;
    DebugLogOverlay.closePanel();
    return true;
  }
}

/// Keeps the current route from treating system back as its own pop while the
/// console is open. The route's [PopScope] is not invoked; the back observer
/// closes the console first.
class _DebugLogPopEntry extends PopEntry<void> {
  final ValueNotifier<bool> _canPop = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get canPopNotifier => _canPop;

  @override
  void onPopInvokedWithResult(bool didPop, void result) {
    if (didPop) return;
    DebugLogOverlay.closePanel();
  }

  void dispose() => _canPop.dispose();
}
