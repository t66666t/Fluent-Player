import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未持久化时默认值可靠回退（测试环境无真实视口，按手机处理为关闭）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.skipPortraitPlayer, isFalse);
  });

  test('跳过竖屏播放页可开启并写入持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'skipPortraitPlayer': false,
    });

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.skipPortraitPlayer, isFalse);

    await settings.saveSkipPortraitPlayer(true);
    expect(settings.skipPortraitPlayer, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('skipPortraitPlayer'), isTrue);
  });

  test('重新初始化后设置值保留（持久化恢复）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'skipPortraitPlayer': true,
    });

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.skipPortraitPlayer, isTrue);

    await settings.saveSkipPortraitPlayer(false);
    expect(settings.skipPortraitPlayer, isFalse);
  });

  test('saveSkipPortraitPlayer 通过 notifyListeners 即时通知监听者', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'skipPortraitPlayer': false,
    });

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    var notified = 0;
    void listener() => notified++;
    settings.addListener(listener);
    addTearDown(() => settings.removeListener(listener));

    await settings.saveSkipPortraitPlayer(true);

    expect(notified, greaterThan(0));
    expect(settings.skipPortraitPlayer, isTrue);
  });
}
