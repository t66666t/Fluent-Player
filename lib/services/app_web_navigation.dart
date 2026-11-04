import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Explicit reference/help links use the system browser. This edition has no
/// website playback route and never resolves or imports a website's media.
class AppWebNavigation {
  const AppWebNavigation._();

  @visibleForTesting
  static Future<bool> Function(Uri url, {String? title})? rootOpenerForTesting;

  static Uri pageUri(Uri url) {
    if (!const ['http', 'https'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.toString().contains(RegExp(r'[\x00-\x20\\]'))) {
      throw const FormatException('参考链接必须是有效的 HTTP(S) 网页');
    }
    return url;
  }

  /// Old media/browser route factories must not recreate a retired feature.
  static Route<void> route(Uri url, {String? title}) =>
      throw UnsupportedError('社区版仅提供本地媒体播放，没有内置浏览器');

  static Future<void> open(
    BuildContext context,
    Uri url, {
    String? title,
  }) async {
    final opened = await openFromRoot(url, title: title);
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('无法打开参考链接，可复制后自行查看')));
    }
  }

  static Future<bool> openFromRoot(Uri url, {String? title}) async {
    final page = pageUri(url);
    final opener = rootOpenerForTesting;
    if (opener != null) return opener(page, title: title);
    return launchUrl(page, mode: LaunchMode.externalApplication);
  }
}
