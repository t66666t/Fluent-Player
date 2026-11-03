import '../../../widgets/embedded_browser_diagnostics_action.dart';
import '../../../services/browser/embedded_browser_diagnostics.dart';
import '../../../widgets/media_library_safe_area.dart';
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../widgets/embedded_browser_view.dart';
import '../auth/cloud_drive_login_browser.dart';
import '../models/cloud_drive_models.dart';
import '../providers/cloud_drive_provider.dart';
import '../services/cloud_drive_account_repository.dart';
import '../../web_media/web_media_browser_controls.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Official web login. Detection is single-flight and stops when the page closes.
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
  State<CloudDriveLoginScreen> createState() => _CloudDriveLoginScreenState();
}

class _CloudDriveLoginScreenState extends State<CloudDriveLoginScreen>
    with WidgetsBindingObserver {
  late final CloudDriveLoginClient _browser =
      widget.browser ?? CloudDriveLoginBrowser(widget.provider);
  Timer? _poll;
  Timer? _loadDeadline;
  InAppWebViewController? _controller;
  var _checking = false;
  var _closed = false;
  var _ready = false;
  bool _foreground = true;
  String? _message;

  final _preparationLease =
      'prepare:cloud-login:${DateTime.now().microsecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    unawaited(EmbeddedBrowserDiagnostics.start(_preparationLease));
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _browser.prepare();
      if (!mounted || _closed) return;
      setState(() => _ready = true);
      _loadDeadline = Timer(const Duration(seconds: 25), () {
        if (mounted && !_closed) {
          setState(() => _message = '网页加载较慢，可刷新网页后重试');
        }
      });
      _poll = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_check());
      });
      unawaited(_check());
    } catch (_) {
      if (mounted) setState(() => _message = cloudDriveLoginFailureMessage());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check({bool manual = false}) async {
    if (_closed ||
        !_ready ||
        _checking ||
        !mounted ||
        (defaultTargetPlatform != TargetPlatform.linux &&
            _controller == null) ||
        (!_foreground && defaultTargetPlatform != TargetPlatform.linux)) {
      return;
    }
    _checking = true;
    try {
      final cookies = await _browser.readCookies(webView: _controller);
      final credential = _browser.credentialFrom(cookies);
      if (credential == null) {
        if (manual && mounted) {
          setState(() => _message = _missingSessionMessage(cookies));
        }
        return;
      }
      final verified = await widget.provider.verifySession(credential);
      if (_closed || !mounted) return;
      final account = await widget.accounts.commitVerified(
        providerId: widget.provider.id,
        remoteAccountId: verified.remoteAccountId,
        displayName: verified.displayName,
        avatar: verified.avatar,
        credential: verified.refreshedCredential ?? credential,
        driveId: verified.driveId,
      );
      _closed = true;
      _stopTimers();
      if (mounted) Navigator.of(context).pop(account);
    } on CloudDriveFailure catch (error) {
      if (mounted &&
          (manual || error.kind != CloudDriveFailureKind.notLoggedIn)) {
        setState(() => _message = error.message);
      }
    } catch (_) {
      if (manual && mounted) {
        setState(() => _message = '暂时无法确认登录状态，请稍后重试');
      }
    } finally {
      _checking = false;
    }
  }

  String _missingSessionMessage(List<CloudDriveCookie> cookies) {
    if (widget.provider.id == 'aliyun') {
      return '请在阿里云盘官方页面完成登录，进入文件列表后再检测登录状态';
    }
    final drive = widget.provider.displayName;
    if (cookies.isEmpty) {
      return '没有从当前网页读到 $drive 的登录 Cookie。请确认页面已登录后再检测。';
    }
    final names = cookies
        .map((cookie) => cookie.name)
        .toSet()
        .take(12)
        .join('、');
    return '没有读到 $drive 登录会话。当前读到的 Cookie 名称：$names';
  }

  Future<void> _reload() async {
    setState(() => _message = null);
    try {
      if (defaultTargetPlatform == TargetPlatform.linux) {
        await _browser.reload();
      } else {
        await _controller?.reload();
      }
    } catch (_) {
      if (mounted) setState(() => _message = cloudDriveLoginFailureMessage());
    }
  }

  void _stopTimers() {
    _poll?.cancel();
    _loadDeadline?.cancel();
    _poll = null;
    _loadDeadline = null;
  }

  @override
  void dispose() {
    unawaited(EmbeddedBrowserDiagnostics.stop(_preparationLease));
    _closed = true;
    _controller = null;
    _stopTimers();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_browser.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.provider.displayName}登录',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: DesktopButtonClickRegion(
          child: IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        actions: [
          if (defaultTargetPlatform == TargetPlatform.android)
            const EmbeddedBrowserDiagnosticsAction(),
          DesktopButtonClickRegion(
            child: IconButton(
              tooltip: '刷新网页',
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
            ),
          ),
          if (MediaQuery.sizeOf(context).width < 600)
            DesktopButtonClickRegion(
              child: IconButton(
                tooltip: '检测登录状态',
                onPressed: () => _check(manual: true),
                icon: const Icon(Icons.check_circle_outline),
              ),
            )
          else
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => _check(manual: true),
                child: const Text('检测登录状态'),
              ),
            ),
        ],
      ),
      body: MediaLibrarySafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * 0.3,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Text('请在官方页面完成登录'),
                      ),
                      if (_message != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            _message!,
                            style: const TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: !_ready
                    ? const Center(child: CircularProgressIndicator())
                    : defaultTargetPlatform == TargetPlatform.linux
                    ? const Center(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            '请在已打开的独立浏览器窗口完成官方登录。完成后回到这里，或点“检测登录状态”。',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : EmbeddedBrowserView(
                        browserId: 'cloud-login',
                        allowPageZoom: true,
                        initialUserScripts: UnmodifiableListView([
                          UserScript(
                            groupName: 'cloud-login-desktop',
                            source: fluentBrowserDesktopViewportScript,
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                          ),
                        ]),
                        onControllerUnavailable: () => _controller = null,
                        webViewEnvironment: _browser.environment,
                        initialUrlRequest: URLRequest(
                          url: WebUri(widget.provider.loginUri.toString()),
                        ),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          userAgent: cloudDriveLoginDesktopUserAgent,
                          preferredContentMode:
                              UserPreferredContentMode.DESKTOP,
                          // Windows has its own WebView2 profile; shared stores
                          // are reset in prepare(). Android incognito would
                          // instead delete cookies for every embedded browser.
                          // InPrivate cookies stay invisible to that profile's
                          // cookie API, so a finished login could not be detected.
                          incognito: false,
                          sharedCookiesEnabled: false,
                          thirdPartyCookiesEnabled: true,
                          useWideViewPort: true,
                          loadWithOverviewMode: true,
                        ),
                        onWebViewCreated: (controller) =>
                            _controller = controller,
                        onLoadStop: (_, _) => unawaited(_check()),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
