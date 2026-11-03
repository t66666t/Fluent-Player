import 'package:flutter/services.dart';

enum LinkDownloadShortcutAction {
  back,
  toggleMode,
  parse,
  paste,
  clearInput,
  openSettings,
  login,
  selectAll,
  primaryRun,
  pause,
  importToLibrary,
  exportToLibrary,
  remove,
  prioritize,
  cancel,
  retry,
}

class LinkDownloadShortcuts {
  static const Map<LinkDownloadShortcutAction, LogicalKeyboardKey> defaults =
      <LinkDownloadShortcutAction, LogicalKeyboardKey>{
        LinkDownloadShortcutAction.back: LogicalKeyboardKey.escape,
        LinkDownloadShortcutAction.toggleMode: LogicalKeyboardKey.keyW,
        LinkDownloadShortcutAction.parse: LogicalKeyboardKey.enter,
        LinkDownloadShortcutAction.paste: LogicalKeyboardKey.keyV,
        LinkDownloadShortcutAction.clearInput: LogicalKeyboardKey.keyX,
        LinkDownloadShortcutAction.openSettings: LogicalKeyboardKey.keyS,
        LinkDownloadShortcutAction.login: LogicalKeyboardKey.keyL,
        LinkDownloadShortcutAction.selectAll: LogicalKeyboardKey.keyA,
        LinkDownloadShortcutAction.primaryRun: LogicalKeyboardKey.space,
        LinkDownloadShortcutAction.pause: LogicalKeyboardKey.keyP,
        LinkDownloadShortcutAction.importToLibrary: LogicalKeyboardKey.keyI,
        LinkDownloadShortcutAction.exportToLibrary: LogicalKeyboardKey.keyE,
        LinkDownloadShortcutAction.remove: LogicalKeyboardKey.keyR,
        LinkDownloadShortcutAction.prioritize: LogicalKeyboardKey.keyQ,
        LinkDownloadShortcutAction.cancel: LogicalKeyboardKey.keyC,
        LinkDownloadShortcutAction.retry: LogicalKeyboardKey.keyT,
      };

  static LinkDownloadShortcutAction? matchAction(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.numpadEnter) {
      return LinkDownloadShortcutAction.parse;
    }
    for (final entry in defaults.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }

  static bool isAvailableOnPlatform(
    LinkDownloadShortcutAction action,
    TargetPlatform platform,
  ) {
    if (platform == TargetPlatform.fuchsia) return false;
    if (platform == TargetPlatform.android &&
        action == LinkDownloadShortcutAction.back) {
      return false;
    }
    return true;
  }
}
