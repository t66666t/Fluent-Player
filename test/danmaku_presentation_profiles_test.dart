import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const portrait = DanmakuPresentationMode.portrait;
  const landscape = DanmakuPresentationMode.landscape;

  test(
    'upgrade keeps historical preferences in landscape and seeds portrait separately',
    () async {
      SharedPreferences.setMockInitialValues({
        'bilibiliDanmakuDisplayArea': .6,
        'bilibiliDanmakuFontScale': 1.3,
        'bilibiliDanmakuSpeed': .4,
        'bilibiliDanmakuFontFamily': '',
        'bilibiliDanmakuFontWeight': 400,
      });
      final settings = SettingsService()..resetForTest();
      await settings.init();
      expect(settings.danmakuDisplayAreaFor(landscape), .6);
      expect(settings.danmakuFontScaleFor(landscape), 1.3);
      expect(settings.danmakuSpeedFor(landscape), .4);
      expect(settings.danmakuDisplayAreaFor(portrait), .25);
      expect(settings.danmakuFontScaleFor(portrait), 1);
      expect(settings.danmakuSpeedFor(portrait), 1.0);
      expect(settings.danmakuDensityFor(portrait), .5);
      expect(settings.bilibiliDanmakuFontFamily, isNull);
      expect(settings.bilibiliDanmakuFontWeight, 400);
    },
  );

  test(
    'both profiles notify immediately, persist, export and reset independently stored values',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      expect(settings.bilibiliDanmakuFontFamily, 'Noto Sans SC');
      expect(settings.bilibiliDanmakuFontWeight, 700);
      var changes = 0;
      void onChange() => changes++;
      settings.addListener(onChange);
      addTearDown(() => settings.removeListener(onChange));
      final pending = settings.saveBilibiliDanmakuFontScale(
        1.2,
        mode: portrait,
      );
      expect(settings.danmakuFontScaleFor(portrait), 1.2);
      expect(changes, 1);
      await pending;
      await settings.saveBilibiliDanmakuDisplayArea(.35, mode: portrait);
      await settings.saveBilibiliDanmakuSpeed(.6, mode: portrait);
      await settings.saveBilibiliDanmakuDensity(.25, mode: portrait);
      await settings.saveBilibiliDanmakuFontScale(1.5);
      await settings.saveBilibiliDanmakuDisplayArea(.75);
      await settings.saveBilibiliDanmakuSpeed(1.2);
      await settings.saveBilibiliDanmakuDensity(.8);
      settings.resetForTest();
      await settings.init();
      expect(settings.danmakuFontScaleFor(portrait), 1.2);
      expect(settings.danmakuDisplayAreaFor(portrait), .35);
      expect(settings.danmakuSpeedFor(portrait), .6);
      expect(settings.danmakuDensityFor(portrait), .25);
      expect(settings.danmakuFontScaleFor(landscape), 1.5);
      expect(settings.danmakuDisplayAreaFor(landscape), .75);
      expect(settings.danmakuSpeedFor(landscape), 1.2);
      expect(settings.danmakuDensityFor(landscape), .8);
      await settings.setPlaybackSpeedLock(2, true);
      await settings.saveBilibiliDanmakuUseLockedSpeedAsBaseline(true);
      expect(settings.effectiveBilibiliDanmakuSpeedFor(portrait), .3);
      expect(settings.effectiveBilibiliDanmakuSpeedFor(landscape), .6);
      final exported = settings.exportSettingsSnapshot()['danmaku'] as Map;
      expect(exported['bilibiliDanmakuPortraitDensity'], .25);
      expect(exported['bilibiliDanmakuDensity'], .8);
      await settings.resetBilibiliDanmakuSettings();
      expect(settings.danmakuDisplayAreaFor(portrait), .25);
      expect(settings.danmakuFontScaleFor(portrait), 1);
      expect(settings.danmakuSpeedFor(portrait), 1.0);
      expect(settings.danmakuDensityFor(portrait), .5);
      expect(settings.danmakuDensityFor(landscape), 1);
      expect(settings.bilibiliDanmakuFontFamily, 'Noto Sans SC');
      expect(settings.bilibiliDanmakuFontWeight, 700);
    },
  );

  test(
    'portrait defaults stay readable across phone sizes, video bands and pixel ratios',
    () {
      const item = DanmakuItem(
        index: 0,
        startTime: Duration.zero,
        duration: Duration(seconds: 8),
        text: '默认弹幕',
        type: DanmakuType.scroll,
        colorValue: 0xffffffff,
        sourceY: 0,
      );
      for (final screen in [
        const Size(320, 568),
        const Size(360, 800),
        const Size(390, 844),
        const Size(430, 932),
        const Size(480, 1040),
      ]) {
        final base = resolveDanmakuFontSize(
          playerHeight: screen.height,
          fontScale: 1,
          screenSize: screen,
          presentationMode: portrait,
        );
        expect(base, inInclusiveRange(14, 16.2));
        for (final height in [screen.height, screen.width * 9 / 16]) {
          expect(
            resolveDanmakuFontSize(
              playerHeight: height,
              fontScale: 1.5,
              screenSize: screen,
              presentationMode: portrait,
            ),
            closeTo(base * 1.5, 1e-8),
          );
          expect(
            resolveDanmakuDurationUs(
              item,
              speed: .8,
              viewportWidth: screen.width,
              referenceWidth: 1920,
              motionAnchorWidth: resolveDanmakuScreenMotionAnchor(
                screen,
                presentationMode: portrait,
              ),
            ),
            (screen.width / 48 * 1000000).ceil(),
          );
        }
      }
    },
  );
}
