import 'package:flutter/foundation.dart';

/// Platform decisions shared by the account page and login dialog.
abstract final class BilibiliLoginPolicy {
  static bool supportsWebLogin(TargetPlatform platform) =>
      !kIsWeb &&
      (platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS ||
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.macOS ||
          platform == TargetPlatform.linux);

  static Uri loginUri(TargetPlatform platform) =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS
      ? mobileLoginUri
      : Uri.https('passport.bilibili.com', '/login');

  static final Uri mobileLoginUri = Uri.https(
    'passport.bilibili.com',
    '/h5-app/passport/login',
    {'navhide': '1'},
  );

  /// Keep the installed WebView version, including on tablets.
  static String mobileUserAgent(String nativeAgent) {
    if (RegExp(r'\bMobile\b').hasMatch(nativeAgent)) return nativeAgent;
    return '$nativeAgent Mobile';
  }
}
