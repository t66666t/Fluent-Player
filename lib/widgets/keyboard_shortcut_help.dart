import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/desktop_media_management_shortcuts.dart';
import '../utils/desktop_player_shortcuts.dart';
import '../utils/page_shortcut_keys.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class KeyboardShortcutHelpIntent extends Intent {
  const KeyboardShortcutHelpIntent();
}

bool _helpVisible = false;

Future<void> showKeyboardShortcutHelp(BuildContext context) async {
  if (_helpVisible) return;
  _helpVisible = true;
  try {
    await showDialog<void>(
      context: context,
      builder: (context) => const _KeyboardShortcutHelpDialog(),
    );
  } finally {
    _helpVisible = false;
  }
}

/// Used by the application action as well as tests. Text editing retains all
/// keystrokes, including help chords, without opening another route.
void invokeKeyboardShortcutHelp(BuildContext? context) {
  if (context == null || isEditableTextFocused()) return;
  unawaited(showKeyboardShortcutHelp(context));
}

class _KeyboardShortcutHelpDialog extends StatelessWidget {
  const _KeyboardShortcutHelpDialog();

  @override
  Widget build(BuildContext context) {
    String library(DesktopMediaManagementShortcutAction action) =>
        DesktopMediaManagementShortcuts.shortcutLabel(action);
    String player(DesktopPlayerShortcutAction action) =>
        DesktopPlayerShortcuts.shortcutLabel(action);
    final groups = <(String, List<(String, String)>)>[
      (
        '通用',
        [
          ('快捷键帮助', 'F1 / Ctrl+/ / ⌘+/'),
          ('返回 / 关闭当前弹窗；输入时先退出输入', 'Esc'),
          ('桌面窗口全屏', 'F11'),
        ],
      ),
      (
        '首页与合集',
        [
          ('向上 / 向下滚动当前页面（可长按）', '↑ / ↓'),
          (
            '展开 / 收起操作按钮',
            library(DesktopMediaManagementShortcutAction.toggleActionButtons),
          ),
          ('搜索 / 媒体库设置', 'S / P'),
          ('新建合集 / 导入媒体', 'N / I'),
          ('语音转录 / 批量字幕导入 / 导入与导出', 'C / M / X'),
          ('切换视图 / 卡片样式 / 批量选择 / 全选', 'V / T / B / A'),
          ('多选时：移入回收站 / 导出 / 重命名（仅单项）', 'R / X / N'),
          ('媒体库首页：按当前入口顺序直达（含小键盘）', '1～3'),
          ('媒体库首页：下一个 / 上一个入口', 'Ctrl+Tab / Ctrl+Shift+Tab'),
          ('输入、弹窗、播放器或批量选择时不切换入口', '仅浏览时生效'),
          ('首页入口排序：长按入口后拖动；侧栏使用相同顺序', '触控与鼠标相同'),
          ('焦点向后 / 向前移动；侧栏用可见按钮展开或收起', 'Tab / Shift+Tab'),
          ('搜索：确认搜索；中文输入时先确认候选文字', 'Enter'),
          ('定时关闭 / 回收站', 'Z / R'),
        ],
      ),
      (
        '视频播放（保留原有按键）',
        [
          ('播放 / 暂停', player(DesktopPlayerShortcutAction.playPause)),
          ('快退 / 快进；音量增减', '← / →；↑ / ↓'),
          ('上一集 / 下一集 / 选集', 'P / N / G'),
          ('静音 / 字幕开关 / 字幕侧栏', 'M / C / B'),
          ('字幕分页；切换分页；横屏侧栏展开收起', 'Alt+← / →；I；B'),
          ('设置 / 字幕库 / 字幕编辑', 'S / L / E'),
          ('字幕样式 / 移动字幕 / OCR / AI', 'T / J / O / W'),
          ('倍速减小 / 增大', '[ / ]，或 Shift+← / →'),
          ('全屏 / 锁定 / 定时关闭', 'F / K / Z'),
        ],
      ),
      (
        '音乐播放',
        [
          ('播放 / 暂停；快退 / 快进；音量', 'Space；← / →；↑ / ↓'),
          ('上一首 / 下一首 / 选集', 'P / N / G'),
          ('页面设置 / 字幕管理 / AI / 定时关闭', 'S / L / W / Z'),
          ('静音 / 桌面全屏', 'M / F'),
        ],
      ),
      (
        '存储管理 / 设备同步',
        [('存储：重新扫描 / 复制诊断摘要', 'R / C'), ('设备同步：立即同步 / 发送文件夹', 'R / N')],
      ),
    ];
    return AlertDialog(
      title: const Text('键盘快捷键'),
      content: SizedBox(
        width: 660,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '单字母与数字快捷键只在当前页面、未输入文字时生效。弹窗和隐藏页面不会触发底层操作。'
                'Windows、macOS、Linux，以及连接外接键盘的 Android / iOS 使用同一套页面按键。'
                '操作不可用时，快捷键也不会执行。',
              ),
              const SizedBox(height: 12),
              for (final (title, rows) in groups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final (label, keys) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 4,
                      children: [
                        Text(label),
                        Text(
                          keys,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              const Text(
                '页面单字母只在应用内生效。本地媒体后台播放控制可在媒体库设置 → 桌面媒体控制中设置。'
                'Windows / macOS 可开启 Ctrl+Alt+Space 播放/暂停、Ctrl+Alt+← / → 上一项/下一项，'
                '也可改用 Ctrl+Alt+Shift 组合。Linux 媒体键由桌面环境处理。'
                'Android / iOS 的后台媒体键沿用系统媒体会话。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ),
      ],
    );
  }
}
