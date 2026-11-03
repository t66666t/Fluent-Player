import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('倍速锁定可锁定、切换并解除，且写入持久化', () async {
    SharedPreferences.setMockInitialValues({
      'playbackSpeed': 1.0,
      'isPlaybackSpeedLocked': false,
    });

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.playbackSpeed, 1.0);
    expect(settings.isPlaybackSpeedLocked, isFalse);

    final lockAction = await settings.togglePlaybackSpeedLock(2.0);
    expect(lockAction, PlaybackSpeedLockAction.locked);
    expect(settings.playbackSpeed, 2.0);
    expect(settings.isPlaybackSpeedLocked, isTrue);
    expect(settings.isLockedPlaybackSpeed(2.0), isTrue);

    final switchAction = await settings.togglePlaybackSpeedLock(1.5);
    expect(switchAction, PlaybackSpeedLockAction.switched);
    expect(settings.playbackSpeed, 1.5);
    expect(settings.isPlaybackSpeedLocked, isTrue);
    expect(settings.isLockedPlaybackSpeed(1.5), isTrue);
    expect(settings.isLockedPlaybackSpeed(2.0), isFalse);

    final unlockAction = await settings.togglePlaybackSpeedLock(1.5);
    expect(unlockAction, PlaybackSpeedLockAction.unlocked);
    expect(settings.playbackSpeed, 1.5);
    expect(settings.isPlaybackSpeedLocked, isFalse);

    await settings.savePlaybackSpeed(1.25);
    expect(settings.playbackSpeed, 1.25);
    expect(settings.isPlaybackSpeedLocked, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('playbackSpeed'), 1.25);
    expect(prefs.getBool('isPlaybackSpeedLocked'), isFalse);
    expect(
      prefs.getString('playbackSpeedLockStateV2'),
      '{"speed":1.25,"locked":false}',
    );
  });

  test('显式锁定操作不会因重复调用而反转状态', () async {
    SharedPreferences.setMockInitialValues({});

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    await settings.setPlaybackSpeedLock(2.0, true);
    await settings.setPlaybackSpeedLock(2.0, true);

    expect(settings.playbackSpeed, 2.0);
    expect(settings.isPlaybackSpeedLocked, isTrue);

    await settings.setPlaybackSpeedLock(2.0, false);
    await settings.setPlaybackSpeedLock(2.0, false);

    expect(settings.playbackSpeed, 2.0);
    expect(settings.isPlaybackSpeedLocked, isFalse);
  });

  test('单一快照优先于可能不一致的旧版字段', () async {
    SharedPreferences.setMockInitialValues({
      'playbackSpeed': 1.0,
      'isPlaybackSpeedLocked': false,
      'playbackSpeedLockStateV2': '{"speed":2.5,"locked":true}',
    });

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.playbackSpeed, 2.5);
    expect(settings.isPlaybackSpeedLocked, isTrue);
    expect(settings.effectiveGlobalPlaybackSpeed, 2.5);
  });

  test('播放器专用设置接口保持与原持久化行为一致', () async {
    SharedPreferences.setMockInitialValues({
      'showSubtitles': true,
      'isMirroredH': false,
      'userSubtitleSidebarWidth': 262.4,
      'subtitleOffset': 0,
      'landscapeSubtitleSidebarVisible': true,
    });

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    await settings.saveShowSubtitles(false);
    await settings.saveMirrorHorizontal(true);
    await settings.saveUserSubtitleSidebarWidth(320.0);
    await settings.saveSubtitleOffsetMilliseconds(1350);
    await settings.saveLandscapeSubtitleSidebarVisible(false);

    expect(settings.showSubtitles, isFalse);
    expect(settings.isMirroredH, isTrue);
    expect(settings.userSubtitleSidebarWidth, 320.0);
    expect(settings.subtitleOffset, const Duration(milliseconds: 1350));
    expect(settings.isLandscapeSubtitleSidebarVisible, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('showSubtitles'), isFalse);
    expect(prefs.getBool('isMirroredH'), isTrue);
    expect(prefs.getDouble('userSubtitleSidebarWidth'), 320.0);
    expect(prefs.getInt('subtitleOffset'), 1350);
    expect(prefs.getBool('landscapeSubtitleSidebarVisible'), isFalse);
  });
}
