import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_login_policy.dart';

void main() {
  test('all five native platforms support official web login', () {
    for (final platform in TargetPlatform.values) {
      expect(
        BilibiliLoginPolicy.supportsWebLogin(platform),
        platform != TargetPlatform.fuchsia,
      );
    }
    expect(BilibiliLoginPolicy.mobileLoginUri.host, 'passport.bilibili.com');
    expect(BilibiliLoginPolicy.mobileLoginUri.scheme, 'https');
  });

  test('tablet UA keeps its actual WebView version and adds Mobile once', () {
    const tablet =
        'Mozilla/5.0 (Linux; Android 15) Chrome/140.0.0.0 Safari/537.36';
    final agent = BilibiliLoginPolicy.mobileUserAgent(tablet);
    expect(agent, contains('Chrome/140.0.0.0'));
    expect(agent, contains('Mobile'));
    expect(BilibiliLoginPolicy.mobileUserAgent(agent), agent);
  });
}
