import 'package:flutter/widgets.dart';

/// Connects a card's secondary click to its own visible overflow button.
/// Uses Flutter pointer gestures on every platform, including mobile mice.
class CardContextMenu extends StatefulWidget {
  const CardContextMenu({super.key, required this.builder, this.onFallback});
  final Widget Function(BuildContext, VoidCallback) builder;
  final VoidCallback? onFallback;

  @override
  State<CardContextMenu> createState() => _CardContextMenuState();
}

class _CardContextMenuState extends State<CardContextMenu> {
  _CardContextMenuTargetState? target;

  void open() {
    final current = target;
    if (current != null && current.mounted) {
      current.widget.onOpen();
    } else {
      widget.onFallback?.call();
    }
  }

  @override
  Widget build(BuildContext context) => _CardMenuScope(
    owner: this,
    child: Builder(builder: (context) => widget.builder(context, open)),
  );
}

class _CardMenuScope extends InheritedWidget {
  const _CardMenuScope({required this.owner, required super.child});
  final _CardContextMenuState owner;

  @override
  bool updateShouldNotify(_CardMenuScope oldWidget) => owner != oldWidget.owner;
}

/// Registers the exact callback used by the overflow button, retaining its
/// anchor, actions and current state instead of constructing a second menu.
class CardContextMenuTarget extends StatefulWidget {
  const CardContextMenuTarget({
    super.key,
    required this.onOpen,
    required this.child,
  });
  final VoidCallback onOpen;
  final Widget child;

  @override
  State<CardContextMenuTarget> createState() => _CardContextMenuTargetState();
}

class _CardContextMenuTargetState extends State<CardContextMenuTarget> {
  _CardContextMenuState? owner;

  void unregister() {
    if (owner?.target == this) owner!.target = null;
    owner = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unregister();
    owner = context.dependOnInheritedWidgetOfExactType<_CardMenuScope>()?.owner;
    owner?.target = this;
  }

  @override
  void deactivate() {
    unregister();
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
