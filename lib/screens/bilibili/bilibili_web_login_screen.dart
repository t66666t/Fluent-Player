import '../../widgets/embedded_browser_diagnostics_action.dart';
import '../../services/browser/embedded_browser_diagnostics.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../services/bilibili/bilibili_api_service.dart';
import '../../services/bilibili/bilibili_login_policy.dart';
import '../../services/bilibili/bilibili_web_login_browser.dart';
import '../../widgets/embedded_browser_view.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// The official login page handles passwords, SMS and captchas itself.
/// Native CookieManager also reads HttpOnly cookies; JavaScript cannot.
class BilibiliWebLoginScreen extends StatefulWidget {
  const BilibiliWebLoginScreen({super.key, required this.api});

  final BilibiliApiService api;

  @override
  State<BilibiliWebLoginScreen> createState() => _BilibiliWebLoginScreenState();
}

class _BilibiliWebLoginScreenState extends State<BilibiliWebLoginScreen>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  final _browser = BilibiliWebLoginBrowser();
  Timer? _timer;
  Timer? _loadDeadline;
  String? _userAgent;
  String? _message;
  int _progress = 0;
  bool _checking = false;
  bool _completed = false;
  bool _foreground = true;
  bool _initializing = false;
  String? _failedSession;

  final _preparationLease =
      'prepare:bilibili-login:${DateTime.now().microsecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    unawaited(EmbeddedBrowserDiagnostics.start(_preparationLease));
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (_initializing || _completed) return;
    _initializing = true;
    try {
      await _browser.prepare();
      if (!mounted) return;
      var agent = '';
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        agent = await InAppWebViewController.getDefaultUserAgent().timeout(
          const Duration(seconds: 10),
        );
        if (agent.trim().isEmpty) throw StateError('WebView unavailable');
        agent = BilibiliLoginPolicy.mobileUserAgent(agent);
      }
      if (!mounted) return;
      setState(() => _userAgent = agent);
      if (defaultTargetPlatform == TargetPlatform.linux) {
        _timer?.cancel();
        _timer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => unawaited(_checkLogin()),
        );
      } else {
        _startLoadDeadline();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = defaultTargetPlatform == TargetPlatform.windows
              ? '无法启动 WebView2，请检查 Microsoft Edge WebView2 Runtime，或返回扫码登录'
              : defaultTargetPlatform == TargetPlatform.linux
              ? 'Linux 网页登录需要 Chromium 或 Google Chrome，以及可用的桌面会话。请安装后重试，或使用扫码登录'
              : '无法启动系统 WebView，请重试或返回使用扫码登录',
        );
      }
    } finally {
      _initializing = false;
    }
  }

  void _startLoadDeadline() {
    _loadDeadline?.cancel();
    _loadDeadline = Timer(const Duration(seconds: 25), () {
      if (mounted && !_completed) {
        setState(() => _message = '网页加载较慢，可重新加载或返回使用扫码登录');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(_checkLogin());
  }

  /// Import a complete browser session only after nav verifies it. Never
  /// overwrite the app's current account with an incomplete/expired session.
  Future<void> _checkLogin({bool force = false}) async {
    if (!mounted ||
        _checking ||
        _completed ||
        (!_foreground && defaultTargetPlatform != TargetPlatform.linux) ||
        _userAgent == null) {
      return;
    }
    _checking = true;
    String? attemptedSession;
    try {
      final cookies = await _browser.readCookies();
      final session = cookies['SESSDATA'];
      if (session == null || (cookies['bili_jct'] ?? '').isEmpty) {
        if (force && mounted) {
          setState(() => _message = '请先在官方网页完成登录，再检测登录状态');
        }
        return;
      }
      if (!force && session == _failedSession) return;
      if (!mounted || _completed) return;
      attemptedSession = session;
      final account = await widget.api.verifyAndSaveCookies(cookies);
      if (!mounted || _completed) return;
      _completed = true;
      _timer?.cancel();
      _loadDeadline?.cancel();
      // Remove the native view before popping its Flutter route.
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop(account);
    } on BilibiliAuthException catch (error) {
      // Explicitly expired browser cookies may precede the new login. Let the
      // web flow finish, then retry when its session changes (or on demand).
      if (error.status == BilibiliLoginStatus.expired) {
        _failedSession = attemptedSession;
      }
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) setState(() => _message = '暂时无法读取登录状态，可稍后手动检测');
    } finally {
      _checking = false;
    }
  }

  Future<void> _reload() async {
    _failedSession = null;
    setState(() {
      _message = null;
      _progress = 0;
    });
    if (defaultTargetPlatform == TargetPlatform.linux && _userAgent != null) {
      try {
        await _browser.reopen();
      } catch (_) {
        if (mounted) setState(() => _message = '无法重新打开浏览器，请返回后重试');
      }
      return;
    }
    if (_controller == null) {
      await _initialize();
      return;
    }
    _startLoadDeadline();
    try {
      await _controller!.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(
            BilibiliLoginPolicy.loginUri(defaultTargetPlatform).toString(),
          ),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _message = '网页重新加载失败，请重试');
    }
  }

  @override
  void dispose() {
    unawaited(EmbeddedBrowserDiagnostics.stop(_preparationLease));
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _loadDeadline?.cancel();
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 300), _browser.dispose),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('B 站官方网页登录'),
      actions: [
        if (defaultTargetPlatform == TargetPlatform.android)
          const EmbeddedBrowserDiagnosticsAction(),
        DesktopButtonClickRegion(
          child: IconButton(
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '重新加载',
          ),
        ),
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => _checkLogin(force: true),
            child: const Text('检测登录'),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('手机号、密码和验证码均在 B 站官方页面填写；完成后自动返回。'),
          ),
          if (_message != null)
            Padding(padding: const EdgeInsets.all(8), child: Text(_message!)),
          SizedBox(
            height: 4,
            child:
                _progress < 100 &&
                    !_completed &&
                    defaultTargetPlatform != TargetPlatform.linux
                ? LinearProgressIndicator(
                    value: _progress == 0 ? null : _progress / 100,
                  )
                : null,
          ),
          Expanded(
            child:
                defaultTargetPlatform == TargetPlatform.linux &&
                    _userAgent != null
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '请在已打开的独立浏览器窗口完成 B 站官方登录。\n完成后本页会自动返回，也可点击“检测登录”。',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : _completed || _userAgent == null
                ? const Center(child: CircularProgressIndicator())
                : EmbeddedBrowserView(
                    browserId: 'bilibili-login',
                    allowPageZoom: true,
                    onControllerUnavailable: () => _controller = null,
                    initialUrlRequest: URLRequest(
                      url: WebUri(
                        BilibiliLoginPolicy.loginUri(
                          defaultTargetPlatform,
                        ).toString(),
                      ),
                    ),
                    webViewEnvironment: _browser.environment,
                    initialSettings: InAppWebViewSettings(
                      userAgent: _userAgent!.isEmpty ? null : _userAgent,
                      javaScriptEnabled: true,
                      thirdPartyCookiesEnabled: true,
                      sharedCookiesEnabled: false,
                      useWideViewPort: true,
                      loadWithOverviewMode: true,
                      useShouldOverrideUrlLoading: true,
                    ),
                    onWebViewCreated: (controller) => _controller = controller,
                    shouldOverrideUrlLoading: (_, navigation) async {
                      final scheme = navigation.request.url?.scheme;
                      return scheme == 'https' || scheme == 'http'
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    onLoadStart: (_, _) {
                      _timer?.cancel();
                      _startLoadDeadline();
                    },
                    onProgressChanged: (_, progress) {
                      if (mounted) setState(() => _progress = progress);
                    },
                    onLoadStop: (_, _) {
                      _loadDeadline?.cancel();
                      if (!mounted || _completed) return;
                      setState(() => _progress = 100);
                      unawaited(_checkLogin());
                      _timer?.cancel();
                      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
                        unawaited(_checkLogin());
                      });
                    },
                    onReceivedError: (_, request, _) {
                      if (mounted && request.isForMainFrame == true) {
                        _loadDeadline?.cancel();
                        setState(() => _message = '登录网页加载失败，请重试或返回使用扫码登录');
                      }
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
