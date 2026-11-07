import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/home_playback_defaults.dart';

Widget _home(SettingsService settings, {Size? size, Widget? child}) =>
    ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            final home = HomePlaybackDefaults(
              child: child ?? const SizedBox.shrink(),
            );
            return size == null
                ? home
                : MediaQuery(
                    data: MediaQuery.of(context).copyWith(size: size),
                    child: home,
                  );
          },
        ),
      ),
    );

class _StartupPlaybackProbe extends StatefulWidget {
  const _StartupPlaybackProbe(this.onStartup);

  final VoidCallback onStartup;

  @override
  State<_StartupPlaybackProbe> createState() => _StartupPlaybackProbeState();
}

class _StartupPlaybackProbeState extends State<_StartupPlaybackProbe> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onStartup());
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
  });
  tearDown(() {
    SettingsService().resetForTest();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final scenario in [
      (const Size(1280, 800), true),
      (const Size(800, 1280), false),
      (const Size(390, 844), false),
      (const Size(844, 390), true),
      (const Size(800, 800), false),
    ]) {
      testWidgets(
        '${platform.name} first home ${scenario.$1} saves skip=${scenario.$2}',
        (tester) async {
          tester.view.devicePixelRatio = 2;
          tester.view.physicalSize = scenario.$1 * 2;
          addTearDown(tester.view.reset);
          // A landscape physical display may contain a portrait split window.
          tester.view.display.devicePixelRatio = 2;
          tester.view.display.size = const Size(3200, 2400);
          addTearDown(tester.view.display.reset);
          final settings = SettingsService();
          await tester.runAsync(settings.init);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.containsKey('skipPortraitPlayer'), false);

          await tester.pumpWidget(_home(settings));
          await tester.pumpAndSettle();
          expect(settings.skipPortraitPlayer, scenario.$2);
          expect(prefs.getBool('skipPortraitPlayer'), scenario.$2);

          tester.view.physicalSize = Size(
            scenario.$1.height * 2,
            scenario.$1.width * 2,
          );
          await tester.pumpAndSettle();
          expect(settings.skipPortraitPlayer, scenario.$2);

          // Restarting in a different orientation keeps the initial choice.
          await tester.pumpWidget(const SizedBox.shrink());
          settings.resetForTest();
          await tester.runAsync(settings.init);
          await tester.pumpWidget(_home(settings));
          await tester.pumpAndSettle();
          expect(settings.skipPortraitPlayer, scenario.$2);
          expect(prefs.getBool('skipPortraitPlayer'), scenario.$2);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }

    for (final saved in [false, true]) {
      testWidgets(
        '${platform.name} preserves saved and manual skip=$saved',
        (tester) async {
          SharedPreferences.setMockInitialValues({'skipPortraitPlayer': saved});
          final settings = SettingsService();
          await tester.runAsync(settings.init);
          await tester.pumpWidget(
            _home(
              settings,
              size: saved ? const Size(800, 1280) : const Size(1280, 800),
            ),
          );
          await tester.pumpAndSettle();
          expect(settings.skipPortraitPlayer, saved);

          await settings.saveSkipPortraitPlayer(!saved);
          await tester.pumpAndSettle();
          final prefs = await SharedPreferences.getInstance();
          expect(settings.skipPortraitPlayer, !saved);
          expect(prefs.getBool('skipPortraitPlayer'), !saved);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }

    testWidgets(
      '${platform.name} waits for valid home metrics',
      (tester) async {
        final settings = SettingsService();
        await tester.runAsync(settings.init);
        final prefs = await SharedPreferences.getInstance();
        for (final invalid in [
          Size.zero,
          const Size(-1, 800),
          const Size(1280, double.nan),
          const Size(double.infinity, 800),
        ]) {
          await settings.initializeSkipPortraitPlayerForHome(invalid);
          expect(prefs.containsKey('skipPortraitPlayer'), false);
        }
        await tester.pumpWidget(_home(settings, size: Size.zero));
        await tester.pumpAndSettle();
        expect(settings.skipPortraitPlayer, false);
        expect(prefs.containsKey('skipPortraitPlayer'), false);

        await tester.pumpWidget(_home(settings, size: const Size(1280, 800)));
        await tester.pumpAndSettle();
        expect(settings.skipPortraitPlayer, true);
        expect(prefs.getBool('skipPortraitPlayer'), true);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      '${platform.name} retries after preferences finish loading',
      (tester) async {
        final settings = SettingsService();
        await tester.pumpWidget(_home(settings, size: const Size(1280, 800)));
        await tester.pumpAndSettle();
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('skipPortraitPlayer'), false);

        await tester.runAsync(settings.init);
        await tester.pumpAndSettle();
        expect(settings.skipPortraitPlayer, true);
        expect(prefs.getBool('skipPortraitPlayer'), true);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      '${platform.name} restored playback sees the home default',
      (tester) async {
        final settings = SettingsService();
        await tester.runAsync(settings.init);
        bool? startupSkipsPortrait;
        await tester.pumpWidget(
          _home(
            settings,
            size: const Size(1280, 800),
            child: _StartupPlaybackProbe(() {
              startupSkipsPortrait = settings.skipPortraitPlayer;
            }),
          ),
        );
        await tester.pumpAndSettle();
        expect(startupSkipsPortrait, true);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'desktop playback defaults are unchanged',
    (tester) async {
      final settings = SettingsService();
      await tester.runAsync(settings.init);
      await tester.pumpWidget(_home(settings, size: const Size(1280, 800)));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('skipPortraitPlayer'), false);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
