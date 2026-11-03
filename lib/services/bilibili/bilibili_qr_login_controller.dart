import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bilibili_api_service.dart';

/// QR login: asks Bilibili for a code, then polls its state every
/// [pollInterval] until it is confirmed, expires or fails. Shared by the
/// login dialog and the account page, which only differ in layout.
class BilibiliQrLoginController extends ChangeNotifier {
  BilibiliQrLoginController({
    required this.api,
    required this.onLoggedIn,
    this.pollInterval = const Duration(seconds: 2),
  });

  final BilibiliApiService api;

  /// Called once after the scan is confirmed and the login was verified and
  /// saved.
  final void Function(BilibiliAccountInfo? account) onLoggedIn;
  final Duration pollInterval;

  static const String expiredStatus = '二维码已失效';

  String? qrUrl;
  String? _qrKey;
  String status = '正在生成二维码…';
  String? errorMessage;
  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _disposed = false;
  int _generation = 0;

  bool get isExpired => status == expiredStatus;

  /// Requests a fresh code and starts polling it.
  Future<void> start() async {
    if (_disposed) return;
    final generation = ++_generation;
    _pollTimer?.cancel();
    _qrKey = null;
    status = '正在生成二维码…';
    errorMessage = null;
    qrUrl = null;
    notifyListeners();
    try {
      final result = await api.generateQrCode();
      if (_disposed || generation != _generation) return;
      qrUrl = result['url'];
      _qrKey = result['qrcode_key'];
      status = '请使用 Bilibili App 扫码登录';
      notifyListeners();
      _startPolling(generation);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      status = '生成二维码失败';
      errorMessage = '无法获取二维码，请重试';
      notifyListeners();
    }
  }

  void _startPolling(int generation) {
    final key = _qrKey;
    if (key == null) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (timer) async {
      if (_disposed || generation != _generation) {
        timer.cancel();
        return;
      }
      // A confirmed scan triggers nav verification; never overlap polls.
      if (_pollInFlight) return;
      _pollInFlight = true;
      Map<String, dynamic> result;
      try {
        result = await api.pollQrCode(key);
      } catch (_) {
        result = {'success': false, 'code': -1, 'message': '网络异常，正在重试'};
      } finally {
        _pollInFlight = false;
      }
      if (_disposed || !timer.isActive || generation != _generation) return;
      if (result['success'] == true) {
        timer.cancel();
        final account = result['account'];
        onLoggedIn(account is BilibiliAccountInfo ? account : null);
      } else if (result['code'] == 86038) {
        timer.cancel();
        status = expiredStatus;
        qrUrl = null;
        notifyListeners();
      } else if (result['code'] == 86090) {
        status = '已扫码，请在手机上确认';
        notifyListeners();
      } else if (result['code'] == -2) {
        // Scan confirmed but nav verification or secure saving failed.
        timer.cancel();
        status = '登录未完成';
        errorMessage = (result['message'] ?? '登录验证失败，请重试').toString();
        qrUrl = null;
        notifyListeners();
      } else if (result['code'] == -1) {
        status = (result['message'] ?? '网络异常，正在重试').toString();
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }
}
