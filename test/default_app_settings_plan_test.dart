import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/default_settings_trial_action.dart';

import 'support/default_trial_features.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'playbackSpeed': 1.75});
    SubtitleDebugSession.instance.resetForTest();
    SettingsService().resetForTest();
    SettingsService().featureSettingsForTrial = MemoryTrialFeatures();
  });
  for (final scenario in [
    (TargetPlatform.android, const Size(320, 568), 2.0, '手机'),
    (TargetPlatform.iOS, const Size(768, 1024), 1.3, '平板'),
    (TargetPlatform.windows, const Size(1280, 720), 1.0, '电脑'),
  ]) {
    testWidgets(
      'plan is read-only and fits ${scenario.$4} ${scenario.$2}',
      (tester) async {
        tester.view.physicalSize = scenario.$2;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final settings = SettingsService();
        await settings.init();
        final prefs = await SharedPreferences.getInstance();
        final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.$3)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: scenario.$2.width,
                  child: DefaultSettingsTrialButton(settings: settings),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('查看默认设置方案'));
        await tester.pumpAndSettle();
        expect(find.text('${scenario.$4}默认设置方案'), findsOneWidget);
        expect(find.text('播放'), findsOneWidget);
        await tester.ensureVisible(find.text('睡眠定时'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        expect(settings.defaultSettingsTrial.hasBackup, false);
        expect({
          for (final key in prefs.getKeys()) key: prefs.get(key),
        }, before);
      },
      variant: TargetPlatformVariant({scenario.$1}),
    );
  }
}
