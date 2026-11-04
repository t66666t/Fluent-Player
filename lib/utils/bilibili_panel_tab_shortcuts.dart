import 'package:flutter/services.dart';

import '../services/bilibili/bilibili_player_panel_policy.dart';

/// Directional tab navigation, separate from seek and subtitle text selection.
/// Pages check route visibility, editing focus and lock state before using it.
PortraitBilibiliTab? bilibiliPanelTabForKey(KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  if (!keyboard.isAltPressed ||
      keyboard.isControlPressed ||
      keyboard.isMetaPressed ||
      keyboard.isShiftPressed) {
    return null;
  }
  return switch (event.logicalKey) {
    LogicalKeyboardKey.arrowLeft => PortraitBilibiliTab.details,
    LogicalKeyboardKey.arrowRight => PortraitBilibiliTab.subtitles,
    _ => null,
  };
}
