import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ImportSheetShortcutAction {
  close,
  gallery,
  files,
  bilibiliOnline,
  archive,
  folder,
  fluentPack,
}

class ImportSheetShortcuts {
  static const Map<ImportSheetShortcutAction, LogicalKeyboardKey> defaults =
      <ImportSheetShortcutAction, LogicalKeyboardKey>{
        ImportSheetShortcutAction.close: LogicalKeyboardKey.escape,
        ImportSheetShortcutAction.gallery: LogicalKeyboardKey.keyA,
        ImportSheetShortcutAction.files: LogicalKeyboardKey.keyF,
        ImportSheetShortcutAction.bilibiliOnline: LogicalKeyboardKey.keyB,
        ImportSheetShortcutAction.archive: LogicalKeyboardKey.keyZ,
        ImportSheetShortcutAction.folder: LogicalKeyboardKey.keyO,
        ImportSheetShortcutAction.fluentPack: LogicalKeyboardKey.keyX,
      };

  static ImportSheetShortcutAction? matchAction(LogicalKeyboardKey key) {
    for (final entry in defaults.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }

  static bool isVisible(ImportSheetShortcutAction action) {
    switch (action) {
      case ImportSheetShortcutAction.gallery:
        return !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS);
      case ImportSheetShortcutAction.folder:
        return defaultTargetPlatform != TargetPlatform.iOS;
      default:
        return true;
    }
  }
}
