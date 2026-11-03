import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';
import 'package:video_player_app/services/network/scoped_network_image.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_qr_login_controller.dart';
import 'package:video_player_app/services/bilibili/bilibili_login_policy.dart';
import 'package:video_player_app/screens/bilibili/bilibili_web_login_screen.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/stable_width_label.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

enum _BilibiliLoginMethod { qr, web }

Future<void> showBilibiliLoginDialog(
  BuildContext context, {
  bool suppressToasts = false,
}) async {
  final service = context.read<BilibiliDownloadService>();
  final cookieController = TextEditingController();
  try {
    final loginState = await service.apiService.fetchLoginState();
    if (!context.mounted) return;

    final account = loginState.account;
    final (statusText, statusColor) = switch (loginState.status) {
      BilibiliLoginStatus.loggedIn => (
        account == null ? '已登录' : '已登录：${account.name}',
        Colors.green,
      ),
      BilibiliLoginStatus.loggedOut => ('未登录', Colors.grey),
      BilibiliLoginStatus.expired => ('已过期，请重新登录', Colors.orange),
      BilibiliLoginStatus.networkError => ('已保存（当前无法联网验证）', Colors.orange),
    };
    final canLogout = loginState.status != BilibiliLoginStatus.loggedOut;

    final method = await showDialog<_BilibiliLoginMethod>(
      context: context,
      builder: (dialogContext) => _ResponsiveLoginDialog(
        statusText: statusText,
        statusColor: statusColor,
        avatarUrl: account?.avatarUrl ?? '',
        cookieController: cookieController,
        onLogout: canLogout
            ? () async {
                await service.apiService.logout();
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
              }
            : null,
        onQrLogin: () {
          Navigator.of(dialogContext).pop(_BilibiliLoginMethod.qr);
        },
        onWebLogin: BilibiliLoginPolicy.supportsWebLogin(defaultTargetPlatform)
            ? () {
                Navigator.of(dialogContext).pop(_BilibiliLoginMethod.web);
              }
            : null,
        onSave: () async {
          final input = cookieController.text.trim();
          if (input.isEmpty) return '请输入 Cookie';
          try {
            // Verified with nav first; only saved when Bilibili confirms.
            await service.apiService.loginWithCookieInput(input);
          } on BilibiliAuthException catch (error) {
            return error.message;
          }
          if (!dialogContext.mounted) return null;
          unawaited(
            dialogContext.read<SettingsService>().updateSetting(
              'suppressBilibiliRestrictedDialog',
              false,
            ),
          );
          Navigator.of(dialogContext).pop();
          return null;
        },
      ),
    );
    if (!context.mounted) return;
    if (method == _BilibiliLoginMethod.qr) {
      await showBilibiliQrCodeDialog(context, suppressToasts: suppressToasts);
    } else if (method == _BilibiliLoginMethod.web) {
      final account = await Navigator.of(context).push<BilibiliAccountInfo>(
        MaterialPageRoute(
          builder: (_) => BilibiliWebLoginScreen(api: service.apiService),
        ),
      );
      if (account != null && context.mounted) {
        unawaited(
          context.read<SettingsService>().updateSetting(
            'suppressBilibiliRestrictedDialog',
            false,
          ),
        );
      }
    }
  } finally {
    cookieController.dispose();
  }
}

class _ResponsiveLoginDialog extends StatefulWidget {
  final String statusText;
  final Color statusColor;
  final String avatarUrl;
  final TextEditingController cookieController;
  final VoidCallback onQrLogin;
  final VoidCallback? onWebLogin;

  /// Null when the cookie was saved. Otherwise the message to show in the form.
  final Future<String?> Function() onSave;
  final Future<void> Function()? onLogout;

  const _ResponsiveLoginDialog({
    required this.statusText,
    required this.statusColor,
    required this.avatarUrl,
    required this.cookieController,
    required this.onQrLogin,
    this.onWebLogin,
    required this.onSave,
    required this.onLogout,
  });

  @override
  State<_ResponsiveLoginDialog> createState() => _ResponsiveLoginDialogState();
}

class _ResponsiveLoginDialogState extends State<_ResponsiveLoginDialog> {
  bool _busy = false;
  String? _formError;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      final error = await widget.onSave();
      if (!mounted) return;
      if (error != null) setState(() => _formError = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get statusText => widget.statusText;
  Color get statusColor => widget.statusColor;
  TextEditingController get cookieController => widget.cookieController;

  @override
  Widget build(BuildContext context) {
    return DialogKeyboardViewport(
      child: Dialog(
        insetAnimationDuration: Duration.zero,
        insetPadding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 430;
            final wide = constraints.maxWidth >= 500;
            final gap = compact ? 8.0 : 14.0;
            final cookieField = TextField(
              controller: cookieController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'B 站 Cookie',
                hintText: '粘贴 SESSDATA 或完整 Cookie',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            );
            final qrButton = DesktopButtonClickRegion(
              child: ElevatedButton.icon(
                onPressed: _busy ? null : widget.onQrLogin,
                icon: const Icon(Icons.qr_code_rounded),
                label: const Text('扫码登录'),
              ),
            );

            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, compact ? 12 : 18, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Bilibili 登录',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: compact ? 2 : 6),
                    Row(
                      children: [
                        if (widget.avatarUrl.isNotEmpty) ...[
                          CircleAvatar(
                            radius: 12,
                            backgroundImage: ScopedNetworkImage(
                              widget.avatarUrl,
                            ),
                            onBackgroundImageError: (_, _) {},
                          ),
                          const SizedBox(width: 8),
                        ],
                        const Text('状态：'),
                        Flexible(
                          child: Text(
                            statusText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: gap),
                    if (widget.onWebLogin != null) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: DesktopButtonClickRegion(
                          child: FilledButton.icon(
                            onPressed: _busy ? null : widget.onWebLogin,
                            icon: const Icon(Icons.language),
                            label: const Text('官方网页登录（手机号 / 密码）'),
                          ),
                        ),
                      ),
                      SizedBox(height: gap),
                    ],
                    const Text(
                      '登录用于读取账号可访问的视频和字幕；也可使用扫码或官方网页登录。',
                      style: TextStyle(fontSize: 12),
                    ),
                    SizedBox(height: gap),
                    if (wide)
                      Row(
                        children: [
                          qrButton,
                          SizedBox(width: gap),
                          Expanded(child: cookieField),
                        ],
                      )
                    else ...[
                      Align(alignment: Alignment.centerLeft, child: qrButton),
                      SizedBox(height: gap),
                      cookieField,
                    ],
                    if (_formError case final formError?) ...[
                      SizedBox(height: gap),
                      Text(
                        formError,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    SizedBox(height: gap),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (widget.onLogout != null) ...[
                          DesktopButtonClickRegion(
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(widget.onLogout!),
                              child: const Text('退出登录'),
                            ),
                          ),
                          const Spacer(),
                        ],
                        DesktopButtonClickRegion(
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        DesktopButtonClickRegion(
                          child: ElevatedButton(
                            onPressed: _busy ? null : _save,
                            child: StableWidthLabel(
                              _busy ? '验证中…' : '保存',
                              variants: const ['保存', '验证中…'],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

Future<void> showBilibiliQrCodeDialog(
  BuildContext context, {
  bool suppressToasts = false,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => BilibiliQrCodeDialog(suppressToasts: suppressToasts),
  );
}

class BilibiliQrCodeDialog extends StatefulWidget {
  const BilibiliQrCodeDialog({super.key, this.suppressToasts = false});

  final bool suppressToasts;

  @override
  State<BilibiliQrCodeDialog> createState() => _BilibiliQrCodeDialogState();
}

class _BilibiliQrCodeDialogState extends State<BilibiliQrCodeDialog> {
  late final BilibiliQrLoginController _qr = BilibiliQrLoginController(
    api: context.read<BilibiliDownloadService>().apiService,
    onLoggedIn: (_) => _handleLoggedIn(),
  )..addListener(_handleQrChanged);

  String? get qrUrl => _qr.qrUrl;
  String get status => _qr.status;
  String? get errorMessage => _qr.errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_qr.start());
  }

  @override
  void dispose() {
    _qr.dispose();
    super.dispose();
  }

  void _handleQrChanged() {
    if (mounted) setState(() {});
  }

  void _generateQrCode() => unawaited(_qr.start());

  void _handleLoggedIn() {
    if (!mounted) return;
    unawaited(
      context.read<SettingsService>().updateSetting(
        'suppressBilibiliRestrictedDialog',
        false,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 420;
          final horizontal =
              compact && constraints.maxWidth >= constraints.maxHeight * 1.25;
          final reservedHeight = horizontal ? 44.0 : (compact ? 112.0 : 132.0);
          final qrSize = math.min(
            horizontal
                ? constraints.maxWidth * 0.42
                : constraints.maxWidth - 48,
            (constraints.maxHeight - reservedHeight).clamp(88.0, 220.0),
          );
          final qr = SizedBox.square(
            dimension: qrSize,
            child: qrUrl != null
                ? ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: QrImageView(
                        data: qrUrl!,
                        version: QrVersions.auto,
                      ),
                    ),
                  )
                : Center(child: _buildQrPlaceholder()),
          );
          final details = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                errorMessage ?? status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: errorMessage == null ? null : Colors.red,
                ),
              ),
              SizedBox(height: compact ? 6 : 12),
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
            ],
          );

          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: EdgeInsets.all(compact ? 10 : 18),
              child: horizontal
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        qr,
                        const SizedBox(width: 16),
                        Flexible(child: details),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '扫码登录',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: compact ? 6 : 12),
                        qr,
                        SizedBox(height: compact ? 6 : 12),
                        details,
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildQrPlaceholder() {
    if (errorMessage != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 34),
          const SizedBox(height: 6),
          DesktopButtonClickRegion(
            child: ElevatedButton(
              onPressed: _generateQrCode,
              child: const Text('重试'),
            ),
          ),
        ],
      );
    }
    if (_qr.isExpired) {
      return DesktopButtonClickRegion(
        child: ElevatedButton(
          onPressed: _generateQrCode,
          child: const Text('刷新二维码'),
        ),
      );
    }
    return const Text(
      '正在获取二维码',
      style: TextStyle(color: Colors.white70, fontSize: 13),
    );
  }
}
