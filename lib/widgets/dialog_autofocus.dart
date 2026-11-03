import 'package:flutter/widgets.dart';

/// Open the keyboard once, after the dialog's entrance has finished, so native
/// IME setup and selection do not compete with the route's opening animation.
class DialogAutofocus extends StatefulWidget {
  const DialogAutofocus({
    super.key,
    required this.focusNode,
    required this.child,
  });

  final FocusNode focusNode;
  final Widget child;

  @override
  State<DialogAutofocus> createState() => _DialogAutofocusState();
}

class _DialogAutofocusState extends State<DialogAutofocus> {
  Animation<double>? _animation;
  bool _requested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (!identical(animation, _animation)) {
      _animation?.removeStatusListener(_statusChanged);
      _animation = animation;
      animation?.addStatusListener(_statusChanged);
    }
    _statusChanged(animation?.status ?? AnimationStatus.completed);
  }

  void _statusChanged(AnimationStatus status) {
    if (_requested || status != AnimationStatus.completed) return;
    _requested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (ModalRoute.isCurrentOf(context) ?? true)) {
        widget.focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_statusChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
