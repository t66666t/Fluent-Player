import 'dart:async';

import 'package:flutter/widgets.dart';
import '../utils/ui_interaction_budget.dart';

/// Visual activity is independent of business tasks. Parked panels keep their
/// drafts and callbacks, while their progress views stop consuming updates.
class SidebarActivity extends InheritedWidget {
  const SidebarActivity({
    super.key,
    required this.active,
    required super.child,
  });
  final bool active;
  static bool of(BuildContext context) =>
      (context.dependOnInheritedWidgetOfExactType<SidebarActivity>()?.active ??
          true) &&
      TickerMode.valuesOf(context).enabled;
  @override
  bool updateShouldNotify(SidebarActivity oldWidget) =>
      active != oldWidget.active;
}

/// Give foreground gestures and scrolling the same preparation headroom as a
/// sidebar transition. Business tasks keep running; no polling/timer is added.
class SidebarInteractionRegion extends StatefulWidget {
  const SidebarInteractionRegion({super.key, required this.child});
  final Widget child;
  @override
  State<SidebarInteractionRegion> createState() =>
      _SidebarInteractionRegionState();
}

class _SidebarInteractionRegionState extends State<SidebarInteractionRegion> {
  final Set<int> _pointers = {};
  final Set<BuildContext?> _scrolling = {};
  bool _active = true;
  int _revision = 0;
  VoidCallback? _release;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = SidebarActivity.of(context);
    if (!_active) {
      _pointers.clear();
      _scrolling.clear();
      _updateBudget();
    }
  }

  void _updateBudget() {
    final revision = ++_revision;
    if (!_active || (_pointers.isEmpty && _scrolling.isEmpty)) {
      _release?.call();
      _release = null;
    } else {
      // Scroll notifications can arrive during layout. The resource observer
      // must not notify unrelated widgets until that layout has finished.
      scheduleMicrotask(() {
        if (mounted && revision == _revision && _active) {
          _release ??= UiInteractionBudget.instance.acquire();
        }
      });
    }
  }

  @override
  void dispose() {
    _revision++;
    _release?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      _pointers.add(event.pointer);
      _updateBudget();
    },
    onPointerUp: (event) {
      _pointers.remove(event.pointer);
      _updateBudget();
    },
    onPointerCancel: (event) {
      _pointers.remove(event.pointer);
      _updateBudget();
    },
    child: NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          _scrolling.add(notification.context);
          _updateBudget();
        } else if (notification is ScrollEndNotification) {
          _scrolling.remove(notification.context);
          _updateBudget();
        }
        return false;
      },
      child: widget.child,
    ),
  );
}

/// A selector which detaches its visual subscription while a panel is hidden.
/// A fresh value is read on re-entry, without replaying hidden progress ticks.
class SidebarValueBuilder<T> extends StatefulWidget {
  const SidebarValueBuilder({
    super.key,
    required this.listenable,
    required this.select,
    required this.builder,
    this.child,
  });
  final Listenable listenable;
  final T Function() select;
  final ValueWidgetBuilder<T> builder;
  final Widget? child;
  @override
  State<SidebarValueBuilder<T>> createState() => _SidebarValueBuilderState<T>();
}

class _SidebarValueBuilderState<T> extends State<SidebarValueBuilder<T>> {
  late T _value;
  bool _listening = false;
  bool _hasValue = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant SidebarValueBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_listening && oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      _listening = false;
    }
    _bind(refresh: true);
  }

  void _bind({bool refresh = false}) {
    final active = SidebarActivity.of(context);
    final reentering = active && !_listening;
    if (active != _listening) {
      if (active) {
        widget.listenable.addListener(_changed);
      } else {
        widget.listenable.removeListener(_changed);
      }
      _listening = active;
    }
    if (!_hasValue || reentering || (active && refresh)) {
      _value = widget.select();
      _hasValue = true;
    }
  }

  void _changed() {
    final value = widget.select();
    if (value != _value) setState(() => _value = value);
  }

  @override
  void dispose() {
    if (_listening) widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _value, widget.child);
}
