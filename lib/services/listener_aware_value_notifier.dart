import 'package:flutter/foundation.dart';

/// Reports only the transitions between zero and one or more listeners.
///
/// The callback can schedule presentation work, but must not synchronously
/// publish a new value: subscriptions can be installed during widget build.
class ListenerAwareValueNotifier<T> extends ValueNotifier<T> {
  ListenerAwareValueNotifier(super.value, {this.onListenersChanged});

  final VoidCallback? onListenersChanged;
  final _activeListeners = <VoidCallback>[];

  // ChangeNotifier defers its own listener count updates during notification.
  // Track actual registrations so a last listener removing itself can stop
  // presentation work immediately, including duplicate registrations.
  bool get hasActiveListeners => _activeListeners.isNotEmpty;

  @override
  void addListener(VoidCallback listener) {
    final hadListeners = hasActiveListeners;
    super.addListener(listener);
    _activeListeners.add(listener);
    if (!hadListeners) onListenersChanged?.call();
  }

  @override
  void removeListener(VoidCallback listener) {
    final index = _activeListeners.indexOf(listener);
    super.removeListener(listener);
    if (index < 0) return;
    _activeListeners.removeAt(index);
    if (!hasActiveListeners) onListenersChanged?.call();
  }

  @override
  void dispose() {
    _activeListeners.clear();
    super.dispose();
  }
}
