import 'dart:io';

import 'package:flutter/services.dart';

import 'network_models.dart';

abstract interface class SystemProxyResolver {
  Future<List<ProxyProfile?>> resolve(Uri url);
}

/// Platform code evaluates PAC off the UI thread. No PAC is run in Dart and
/// an unavailable resolver is an error, rather than an implicit DIRECT result.
class PlatformProxyResolver implements SystemProxyResolver {
  static const channel = MethodChannel('com.example.video_player_app/network');
  static const events = EventChannel(
    'com.example.video_player_app/network_events',
  );

  @override
  Future<List<ProxyProfile?>> resolve(Uri url) async {
    if (NetworkSites.isLoopback(url.host)) return [null];
    if (Platform.isLinux) {
      final fromEnvironment = environmentProxy(url, Platform.environment);
      if (fromEnvironment != null) return fromEnvironment;
    }
    try {
      final values = await channel.invokeListMethod<String>('resolveProxy', {
        'url': url.toString(),
      });
      if (values == null || values.isEmpty) {
        throw const NetworkSettingsException('设备未返回网络配置');
      }
      return values
          .map(
            (value) => value == 'DIRECT' ? null : ProxyProfile.fromUri(value),
          )
          .toList();
    } catch (_) {
      throw const NetworkSettingsException('无法读取设备代理设置，请重试。当前网络方式未更改。');
    }
  }

  static List<ProxyProfile?>? environmentProxy(
    Uri uri,
    Map<String, String> environment,
  ) {
    String? lookup(String key) =>
        environment[key.toLowerCase()] ?? environment[key.toUpperCase()];
    final bypass = lookup('no_proxy');
    if (bypass != null &&
        bypass.split(',').any((rule) => _bypasses(uri, rule.trim()))) {
      return [null];
    }
    // An explicit empty value deliberately disables the proxy for this scheme.
    final value = lookup('${uri.scheme}_proxy') ?? lookup('all_proxy');
    if (value == null) return null;
    if (value.trim().isEmpty) return [null];
    return [ProxyProfile.fromUri(value)];
  }

  static bool _bypasses(Uri uri, String rule) {
    if (rule.isEmpty) return false;
    if (rule == '*') return true;
    var host = rule;
    int? port;
    if (rule.startsWith('[')) {
      final end = rule.indexOf(']');
      if (end < 0) return false;
      host = rule.substring(1, end);
      if (rule.length > end + 1) port = int.tryParse(rule.substring(end + 2));
    } else if (rule.split(':').length == 2) {
      final index = rule.lastIndexOf(':');
      port = int.tryParse(rule.substring(index + 1));
      if (port != null) host = rule.substring(0, index);
    }
    if (port != null && uri.port != port) return false;
    if (host.contains('/')) {
      final parts = host.split('/');
      final address = InternetAddress.tryParse(
        NetworkSites.socketHost(uri.host),
      );
      final network = InternetAddress.tryParse(parts[0]);
      final bits = int.tryParse(parts.last);
      if (address == null ||
          network == null ||
          bits == null ||
          address.type != network.type ||
          bits < 0 ||
          bits > address.rawAddress.length * 8) {
        return false;
      }
      for (var i = 0; i < address.rawAddress.length; i++) {
        final remaining = bits - i * 8;
        final mask = remaining >= 8
            ? 255
            : remaining <= 0
            ? 0
            : (255 << (8 - remaining)) & 255;
        if (address.rawAddress[i] & mask != network.rawAddress[i] & mask) {
          return false;
        }
      }
      return true;
    }
    return NetworkSites.matches(uri.host, [
      host.startsWith('.') ? host.substring(1) : host,
    ]);
  }
}
