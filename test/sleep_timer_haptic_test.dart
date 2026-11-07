import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/sleep_timer_dialog.dart';

final _android = TargetPlatformVariant.only(TargetPlatform.android);

const _light = 'HapticFeedbackType.lightImpact';
const _selection = 'HapticFeedbackType.selectionClick';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final feedback = <Object?>[];
  late SettingsService settings;
  late MediaPlaybackService playback;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService()..resetForTest();
    await settings.init();
    playback = MediaPlaybackService();
    await playback.stop();
    feedback.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            feedback.add(call.arguments);
          }
          return null;
        });
  });

  tearDown(() async {
    await playback.stop();
    settings.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> openDialog(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showSleepTimerDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('快捷时长按钮设定计时并只震一次', (tester) async {
    await openDialog(tester);
    expect(feedback, isEmpty, reason: '打开弹窗本身不震动');

    await tester.tap(find.text('30 分'));
    await tester.pump();

    expect(playback.sleepTimer.isActive, isTrue);
    expect(feedback, <Object?>[_selection]);

    // 取消计时，停掉心跳定时器，避免测试结束时留下 pending timer。
    unawaited(playback.sleepTimer.cancel());
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.sleepTimer.isActive, isFalse);
  }, variant: _android);

  testWidgets('计时方式开关只震一次', (tester) async {
    await openDialog(tester);
    final before = playback.sleepTimer.countOnlyWhilePlaying;
    final label = before ? '仅计算实际播放时间' : '按现实时间计时';

    await tester.tap(find.text(label));
    await tester.pump();

    expect(playback.sleepTimer.countOnlyWhilePlaying, isNot(before));
    expect(feedback, <Object?>[_selection]);
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: _android);

  testWidgets('关闭按钮震一次并关闭弹窗', (tester) async {
    await openDialog(tester);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(find.text('倒计时'), findsNothing);
    expect(feedback, <Object?>[_light]);
  }, variant: _android);

  testWidgets('关闭震动开关后弹窗内全部静默', (tester) async {
    await settings.saveEnableHapticFeedback(false);
    await openDialog(tester);

    await tester.tap(find.text('30 分'));
    await tester.pump();
    unawaited(playback.sleepTimer.cancel());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(feedback, isEmpty);
  }, variant: _android);
}
