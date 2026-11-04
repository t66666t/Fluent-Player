import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/device_form_factor.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
  });
  tearDown(() {
    SettingsService().resetForTest();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '${platform.name} tablet resolves late startup metrics',
      (tester) async {
        final display = tester.view.display;
        addTearDown(display.reset);
        display.devicePixelRatio = 2;
        display.size = Size.zero;
        final settings = SettingsService();
        expect(
          settings.registeredDefaultPreferences['skipPortraitPlayer'],
          false,
        );
        await tester.runAsync(settings.init);
        expect(settings.skipPortraitPlayer, false);

        // Startup completes with the same landscape display used by the folder
        // page. Its 800dp shortest side must select the landscape playback entry.
        display.size = const Size(2400, 1600);
        expect(settings.skipPortraitPlayer, true);
        expect(
          settings.registeredDefaultPreferences['skipPortraitPlayer'],
          true,
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('skipPortraitPlayer'), false);

        // A compact split-screen window must not reclassify the physical tablet.
        tester.view.physicalSize = const Size(800, 1200);
        addTearDown(tester.view.resetPhysicalSize);
        expect(settings.skipPortraitPlayer, true);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    for (final saved in [false, true]) {
      testWidgets(
        '${platform.name} preserves saved skip portrait=$saved',
        (tester) async {
          final display = tester.view.display;
          addTearDown(display.reset);
          display.devicePixelRatio = 2;
          display.size = const Size(2400, 1600);
          SharedPreferences.setMockInitialValues({'skipPortraitPlayer': saved});
          final settings = SettingsService();
          await tester.runAsync(settings.init);
          expect(settings.skipPortraitPlayer, saved);
          display.size = const Size(800, 1600);
          expect(settings.skipPortraitPlayer, saved);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }

  testWidgets(
    'phones retain portrait entry and tablet threshold is 600dp',
    (tester) async {
      final display = tester.view.display;
      addTearDown(display.reset);
      display.devicePixelRatio = 2;
      display.size = const Size(2400, 1198);
      final settings = SettingsService();
      await tester.runAsync(settings.init);
      expect(DeviceFormFactor.isTabletLikeDevice(), false);
      expect(settings.skipPortraitPlayer, false);
      display.size = const Size(2400, 1200);
      expect(DeviceFormFactor.isTabletLikeDevice(), true);
      expect(settings.skipPortraitPlayer, true);

      // A user can turn the tablet default off; its first write takes effect
      // immediately and survives a settings reload.
      await settings.saveSkipPortraitPlayer(false);
      expect(settings.skipPortraitPlayer, false);
      settings.resetForTest();
      await tester.runAsync(settings.init);
      expect(settings.skipPortraitPlayer, false);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
