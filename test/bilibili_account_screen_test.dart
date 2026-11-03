import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_account_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_cookie_store.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';

class _MemoryStorage implements BilibiliSecretStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

const _account = BilibiliAccountInfo(
  mid: 7,
  name: '测试用户',
  avatarUrl: 'https://i0.hdslb.com/bfs/face/a.jpg',
);

/// Account backend without network: login state, QR and logout are scripted.
class _FakeApi extends BilibiliApiService {
  _FakeApi(this.state)
    : super(cookieStore: BilibiliCookieStore(storage: _MemoryStorage()));

  BilibiliLoginState state;
  final List<Map<String, dynamic>> pollAnswers = <Map<String, dynamic>>[];
  int logouts = 0;
  int qrRequests = 0;

  @override
  Future<void> init() async {}

  @override
  Future<BilibiliLoginState> fetchLoginState() async => state;

  @override
  Future<void> logout() async {
    logouts++;
    state = const BilibiliLoginState(BilibiliLoginStatus.loggedOut);
  }

  @override
  Future<Map<String, String>> generateQrCode() async {
    qrRequests++;
    return {
      'url': 'https://passport.bilibili.com/qr?k=$qrRequests',
      'qrcode_key': 'k',
    };
  }

  @override
  Future<Map<String, dynamic>> pollQrCode(String qrcodeKey) async {
    if (pollAnswers.isEmpty) return {'success': false, 'code': 86101};
    return pollAnswers.removeAt(0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  Future<List<BilibiliLoginState>> pumpScreen(
    WidgetTester tester,
    _FakeApi api, {
    TargetPlatform platform = TargetPlatform.fuchsia,
  }) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await SettingsService().init();
    final seen = <BilibiliLoginState>[];
    await tester.pumpWidget(
      MaterialApp(
        home: BilibiliAccountScreen(
          api: api,
          onStateChanged: seen.add,
          platform: platform,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return seen;
  }

  /// Disposes the page so the QR polling timer stops.
  Future<void> closeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  for (final platform in TargetPlatform.values.where(
    (p) => p != TargetPlatform.fuchsia,
  )) {
    testWidgets('$platform offers official web login before optional QR', (
      tester,
    ) async {
      final api = _FakeApi(
        const BilibiliLoginState(BilibiliLoginStatus.loggedOut),
      );
      await pumpScreen(tester, api, platform: platform);
      expect(
        find.byKey(const ValueKey('bilibili-account-web-login')),
        findsOneWidget,
      );
      expect(find.byType(QrImageView), findsNothing);
      expect(api.qrRequests, 0);
      await tester.tap(find.byKey(const ValueKey('bilibili-account-use-qr')));
      await tester.pump();
      await tester.pump();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(api.qrRequests, 1);
      await closeScreen(tester);
    });
  }

  String statusText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('bilibili-account-status')))
      .data!;

  testWidgets('a logged-in QR account can switch directly to web login', (
    tester,
  ) async {
    final api = _FakeApi(
      const BilibiliLoginState(BilibiliLoginStatus.loggedIn, account: _account),
    );
    await pumpScreen(tester, api, platform: TargetPlatform.windows);
    expect(
      find.byKey(const ValueKey('bilibili-account-web-relogin')),
      findsOneWidget,
    );
    expect(find.byType(QrImageView), findsNothing);
    await closeScreen(tester);
  });

  testWidgets('logged out: QR login in the page, then logged in', (
    tester,
  ) async {
    final api = _FakeApi(
      const BilibiliLoginState(BilibiliLoginStatus.loggedOut),
    );
    final seen = await pumpScreen(tester, api);

    expect(statusText(tester), '未登录');
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('请使用 Bilibili App 扫码登录'), findsOneWidget);
    expect(find.byKey(const ValueKey('bilibili-account-logout')), findsNothing);

    api.pollAnswers.add({'success': false, 'code': 86090});
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('已扫码，请在手机上确认'), findsOneWidget);

    api.state = const BilibiliLoginState(
      BilibiliLoginStatus.loggedIn,
      account: _account,
    );
    api.pollAnswers.add({'success': true, 'account': _account});
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();

    expect(statusText(tester), '已登录');
    expect(find.text('测试用户'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(seen.last.status, BilibiliLoginStatus.loggedIn);
    expect(seen.last.account?.name, '测试用户');
    await closeScreen(tester);
  });

  testWidgets('an expired QR code can be refreshed', (tester) async {
    final api = _FakeApi(
      const BilibiliLoginState(BilibiliLoginStatus.loggedOut),
    );
    await pumpScreen(tester, api);
    api.pollAnswers.add({'success': false, 'code': 86038});
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('二维码已失效'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bilibili-account-qr-refresh')));
    await tester.pump();
    await tester.pump();
    expect(api.qrRequests, 2);
    expect(find.byType(QrImageView), findsOneWidget);
    await closeScreen(tester);
  });

  testWidgets('logged in: avatar, name, state; logout asks first', (
    tester,
  ) async {
    final api = _FakeApi(
      const BilibiliLoginState(BilibiliLoginStatus.loggedIn, account: _account),
    );
    final seen = await pumpScreen(tester, api);

    expect(statusText(tester), '已登录');
    expect(find.text('测试用户'), findsOneWidget);
    expect(find.byType(BilibiliAvatar), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('账号只读模式'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('bilibili-account-logout')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.logouts, 0);
    expect(statusText(tester), '已登录');

    await tester.tap(find.byKey(const ValueKey('bilibili-account-logout')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(api.logouts, 1);
    expect(statusText(tester), '未登录');
    expect(seen.last.status, BilibiliLoginStatus.loggedOut);
    expect(find.byType(QrImageView), findsOneWidget);
    await closeScreen(tester);
  });

  testWidgets('expired: offers re-login with the QR code', (tester) async {
    final api = _FakeApi(const BilibiliLoginState(BilibiliLoginStatus.expired));
    await pumpScreen(tester, api);

    expect(statusText(tester), '登录已过期');
    expect(find.byType(QrImageView), findsNothing);
    expect(
      find.byKey(const ValueKey('bilibili-account-logout')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('bilibili-account-relogin')));
    await tester.pump();
    await tester.pump();
    expect(find.text('重新扫码登录'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    await closeScreen(tester);
  });

  testWidgets('network error keeps the login and offers a retry', (
    tester,
  ) async {
    final api = _FakeApi(
      const BilibiliLoginState(BilibiliLoginStatus.networkError),
    );
    await pumpScreen(tester, api);
    expect(statusText(tester), '网络错误，暂时无法验证');
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    api.state = const BilibiliLoginState(
      BilibiliLoginStatus.loggedIn,
      account: _account,
    );
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(statusText(tester), '已登录');
    await closeScreen(tester);
  });

  testWidgets('account links open settings without a read-only row', (
    tester,
  ) async {
    final api = _FakeApi(
      const BilibiliLoginState(BilibiliLoginStatus.loggedIn, account: _account),
    );
    await pumpScreen(tester, api);
    expect(
      find.byKey(const ValueKey('bilibili-account-read-only')),
      findsNothing,
    );
    expect(find.text('账号只读模式'), findsNothing);
    expect(
      find.byKey(const ValueKey('bilibili-account-settings')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bilibili-account-history')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bilibili-account-network-settings')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('bilibili-account-settings')));
    await tester.pumpAndSettle();
    expect(find.text('B 站设置'), findsWidgets);
    expect(find.text('账号只读模式'), findsNothing);
    expect(
      find.byKey(const ValueKey('bilibili-setting-auto-import')),
      findsOneWidget,
    );
    await closeScreen(tester);
  });

  testWidgets('other login methods open the old dialog and refresh', (
    tester,
  ) async {
    final api = _FakeApi(
      const BilibiliLoginState(BilibiliLoginStatus.loggedOut),
    );
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await SettingsService().init();
    final seen = <BilibiliLoginState>[];
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BilibiliAccountScreen(
          api: api,
          platform: TargetPlatform.fuchsia,
          onStateChanged: seen.add,
          openOtherLogin: (context) async {
            opened++;
            api.state = const BilibiliLoginState(
              BilibiliLoginStatus.loggedIn,
              account: _account,
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('bilibili-account-other-login')),
    );
    await tester.pump();
    await tester.pump();
    expect(opened, 1);
    expect(statusText(tester), '已登录');
    expect(seen.last.status, BilibiliLoginStatus.loggedIn);
    expect(
      find.byKey(const ValueKey('bilibili-account-other-login')),
      findsNothing,
    );
    await closeScreen(tester);
  });

  testWidgets('expired shows other login methods too', (tester) async {
    final api = _FakeApi(const BilibiliLoginState(BilibiliLoginStatus.expired));
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await SettingsService().init();
    await tester.pumpWidget(
      MaterialApp(
        home: BilibiliAccountScreen(
          api: api,
          platform: TargetPlatform.fuchsia,
          openOtherLogin: (context) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('bilibili-account-other-login-expired')),
      findsOneWidget,
    );
    await closeScreen(tester);
  });
}
