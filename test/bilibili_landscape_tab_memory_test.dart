import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
  });
  tearDown(settings.resetForTest);

  test(
    'tab, shared visibility and width survive restart independently',
    () async {
      await settings.init();
      expect(settings.bilibiliLandscapeShowsSubtitles, isFalse);
      await settings.saveBilibiliLandscapeShowsSubtitles(true);
      await settings.saveUserSubtitleSidebarWidth(318);
      await settings.saveLandscapeSubtitleSidebarVisible(false);
      settings.resetForTest();
      await settings.init();
      expect(settings.bilibiliLandscapeShowsSubtitles, isTrue);
      expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);
      expect(settings.userSubtitleSidebarWidth, 318);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      expect(settings.bilibiliPlayerPanelOpen, isTrue);
      expect(
        settings
            .exportSettingsSnapshot()['layout']['bilibiliLandscapeShowsSubtitles'],
        isTrue,
      );
    },
  );

  test('rapid tab and visibility changes persist the latest intent', () async {
    await settings.init();
    final writes = <Future<void>>[];
    for (var i = 0; i < 21; i++) {
      writes.add(settings.saveBilibiliLandscapeShowsSubtitles(i.isEven));
      writes.add(settings.saveLandscapeSubtitleSidebarVisible(i.isOdd));
    }
    await Future.wait(writes);
    settings.resetForTest();
    await settings.init();
    expect(settings.bilibiliLandscapeShowsSubtitles, isTrue);
    expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);
  });

  test(
    'legacy closed Bilibili panel starts on subtitles until explicitly picked',
    () async {
      SharedPreferences.setMockInitialValues({
        'bilibiliPlayerPanelOpen': false,
      });
      await settings.init();
      expect(settings.bilibiliLandscapeShowsSubtitles, isTrue);
      await settings.saveBilibiliLandscapeShowsSubtitles(false);
      settings.resetForTest();
      await settings.init();
      expect(settings.bilibiliLandscapeShowsSubtitles, isFalse);
      expect(settings.bilibiliPlayerPanelOpen, isFalse);
    },
  );
}
