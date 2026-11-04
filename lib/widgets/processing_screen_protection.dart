import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import '../services/app_wakelock_coordinator.dart';
import '../models/processing_screen_protection_timing.dart';
import '../utils/page_shortcut_keys.dart';

/// Shared by all processing wake-lock owners. This is an overlay, not a route.
class ProcessingScreenProtection extends StatefulWidget {
  const ProcessingScreenProtection({
    super.key,
    required this.enabled,
    required this.child,
    this.observer,
    this.idleDelay = const Duration(
      seconds: ProcessingScreenProtectionTiming.defaultSeconds,
    ),
    this.playbackActive = false,
    this.onDisableRequested,
  });

  final bool enabled;
  final Widget child;
  final ProtectionNavigatorObserver? observer;
  final Duration idleDelay;
  final bool playbackActive;
  final Future<void> Function(BuildContext context)? onDisableRequested;
  static final navigationObserver = ProtectionNavigatorObserver();

  @override
  State<ProcessingScreenProtection> createState() => _ProtectionState();
}

/// A local history entry consumes system Back without pushing a screen.
/// Navigation by the application always dismisses the protection overlay.
class ProtectionNavigatorObserver extends NavigatorObserver {
  final changes = ValueNotifier<int>(0);
  final _routes = <Route<dynamic>>[];
  ModalRoute<dynamic>? get currentRoute =>
      _routes.lastOrNull is ModalRoute<dynamic>
      ? _routes.last as ModalRoute<dynamic>
      : null;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    changes.value++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    changes.value++;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    changes.value++;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
    changes.value++;
  }
}

class _ProtectionState extends State<ProcessingScreenProtection>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Timer? _idle;
  Timer? _sample;
  Timer? _move;
  Timer? _relocate;
  LocalHistoryEntry? _history;
  bool _disposing = false;
  bool _visible = false;
  bool _dimmed = false;
  bool _foreground = true;
  bool _eligible = false;
  bool _dialogOpen = false;
  bool _scrolling = false;
  int _position = 0;
  int _pointers = 0;
  late final _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  late final _fade = CurvedAnimation(
    parent: _entrance,
    curve: Curves.easeOutCubic,
  );
  List<String> _details = const [];
  final _swallowedKeys = <PhysicalKeyboardKey>{};
  final _auxiliaryPointers = <int>{};
  ProtectionNavigatorObserver get _observer =>
      widget.observer ?? ProcessingScreenProtection.navigationObserver;

  static const _positions = [
    Alignment(-.72, -.72),
    Alignment(.72, .72),
    Alignment(.72, -.65),
    Alignment(-.72, .65),
    Alignment(0, -.85),
    Alignment(0, .85),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_key);
    FocusManager.instance.addListener(_focusChanged);
    AppWakelockCoordinator.changes.addListener(_changed);
    _observer.changes.addListener(_navigation);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _refresh();
  }

  @override
  void didUpdateWidget(ProcessingScreenProtection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.observer != widget.observer) {
      (oldWidget.observer ?? ProcessingScreenProtection.navigationObserver)
          .changes
          .removeListener(_navigation);
      _observer.changes.addListener(_navigation);
    }
    _refresh();
    if (oldWidget.idleDelay != widget.idleDelay) _restartIdle();
  }

  void _changed() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      scheduleMicrotask(() {
        if (mounted) _refresh();
      });
    } else if (mounted) {
      _refresh();
    }
  }

  void _navigation() => scheduleMicrotask(() {
    if (mounted) {
      _scrolling = false;
      _dismiss();
    }
  });

  void _focusChanged() {
    if (mounted && !_disposing && !_visible) _restartIdle();
  }

  void _refresh() {
    final eligible =
        widget.enabled &&
        _foreground &&
        !widget.playbackActive &&
        AppWakelockCoordinator.canProtect;
    if (_eligible == eligible) return;
    _eligible = eligible;
    if (!eligible) {
      _dismiss();
    } else {
      _restartIdle();
    }
  }

  void _restartIdle() {
    _idle?.cancel();
    if (_disposing) return;
    if (_eligible &&
        !_visible &&
        !_dialogOpen &&
        !_scrolling &&
        _pointers == 0 &&
        !isEditableTextFocused() &&
        _observer.currentRoute is PageRoute &&
        HardwareKeyboard.instance.physicalKeysPressed.isEmpty) {
      _idle = Timer(widget.idleDelay, _enter);
    }
  }

  void _enter() {
    if (!mounted ||
        !_eligible ||
        _visible ||
        !widget.enabled ||
        widget.playbackActive ||
        !AppWakelockCoordinator.canProtect ||
        _dialogOpen ||
        _scrolling ||
        _pointers != 0 ||
        _observer.currentRoute is! PageRoute) {
      return;
    }
    // A focused editor or assistive navigation should not be interrupted.
    if (WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .accessibleNavigation ||
        isEditableTextFocused() ||
        HardwareKeyboard.instance.physicalKeysPressed.isNotEmpty ||
        (MediaQuery.maybeOf(context)?.viewInsets.bottom ?? 0) > 0) {
      _restartIdle();
      return;
    }
    _details = AppWakelockCoordinator.protectionDetails();
    _history = LocalHistoryEntry(
      onRemove: () {
        _history = null;
        if (mounted && !_disposing) _dismiss();
      },
    );
    final route = _observer.currentRoute;
    if (route != null) {
      route.addLocalHistoryEntry(_history!);
    } else {
      _history = null;
    }
    setState(() => _visible = true);
    if (WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations ||
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
      _entrance.value = 1;
    } else {
      _entrance.forward(from: 0);
    }
    _sample = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() => _details = AppWakelockCoordinator.protectionDetails());
    });
    _move = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() => _dimmed = true);
      _relocate?.cancel();
      _relocate = Timer(const Duration(seconds: 2), () {
        if (!mounted || !_visible) return;
        setState(() {
          _position = (_position + 1) % _positions.length;
          _dimmed = false;
        });
      });
    });
  }

  void _dismiss() {
    _entrance.stop();
    _sample?.cancel();
    _move?.cancel();
    _relocate?.cancel();
    final history = _history;
    _history = null;
    history?.remove();
    if (_visible && mounted) setState(() => _visible = false);
    _dimmed = false;
    _restartIdle();
  }

  Future<void> _requestDisable() async {
    final request = widget.onDisableRequested;
    final dialogContext = _observer.navigator?.overlay?.context;
    if (_dialogOpen || request == null || dialogContext == null) return;
    _dialogOpen = true;
    _dismiss();
    try {
      await request(dialogContext);
    } finally {
      _dialogOpen = false;
      if (mounted) {
        _refresh();
        _restartIdle();
      }
    }
  }

  bool _key(KeyEvent event) {
    if (_visible) {
      if (event is! KeyUpEvent) _swallowedKeys.add(event.physicalKey);
      _dismiss();
      return true;
    }
    if (_swallowedKeys.contains(event.physicalKey)) {
      if (event is KeyUpEvent) _swallowedKeys.remove(event.physicalKey);
      _restartIdle();
      return true;
    }
    _restartIdle();
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _pointers = 0;
    _auxiliaryPointers.clear();
    _scrolling = false;
    _refresh();
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .accessibleNavigation) {
      _dismiss();
    }
  }

  @override
  void dispose() {
    _idle?.cancel();
    _sample?.cancel();
    _move?.cancel();
    _relocate?.cancel();
    // Detach before removing history; its callback must not re-arm a timer.
    _disposing = true;
    _history?.remove();
    _observer.changes.removeListener(_navigation);
    AppWakelockCoordinator.changes.removeListener(_changed);
    HardwareKeyboard.instance.removeHandler(_key);
    FocusManager.instance.removeListener(_focusChanged);
    WidgetsBinding.instance.removeObserver(this);
    _fade.dispose();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        _pointers++;
        _idle?.cancel();
        if (_visible && event.buttons != kPrimaryButton) {
          _auxiliaryPointers.add(event.pointer);
        }
      },
      onPointerUp: (event) {
        _pointers = (_pointers - 1).clamp(0, 100);
        if (_auxiliaryPointers.remove(event.pointer) && _visible) _dismiss();
        _restartIdle();
      },
      onPointerCancel: (_) {
        _pointers = 0;
        _auxiliaryPointers.clear();
        _restartIdle();
      },
      onPointerHover: (_) => _restartIdle(),
      onPointerSignal: (_) => _visible ? _dismiss() : _restartIdle(),
      onPointerPanZoomStart: (_) {
        _pointers++;
        _idle?.cancel();
      },
      onPointerPanZoomEnd: (_) {
        _pointers = (_pointers - 1).clamp(0, 100);
        _restartIdle();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: _visible,
            child: ExcludeSemantics(
              excluding: _visible,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (!_visible) {
                    if (notification is ScrollStartNotification) {
                      _scrolling = true;
                    } else if (notification is ScrollEndNotification) {
                      _scrolling = false;
                    }
                    _restartIdle();
                  }
                  return false;
                },
                child: widget.child,
              ),
            ),
          ),
          if (_visible)
            Positioned.fill(
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: const SystemUiOverlayStyle(
                  statusBarColor: Colors.black,
                  systemNavigationBarColor: Colors.black,
                  systemNavigationBarDividerColor: Colors.black,
                  statusBarIconBrightness: Brightness.dark,
                  systemNavigationBarIconBrightness: Brightness.dark,
                  systemStatusBarContrastEnforced: false,
                  systemNavigationBarContrastEnforced: false,
                ),
                child: FadeTransition(
                  key: const ValueKey('processing-protection-entrance'),
                  opacity: _fade,
                  child: ColoredBox(
                    key: const ValueKey('processing-screen-protection'),
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned.fill(
                          child: Listener(
                            behavior: HitTestBehavior.opaque,
                            // Capture the entire first pointer sequence.
                            onPointerUp: (_) => _dismiss(),
                            onPointerSignal: (_) => _dismiss(),
                            child: Semantics(
                              button: true,
                              label: '屏幕保护，点击退出',
                              onTap: _dismiss,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                        SafeArea(
                          minimum: const EdgeInsets.all(24),
                          child: Align(
                            alignment: _positions[_position],
                            child: AnimatedOpacity(
                              opacity: _dimmed ? 0 : 1,
                              duration: const Duration(milliseconds: 600),
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, .08),
                                  end: Offset.zero,
                                ).animate(_fade),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _dismiss,
                                  onSecondaryTap: _dismiss,
                                  child: ProtectionReadout(
                                    details: _details,
                                    onDisableRequested:
                                        widget.onDisableRequested == null
                                        ? null
                                        : _requestDisable,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Fixed geometry and tabular digits keep progress updates from shifting text.
class ProtectionReadout extends StatelessWidget {
  const ProtectionReadout({
    super.key,
    required this.details,
    this.onDisableRequested,
  });
  final List<String> details;
  final VoidCallback? onDisableRequested;

  @override
  Widget build(BuildContext context) {
    final parts = (details.firstOrNull ?? '任务处理 · 进行中').split(' · ');
    final label = parts.first;
    final value = parts.length > 1 ? parts[1] : '处理中';
    final secondary = details.length > 1
        ? '另有 ${details.length - 1} 类任务正在处理'
        : parts.length > 2
        ? parts[2]
        : '任务持续运行中';
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: 256,
        height: onDisableRequested == null ? 168 : 240,
        child: DefaultTextStyle(
          style: TextStyle(
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
            color: Color(0xFF707070),
            fontSize: 13,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            child: Column(
              children: [
                SizedBox(height: 26, child: Text(label)),
                SizedBox(
                  height: 64,
                  child: Center(
                    child: Text(
                      value,
                      style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w300,
                        color: Color(0xFF808080),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 28, child: Text(secondary)),
                const SizedBox(height: 20),
                const Text(
                  '点击空白处或进度退出 · 按键 / 返回',
                  style: TextStyle(fontSize: 11, color: Color(0xFF686868)),
                ),
                if (onDisableRequested != null) ...[
                  const SizedBox(height: 8),
                  Material(
                    color: Colors.transparent,
                    child: Center(
                      child: MergeSemantics(
                        child: Semantics(
                          checked: false,
                          child: InkWell(
                            key: const ValueKey(
                              'processing-protection-disable',
                            ),
                            borderRadius: BorderRadius.circular(8),
                            onTap: onDisableRequested,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.check_box_outline_blank_rounded,
                                      key: ValueKey(
                                        'processing-protection-disable-icon',
                                      ),
                                      size: 18,
                                      color: Color(0xFF707070),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      '关闭防烧屏',
                                      key: ValueKey(
                                        'processing-protection-disable-label',
                                      ),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF808080),
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
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
