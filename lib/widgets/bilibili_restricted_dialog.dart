import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Presentation only: login and suppression policy remain with the home screen.
class BilibiliRestrictedDialog extends StatelessWidget {
  const BilibiliRestrictedDialog({
    super.key,
    required this.dontShowAgain,
    required this.onDontShowAgainChanged,
    required this.onDefer,
    required this.onLogin,
  });

  final bool dontShowAgain;
  final ValueChanged<bool> onDontShowAgainChanged;
  final VoidCallback onDefer;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFF2C2C2C),
    title: const Text('B站功能受限提示', style: TextStyle(color: Colors.white)),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '检测到您尚未登录或Cookie已过期。\n\n登录后可使用 B 站专用播放和解析功能。剪贴板链接仍可导入浏览器或通用下载页。',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => onDontShowAgainChanged(!dontShowAgain),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: dontShowAgain,
                  onChanged: (value) => onDontShowAgainChanged(value ?? false),
                  fillColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? const Color(0xFFFB7299)
                        : Colors.grey,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Flexible(
                child: Text('之后不显示', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ],
    ),
    actions: [
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: onDefer,
          child: const Text('暂不登录', style: TextStyle(color: Colors.white70)),
        ),
      ),
      DesktopButtonClickRegion(
        child: ElevatedButton(
          onPressed: onLogin,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFB7299),
            foregroundColor: const Color(0xFF28131A),
          ),
          child: const Text('去登录'),
        ),
      ),
    ],
  );
}
