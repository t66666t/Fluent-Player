import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('long-press speed remains inside the native pitch-safe range', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService()..resetForTest();
    await settings.init();

    await settings.saveLongPressSpeed(12);
    expect(settings.longPressSpeed, 8);

    await settings.saveLongPressSpeed(0.05);
    expect(settings.longPressSpeed, 0.25);

    await settings.saveLongPressSpeed(5);
    expect(settings.longPressSpeed, 5);
  });
}
