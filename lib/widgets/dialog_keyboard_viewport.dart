import 'package:flutter/material.dart';
import 'route_keyboard_viewport.dart';
import 'keyboard_inset_padding.dart';

/// Only the front dialog follows the IME. A covered dialog keeps its viewport
/// while an input page above it opens or closes the keyboard.
class DialogKeyboardViewport extends StatelessWidget {
  const DialogKeyboardViewport({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => RouteKeyboardViewport(
    // Consume IME geometry outside Dialog/AlertDialog. Their internal 100 ms
    // AnimatedPadding then remains at zero instead of restarting every frame.
    child: KeyboardInsetPadding(
      child: SafeArea(maintainBottomViewPadding: true, child: child),
    ),
  );
}
