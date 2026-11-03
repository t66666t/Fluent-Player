import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../network/browser_network_policy.dart';
import '../network/network_http.dart';

import 'package:path/path.dart' as p;

/// Linux has no in-app WebView plugin here. A dedicated visible Chromium profile
/// provides the same official login/page flow through its loopback-only CDP port.
class LinuxChromiumBrowser {
  LinuxChromiumBrowser(
    this.profile, {
    Future<Uri> Function()? proxyEndpoint,
    Future<String?> Function()? browserExecutable,
  }) : _proxyEndpoint =
           proxyEndpoint ??
           (() => BrowserNetworkPolicy.endpoint(NetworkScope.other)),
       _browserExecutable = browserExecutable;

  final Directory profile;
  final Future<Uri> Function() _proxyEndpoint;
  final Future<String?> Function()? _browserExecutable;
  bool _ownsBrowser = false;
  Process? _process;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _pendingSessions = <int, String?>{};
  int _nextId = 0;
  String? _sessionId;
  bool _disposed = false;
  Future<void>? _starting;
  String? _captureSession;
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get isOpen => _socket != null && _sessionId != null;

  Future<void> start() => _ensureStarted();

  Future<void> open(
    Uri uri,
    String captureScript, {
    bool resume = false,
  }) async {
    final alreadyOpen = isOpen;
    await _ensureStarted();
    if (_disposed) return;
    if (_captureSession != _sessionId) {
      await command('Page.addScriptToEvaluateOnNewDocument', {
        'source': captureScript,
      });
      _captureSession = _sessionId;
    }
    if (!resume || !alreadyOpen) {
      await command('Page.navigate', {'url': uri.toString()});
    }
    await command('Page.bringToFront');
  }

  Future<bool> canNavigate(int direction) async {
    final history = await command('Page.getNavigationHistory');
    final index = history['currentIndex'] as int? ?? 0;
    final entries = history['entries'] as List? ?? const [];
    final next = index + direction;
    return next >= 0 && next < entries.length;
  }

  Future<void> reload() => command('Page.reload').then((_) {});

  Future<void> navigateHistory(int direction) async {
    final history = await command('Page.getNavigationHistory');
    final entries = history['entries'] as List? ?? const [];
    final next = (history['currentIndex'] as int? ?? 0) + direction;
    if (next < 0 || next >= entries.length) return;
    await command('Page.navigateToHistoryEntry', {
      'entryId': (entries[next] as Map)['id'],
    });
  }

  Future<void> _ensureStarted() async {
    if (_disposed) throw StateError('专用浏览器会话已关闭。');
    if (isOpen) return;
    final starting = _starting ??= _start();
    try {
      await starting;
    } finally {
      if (identical(_starting, starting)) _starting = null;
    }
  }

  Future<void> _start() async {
    await profile.create(recursive: true);
    if (_disposed) return;
    final portFile = File(p.join(profile.path, 'DevToolsActivePort'));
    final proxy = await _proxyEndpoint();
    if (_socket == null && await portFile.exists()) {
      await _tryConnect(portFile);
      if (_socket != null) {
        // A browser left by a crashed app retains its old loopback proxy port.
        // Check its actual command line before reusing or closing that process.
        final Map<String, dynamic> details;
        try {
          details = await command(
            'Browser.getBrowserCommandLine',
            const {},
            true,
          );
        } catch (_) {
          await _disconnectTransport();
          throw StateError('请关闭之前的专用浏览器后重试，以应用当前网络设置。');
        }
        final arguments = (details['arguments'] as List? ?? const [])
            .whereType<String>()
            .toList();
        _ownsBrowser = arguments.contains('--user-data-dir=${profile.path}');
        if (!_ownsBrowser) {
          await _disconnectTransport();
          throw StateError('无法确认专用浏览器的网络设置，请关闭旧窗口后重试。');
        }
        if (!arguments.contains('--proxy-server=$proxy') ||
            !arguments.contains(
              '--proxy-bypass-list=127.0.0.1;[::1];localhost',
            )) {
          final socket = _socket!;
          await command('Browser.close', const {}, true);
          try {
            await socket.done.timeout(const Duration(seconds: 5));
          } catch (_) {}
          await _subscription?.cancel();
          await socket.close();
          _disconnected();
          _ownsBrowser = false;
        }
      }
    }
    if (_socket == null) {
      final executable = await _findBrowser();
      if (executable == null) {
        throw StateError('Linux 需要 Chromium 或 Google Chrome。请先安装浏览器，再点击重试。');
      }
      if (_disposed) return;
      if (await portFile.exists()) await portFile.delete();
      _process = await Process.start(
        executable,
        [
          '--proxy-server=$proxy',
          '--proxy-bypass-list=127.0.0.1;[::1];localhost',
          '--user-data-dir=${profile.path}',
          '--remote-debugging-address=127.0.0.1',
          '--remote-debugging-port=0',
          '--enable-automation',
          '--no-first-run',
          '--no-default-browser-check',
          'about:blank',
        ],
        environment: NetworkHttp.childEnvironment(),
        includeParentEnvironment: false,
      );
      _ownsBrowser = true;
      // Drain output; do not persist browser output or account information.
      unawaited(_process!.stdout.drain<void>());
      unawaited(_process!.stderr.drain<void>());
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!_disposed &&
          _socket == null &&
          DateTime.now().isBefore(deadline)) {
        if (await portFile.exists()) await _tryConnect(portFile);
        if (_socket == null) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      if (_disposed) return;
      if (_socket == null) {
        _process?.kill();
        _process = null;
        throw StateError('无法连接专用浏览器，请确认桌面会话可用，并重试。');
      }
    }
    final targets = await command('Target.getTargets', const {}, true);
    final pages = (targets['targetInfos'] as List? ?? const [])
        .whereType<Map>()
        .where((target) => target['type'] == 'page');
    final String targetId;
    if (pages.isNotEmpty) {
      targetId = pages.first['targetId'] as String;
    } else {
      final created = await command('Target.createTarget', {
        'url': 'about:blank',
      }, true);
      targetId = created['targetId'] as String;
    }
    final attached = await command('Target.attachToTarget', {
      'targetId': targetId,
      'flatten': true,
    }, true);
    _sessionId = attached['sessionId'] as String;
    await command('Page.enable');
    await command('Runtime.enable');
    await command('Network.enable');
  }

  Future<String?> _findBrowser() async {
    if (_browserExecutable != null) {
      return _browserExecutable();
    }
    for (final executable in const [
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
      '/usr/bin/google-chrome',
      '/usr/bin/google-chrome-stable',
      '/opt/google/chrome/google-chrome',
      '/snap/bin/chromium',
    ]) {
      if (await File(executable).exists()) return executable;
    }
    return null;
  }

  Future<void> _tryConnect(File portFile) async {
    try {
      final lines = await portFile.readAsLines();
      if (lines.length < 2) return;
      final port = int.tryParse(lines[0]);
      if (port == null ||
          port < 1 ||
          port > 65535 ||
          !RegExp(r'^/devtools/browser/[a-zA-Z0-9-]+$').hasMatch(lines[1])) {
        return;
      }
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:$port${lines[1]}',
      ).timeout(const Duration(seconds: 2));
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      _subscription = socket.listen(
        _onMessage,
        onDone: () {
          if (identical(_socket, socket)) _disconnected();
        },
        onError: (Object _) {
          if (identical(_socket, socket)) _disconnected();
        },
      );
    } catch (_) {
      // Chromium may still be starting or the saved port may belong to a past run.
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) return;
    if (value['method'] == 'Target.detachedFromTarget') {
      final params = value['params'];
      final detachedSession = params is Map ? params['sessionId'] : null;
      if (detachedSession is String) _sessionDetached(detachedSession);
      return;
    }
    if (value['method'] == 'Inspector.detached') {
      final detachedSession = value['sessionId'];
      if (detachedSession is String) _sessionDetached(detachedSession);
      return;
    }
    if (value['id'] is! int) {
      if (!_events.isClosed &&
          value['method'] is String &&
          (value['sessionId'] == null || value['sessionId'] == _sessionId)) {
        _events.add(value);
      }
      return;
    }
    final pending = _pending.remove(value['id']);
    _pendingSessions.remove(value['id']);
    if (pending == null || pending.isCompleted) return;
    if (value['error'] != null) {
      pending.completeError(StateError('浏览器暂时无法执行操作，请刷新网页重试。'));
    } else {
      pending.complete(
        Map<String, dynamic>.from(value['result'] as Map? ?? const {}),
      );
    }
  }

  void _sessionDetached(String sessionId) {
    // Closing one tab need not close Chromium or its browser-level socket.
    // Leave browser commands intact so the next open can attach a fresh page.
    if (_sessionId == sessionId) _sessionId = null;
    final ids = _pendingSessions.entries
        .where((entry) => entry.value == sessionId)
        .map((entry) => entry.key)
        .toList();
    for (final id in ids) {
      _pendingSessions.remove(id);
      final pending = _pending.remove(id);
      if (pending != null && !pending.isCompleted) {
        pending.completeError(StateError('浏览器标签页已关闭，请重新打开。'));
      }
    }
  }

  void _disconnected() {
    _socket = null;
    _sessionId = null;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('专用浏览器已关闭，请重新打开。'));
      }
    }
    _pending.clear();
    _pendingSessions.clear();
  }

  Future<void> _disconnectTransport() async {
    final socket = _socket;
    await _subscription?.cancel();
    await socket?.close();
    _disconnected();
  }

  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> params = const {},
    bool browser = false,
  ]) async {
    final socket = _socket;
    if (socket == null) throw StateError('专用浏览器已关闭，请重新打开。');
    final sessionId = browser ? null : _sessionId;
    if (!browser && sessionId == null) {
      throw StateError('浏览器标签页已关闭，请重新打开。');
    }
    final id = ++_nextId;
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    _pendingSessions[id] = sessionId;
    try {
      socket.add(
        jsonEncode({
          'id': id,
          'method': method,
          'params': params,
          'sessionId': ?sessionId,
        }),
      );
      return await result.future.timeout(const Duration(seconds: 12));
    } finally {
      _pending.remove(id);
      _pendingSessions.remove(id);
    }
  }

  Future<Object?> evaluate(String source) async {
    final response = await command('Runtime.evaluate', {
      'expression': source,
      'returnByValue': true,
      'awaitPromise': true,
    });
    return (response['result'] as Map?)?['value'];
  }

  Future<List<Map<String, dynamic>>> cookiesFor(Uri uri) async {
    if (!isOpen) return const [];
    final response = await command('Network.getCookies', {
      'urls': [uri.toString()],
    });
    return (response['cookies'] as List? ?? const [])
        .whereType<Map>()
        .map((cookie) => Map<String, dynamic>.from(cookie))
        .toList();
  }

  Future<String> cookieHeaderFor(Uri uri) async => (await cookiesFor(uri))
      .where(
        (cookie) =>
            !RegExp(r'[\r\n]').hasMatch('${cookie['name']}${cookie['value']}'),
      )
      .map((cookie) => '${cookie['name']}=${cookie['value']}')
      .join('; ');

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _starting;
    } catch (_) {}
    if (_socket != null && _ownsBrowser) {
      try {
        await command('Browser.close', const {}, true);
      } catch (_) {}
    }
    await _subscription?.cancel();
    await _socket?.close();
    _disconnected();
    _process?.kill();
    _process = null;
    await _events.close();
  }
}
