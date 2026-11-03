import 'package:flutter/material.dart';

import '../models/cloud_drive_models.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class CloudDriveFailurePanel extends StatelessWidget {
  const CloudDriveFailurePanel({
    super.key,
    required this.message,
    required this.needsLogin,
    required this.onRetry,
    required this.onBack,
    this.onRelogin,
  });

  final String message;
  final bool needsLogin;
  final VoidCallback onRetry;
  final VoidCallback onBack;
  final VoidCallback? onRelogin;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (needsLogin && onRelogin != null)
                      DesktopButtonClickRegion(
                        child: FilledButton(
                          onPressed: onRelogin,
                          child: const Text('重新登录'),
                        ),
                      ),
                    DesktopButtonClickRegion(
                      child: FilledButton(
                        onPressed: onRetry,
                        child: const Text('重试'),
                      ),
                    ),
                    DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: onBack,
                        child: const Text('返回目录'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool cloudDriveFailureNeedsLogin(CloudDriveFailureKind? kind) =>
    kind == CloudDriveFailureKind.notLoggedIn;
