import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/models/recommended_app_defaults.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'support/default_trial_features.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'tablet defaults keep nine columns across pane widths and custom geometry wins',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      settings.defaultTrialDevice = const DefaultSettingsDevice(
        TargetPlatform.android,
        Size(1200, 750),
      );
      settings.featureSettingsForTrial = MemoryTrialFeatures();
      await settings.init();
      final original = settings.homeCardStyleFor(const Size(1280, 800));
      await settings.defaultSettingsTrial.toggle();
      const screen = Size(1280, 800);
      final style = settings.homeCardStyleFor(screen);
      final pane = MediaLibraryLayoutDefaults.cardGrid(
        screenSize: const Size(1080, 800),
        style: style,
      );
      expect(style.crossAxisCount, 9);
      expect(pane.crossAxisCount, 9);
      // 2880 x 1800 physical pixels must retain nine tablet columns at
      // different display densities, including an unscaled display.
      for (final density in [1.0, 2.0, 2.25, 2.4, 2.5, 3.0]) {
        final logicalSize = const Size(2880, 1800) / density;
        settings.defaultTrialDevice = DefaultSettingsDevice(
          TargetPlatform.android,
          logicalSize,
        );
        expect(settings.homeCardStyleFor(logicalSize).crossAxisCount, 9);
        expect(
          settings.homeCardStyleFor(logicalSize.flipped).crossAxisCount,
          6,
        );
      }
      final heightRatio = pane.cellHeight / pane.cellWidth;
      for (final count in [1, 3, 9, 20]) {
        await settings.updateHomeCardStyleFor(screen, crossAxisCount: count);
        final changed = settings.homeCardStyleFor(screen);
        expect(changed.titleScale, closeTo(12.5 / 150, 1e-10));
        for (final width in [120.0, 320.0, 1920.0, 8000.0]) {
          final grid = MediaLibraryLayoutDefaults.cardGrid(
            screenSize: Size(width, 800),
            style: changed,
          );
          expect(grid.cellHeight / grid.cellWidth, closeTo(heightRatio, 1e-10));
        }
      }
      await settings.updateHomeCardStyleFor(
        screen,
        crossAxisCount: 10,
        heightScale: .8,
      );
      final custom = settings.homeCardStyleFor(screen);
      expect(custom.usesDefaultColumns, false);
      expect(custom.reserveTwoTitleLines, false);
      expect(
        settings.homeCardStyleFor(const Size(800, 1280)).usesDefaultColumns,
        true,
      );
      final customGrid = MediaLibraryLayoutDefaults.cardGrid(
        screenSize: screen,
        style: custom,
        textScaler: const TextScaler.linear(2),
      );
      expect(customGrid.crossAxisCount, 10);
      expect(customGrid.cellHeight / customGrid.cellWidth, closeTo(.8, .001));
      await settings.defaultSettingsTrial.toggle();
      expect(settings.mediaLibraryReadableCardDefaults, false);
      final restored = settings.homeCardStyleFor(screen);
      expect(restored.crossAxisCount, original.crossAxisCount);
      expect(restored.titleScale, original.titleScale);
      expect(restored.heightScale, original.heightScale);
      expect(restored.crossSpacingScale, original.crossSpacingScale);
      expect(restored.mainSpacingScale, original.mainSpacingScale);
      expect(restored.reserveTwoTitleLines, original.reserveTwoTitleLines);
    },
  );
  test(
    'device presets keep small phones at three and desktop columns fixed',
    () {
      for (final size in [const Size(320, 568), const Size(390, 844)]) {
        expect(
          MediaLibraryLayoutDefaults.readableCardCrossAxisCount(
            size,
            mobile: true,
            phone: true,
          ),
          3,
        );
        expect(
          MediaLibraryLayoutDefaults.readableCardCrossAxisCount(
            size.flipped,
            mobile: true,
            phone: true,
          ),
          6,
        );
      }
      for (final size in [const Size(1280, 800), const Size(2560, 1440)]) {
        expect(
          MediaLibraryLayoutDefaults.readableCardCrossAxisCount(
            size,
            mobile: false,
            phone: false,
          ),
          12,
        );
      }
    },
  );
}
