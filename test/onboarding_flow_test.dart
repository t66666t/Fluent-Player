import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/onboarding/onboarding_flow.dart';
import 'package:video_player_app/features/onboarding/onboarding_screen.dart';
import 'package:video_player_app/features/onboarding/onboarding_store.dart';
import 'package:video_player_app/features/model_center/model_center_screen.dart';
import 'package:video_player_app/screens/network_settings_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';

class _Routes extends NavigatorObserver {
  Route<dynamic>? last;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      last = route;
}

class _LoginApi extends BilibiliApiService {
  int loads = 0;
  @override
  Future<void> init() async {
    loads++;
  }

  @override
  Future<bool> hasCookie() async => false;
}

void main() {
  late SettingsService settings;
  late SharedPreferences prefs;
  late _LoginApi api;
  late _Routes routes;

  Future<void> host(WidgetTester tester, {bool preview = true}) async {
    SharedPreferences.setMockInitialValues({
      OnboardingStore.handledKey: false,
      'copyImportedMediaToPrivateStorage': false,
      'playback_state_snapshot': 'untouched-playback',
      'mediaLibraryLastFolderId': 'my-course',
    });
    settings = SettingsService()..resetForTest();
    await settings.init();
    prefs = await SharedPreferences.getInstance();
    api = _LoginApi();
    routes = _Routes();
    final translation = SubtitleTranslateSettings();
    await translation.ensureLoaded();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: translation),
          ChangeNotifierProvider(
            create: (_) => BilibiliDownloadService(apiService: api),
          ),
        ],
        child: MaterialApp(
          navigatorObservers: [routes],
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('原来的文件夹'),
                  onPressed: () {
                    OnboardingFlow.open(context, settings, preview: preview);
                    OnboardingFlow.open(context, settings, preview: preview);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('原来的文件夹'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
  }

  testWidgets(
    'opening and dismissing setup leaves settings, playback and first-run state alone',
    (tester) async {
      await host(tester);
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      expect(api.loads, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('原来的文件夹'), findsOneWidget);
      expect(OnboardingFlow.isShowing, isFalse);
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
    },
  );

  testWidgets(
    'preview edits are real settings and finishing returns to the same folder',
    (tester) async {
      await host(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('copyImportedMediaToPrivateStorage')),
      );
      await tester.tap(
        find.byKey(const ValueKey('copyImportedMediaToPrivateStorage')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('onboarding-done')));
      await tester.pumpAndSettle();
      expect(settings.copyImportedMediaToPrivateStorage, isTrue);
      expect(prefs.getBool('copyImportedMediaToPrivateStorage'), isTrue);
      expect(prefs.getBool(OnboardingStore.handledKey), isFalse);
      expect(prefs.getString('playback_state_snapshot'), 'untouched-playback');
      expect(prefs.getString('mediaLibraryLastFolderId'), 'my-course');
      expect(find.text('原来的文件夹'), findsOneWidget);
      expect(OnboardingFlow.isShowing, isFalse);
    },
  );

  testWidgets(
    'setup opens network and model-center screens without placement settings',
    (tester) async {
      await host(tester);
      expect(
        find.byKey(const ValueKey('onboarding-importLocation')),
        findsNothing,
      );
      expect(find.text('导入位置与整理'), findsNothing);
      for (final (destination, type) in [
        (OnboardingDestination.network, NetworkSettingsScreen),
        (OnboardingDestination.subtitleServices, ModelCenterScreen),
      ]) {
        final tile = find.byKey(ValueKey('onboarding-${destination.name}'));
        await tester.scrollUntilVisible(
          tile,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        await tester.tap(tile.hitTestable());
        final route = routes.last! as MaterialPageRoute;
        // Inspect the real destination before mounting native services.
        expect(
          route
              .builder(tester.element(find.byType(OnboardingScreen)))
              .runtimeType,
          type,
        );
        route.navigator!.removeRoute(route);
        await tester.pumpAndSettle();
        expect(find.byType(OnboardingScreen), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('onboarding-close')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('local setup contains no website player or account login', (
    tester,
  ) async {
    await host(tester);
    expect(api.loads, 0);
    expect(find.byKey(const ValueKey('onboarding-bilibili')), findsNothing);
    expect(find.textContaining('官方播放'), findsNothing);
    expect(find.text('扫码登录'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('onboarding-close')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('first launch can be skipped immediately and will not repeat', (
    tester,
  ) async {
    await host(tester, preview: false);
    expect(find.text('使用前设置'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-close')));
    await tester.pumpAndSettle();
    expect(await OnboardingStore.shouldShow(), isFalse);
    expect(settings.copyImportedMediaToPrivateStorage, isFalse);
    expect(OnboardingFlow.isShowing, isFalse);
  });
}
