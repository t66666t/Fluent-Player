import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'keyboard_shortcut_hints.dart';

enum DesktopPlayerShortcutAction {
  back,
  playPause,
  seekBackward,
  seekForward,
  openSettings,
  openSubtitleLibrary,
  openSubtitleEditor,
  openVideoCompose,
  openSubtitleStyle,
  moveSubtitles,
  toggleSubtitleSidebar,
  toggleFullScreen,
  openAspectRatio,
  toggleEpisodePicker,
  previousEpisode,
  nextEpisode,
  toggleSubtitles,
  toggleMute,
  volumeUp,
  volumeDown,
  speedSlower,
  speedFaster,
  openChapters,
  toggleLock,
  toggleDanmaku,
  openDanmakuSettings,
  openOcrSubtitle,
  toggleAiChat,
  toggleBilibiliPanel,
  openStreamQuality,
  resetScreen,
  openSleepTimer,
}

class DesktopPlayerShortcutBinding {
  const DesktopPlayerShortcutBinding(this.logicalKey, {this.shift = false});

  final LogicalKeyboardKey logicalKey;

  /// Shift is a dedicated chord for speed notches, not a global blocker.
  final bool shift;

  bool matches(LogicalKeyboardKey key, {bool shiftPressed = false}) =>
      logicalKey == key && shift == shiftPressed;

  String formatLabel() {
    String base;
    if (logicalKey == LogicalKeyboardKey.space) {
      base = 'Space';
    } else if (logicalKey == LogicalKeyboardKey.escape) {
      base = 'Esc';
    } else if (logicalKey == LogicalKeyboardKey.arrowLeft) {
      base = 'Left';
    } else if (logicalKey == LogicalKeyboardKey.arrowRight) {
      base = 'Right';
    } else if (logicalKey == LogicalKeyboardKey.arrowUp) {
      base = 'Up';
    } else if (logicalKey == LogicalKeyboardKey.arrowDown) {
      base = 'Down';
    } else if (logicalKey == LogicalKeyboardKey.bracketLeft) {
      base = '[';
    } else if (logicalKey == LogicalKeyboardKey.bracketRight) {
      base = ']';
    } else {
      base = logicalKey.keyLabel.toUpperCase();
    }
    return shift ? 'Shift+$base' : base;
  }
}

class DesktopPlayerShortcuts {
  /// Primary binding first; extra entries are aliases (Shift+arrows for speed).
  static const Map<
    DesktopPlayerShortcutAction,
    List<DesktopPlayerShortcutBinding>
  >
  defaults =
      <DesktopPlayerShortcutAction, List<DesktopPlayerShortcutBinding>>{
        DesktopPlayerShortcutAction.back: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.escape),
        ],
        DesktopPlayerShortcutAction.playPause: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.space),
        ],
        DesktopPlayerShortcutAction.seekBackward:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.arrowLeft),
            ],
        DesktopPlayerShortcutAction.seekForward: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.arrowRight),
        ],
        DesktopPlayerShortcutAction.openSettings:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyS),
            ],
        DesktopPlayerShortcutAction.openSubtitleLibrary:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyL),
            ],
        DesktopPlayerShortcutAction.openSubtitleEditor:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyE),
            ],
        DesktopPlayerShortcutAction.openVideoCompose:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyV),
            ],
        DesktopPlayerShortcutAction.openSubtitleStyle:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyT),
            ],
        DesktopPlayerShortcutAction.moveSubtitles:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyJ),
            ],
        DesktopPlayerShortcutAction.toggleSubtitleSidebar:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyB),
            ],
        DesktopPlayerShortcutAction.toggleFullScreen:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyF),
            ],
        DesktopPlayerShortcutAction.openAspectRatio:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyA),
            ],
        DesktopPlayerShortcutAction.toggleEpisodePicker:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyG),
            ],
        DesktopPlayerShortcutAction.previousEpisode:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyP),
            ],
        DesktopPlayerShortcutAction.nextEpisode: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyN),
        ],
        DesktopPlayerShortcutAction.toggleSubtitles:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyC),
            ],
        DesktopPlayerShortcutAction.toggleMute: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyM),
        ],
        DesktopPlayerShortcutAction.volumeUp: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.arrowUp),
        ],
        DesktopPlayerShortcutAction.volumeDown: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.arrowDown),
        ],
        DesktopPlayerShortcutAction.speedSlower: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.bracketLeft),
          DesktopPlayerShortcutBinding(
            LogicalKeyboardKey.arrowLeft,
            shift: true,
          ),
        ],
        DesktopPlayerShortcutAction.speedFaster: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.bracketRight),
          DesktopPlayerShortcutBinding(
            LogicalKeyboardKey.arrowRight,
            shift: true,
          ),
        ],
        DesktopPlayerShortcutAction.openChapters:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyH),
            ],
        DesktopPlayerShortcutAction.toggleLock: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyK),
        ],
        DesktopPlayerShortcutAction.toggleDanmaku:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyD),
            ],
        DesktopPlayerShortcutAction.openDanmakuSettings:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyX),
            ],
        DesktopPlayerShortcutAction.openOcrSubtitle:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyO),
            ],
        DesktopPlayerShortcutAction.toggleAiChat:
            <DesktopPlayerShortcutBinding>[
              // W = 问答; A and I already belong to player controls.
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyW),
            ],
        DesktopPlayerShortcutAction.toggleBilibiliPanel:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyI),
            ],
        DesktopPlayerShortcutAction.openStreamQuality:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyQ),
            ],
        DesktopPlayerShortcutAction.resetScreen: <DesktopPlayerShortcutBinding>[
          DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyR),
        ],
        DesktopPlayerShortcutAction.openSleepTimer:
            <DesktopPlayerShortcutBinding>[
              DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyZ),
            ],
      };

  static DesktopPlayerShortcutBinding primaryBinding(
    DesktopPlayerShortcutAction action,
  ) {
    return defaults[action]!.first;
  }

  static DesktopPlayerShortcutAction? matchAction(
    LogicalKeyboardKey key, {
    bool shiftPressed = false,
  }) {
    // Prefer Shift+arrow speed chords, then fall back so Shift+Space still pauses.
    if (shiftPressed) {
      for (final MapEntry<
            DesktopPlayerShortcutAction,
            List<DesktopPlayerShortcutBinding>
          >
          entry
          in defaults.entries) {
        for (final DesktopPlayerShortcutBinding binding in entry.value) {
          if (binding.matches(key, shiftPressed: true)) {
            return entry.key;
          }
        }
      }
    }
    for (final MapEntry<
          DesktopPlayerShortcutAction,
          List<DesktopPlayerShortcutBinding>
        >
        entry
        in defaults.entries) {
      for (final DesktopPlayerShortcutBinding binding in entry.value) {
        if (binding.matches(key, shiftPressed: false)) {
          return entry.key;
        }
      }
    }
    return null;
  }

  /// Filters desktop bindings down to actions that also make sense when a
  /// phone or tablet has a physical keyboard attached.
  static bool isAvailableOnPlatform(
    DesktopPlayerShortcutAction action,
    TargetPlatform platform,
  ) {
    switch (platform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
        return action != DesktopPlayerShortcutAction.back &&
            action != DesktopPlayerShortcutAction.toggleFullScreen;
      case TargetPlatform.iOS:
        return action != DesktopPlayerShortcutAction.toggleFullScreen;
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  /// Rapid left/right presses use the same accumulated, subtitle-aware seek
  /// coordinator on Windows and on mobile physical keyboards.
  static bool usesCoordinatedSeekOnPlatform(TargetPlatform platform) {
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS;
  }

  static String shortcutLabel(DesktopPlayerShortcutAction action) {
    return primaryBinding(action).formatLabel();
  }

  static String buildTooltip(
    String label,
    DesktopPlayerShortcutAction action, {
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
