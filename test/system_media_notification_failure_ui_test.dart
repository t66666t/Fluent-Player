import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';
import 'package:video_player_app/widgets/system_media_notification_setting.dart';

class _FailureSession extends SystemMediaSessionService {
  _FailureSession(MediaPlaybackService playback, {required bool visible})
    : super.forTesting(playbackService: playback) {
    failure = SystemMediaNotificationFailure(
      epoch: 1,
      requestedVisible: visible,
      mediaId: 'media',
      sessionGeneration: 1,
    );
    feedback.value = failure;
  }
  late final SystemMediaNotificationFailure failure;
  final feedback = ValueNotifier<SystemMediaNotificationFailure?>(null);
  final retryFinished = Completer<void>();
  var attempts = 0;
  var succeeds = true;
  @override
  ValueListenable<SystemMediaNotificationFailure?> get notificationFailure =>
      feedback;
  @override
  Future<void> retryNotificationVisibility() async {
    attempts++;
    feedback.value = null;
    await retryFinished.future;
    if (!succeeds) feedback.value = failure;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    await settings.init();
    SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemMediaNotificationGate.channel,
          (_) async => {
            'channelBlocked': false,
            'ordinaryNotificationsAllowed': false,
          },
        );
  });
  tearDown(() {
    SystemMediaNotificationGate.debugTargetPlatform = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemMediaNotificationGate.channel, null);
    settings.resetForTest();
  });

  for (final visible in [true, false]) {
    testWidgets(
      'native ${visible ? 'show' : 'hide'} failure offers a persistent retry',
      (tester) async {
        final playback = MediaPlaybackService.forTesting();
        final session = _FailureSession(playback, visible: visible)
          ..succeeds = visible;
        settings.showSystemMediaNotification = visible;
        addTearDown(() {
          session.dispose();
          session.feedback.dispose();
          playback.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SystemMediaNotificationSetting(
                    settings: settings,
                    session: session,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final message = visible ? '系统播放控件未能显示' : '系统播放控件未能隐藏';
        expect(find.text(message), findsOneWidget);
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('showSystemMediaNotification')),
              )
              .onChanged,
          isNotNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('retry-system-media-notification')),
        );
        await tester.pump();
        expect(session.attempts, 1);
        expect(find.text('正在重试系统播放控件…'), findsOneWidget);
        session.retryFinished.complete();
        await tester.pumpAndSettle();
        expect(settings.showSystemMediaNotification, visible);
        expect(find.text(message), visible ? findsNothing : findsOneWidget);
        if (!visible) {
          expect(
            find.byKey(const ValueKey('retry-system-media-notification')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
