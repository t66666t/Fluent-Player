import 'package:flutter/material.dart';
import '../../../services/app_web_navigation.dart';

import '../auth/cloud_drive_login_browser.dart';
import '../providers/cloud_drive_provider.dart';
import '../services/cloud_drive_account_repository.dart';

/// Compatibility route for old navigation; credentials stay on the official site.
class CloudDriveLoginScreen extends StatefulWidget {
  const CloudDriveLoginScreen({
    super.key,
    required this.provider,
    required this.accounts,
    this.browser,
  });

  final CloudDriveProvider provider;
  final CloudDriveAccountRepository accounts;
  final CloudDriveLoginClient? browser;

  @override
  State<CloudDriveLoginScreen> createState() =>
      _CommunityCloudDriveLoginScreenState();
}

class _CommunityCloudDriveLoginScreenState
    extends State<CloudDriveLoginScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.provider.displayName)),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('网盘接口尚未取得并核实官方应用授权。请在官方网盘管理文件，开源版不读取登录 Cookie。'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => AppWebNavigation.open(
                context,
                widget.provider.loginUri,
                title: widget.provider.displayName,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('打开官方网盘'),
            ),
          ],
        ),
      ),
    ),
  );
}
