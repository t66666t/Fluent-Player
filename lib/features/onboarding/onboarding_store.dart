import 'package:shared_preferences/shared_preferences.dart';

/// Reopening setup from the hidden entry leaves first-run status alone.
/// Explicit settings edits use their regular persistence services.
class OnboardingStore {
  static const handledKey = 'onboarding.handled.v1';

  static Future<void> prepareFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(handledKey)) return;
    // These keys predate onboarding and are written by settings migrations.
    // Upgrades keep opening normally, including an existing empty library.
    final existingInstall = [
      'subtitleTextStyle',
      'subtitleStyle',
      'subtitleStyleLandscape',
      'ghostLayoutCompatibilityVersion',
      'subtitleTextMetricCompatibilityVersion',
      'mediaLibraryRootEntryOrder',
      'largeDataRootPath',
      'playback_state_snapshot',
    ].any(prefs.containsKey);
    await prefs.setBool(handledKey, existingInstall);
  }

  static Future<bool> shouldShow() async =>
      (await SharedPreferences.getInstance()).getBool(handledKey) == false;

  static Future<void> markHandled() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(handledKey, true)) {
      throw StateError('Unable to save onboarding state');
    }
  }
}
