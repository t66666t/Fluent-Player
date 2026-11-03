import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_login_browser.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_login_screen.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_screen.dart';
import 'package:video_player_app/features/cloud_drive/providers/aliyun_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/baidu_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/quark_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/uc_cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_launch_coordinator.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_playback_service.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/features/web_media/web_media_browser_controls.dart';
import 'package:video_player_app/widgets/embedded_browser_view.dart';
import 'support/embedded_browser_platform.dart';

class _Secrets implements CloudDriveSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

CloudDriveAccountRepository _accounts() => CloudDriveAccountRepository(
  credentials: CloudDriveCredentialStore(storage: _Secrets()),
  metadata: MemoryCloudDriveAccountMetadataStore(),
);

class _Browser implements CloudDriveLoginClient {
  _Browser(this.credential);
  final CloudDriveCredential credential;
  var loggedIn = false;
  var disposed = false;
  @override
  WebViewEnvironment? get environment => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<List<CloudDriveCookie>> readCookies({
    InAppWebViewController? webView,
  }) async => const [];
  @override
  CloudDriveCredential? credentialFrom(List<CloudDriveCookie> cookies) =>
      loggedIn ? credential : null;
  @override
  Future<void> reload() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _VerifiedProvider extends UcCloudDriveProvider {
  _VerifiedProvider(this.provider);
  final String provider;
  @override
  String get id => provider;
  @override
  String get displayName => cloudDriveProviderNames[id]!;
  @override
  Future<CloudDriveVerifiedSession> verifySession(
    CloudDriveCredential credential, {
    Object? cancelToken,
  }) async => CloudDriveVerifiedSession(
    remoteAccountId: 'test-user',
    displayName: '学习账号',
    driveId: provider == 'aliyun' ? 'resource' : '0',
    refreshedCredential: credential,
  );
}

void main() {
  for (final provider in [
    BaiduCloudDriveProvider(),
    QuarkCloudDriveProvider(),
    UcCloudDriveProvider(),
    AliyunCloudDriveProvider(),
  ]) {
    testWidgets(
      '${provider.id} login uses desktop identity and viewport from first navigation',
      (tester) async {
        final platform = BrowserTestPlatform();
        InAppWebViewPlatform.instance = platform;
        await tester.pumpWidget(
          MaterialApp(
            home: CloudDriveLoginScreen(
              provider: provider,
              accounts: _accounts(),
              browser: _Browser(const CloudDriveCredential(cookies: [])),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final params = platform.params;
        final settings = params.initialSettings!;
        expect(settings.userAgent, cloudDriveLoginDesktopUserAgent);
        expect(
          settings.userAgent,
          isNot(matches('Android|Mobile|iPhone|iPad')),
        );
        expect(settings.preferredContentMode, UserPreferredContentMode.DESKTOP);
        expect(settings.useWideViewPort, isTrue);
        expect(settings.loadWithOverviewMode, isTrue);
        expect(settings.supportZoom, isTrue);
        expect(settings.thirdPartyCookiesEnabled, isTrue);
        expect(
          params.initialUrlRequest!.url.toString(),
          provider.loginUri.toString(),
        );
        expect(
          params.initialUserScripts!.map((script) => script.source),
          containsAll([
            fluentBrowserDesktopViewportScript,
            embeddedBrowserZoomScript,
          ]),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }),
    );
  }

  for (final size in [const Size(360, 640), const Size(960, 640)]) {
    testWidgets('four drive tabs and restored Aliyun selection fit $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'cloudDrive.lastProvider': 'aliyun',
      });
      final accounts = _accounts();
      final registry = CloudDriveProviderRegistry([
        BaiduCloudDriveProvider(),
        QuarkCloudDriveProvider(),
        UcCloudDriveProvider(),
        AliyunCloudDriveProvider(),
      ]);
      final playback = CloudDrivePlaybackService(
        providers: registry,
        accounts: accounts,
      );
      addTearDown(playback.close);
      final runtime = CloudDriveRuntime(
        accounts: accounts,
        providers: registry,
        playback: playback,
        launch: CloudDriveLaunchCoordinator(
          library: LibraryService(),
          playlist: PlaylistManager(),
          playback: MediaPlaybackService(),
        ),
      );
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 40);
      tester.view.viewPadding = const FakeViewPadding(top: 40);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              appBar: AppBar(title: const Text('媒体库')),
              // The library shell preserves the window MediaQuery when it
              // removes bottom padding for its playback card.
              body: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: CloudDriveScreen(embedded: true, runtime: runtime),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('cloud-drive-tab-baidu')))
            .dy,
        tester.getBottomRight(find.byType(AppBar)).dy,
      );
      for (final id in cloudDriveProviderNames.keys) {
        expect(find.byKey(ValueKey('cloud-drive-tab-$id')), findsOneWidget);
      }
      expect(find.text('登录阿里云盘'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cloud-drive-tab-aliyun')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('cloud-drive-tab-uc')),
      );
      await tester.tap(find.byKey(const ValueKey('cloud-drive-tab-uc')));
      await tester.pumpAndSettle();
      expect(find.text('登录UC网盘'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'cloudDrive.lastProvider',
        ),
        'uc',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    });
  }

  for (final id in ['uc', 'aliyun']) {
    testWidgets(
      '$id official login commits a verified account and disposes browser',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          final accounts = _accounts();
          final credential = id == 'aliyun'
              ? const CloudDriveCredential(
                  cookies: [],
                  secrets: {'refresh_token': 'test-token'},
                )
              : const CloudDriveCredential(
                  cookies: [
                    CloudDriveCookie(
                      name: '__puus',
                      value: 'test-cookie',
                      domain: '.uc.cn',
                    ),
                  ],
                );
          final browser = _Browser(credential);
          CloudDriveAccount? result;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await Navigator.of(context)
                          .push<CloudDriveAccount>(
                            MaterialPageRoute(
                              builder: (_) => CloudDriveLoginScreen(
                                provider: _VerifiedProvider(id),
                                accounts: accounts,
                                browser: browser,
                              ),
                            ),
                          );
                    },
                    child: const Text('打开登录'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('打开登录'));
          await tester.pumpAndSettle();
          expect(accounts.accounts, isEmpty);
          browser.loggedIn = true;
          await tester.pump(const Duration(seconds: 3));
          await tester.pumpAndSettle();
          expect(result?.providerId, id);
          expect(result?.driveId, id == 'aliyun' ? 'resource' : '0');
          expect(
            (await accounts.credentialFor(accounts.accounts.single))!.toJson(),
            credential.toJson(),
          );
          expect(browser.disposed, isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
