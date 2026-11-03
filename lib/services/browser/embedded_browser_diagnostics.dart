import 'dart:io';

import 'package:flutter/services.dart';

import '../../debug/log_redaction.dart';

/// One bounded Android watchdog, with separate leases for every browser owner.
abstract final class EmbeddedBrowserDiagnostics {
  // Keep the existing bridge identifier so previous reports remain readable.
  static const channel = MethodChannel(
    'com.example.video_player_app/douyin_browser_diagnostics',
  );
  static Future<void> start(String lease) => _invoke('start', lease);
  static Future<void> closing(String lease) => _invoke('closing', lease);
  static Future<void> stop(String lease) => _invoke('stop', lease);
  static Future<void> record(String lease, String event) =>
      _invoke('record', lease, event: event);

  static Future<void> _invoke(
    String method,
    String lease, {
    String? event,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await channel
          .invokeMethod<void>(method, {'lease': lease, 'event': ?event})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Diagnostics must never prevent browsing or closing.
    }
  }

  static Future<String> report() async {
    if (!Platform.isAndroid) return '浏览器卡顿诊断仅用于 Android。';
    try {
      final report = await channel
          .invokeMethod<String>('report')
          .timeout(const Duration(seconds: 5));
      return redactSensitiveLogText(report ?? '暂无浏览器诊断记录。');
    } on MissingPluginException {
      return '此安装包没有浏览器诊断模块，请安装本次构建的版本。';
    } catch (_) {
      return '诊断暂时无法读取，请重新打开应用后再试。';
    }
  }
}
