import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import '../services/app_wakelock_coordinator.dart';

/// Shared by all processing wake-lock owners. This is an overlay, not a route.
class ProcessingScreenProtection extends StatefulWidget {
  const ProcessingScreenProtection({
    super.key,
    required this.enabled,
    required this.child,
    this.observer,
  });

  final bool enabled;
  final Widget child;
  final ProtectionNavigatorObserver? observer;
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
    with WidgetsBindingObserver {
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
  int _position = 0;
  int _pointers = 0;
  List<String> _details = const [];
  final _swallowedKeys = <PhysicalKeyboardKey>{};
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
    if (mounted) _dismiss();
  });

  void _refresh() {
    final eligible =
        widget.enabled && _foreground && AppWakelockCoordinator.canProtect;
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
    if (_eligible &&
        !_visible &&
        _pointers == 0 &&
        HardwareKeyboard.instance.physicalKeysPressed.isEmpty) {
      _idle = Timer(const Duration(seconds: 10), _enter);
    }
  }

  void _enter() {
    if (!mounted || !_eligible || _visible || _pointers != 0) return;
    // A focused editor or assistive navigation should not be interrupted.
    if (WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .accessibleNavigation ||
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        _pointers++;
        _idle?.cancel();
      },
      onPointerUp: (_) {
        _pointers = (_pointers - 1).clamp(0, 100);
        _restartIdle();
      },
      onPointerCancel: (_) {
        _pointers = 0;
        _restartIdle();
      },
      onPointerHover: (_) => _restartIdle(),
      onPointerSignal: (_) => _restartIdle(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: _visible,
            child: ExcludeSemantics(excluding: _visible, child: widget.child),
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
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  // Dismiss on release so the entire first pointer sequence is
                  // captured here, including mouse back/secondary buttons.
                  onPointerUp: (_) => _dismiss(),
                  onPointerSignal: (_) => _dismiss(),
                  onPointerHover: (event) {
                    if (event.delta.distance > 3) _dismiss();
                  },
                  child: Semantics(
                    button: true,
                    label: '屏幕保护，点击退出',
                    onTap: _dismiss,
                    child: ColoredBox(
                      key: const ValueKey('processing-screen-protection'),
                      color: Colors.black,
                      child: SafeArea(
                        minimum: const EdgeInsets.all(24),
                        child: Align(
                          alignment: _positions[_position],
                          child: AnimatedOpacity(
                            opacity: _dimmed ? 0 : 1,
                            duration: const Duration(milliseconds: 600),
                            child: ProtectionReadout(details: _details),
                          ),
                        ),
                      ),
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
  const ProtectionReadout({super.key, required this.details});
  final List<String> details;

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
        height: 168,
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
                  '点击任意位置退出 · 按键 / 返回',
                  style: TextStyle(fontSize: 11, color: Color(0xFF686868)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
