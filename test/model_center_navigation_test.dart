import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_center_screen.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/widgets/model_center_button.dart';
import 'package:video_player_app/widgets/transcript_translate_settings_sheet.dart';

class _Routes extends NavigatorObserver {
  Route<dynamic>? last;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    last = route;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final compact in [false, true]) {
    testWidgets(
      'shortcut covers nested navigator and retains edits ($compact)',
      (tester) async {
        final rootRoutes = _Routes();
        final childRoutes = _Routes();
        final settings = SubtitleTranslateSettings();
        await settings.ensureLoaded();
        final text = TextEditingController(text: '未提交的字幕文本');
        addTearDown(text.dispose);
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [rootRoutes],
            home: Navigator(
              observers: [childRoutes],
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => ChangeNotifierProvider.value(
                  value: settings,
                  child: Scaffold(
                    body: Column(
                      children: [
                        TextField(controller: text),
                        ModelCenterButton(compact: compact),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final rootHome = rootRoutes.last;
        final childHome = childRoutes.last;
        ModelCenterService.instance.selectedTab = 3;
        await tester.tap(
          compact ? find.byTooltip('模型中心（转录与翻译）') : find.text('模型中心'),
        );
        final route = rootRoutes.last! as MaterialPageRoute<void>;
        expect(route, isNot(same(rootHome)));
        expect(childRoutes.last, same(childHome));
        final screen =
            route.builder(tester.element(find.byType(ModelCenterButton)))
                as ModelCenterScreen;
        expect(screen.initialTab, 0);
        expect(screen.translateSettings, same(settings));
        // Inspect the destination before mounting it: this test needs no native
        // inference runtime, device probes or real application storage.
        route.navigator!.removeRoute(route);
        await tester.pumpAndSettle();
        expect(text.text, '未提交的字幕文本');
        expect(find.byType(ModelCenterButton), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        settings.dispose();
      },
    );
  }

  for (final provider in [
    SubtitleTranslateProvider.bing,
    SubtitleTranslateProvider.local,
  ]) {
    testWidgets(
      'translation settings shortcut shares settings at 320px ($provider)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final settings = SubtitleTranslateSettings();
        await settings.ensureLoaded();
        await settings.setProviderEnZh(provider);
        final routes = _Routes();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [routes],
            home: Scaffold(
              body: TranscriptTranslateSettingsSheet(settings: settings),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('模型中心'));
        final route = routes.last! as MaterialPageRoute<void>;
        final screen =
            route.builder(tester.element(find.byType(ModelCenterButton)))
                as ModelCenterScreen;
        expect(screen.translateSettings, same(settings));
        expect(screen.initialTab, 0);
        route.navigator!.removeRoute(route);
        await tester.pumpAndSettle();
        expect(find.text('翻译设置'), findsOneWidget);
        expect(settings.providerEnZh, provider);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        settings.dispose();
      },
    );
  }
}
