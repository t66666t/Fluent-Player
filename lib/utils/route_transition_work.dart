import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Binds optional work to route status without subscribing the whole page to
/// navigator changes. Its child is retained when a menu/page opens or closes.
class RouteTransitionWorkHost extends StatefulWidget {
  const RouteTransitionWorkHost({
    super.key,
    required this.work,
    required this.child,
  });

  final RouteTransitionWork work;
  final Widget child;

  @override
  State<RouteTransitionWorkHost> createState() =>
      _RouteTransitionWorkHostState();
}

class _RouteTransitionWorkHostState extends State<RouteTransitionWorkHost> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.work.bind(ModalRoute.of(context));
  }

  @override
  void didUpdateWidget(RouteTransitionWorkHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.work != widget.work) {
      widget.work.bind(ModalRoute.of(context));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Runs optional page work after its entry and any covering transition settle.
///
/// The owner binds from didChangeDependencies and disposes with its State.
/// Status listeners release work without a timer or a per-frame polling loop.
class RouteTransitionWork {
  final Map<Object, VoidCallback> _pending = {};
  ModalRoute<dynamic>? _route;
  bool _scheduled = false;
  bool _disposed = false;

  void bind(ModalRoute<dynamic>? route) {
    if (_disposed) return;
    if (_route != route) {
      _removeListeners();
      _route = route;
      route?.animation?.addStatusListener(_onStatus);
      route?.secondaryAnimation?.addStatusListener(_onStatus);
    }
    _schedule();
  }

  /// Repeated requests with the same key replace obsolete work.
  void schedule(Object key, VoidCallback work) {
    if (_disposed) return;
    _pending[key] = work;
    _schedule();
  }

  /// An explicit action can supersede automatic UI waiting for entry to finish.
  void cancel(Object key) {
    _pending.remove(key);
  }

  bool get _ready {
    final route = _route;
    return !_disposed &&
        (route == null ||
            (route.isActive &&
                route.isCurrent &&
                (route.animation == null || route.animation!.isCompleted) &&
                (route.secondaryAnimation == null ||
                    route.secondaryAnimation!.isDismissed)));
  }

  void _onStatus(AnimationStatus status) => _schedule();

  void _schedule() {
    if (_scheduled || _pending.isEmpty || !_ready) return;
    _scheduled = true;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_ready) return;
      final work = _pending.entries.toList(growable: false);
      for (final entry in work) {
        // A callback may navigate away or dispose the owner.
        if (!_ready) return;
        if (!identical(_pending[entry.key], entry.value)) continue;
        _pending.remove(entry.key);
        entry.value();
      }
    });
    // A paused player need not have another frame pending. Request just the
    // frame that will deliver this batch, never a repeating idle check.
    binding.ensureVisualUpdate();
  }

  void _removeListeners() {
    _route?.animation?.removeStatusListener(_onStatus);
    _route?.secondaryAnimation?.removeStatusListener(_onStatus);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _removeListeners();
    _route = null;
    _pending.clear();
  }
}
