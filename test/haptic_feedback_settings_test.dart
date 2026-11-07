import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/app_haptics.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  final platformCalls = <MethodCall>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService()..resetForTest();
    await settings.init();
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('震动默认开启、实时更新并持久化', () async {
    expect(settings.enableHapticFeedback, isTrue);

    final saving = settings.saveEnableHapticFeedback(false);
    expect(settings.enableHapticFeedback, isFalse);
    await saving;

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('enableHapticFeedback'), isFalse);

    settings.resetForTest();
    await settings.init();
    expect(settings.enableHapticFeedback, isFalse);
  });

  test('Android 与 iOS 均会执行长按震动，关闭总开关后全部静默', () async {
    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      await settings.saveEnableHapticFeedback(true);
      await AppHaptics.longPressStarted(settings);
    }

    expect(
      platformCalls.where(
        (call) =>
            call.method == 'HapticFeedback.vibrate' &&
            call.arguments == 'HapticFeedbackType.lightImpact',
      ),
      hasLength(2),
    );

    await settings.saveEnableHapticFeedback(false);
    await AppHaptics.longPressStarted(settings);
    await AppHaptics.selectionClick(settings);
    expect(platformCalls, hasLength(2));
  });

  test('桌面平台即使开启开关也不会触发震动', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await AppHaptics.selectionClick(settings);
    expect(platformCalls, isEmpty);
  });

  test('双击快进使用轻触反馈并受震动总开关控制', () async {
    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      await AppHaptics.doubleTapSeek(settings);
    }
    expect(
      platformCalls.where(
        (call) =>
            call.method == 'HapticFeedback.vibrate' &&
            call.arguments == 'HapticFeedbackType.lightImpact',
      ),
      hasLength(2),
    );

    await settings.saveEnableHapticFeedback(false);
    await AppHaptics.doubleTapSeek(settings);
    expect(platformCalls, hasLength(2));
  });

  test('任务排序使用轻触和选择反馈并受总开关控制', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await AppHaptics.reorderDragStarted(settings);
    await AppHaptics.reorderTargetChanged(settings);
    await AppHaptics.reorderDragCompleted(settings);

    expect(platformCalls.map((call) => call.arguments), [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.lightImpact',
    ]);

    await settings.saveEnableHapticFeedback(false);
    await AppHaptics.reorderDragStarted(settings);
    await AppHaptics.reorderTargetChanged(settings);
    await AppHaptics.reorderDragCompleted(settings);
    expect(platformCalls, hasLength(3));
  });

  test('轻触受震动总开关控制', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await AppHaptics.lightTap(settings);

    expect(platformCalls.map((call) => call.arguments), [
      'HapticFeedbackType.lightImpact',
    ]);

    await settings.saveEnableHapticFeedback(false);
    await AppHaptics.lightTap(settings);
    expect(platformCalls, hasLength(1));
  });
}
