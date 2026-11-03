import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_sidebar_width.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
  });

  test('first use chooses a responsive phone and desktop width', () async {
    final settings = SettingsService();
    await settings.init();
    expect(settings.userAiSidebarWidth, 0);
    expect(AiSidebarWidth.resolve(const Size(800, 360)), 304);
    expect(AiSidebarWidth.resolve(const Size(1440, 900)), closeTo(518.4, .01));
  });

  test('AI and subtitle widths persist independently across reloads', () async {
    final settings = SettingsService();
    await settings.init();
    await settings.saveUserSubtitleSidebarWidth(310);
    await settings.saveUserAiSidebarWidth(680);
    expect(settings.userSubtitleSidebarWidth, 310);
    expect(settings.userAiSidebarWidth, 680);
    final snapshot = settings.exportSettingsSnapshot();
    expect(snapshot['layout']['userAiSidebarWidth'], 680);
    settings.resetForTest();
    await settings.init();
    expect(settings.userAiSidebarWidth, 680);
    expect(settings.userSubtitleSidebarWidth, 310);
    await settings.saveUserSubtitleSidebarWidth(190);
    expect(settings.userAiSidebarWidth, 680);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('userAiSidebarWidth'), 680);
  });

  test(
    'a smaller viewport clamps display without losing preferred width',
    () async {
      final settings = SettingsService();
      await settings.init();
      await settings.saveUserAiSidebarWidth(900);
      expect(
        AiSidebarWidth.resolve(
          const Size(800, 360),
          preference: settings.userAiSidebarWidth,
        ),
        668,
      );
      expect(
        AiSidebarWidth.resolve(
          const Size(1440, 900),
          preference: settings.userAiSidebarWidth,
        ),
        900,
      );
      expect(settings.userAiSidebarWidth, 900);
    },
  );

  test('resize bounds retain readable chat and space for the video', () {
    expect(AiSidebarWidth.clamp(const Size(800, 360), 20), 240);
    expect(AiSidebarWidth.clamp(const Size(800, 360), 2000), 668);
    expect(AiSidebarWidth.clamp(const Size(320, 200), 240), 188);
    expect(AiSidebarWidth.clamp(const Size(120, 100), 240), 0);
  });

  test('invalid stored widths restore the automatic default', () async {
    SharedPreferences.setMockInitialValues({'userAiSidebarWidth': -200.0});
    final settings = SettingsService();
    await settings.init();
    expect(settings.userAiSidebarWidth, 0);
    await settings.saveUserAiSidebarWidth(double.infinity);
    expect(settings.userAiSidebarWidth, 0);
    expect(
      AiSidebarWidth.resolve(const Size(800, 360), preference: double.nan),
      304,
    );
  });
}
