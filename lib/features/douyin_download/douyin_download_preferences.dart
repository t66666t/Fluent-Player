import 'package:shared_preferences/shared_preferences.dart';

class DouyinDownloadPreferences {
  static const manualModeKey = 'douyin_manual_capture_mode';
  static const autoRemoveAfterImportKey = 'douyin_auto_remove_after_import';

  static Future<bool> loadAutoRemoveAfterImport() async =>
      (await SharedPreferences.getInstance()).getBool(
        autoRemoveAfterImportKey,
      ) ??
      false;

  static Future<void> saveAutoRemoveAfterImport(bool value) async {
    if (!await (await SharedPreferences.getInstance()).setBool(
      autoRemoveAfterImportKey,
      value,
    )) {
      throw StateError('下载设置未能保存，请重试');
    }
  }

  static Future<bool> loadManualMode() async =>
      (await SharedPreferences.getInstance()).getBool(manualModeKey) ?? false;

  static Future<void> saveManualMode(bool value) async {
    if (!await (await SharedPreferences.getInstance()).setBool(
      manualModeKey,
      value,
    )) {
      throw StateError('下载设置未能保存，请重试');
    }
  }
}
