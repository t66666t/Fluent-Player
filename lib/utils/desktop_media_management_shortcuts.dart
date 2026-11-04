import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'keyboard_shortcut_hints.dart';

enum DesktopMediaManagementShortcutAction {
  backOrExitSelection,
  toggleViewMode,
  toggleFullScreen,
  openLargeDataDirectory,
  exportSettings,
  openRecycleBin,
  openCardStyle,
  enterSelectionMode,
  toggleSelectAll,
  openSearch,
  openLibrarySettings,
  openSleepTimer,
  createCollection,
  importMedia,
  openBilibiliDownload,
  openYtDlpDownload,
  openDouyinDownload,
  openWebMedia,
  toggleActionButtons,
  openBatchSubtitle,
  openBatchImport,
  moveToParent,
  exportFluentPack,
}

class DesktopMediaManagementShortcuts {
  static const Map<DesktopMediaManagementShortcutAction, LogicalKeyboardKey>
  defaults = <DesktopMediaManagementShortcutAction, LogicalKeyboardKey>{
    DesktopMediaManagementShortcutAction.backOrExitSelection:
        LogicalKeyboardKey.escape,
    DesktopMediaManagementShortcutAction.toggleViewMode:
        LogicalKeyboardKey.keyV,
    DesktopMediaManagementShortcutAction.toggleFullScreen:
        LogicalKeyboardKey.keyF,
    DesktopMediaManagementShortcutAction.openLargeDataDirectory:
        LogicalKeyboardKey.keyO,
    DesktopMediaManagementShortcutAction.exportSettings:
        LogicalKeyboardKey.keyE,
    DesktopMediaManagementShortcutAction.openRecycleBin:
        LogicalKeyboardKey.keyR,
    DesktopMediaManagementShortcutAction.openCardStyle: LogicalKeyboardKey.keyT,
    DesktopMediaManagementShortcutAction.enterSelectionMode:
        LogicalKeyboardKey.keyB,
    DesktopMediaManagementShortcutAction.toggleSelectAll:
        LogicalKeyboardKey.keyA,
    DesktopMediaManagementShortcutAction.openSearch: LogicalKeyboardKey.keyS,
    DesktopMediaManagementShortcutAction.openLibrarySettings:
        LogicalKeyboardKey.keyP,
    DesktopMediaManagementShortcutAction.openSleepTimer:
        LogicalKeyboardKey.keyZ,
    DesktopMediaManagementShortcutAction.createCollection:
        LogicalKeyboardKey.keyN,
    DesktopMediaManagementShortcutAction.importMedia: LogicalKeyboardKey.keyI,
    DesktopMediaManagementShortcutAction.openBilibiliDownload:
        LogicalKeyboardKey.keyD,
    DesktopMediaManagementShortcutAction.openYtDlpDownload:
        LogicalKeyboardKey.keyY,
    DesktopMediaManagementShortcutAction.openDouyinDownload:
        LogicalKeyboardKey.keyJ,
    DesktopMediaManagementShortcutAction.openWebMedia: LogicalKeyboardKey.keyW,
    DesktopMediaManagementShortcutAction.toggleActionButtons:
        LogicalKeyboardKey.keyH,
    DesktopMediaManagementShortcutAction.openBatchSubtitle:
        LogicalKeyboardKey.keyC,
    DesktopMediaManagementShortcutAction.openBatchImport:
        LogicalKeyboardKey.keyM,
    DesktopMediaManagementShortcutAction.moveToParent: LogicalKeyboardKey.keyU,
    // Browse: open 导入与导出. Selection: choose Fluent Pack or Zip.
    DesktopMediaManagementShortcutAction.exportFluentPack:
        LogicalKeyboardKey.keyX,
  };

  static DesktopMediaManagementShortcutAction? matchAction(
    LogicalKeyboardKey key,
  ) {
    for (final entry in defaults.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }

  static bool isAvailableOnPlatform(
    DesktopMediaManagementShortcutAction action,
    TargetPlatform platform,
  ) {
    if (const {
      DesktopMediaManagementShortcutAction.openBilibiliDownload,
      DesktopMediaManagementShortcutAction.openYtDlpDownload,
      DesktopMediaManagementShortcutAction.openDouyinDownload,
      DesktopMediaManagementShortcutAction.openWebMedia,
    }.contains(action)) {
      return false;
    }
    switch (platform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
        return action !=
                DesktopMediaManagementShortcutAction.backOrExitSelection &&
            action != DesktopMediaManagementShortcutAction.toggleFullScreen &&
            action !=
                DesktopMediaManagementShortcutAction.openLargeDataDirectory;
      case TargetPlatform.iOS:
        return action !=
                DesktopMediaManagementShortcutAction.toggleFullScreen &&
            action !=
                DesktopMediaManagementShortcutAction.openLargeDataDirectory;
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  static String shortcutLabel(DesktopMediaManagementShortcutAction action) {
    final LogicalKeyboardKey? key = defaults[action];
    if (key == null) return '';
    if (key == LogicalKeyboardKey.escape) return 'Esc';
    return key.keyLabel.toUpperCase();
  }

  static String buildTooltip(
    String label,
    DesktopMediaManagementShortcutAction action, {
    BuildContext? context,
  }) {
    if (context != null && !KeyboardShortcutHints.of(context)) {
      return label;
    }
    final String shortcut = shortcutLabel(action);
    if (shortcut.isEmpty) return label;
    return '$label ($shortcut)';
  }
}
