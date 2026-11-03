import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_login_browser.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_login_screen.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_screen.dart';
import 'package:video_player_app/features/cloud_drive/providers/baidu_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/quark_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_playback_service.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_launch_coordinator.dart';

void main() {
  test('DevTools cookie payload keeps the Baidu session', () {
    final cookies = cookiesFromDevToolsPayload({
      'cookies': [
        {
          'name': 'BDUSS_BFESS',
          'value': 'session-value',
          'domain': '.baidu.com',
          'path': '/',
          'secure': true,
          'httpOnly': true,
        },
        {
          'name': 'tracker',
          'value': 'ignore-me',
          'domain': '.example.com',
          'path': '/',
        },
      ],
    });
    final credential = CloudDriveLoginBrowser(
      BaiduCloudDriveProvider(),
    ).credentialFrom(cookies);
    expect(credential, isNotNull);
    expect(
      credential!.headerFor(Uri.https('pan.baidu.com', '/')),
      contains('BDUSS=session-value'),
    );
    expect(credential.headerFor(Uri.https('evil.example', '/')), isEmpty);
  });

  test('Baidu BFESS session cookie is accepted as BDUSS', () {
    final browser = CloudDriveLoginBrowser(BaiduCloudDriveProvider());
    final credential = browser.credentialFrom(const [
      CloudDriveCookie(
        name: 'BDUSS_BFESS',
        value: 'session-value',
        domain: '.baidu.com',
      ),
      CloudDriveCookie(
        name: 'STOKEN_BFESS',
        value: 'stoken-value',
        domain: '.baidu.com',
      ),
    ]);
    expect(credential, isNotNull);
    expect(
      credential!.cookies.map((cookie) => cookie.name),
      containsAll(<String>['BDUSS', 'BDUSS_BFESS', 'STOKEN']),
    );
    expect(
      credential.headerFor(Uri.https('pan.baidu.com', '/disk/main')),
      contains('BDUSS=session-value'),
    );
  });

  test('baidu and quark login keep the live browser in the exit zoom', () {
    final accounts = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: _Memory()),
      metadata: MemoryCloudDriveAccountMetadataStore(),
    );
    for (final provider in <CloudDriveProvider>[
      BaiduCloudDriveProvider(),
      QuarkCloudDriveProvider(),
    ]) {
      final route = CloudDriveLoginRoute(
        provider: provider,
        accounts: accounts,
      );
      expect(route.allowSnapshotting, isFalse, reason: provider.displayName);
      expect(route.settings.name, '/cloud_drive/login/${provider.id}');
    }
  });

  testWidgets('cloud drive home fits a 360 wide phone', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final providers = CloudDriveProviderRegistry([BaiduCloudDriveProvider()]);
    final accounts = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: _Memory()),
      metadata: MemoryCloudDriveAccountMetadataStore(),
    );
    final runtime = CloudDriveRuntime(
      accounts: accounts,
      providers: providers,
      playback: CloudDrivePlaybackService(
        providers: providers,
        accounts: accounts,
      ),
      launch: CloudDriveLaunchCoordinator(
        library: LibraryService(),
        playlist: PlaylistManager(),
        playback: MediaPlaybackService(),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(360, 640));
    await tester.pumpWidget(
      MaterialApp(home: CloudDriveScreen(runtime: runtime)),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('添加网盘账号'), findsOneWidget);
    expect(find.text('百度网盘'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('login polling stops when the page is closed', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final browser = _FakeBrowser();
      final provider = BaiduCloudDriveProvider();
      await tester.pumpWidget(
        MaterialApp(
          home: CloudDriveLoginScreen(
            provider: provider,
            accounts: CloudDriveAccountRepository(
              credentials: CloudDriveCredentialStore(storage: _Memory()),
              metadata: MemoryCloudDriveAccountMetadataStore(),
            ),
            browser: browser,
          ),
        ),
      );
      await tester.pump();
      expect(browser.disposed, isFalse);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      expect(browser.disposed, isTrue);
      final checks = browser.checks;
      await tester.pump(const Duration(seconds: 4));
      expect(browser.checks, checks);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

class _Memory implements CloudDriveSecretStorage {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}

class _FakeBrowser implements CloudDriveLoginClient {
  var disposed = false;
  var checks = 0;

  @override
  WebViewEnvironment? get environment => null;

  @override
  Future<void> prepare() async {}

  @override
  Future<List<CloudDriveCookie>> readCookies({
    InAppWebViewController? webView,
  }) async {
    checks++;
    return const [];
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<void> reload() async {}

  @override
  CloudDriveCredential? credentialFrom(List<CloudDriveCookie> cookies) => null;
}
