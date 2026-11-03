import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_login_browser.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_login_screen.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_safe_area.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'support/cloud_drive_fixture.dart';

class _Login extends CloudDriveLoginClient {
  bool disposed = false;
  @override
  WebViewEnvironment? get environment => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<void> reload() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<List<CloudDriveCookie>> readCookies({
    InAppWebViewController? webView,
  }) async => const [];
  @override
  CloudDriveCredential? credentialFrom(List<CloudDriveCookie> cookies) => null;
}

void main() {
  for (final size in [const Size(360, 640), const Size(844, 390)]) {
    testWidgets(
      'official login keeps visible controls above mini player at $size',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        await settings.init();
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        final playback = MediaPlaybackService();
        await playback.stop();
        playback.publishRestoredSessionPreview(
          VideoItem(
            id: 'preview',
            path: 'local.mp4',
            title: '当前播放',
            durationMs: 120000,
            lastUpdated: 0,
          ),
          Duration.zero,
        );
        final provider = FixtureCloudProvider('baidu', {});
        final runtime = await cloudRuntime([provider]);
        final client = _Login();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.view.padding = const FakeViewPadding(bottom: 32);
        tester.view.viewPadding = const FakeViewPadding(bottom: 32);
        tester.view.systemGestureInsets = const FakeViewPadding(bottom: 24);
        addTearDown(() async {
          tester.view.reset();
          debugDefaultTargetPlatformOverride = null;
          await playback.stop();
          await runtime.shutdown();
          settings.resetForTest();
        });
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: playback,
              ),
            ],
            child: MaterialApp(
              theme: ThemeData.dark(),
              home: MediaLibraryShell(
                home: CloudDriveLoginScreen(
                  provider: provider,
                  accounts: runtime.accounts,
                  browser: client,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final area = find
            .descendant(
              of: find.byType(MediaLibrarySafeArea),
              matching: find.byType(Column),
            )
            .first;
        expect(
          tester.getBottomRight(area).dy,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byType(MiniPlaybackCard)).dy,
          ),
        );
        final check = size.width < 600
            ? find.byTooltip('检测登录状态')
            : find.widgetWithText(TextButton, '检测登录状态');
        expect(check.hitTestable(), findsOneWidget);
        await tester.tap(check);
        await tester.pumpAndSettle();
        unawaited(settings.updateSetting('showMiniPlaybackCard', false));
        await tester.pumpAndSettle();
        expect(tester.getBottomRight(area).dy, size.height - 32);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(client.disposed, isTrue);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
