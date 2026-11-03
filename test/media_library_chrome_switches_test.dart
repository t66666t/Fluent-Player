import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

import 'media_private_import_setting_test.dart' show useTallSettingsSurface;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  test('迷你卡片和媒体通知默认开启，并可在反复写入后保持最后一次', () async {
    final settings = SettingsService();
    await settings.init();
    expect(settings.showMiniPlaybackCard, isTrue);
    expect(settings.showSystemMediaNotification, isTrue);

    final first = settings.updateSetting('showMiniPlaybackCard', false);
    final second = settings.updateSetting('showMiniPlaybackCard', true);
    final third = settings.updateSetting('showMiniPlaybackCard', false);
    expect(settings.showMiniPlaybackCard, isFalse);

    final notification = settings.updateSetting(
      'showSystemMediaNotification',
      false,
    );
    expect(settings.showSystemMediaNotification, isFalse);

    await Future.wait(<Future<void>>[first, second, third, notification]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('showMiniPlaybackCard'), isFalse);
    expect(prefs.getBool('showSystemMediaNotification'), isFalse);

    settings.resetForTest();
    await settings.init();
    expect(settings.showMiniPlaybackCard, isFalse);
    expect(settings.showSystemMediaNotification, isFalse);
  });

  test('迷你卡片开关会立刻通知播放服务，重复设成同一值不再通知', () async {
    final settings = SettingsService();
    await settings.init();
    final playback = MediaPlaybackService();
    await playback.stop();
    addTearDown(playback.stop);
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'mini-switch',
        path: 'bilibili://stream/BV1xx411c7mD?cid=1',
        title: 'Online',
        durationMs: 120000,
        lastUpdated: 0,
      ),
      const Duration(seconds: 4),
    );
    expect(playback.shouldShowMiniPlaybackCard, isTrue);

    var notifications = 0;
    playback.addListener(() => notifications++);

    final hiding = settings.updateSetting('showMiniPlaybackCard', false);
    expect(notifications, 1);
    expect(playback.shouldShowMiniPlaybackCard, isFalse);
    await hiding;
    expect(
      isMiniPlaybackCardVisible(
        currentItem: playback.currentItem,
        state: playback.state,
        enabled: false,
      ),
      isFalse,
    );

    final beforeShowing = notifications;
    final showing = settings.updateSetting('showMiniPlaybackCard', true);
    expect(notifications, beforeShowing + 1);
    expect(playback.shouldShowMiniPlaybackCard, isTrue);
    await showing;

    final beforeRepeat = notifications;
    final repeated = settings.updateSetting('showMiniPlaybackCard', true);
    expect(notifications, beforeRepeat);
    await repeated;
    expect(playback.state, isNot(PlaybackState.idle));
  });

  test('过期的通知开关提交会被丢掉，同一轮隐藏不会重复', () {
    expect(
      resolveSystemMediaNotificationCommit(
        epoch: 4,
        capturedEpoch: 3,
        enabled: true,
        suppressedEpoch: 2,
        suppressQueuedEpoch: 2,
      ),
      SystemMediaNotificationCommit.drop,
    );
    expect(
      resolveSystemMediaNotificationCommit(
        epoch: 4,
        capturedEpoch: 4,
        enabled: false,
        suppressedEpoch: 2,
        suppressQueuedEpoch: 2,
      ),
      SystemMediaNotificationCommit.suppress,
    );
    expect(
      resolveSystemMediaNotificationCommit(
        epoch: 4,
        capturedEpoch: 4,
        enabled: false,
        suppressedEpoch: 4,
        suppressQueuedEpoch: 1,
      ),
      SystemMediaNotificationCommit.drop,
    );
    expect(
      resolveSystemMediaNotificationCommit(
        epoch: 5,
        capturedEpoch: 5,
        enabled: true,
        suppressedEpoch: 4,
        suppressQueuedEpoch: 4,
      ),
      SystemMediaNotificationCommit.publish,
    );
    expect(
      resolveSystemMediaNotificationCommit(
        epoch: 4,
        capturedEpoch: 4,
        enabled: false,
        suppressedEpoch: 4,
        suppressQueuedEpoch: 4,
        headsetControlsEnabled: true,
      ),
      SystemMediaNotificationCommit.publishConcealed,
    );
    expect(
      nudgedSystemMediaNotificationPosition(const Duration(seconds: 3)),
      const Duration(seconds: 3, milliseconds: 1),
    );
    expect(
      shouldNudgeSystemMediaNotification(
        isIOS: true,
        nativeSuppressed: true,
        hasMedia: true,
      ),
      isTrue,
    );
    expect(
      shouldNudgeSystemMediaNotification(
        isIOS: false,
        nativeSuppressed: true,
        hasMedia: true,
      ),
      isFalse,
    );
  });

  testWidgets('桌面端常用设置前置，迷你卡片可切换且没有媒体通知开关', (tester) async {
    useTallSettingsSurface(tester);
    final settings = SettingsService();
    await settings.init();
    await _openSettings(tester, settings);

    final switches = find.byType(SwitchListTile);
    expect(
      tester.widget<SwitchListTile>(switches.first).key,
      const ValueKey<String>('mediaLibraryRestoreLastPage'),
    );
    expect(
      find.byKey(const ValueKey('showSystemMediaNotification')),
      findsNothing,
    );
    expect(find.text('显示迷你播放卡片'), findsOneWidget);
    expect(find.text('打开时回到上次离开的页面'), findsOneWidget);

    for (var tap = 0; tap < 6; tap++) {
      await tester.tap(find.byKey(const ValueKey('showMiniPlaybackCard')));
      await tester.pump();
      expect(settings.showMiniPlaybackCard, tap.isOdd);
    }
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('showMiniPlaybackCard')),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('移动端媒体通知保留且反复切换和设置值一致', (tester) async {
    useTallSettingsSurface(tester);
    final settings = SettingsService();
    await settings.init();
    await _openSettings(
      tester,
      settings,
      showSystemMediaNotificationSetting: true,
    );

    final switches = find.byType(SwitchListTile);
    expect(
      tester.widget<SwitchListTile>(switches.at(0)).key,
      const ValueKey<String>('mediaLibraryRestoreLastPage'),
    );
    expect(
      tester.widget<SwitchListTile>(switches.at(1)).key,
      const ValueKey<String>('showMiniPlaybackCard'),
    );

    for (var tap = 0; tap < 5; tap++) {
      await tester.tap(
        find.byKey(const ValueKey('showSystemMediaNotification')),
      );
      await tester.pump();
      expect(
        settings.showSystemMediaNotification,
        tap.isEven ? isFalse : isTrue,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('showSystemMediaNotification')),
            )
            .value,
        settings.showSystemMediaNotification,
      );
    }
  });
}

Future<void> _openSettings(
  WidgetTester tester,
  SettingsService settings, {
  bool? showSystemMediaNotificationSetting,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaLibrarySettingsBottomSheet(
              context,
              settings,
              showSystemMediaNotificationSetting:
                  showSystemMediaNotificationSetting,
            ),
            child: const Text('打开设置'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
  expect(find.text('打开时回到上次离开的页面'), findsOneWidget);

  await tester.pumpAndSettle();
}
