import 'package:flutter/services.dart';

enum BatchSubtitleShortcutAction {
  back,
  addVideos,
  pickExternal,
  toggleAll,
  toggleAutoRemove,
  openSettings,
  clearCompleted,
}

class BatchSubtitleShortcuts {
  static const Map<BatchSubtitleShortcutAction, LogicalKeyboardKey> defaults =
      <BatchSubtitleShortcutAction, LogicalKeyboardKey>{
        BatchSubtitleShortcutAction.back: LogicalKeyboardKey.escape,
        BatchSubtitleShortcutAction.addVideos: LogicalKeyboardKey.keyA,
        BatchSubtitleShortcutAction.pickExternal: LogicalKeyboardKey.keyF,
        BatchSubtitleShortcutAction.toggleAll: LogicalKeyboardKey.space,
        BatchSubtitleShortcutAction.toggleAutoRemove: LogicalKeyboardKey.keyD,
        BatchSubtitleShortcutAction.openSettings: LogicalKeyboardKey.keyS,
        BatchSubtitleShortcutAction.clearCompleted: LogicalKeyboardKey.keyC,
      };

  static BatchSubtitleShortcutAction? matchAction(LogicalKeyboardKey key) {
    for (final entry in defaults.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }

  static bool isAvailableOnPlatform(
    BatchSubtitleShortcutAction action,
    TargetPlatform platform,
  ) {
    if (platform == TargetPlatform.fuchsia) return false;
    if (platform == TargetPlatform.android &&
        action == BatchSubtitleShortcutAction.back) {
      return false;
    }
    return true;
  }
}

enum BatchImportShortcutAction { back, importMedia, importSubtitles, help }

class BatchImportShortcuts {
  static const Map<BatchImportShortcutAction, LogicalKeyboardKey> defaults =
      <BatchImportShortcutAction, LogicalKeyboardKey>{
        BatchImportShortcutAction.back: LogicalKeyboardKey.escape,
        BatchImportShortcutAction.importMedia: LogicalKeyboardKey.keyI,
        BatchImportShortcutAction.importSubtitles: LogicalKeyboardKey.keyC,
        BatchImportShortcutAction.help: LogicalKeyboardKey.keyH,
      };

  static BatchImportShortcutAction? matchAction(LogicalKeyboardKey key) {
    for (final entry in defaults.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }

  static bool isAvailableOnPlatform(
    BatchImportShortcutAction action,
    TargetPlatform platform,
  ) {
    if (platform == TargetPlatform.fuchsia) return false;
    if (platform == TargetPlatform.android &&
        action == BatchImportShortcutAction.back) {
      return false;
    }
    return true;
  }
}

enum PortableTransferShortcutAction {
  backOrExitManagement,
  exportTab,
  importTab,
  primaryAction,
  enterManagement,
  selectAll,
  deleteSelected,
}

class PortableTransferShortcuts {
  static const Map<PortableTransferShortcutAction, LogicalKeyboardKey>
  defaults = <PortableTransferShortcutAction, LogicalKeyboardKey>{
    PortableTransferShortcutAction.backOrExitManagement:
        LogicalKeyboardKey.escape,
    PortableTransferShortcutAction.exportTab: LogicalKeyboardKey.keyE,
    PortableTransferShortcutAction.importTab: LogicalKeyboardKey.keyI,
    PortableTransferShortcutAction.primaryAction: LogicalKeyboardKey.keyN,
    PortableTransferShortcutAction.enterManagement: LogicalKeyboardKey.keyB,
    PortableTransferShortcutAction.selectAll: LogicalKeyboardKey.keyA,
    PortableTransferShortcutAction.deleteSelected: LogicalKeyboardKey.keyR,
  };

  static PortableTransferShortcutAction? matchAction(LogicalKeyboardKey key) {
    for (final entry in defaults.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }

  static bool isAvailableOnPlatform(
    PortableTransferShortcutAction action,
    TargetPlatform platform,
  ) {
    if (platform == TargetPlatform.fuchsia) return false;
    if (platform == TargetPlatform.android &&
        action == PortableTransferShortcutAction.backOrExitManagement) {
      return false;
    }
    return true;
  }
}

enum PortableSelectionShortcutAction { back, selectAll, toggleExpand, confirm }

class PortableSelectionShortcuts {
  static const Map<PortableSelectionShortcutAction, LogicalKeyboardKey>
  defaults = <PortableSelectionShortcutAction, LogicalKeyboardKey>{
    PortableSelectionShortcutAction.back: LogicalKeyboardKey.escape,
    PortableSelectionShortcutAction.selectAll: LogicalKeyboardKey.keyA,
    PortableSelectionShortcutAction.toggleExpand: LogicalKeyboardKey.keyF,
    PortableSelectionShortcutAction.confirm: LogicalKeyboardKey.enter,
  };

  static PortableSelectionShortcutAction? matchAction(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.numpadEnter) {
      return PortableSelectionShortcutAction.confirm;
    }
    for (final entry in defaults.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }
}
