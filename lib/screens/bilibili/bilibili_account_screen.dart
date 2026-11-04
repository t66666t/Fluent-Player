import 'dart:async';
import '../network_settings_screen.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:video_player_app/screens/bilibili/bilibili_settings_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_history_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_favorites_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_qr_login_controller.dart';
import 'package:video_player_app/services/bilibili/bilibili_login_policy.dart';
import 'bilibili_web_login_screen.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/bilibili_image_url.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';
import 'package:video_player_app/widgets/bilibili_login_dialogs.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/stable_width_label.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Opens the account page. [api] defaults to the app's Bilibili service;
/// [onStateChanged] hears every login state the page shows, so the caller's
/// avatar can follow without waiting for the page to close.
Future<void> openBilibiliAccount(
  BuildContext context, {
  BilibiliApiService? api,
  ValueChanged<BilibiliLoginState>? onStateChanged,
}) {
  return pushAboveMediaLibrary(
    context,
    AppMaterialPageRoute<void>(
      builder: (_) =>
          BilibiliAccountScreen(api: api, onStateChanged: onStateChanged),
    ),
  );
}

/// Bilibili account: QR login when logged out; avatar, name, state and
/// logout when logged in; links to the Bilibili settings and watch history.
class BilibiliAccountScreen extends StatefulWidget {
  const BilibiliAccountScreen({
    super.key,
    this.api,
    this.settings,
    this.onStateChanged,
    this.openOtherLogin,
    this.platform,
  });

  final BilibiliApiService? api;
  final SettingsService? settings;
  final ValueChanged<BilibiliLoginState>? onStateChanged;

  /// Other ways to log in (pasting a cookie); defaults to the existing login
  /// dialog when the app's Bilibili service is available.
  final Future<void> Function(BuildContext context)? openOtherLogin;
  final TargetPlatform? platform;

  @override
  State<BilibiliAccountScreen> createState() => _BilibiliAccountScreenState();
}

class _BilibiliAccountScreenState extends State<BilibiliAccountScreen> {
  late final SettingsService _settings = widget.settings ?? SettingsService();
  late final BilibiliApiService? _api = widget.api ?? _appApi();

  BilibiliLoginState? _state;
  bool _loggingOut = false;
  String? _notice;

  /// Expired or network-error login the user chose to replace by scanning.
  bool _relogin = false;
  BilibiliQrLoginController? _qr;
  bool _qrRequested = false;

  bool get _usesWebLogin => BilibiliLoginPolicy.supportsWebLogin(
    widget.platform ?? defaultTargetPlatform,
  );

  @override
  void initState() {
    super.initState();
    final cached = _api?.cachedLoginState;
    if (cached != null) _state = cached;
    // A known login paints immediately. A silent refresh updates it later
    // without covering the card. Logged-out still checks, in the same frame.
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _qr?.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  BilibiliApiService? _appApi() {
    try {
      return context.read<BilibiliDownloadService>().apiService;
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null) {
      // No Bilibili service (tests, early start): show logged out.
      _state = const BilibiliLoginState(BilibiliLoginStatus.loggedOut);
      return;
    }
    BilibiliLoginState state;
    try {
      await api.init();
      state = await api.fetchLoginState();
    } catch (_) {
      state = const BilibiliLoginState(BilibiliLoginStatus.networkError);
    }
    _apply(state);
  }

  void _apply(BilibiliLoginState state) {
    if (!mounted) return;
    setState(() {
      _state = state;
      if (state.status == BilibiliLoginStatus.loggedIn) {
        _relogin = false;
        _notice = null;
      }
    });
    widget.onStateChanged?.call(state);
    _syncQr();
  }

  bool get _showQr {
    final status = _state?.status;
    if (status == null) return false;
    return (status == BilibiliLoginStatus.loggedOut || _relogin) &&
        (!_usesWebLogin || _qrRequested);
  }

  bool get _showWebLogin =>
      _usesWebLogin &&
      (_state?.status == BilibiliLoginStatus.loggedOut || _relogin);

  Future<void> _openWebLogin() async {
    final api = _api;
    if (api == null) return;
    _qr?.dispose();
    _qr = null;
    final account = await Navigator.of(context).push<BilibiliAccountInfo>(
      MaterialPageRoute(builder: (_) => BilibiliWebLoginScreen(api: api)),
    );
    if (!mounted) return;
    if (account != null) {
      await _handleLoggedIn();
    } else {
      _syncQr();
    }
  }

  /// Runs the shared QR login only while the QR panel is on screen.
  void _syncQr() {
    final api = _api;
    if (_showQr && api != null) {
      if (_qr != null) return;
      final qr = BilibiliQrLoginController(
        api: api,
        onLoggedIn: (_) => unawaited(_handleLoggedIn()),
      )..addListener(_rebuild);
      _qr = qr;
      unawaited(qr.start());
    } else if (!_showQr && _qr != null) {
      _qr!.dispose();
      _qr = null;
    }
  }

  Future<void> _handleLoggedIn() async {
    unawaited(
      _settings.updateSetting<bool>('suppressBilibiliRestrictedDialog', false),
    );
    _notice = null;
    _relogin = false;
    _qrRequested = false;
    await _refresh();
  }

  Future<void> _logout() async {
    final api = _api;
    if (api == null || _loggingOut) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('会删除本机保存的 B 站登录信息，之后需要重新登录。'),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.brandBilibili,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('退出'),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _loggingOut = true);
    try {
      await api.logout();
      _notice = null;
    } catch (_) {
      if (mounted) setState(() => _notice = '退出失败，请重试');
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
    _relogin = false;
    await _refresh();
  }

  void _startRelogin() {
    setState(() => _relogin = true);
    _syncQr();
  }

  Future<void> Function(BuildContext context)? get _otherLogin {
    final own = widget.openOtherLogin;
    if (own != null) return own;
    try {
      context.read<BilibiliDownloadService>();
    } on ProviderNotFoundException {
      return null;
    }
    return (context) => showBilibiliLoginDialog(context);
  }

  /// The old dialog (SESSDATA / cookie). Afterwards the page and the caller's
  /// avatar follow whatever login it left.
  Future<void> _openOtherLogin() async {
    final open = _otherLogin;
    if (open == null) return;
    await open(context);
    if (!mounted) return;
    _relogin = false;
    await _refresh();
  }

  void _cancelRelogin() {
    setState(() => _relogin = false);
    _syncQr();
  }

  @override
  Widget build(BuildContext context) {
    return BilibiliQuietTap(
      child: Scaffold(
        backgroundColor: AppTokens.bgBase,
        appBar: AppBar(
          backgroundColor: AppTokens.bgBase,
          foregroundColor: AppTokens.text1,
          elevation: 0,
          title: const Text('B 站账号', style: TextStyle(fontSize: 16)),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _card(_buildAccount()),
              if (_showWebLogin) ...[
                const SizedBox(height: 12),
                _card(_buildLoginOptions()),
              ],
              if (_showQr) ...[const SizedBox(height: 12), _card(_buildQr())],
              const SizedBox(height: 18),
              _card(_buildLinks()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAccount() {
    final state =
        _state ?? const BilibiliLoginState(BilibiliLoginStatus.loggedOut);
    final pending = _state == null;
    final account = state.account;
    final (label, color) = switch (state.status) {
      BilibiliLoginStatus.loggedIn when pending => (
        '正在确认登录状态',
        AppTokens.text3,
      ),
      BilibiliLoginStatus.loggedIn => ('已登录', const Color(0xFF4CAF50)),
      BilibiliLoginStatus.loggedOut when pending => (
        '正在确认登录状态',
        AppTokens.text3,
      ),
      BilibiliLoginStatus.loggedOut => ('未登录', AppTokens.text3),
      BilibiliLoginStatus.expired => ('登录已过期', const Color(0xFFFFA726)),
      BilibiliLoginStatus.networkError => (
        '网络错误，暂时无法验证',
        const Color(0xFFFFA726),
      ),
    };
    final name = switch (state.status) {
      BilibiliLoginStatus.loggedIn when pending => 'B 站账号',
      BilibiliLoginStatus.loggedIn => account?.name ?? '已登录用户',
      BilibiliLoginStatus.loggedOut when pending => 'B 站账号',
      BilibiliLoginStatus.loggedOut => '未登录 B 站',
      BilibiliLoginStatus.expired => '登录已过期',
      BilibiliLoginStatus.networkError => account?.name ?? 'B 站账号',
    };
    final avatar = bilibiliAvatarUrl(account?.avatarUrl);
    final hasLogin = !pending && state.status != BilibiliLoginStatus.loggedOut;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              avatar == null
                  ? const Icon(
                      Icons.account_circle_outlined,
                      size: 56,
                      color: AppTokens.text3,
                    )
                  : BilibiliAvatar(url: avatar, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      key: const ValueKey('bilibili-account-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTokens.text1,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.circle, size: 8, color: color),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            label,
                            key: const ValueKey('bilibili-account-status'),
                            style: TextStyle(color: color, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_notice case final notice?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                notice,
                key: const ValueKey('bilibili-account-notice'),
                style: const TextStyle(color: AppTokens.danger, fontSize: 12),
              ),
            ),
          SizedBox(
            height: hasLogin ? null : 40,
            child: hasLogin
                ? Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      if (state.status == BilibiliLoginStatus.loggedIn &&
                          _usesWebLogin)
                        DesktopButtonClickRegion(
                          child: TextButton.icon(
                            key: const ValueKey('bilibili-account-web-relogin'),
                            onPressed: _openWebLogin,
                            icon: const Icon(Icons.language),
                            label: const Text('官方网页登录'),
                          ),
                        ),
                      if (state.status == BilibiliLoginStatus.expired &&
                          !_relogin)
                        DesktopButtonClickRegion(
                          child: FilledButton(
                            key: const ValueKey('bilibili-account-relogin'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTokens.brandBilibili,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _startRelogin,
                            child: const Text('重新登录'),
                          ),
                        ),
                      if (state.status == BilibiliLoginStatus.networkError)
                        DesktopButtonClickRegion(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTokens.text1,
                              side: const BorderSide(color: AppTokens.text4),
                            ),
                            onPressed: () => unawaited(_refresh()),
                            child: const Text('重试'),
                          ),
                        ),
                      if (state.status == BilibiliLoginStatus.expired &&
                          !_relogin &&
                          _otherLogin != null)
                        DesktopButtonClickRegion(
                          child: TextButton(
                            key: const ValueKey(
                              'bilibili-account-other-login-expired',
                            ),
                            onPressed: () => unawaited(_openOtherLogin()),
                            style: TextButton.styleFrom(
                              foregroundColor: AppTokens.text3,
                              visualDensity: VisualDensity.compact,
                            ),
                            child: const Text(
                              '其他登录方式',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      DesktopButtonClickRegion(
                        child: OutlinedButton(
                          key: const ValueKey('bilibili-account-logout'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTokens.text1,
                            side: const BorderSide(color: AppTokens.text4),
                          ),
                          onPressed: _loggingOut ? null : _logout,
                          child: StableWidthLabel(
                            _loggingOut ? '正在退出…' : '退出登录',
                            variants: const ['退出登录', '正在退出…'],
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox(height: 40),
          ),
        ],
      ),
    );
  }

  Widget _buildQr() {
    final qr = _qr;
    final url = qr?.qrUrl;
    final Widget code;
    if (url != null) {
      code = ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: QrImageView(data: url, version: QrVersions.auto),
        ),
      );
    } else if (qr == null) {
      code = const Center(
        child: Text('暂时无法登录', style: TextStyle(color: AppTokens.text2)),
      );
    } else if (qr.errorMessage != null || qr.isExpired) {
      code = Center(
        child: DesktopButtonClickRegion(
          child: FilledButton(
            key: const ValueKey('bilibili-account-qr-refresh'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.brandBilibili,
              foregroundColor: Colors.white,
            ),
            onPressed: () => unawaited(qr.start()),
            child: Text(qr.isExpired ? '刷新二维码' : '重试'),
          ),
        ),
      );
    } else {
      code = const Center(
        child: Text(
          '正在获取二维码',
          style: TextStyle(color: AppTokens.text2, fontSize: 13),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            _relogin ? '重新扫码登录' : '扫码登录',
            style: const TextStyle(
              color: AppTokens.text1,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox.square(
            key: const ValueKey('bilibili-account-qr'),
            dimension: 200,
            child: code,
          ),
          const SizedBox(height: 12),
          Text(
            qr?.errorMessage ?? qr?.status ?? '',
            key: const ValueKey('bilibili-account-qr-status'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: qr?.errorMessage == null
                  ? AppTokens.text2
                  : AppTokens.danger,
              fontSize: 13,
            ),
          ),
          if (_otherLogin != null)
            DesktopButtonClickRegion(
              child: TextButton(
                key: const ValueKey('bilibili-account-other-login'),
                onPressed: () => unawaited(_openOtherLogin()),
                style: TextButton.styleFrom(
                  foregroundColor: AppTokens.text3,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('其他登录方式', style: TextStyle(fontSize: 12)),
              ),
            ),
          if (_relogin) ...[
            const SizedBox(height: 6),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: _cancelRelogin,
                child: const Text(
                  '取消',
                  style: TextStyle(color: AppTokens.text2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLoginOptions() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '使用 B 站官方网页完成手机号、密码和人机验证登录。',
          style: TextStyle(color: AppTokens.text2),
        ),
        const SizedBox(height: 12),
        DesktopButtonClickRegion(
          child: FilledButton.icon(
            key: const ValueKey('bilibili-account-web-login'),
            onPressed: _api == null ? null : _openWebLogin,
            icon: const Icon(Icons.language),
            label: const Text('官方网页登录'),
          ),
        ),
        if (!_qrRequested)
          DesktopButtonClickRegion(
            child: TextButton.icon(
              key: const ValueKey('bilibili-account-use-qr'),
              onPressed: () {
                setState(() => _qrRequested = true);
                _syncQr();
              },
              icon: const Icon(Icons.qr_code),
              label: const Text('使用其他设备扫码登录'),
            ),
          ),
        if (!_qrRequested && _otherLogin != null)
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: _openOtherLogin,
              child: const Text('Cookie 登录'),
            ),
          ),
        if (_relogin && !_qrRequested)
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: _cancelRelogin,
              child: const Text('取消'),
            ),
          ),
      ],
    ),
  );

  Widget _buildLinks() {
    return Column(
      children: [
        _linkTile(
          key: const ValueKey('bilibili-account-favorites'),
          icon: Icons.folder_special_outlined,
          title: 'B 站收藏夹',
          onTap: () =>
              unawaited(openBilibiliFavorites(context, accountApi: _api)),
        ),
        const Divider(height: 1, color: AppTokens.lineSubtle),
        _linkTile(
          key: const ValueKey('bilibili-account-settings'),
          icon: Icons.settings_outlined,
          title: 'B 站设置',
          onTap: () => unawaited(openBilibiliSettings(context)),
        ),
        const Divider(height: 1, color: AppTokens.lineSubtle),
        _linkTile(
          key: const ValueKey('bilibili-account-history'),
          icon: Icons.history,
          title: '观看历史',
          onTap: () => unawaited(openBilibiliWatchHistory(context)),
        ),
        const Divider(height: 1, color: AppTokens.lineSubtle),
        _linkTile(
          key: const ValueKey('bilibili-account-network-settings'),
          icon: Icons.language_outlined,
          title: '网络设置',
          onTap: () => unawaited(openNetworkSettings(context)),
        ),
      ],
    );
  }

  Widget _linkTile({
    required Key key,
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      key: key,
      leading: Icon(icon, size: 20, color: AppTokens.text2),
      title: Text(
        title,
        style: const TextStyle(color: AppTokens.text1, fontSize: 15),
      ),
      trailing: const Icon(
        Icons.chevron_right,
        size: 20,
        color: AppTokens.text3,
      ),
      onTap: onTap,
    );
  }

  Widget _card(Widget child) {
    return Material(
      color: AppTokens.bgCard,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
