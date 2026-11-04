import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/desktop_player_shortcuts.dart';

void main() {
  group('DesktopPlayerShortcuts', () {
    test('every player action has a unique primary key binding', () {
      expect(
        DesktopPlayerShortcuts.defaults.length,
        DesktopPlayerShortcutAction.values.length,
      );

      final identities = DesktopPlayerShortcuts.defaults.values
          .map((bindings) => (bindings.first.logicalKey, bindings.first.shift))
          .toSet();
      expect(identities.length, DesktopPlayerShortcutAction.values.length);
    });

    test('matches transport and panel shortcuts to their intended actions', () {
      final expected = <LogicalKeyboardKey, DesktopPlayerShortcutAction>{
        LogicalKeyboardKey.escape: DesktopPlayerShortcutAction.back,
        LogicalKeyboardKey.space: DesktopPlayerShortcutAction.playPause,
        LogicalKeyboardKey.arrowLeft: DesktopPlayerShortcutAction.seekBackward,
        LogicalKeyboardKey.arrowRight: DesktopPlayerShortcutAction.seekForward,
        LogicalKeyboardKey.keyS: DesktopPlayerShortcutAction.openSettings,
        LogicalKeyboardKey.keyL:
            DesktopPlayerShortcutAction.openSubtitleLibrary,
        LogicalKeyboardKey.keyE: DesktopPlayerShortcutAction.openSubtitleEditor,
        LogicalKeyboardKey.keyV: DesktopPlayerShortcutAction.openVideoCompose,
        LogicalKeyboardKey.keyT: DesktopPlayerShortcutAction.openSubtitleStyle,
        LogicalKeyboardKey.keyJ: DesktopPlayerShortcutAction.moveSubtitles,
        LogicalKeyboardKey.keyD: DesktopPlayerShortcutAction.toggleDanmaku,
        LogicalKeyboardKey.keyB:
            DesktopPlayerShortcutAction.toggleSubtitleSidebar,
        LogicalKeyboardKey.keyF: DesktopPlayerShortcutAction.toggleFullScreen,
        LogicalKeyboardKey.keyA: DesktopPlayerShortcutAction.openAspectRatio,
        LogicalKeyboardKey.keyG:
            DesktopPlayerShortcutAction.toggleEpisodePicker,
        LogicalKeyboardKey.keyP: DesktopPlayerShortcutAction.previousEpisode,
        LogicalKeyboardKey.keyN: DesktopPlayerShortcutAction.nextEpisode,
        LogicalKeyboardKey.keyC: DesktopPlayerShortcutAction.toggleSubtitles,
        LogicalKeyboardKey.keyM: DesktopPlayerShortcutAction.toggleMute,
        LogicalKeyboardKey.arrowUp: DesktopPlayerShortcutAction.volumeUp,
        LogicalKeyboardKey.arrowDown: DesktopPlayerShortcutAction.volumeDown,
        LogicalKeyboardKey.keyH: DesktopPlayerShortcutAction.openChapters,
        LogicalKeyboardKey.keyK: DesktopPlayerShortcutAction.toggleLock,
        LogicalKeyboardKey.keyX:
            DesktopPlayerShortcutAction.openDanmakuSettings,
        LogicalKeyboardKey.keyO: DesktopPlayerShortcutAction.openOcrSubtitle,
        LogicalKeyboardKey.keyW: DesktopPlayerShortcutAction.toggleAiChat,
        LogicalKeyboardKey.keyI:
            DesktopPlayerShortcutAction.toggleBilibiliPanel,
        LogicalKeyboardKey.keyQ: DesktopPlayerShortcutAction.openStreamQuality,
        LogicalKeyboardKey.keyR: DesktopPlayerShortcutAction.resetScreen,
        LogicalKeyboardKey.keyZ: DesktopPlayerShortcutAction.openSleepTimer,
        LogicalKeyboardKey.bracketLeft: DesktopPlayerShortcutAction.speedSlower,
        LogicalKeyboardKey.bracketRight:
            DesktopPlayerShortcutAction.speedFaster,
      };

      for (final entry in expected.entries) {
        expect(
          DesktopPlayerShortcuts.matchAction(entry.key),
          entry.value,
          reason: 'Unexpected action for ${entry.key.keyLabel}',
        );
      }
      expect(
        DesktopPlayerShortcuts.matchAction(LogicalKeyboardKey.keyY),
        isNull,
      );
      expect(
        DesktopPlayerShortcuts.matchAction(LogicalKeyboardKey.keyU),
        isNull,
      );
      expect(
        DesktopPlayerShortcuts.matchAction(
          LogicalKeyboardKey.arrowLeft,
          shiftPressed: true,
        ),
        DesktopPlayerShortcutAction.speedSlower,
      );
      expect(
        DesktopPlayerShortcuts.matchAction(
          LogicalKeyboardKey.arrowRight,
          shiftPressed: true,
        ),
        DesktopPlayerShortcutAction.speedFaster,
      );
      expect(
        DesktopPlayerShortcuts.matchAction(
          LogicalKeyboardKey.space,
          shiftPressed: true,
        ),
        DesktopPlayerShortcutAction.playPause,
      );
    });

    test('tooltips expose the actual configured shortcut', () {
      expect(
        DesktopPlayerShortcuts.buildTooltip(
          'AI 对话',
          DesktopPlayerShortcutAction.toggleAiChat,
        ),
        'AI 对话 (W)',
      );
      expect(
        DesktopPlayerShortcuts.buildTooltip(
          '播放/暂停',
          DesktopPlayerShortcutAction.playPause,
        ),
        '播放/暂停 (Space)',
      );
      expect(
        DesktopPlayerShortcuts.buildTooltip(
          '返回',
          DesktopPlayerShortcutAction.back,
        ),
        '返回 (Esc)',
      );
      expect(
        DesktopPlayerShortcuts.buildTooltip(
          '弹幕',
          DesktopPlayerShortcutAction.toggleDanmaku,
        ),
        '弹幕 (D)',
      );
      expect(
        DesktopPlayerShortcuts.buildTooltip(
          '移动字幕',
          DesktopPlayerShortcutAction.moveSubtitles,
        ),
        '移动字幕 (J)',
      );
      expect(
        DesktopPlayerShortcuts.shortcutLabel(
          DesktopPlayerShortcutAction.speedSlower,
        ),
        '[',
      );
      expect(
        DesktopPlayerShortcuts.shortcutLabel(
          DesktopPlayerShortcutAction.speedFaster,
        ),
        ']',
      );
    });

    test(
      'AI chat is available with a physical keyboard on every native platform',
      () {
        for (final platform in TargetPlatform.values) {
          expect(
            DesktopPlayerShortcuts.isAvailableOnPlatform(
              DesktopPlayerShortcutAction.toggleAiChat,
              platform,
            ),
            platform != TargetPlatform.fuchsia,
          );
        }
      },
    );
  });
}
