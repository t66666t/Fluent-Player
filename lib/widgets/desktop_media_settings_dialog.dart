import 'dart:io';

import 'package:flutter/material.dart';

import '../services/desktop_media_session_service.dart';
import '../services/settings_service.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> showDesktopMediaSettings(
  BuildContext context,
  SettingsService settings,
) => showDialog<void>(
  context: context,
  builder: (_) => _DesktopMediaSettings(settings: settings),
);

class _DesktopMediaSettings extends StatelessWidget {
  const _DesktopMediaSettings({required this.settings});
  final SettingsService settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => ValueListenableBuilder<Map<String, Object?>>(
      valueListenable: DesktopMediaSessionService.instance.status,
      builder: (context, status, _) {
        final windows = Platform.isWindows;
        final globalSupported = status['globalHotkeys'] == true;
        final modifiers =
            settings.desktopMediaHotkeyModifiers == 'ctrl+alt+shift'
            ? 'Ctrl+Alt+Shift'
            : 'Ctrl+Alt';
        return AlertDialog(
          title: const Text('桌面媒体控制'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '最小化或切换到其他软件后仍可控制当前播放。上一项、下一项使用播放器原有队列。关闭窗口并退出应用后，控制随之结束。',
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    key: const ValueKey('desktop-system-media'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('系统媒体面板与媒体键'),
                    subtitle: Text(
                      windows
                          ? '在 Windows 媒体面板显示标题、封面和播放控件；键盘、耳机媒体键由系统分配。'
                          : Platform.isMacOS
                          ? '接入 macOS 正在播放与媒体键。'
                          : '接入 Linux MPRIS，媒体控件由桌面环境显示。',
                    ),
                    value: settings.desktopSystemMediaControls,
                    onChanged: (value) => settings.updateSetting(
                      'desktopSystemMediaControls',
                      value,
                    ),
                  ),
                  if (windows)
                    SwitchListTile.adaptive(
                      key: const ValueKey('desktop-taskbar-media'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('任务栏预览播放按钮'),
                      subtitle: const Text(
                        '鼠标悬停在任务栏图标上，显示上一项、快退、播放/暂停、快进、下一项和播放模式。跳转沿用现有秒数或字幕设置，播放模式点击后依次切换。',
                      ),
                      value: settings.desktopTaskbarMediaControls,
                      onChanged: (value) => settings.updateSetting(
                        'desktopTaskbarMediaControls',
                        value,
                      ),
                    ),
                  if (globalSupported) ...[
                    SwitchListTile.adaptive(
                      key: const ValueKey('desktop-global-hotkeys'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('全局组合快捷键'),
                      subtitle: const Text('只在存在播放会话时注册。启用后，在其他软件里也会生效。'),
                      value: settings.desktopGlobalMediaHotkeys,
                      onChanged: (value) => settings.updateSetting(
                        'desktopGlobalMediaHotkeys',
                        value,
                      ),
                    ),
                    DropdownButtonFormField<String>(
                      key: ValueKey(settings.desktopMediaHotkeyModifiers),
                      initialValue: settings.desktopMediaHotkeyModifiers,
                      decoration: const InputDecoration(labelText: '快捷键组合'),
                      items: const [
                        DropdownMenuItem(
                          value: 'ctrl+alt',
                          child: Text('Ctrl + Alt'),
                        ),
                        DropdownMenuItem(
                          value: 'ctrl+alt+shift',
                          child: Text('Ctrl + Alt + Shift'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          settings.updateSetting(
                            'desktopMediaHotkeyModifiers',
                            value,
                          );
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '$modifiers + Space：播放 / 暂停\n$modifiers + ←：上一项\n$modifiers + →：下一项',
                    ),
                    if (settings.desktopGlobalMediaHotkeys &&
                        status['hotkeysRegistered'] != true &&
                        (status['error'] as String? ?? '').isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('播放媒体后启用全局组合键。'),
                      ),
                  ] else if (Platform.isLinux)
                    const Text(
                      'Linux 通过桌面环境的媒体键控制；如需自定义全局组合键，可在系统键盘设置中绑定媒体播放操作。兼容 X11 和 Wayland，不强行占用全局按键。',
                    ),
                  if ((status['error'] as String? ?? '').isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      '媒体控制未能完全启用。若快捷键被占用，请切换上方组合或关闭冲突软件。\n${status['error']}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ),
          ],
        );
      },
    ),
  );
}
