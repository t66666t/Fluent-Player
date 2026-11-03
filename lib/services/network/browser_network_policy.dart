import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'network_http.dart';
import 'platform_proxy_resolver.dart';

/// Native browsers use the same authenticated bridge as downloads. System
/// versions without a public override API may only use the device policy.
abstract final class BrowserNetworkPolicy {
  static final Map<Object, NetworkScope> _owners = {};
  static void release(Object owner) => _owners.remove(owner);
  static Future<Uri> endpoint(NetworkScope scope, {Uri? source}) =>
      NetworkHttp.instance.bridge.browserEndpoint(scope, source: source);

  static Future<void> prepare(
    NetworkScope scope, {
    Uri? source,
    Object? owner,
  }) async {
    final sharedStore =
        Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
    if (sharedStore && owner != null) {
      if (_owners.entries.any(
        (entry) => entry.key != owner && entry.value != scope,
      )) {
        throw const NetworkSettingsException(
          '请先关闭另一个网页窗口，再打开此页面。系统网页组件共用网络设置。',
        );
      }
      _owners[owner] = scope;
    }
    final proxy = await endpoint(scope, source: source);
    if (sharedStore && owner != null && !_owners.containsKey(owner)) return;
    if (Platform.isAndroid) {
      final supported = await WebViewFeature.isFeatureSupported(
        WebViewFeature.PROXY_OVERRIDE,
      );
      if (!supported) {
        if (NetworkSettingsService.instance.configuration.modes[scope] ==
            NetworkMode.system) {
          return;
        }
        throw const NetworkSettingsException(
          '此设备的网页组件不支持所选网络方式，请更新系统网页组件。链接解析和下载仍可使用此方式。',
        );
      }
      await ProxyController.instance().setProxyOverride(
        settings: ProxySettings(
          proxyRules: [ProxyRule(url: proxy.toString())],
          removeImplicitRules: true,
          bypassRules: ['127.0.0.1', '[::1]', 'localhost'],
        ),
      );
    } else if (Platform.isIOS || Platform.isMacOS) {
      final supported =
          await PlatformProxyResolver.channel.invokeMethod<bool>(
            'configureWebViewProxy',
            {'host': proxy.host, 'port': proxy.port},
          ) ??
          false;
      if (!supported &&
          NetworkSettingsService.instance.configuration.modes[scope] !=
              NetworkMode.system) {
        throw const NetworkSettingsException(
          '当前系统的网页组件不支持独立代理设置。此网页需要 iOS 17 或 macOS 14 以上；链接解析和下载仍可使用所选网络方式。',
        );
      }
    }
  }

  static Future<String> windowsArguments(
    NetworkScope scope, {
    Uri? source,
  }) async {
    final proxy = await endpoint(scope, source: source);
    return '--proxy-server=$proxy --proxy-bypass-list=127.0.0.1;[::1];localhost';
  }
}
