import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const plugin = MethodChannel('com.ryanheise.audio_service.handler.methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  setUp(() {
    calls.clear();
    SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      calls.add('plugin:${call.method}:${call.arguments}');
      return true;
    });
    messenger.setMockMethodCallHandler(SystemMediaNotificationGate.channel, (
      call,
    ) async {
      calls.add('app:${call.method}');
      return true;
    });
  });

  tearDown(() {
    SystemMediaNotificationGate.debugTargetPlatform = null;
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(
      SystemMediaNotificationGate.channel,
      null,
    );
  });

  test(
    'iOS conceal installs the native policy without disabling commands',
    () async {
      expect(await SystemMediaNotificationGate.conceal(), isTrue);
      expect(calls, ['plugin:setNowPlayingVisible:{visible: false}']);
    },
  );

  test(
    'iOS hides before an asynchronous playback publication is sent',
    () async {
      expect(await SystemMediaNotificationGate.holdPlaying(), isTrue);
      await plugin.invokeMethod<void>('setState', {
        'state': 'truthful playback',
      });
      expect(await SystemMediaNotificationGate.conceal(), isTrue);
      expect(calls, [
        'plugin:setNowPlayingVisible:{visible: false}',
        'plugin:setState:{state: truthful playback}',
        'plugin:setNowPlayingVisible:{visible: false}',
      ]);
    },
  );

  test('iOS suppress keeps the existing remote-command suppression', () async {
    expect(await SystemMediaNotificationGate.suppress(), isTrue);
    expect(calls, [
      'plugin:setNowPlayingVisible:{visible: false}',
      'app:suppress',
    ]);
  });

  test(
    'iOS show releases the policy without publishing cached media',
    () async {
      expect(await SystemMediaNotificationGate.armShow(), isTrue);
      expect(calls, ['plugin:setNowPlayingVisible:{visible: true}']);
    },
  );

  test(
    'an unavailable iOS plugin does not report successful concealment',
    () async {
      messenger.setMockMethodCallHandler(plugin, (_) async {
        throw MissingPluginException();
      });
      expect(await SystemMediaNotificationGate.conceal(), isFalse);
      expect(calls, isEmpty);
    },
  );

  test(
    'iOS suppress reports a missing plugin while retaining app suppression',
    () async {
      messenger.setMockMethodCallHandler(plugin, (_) async {
        throw MissingPluginException();
      });
      expect(await SystemMediaNotificationGate.suppress(), isFalse);
      expect(calls, ['app:suppress']);
    },
  );

  test('an iOS policy error is controlled and can be retried', () async {
    messenger.setMockMethodCallHandler(plugin, (_) async {
      throw PlatformException(code: 'NOW_PLAYING_VISIBILITY');
    });
    expect(await SystemMediaNotificationGate.conceal(), isFalse);
    messenger.setMockMethodCallHandler(plugin, (_) async => true);
    expect(await SystemMediaNotificationGate.conceal(), isTrue);
  });

  test('a null iOS policy acknowledgment is not success', () async {
    messenger.setMockMethodCallHandler(plugin, (_) async => null);
    expect(await SystemMediaNotificationGate.conceal(), isFalse);
  });

  testWidgets(
    'an unresponsive old host cannot block subsequent visibility commits',
    (tester) async {
      final oldHost = Completer<bool>();
      messenger.setMockMethodCallHandler(plugin, (_) => oldHost.future);
      final hiding = SystemMediaNotificationGate.conceal();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(await hiding, isFalse);
      oldHost.complete(true);
      await tester.pump();
      messenger.setMockMethodCallHandler(plugin, (_) async => true);
      expect(await SystemMediaNotificationGate.armShow(), isTrue);
    },
  );

  test(
    'Android retains its existing application notification-gate methods',
    () async {
      SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
      expect(await SystemMediaNotificationGate.holdPlaying(), isTrue);
      expect(await SystemMediaNotificationGate.conceal(), isTrue);
      expect(await SystemMediaNotificationGate.suppress(), isTrue);
      expect(await SystemMediaNotificationGate.armShow(), isTrue);
      expect(calls, [
        'app:holdPlaying',
        'app:conceal',
        'app:suppress',
        'app:armShow',
      ]);
    },
  );

  test('Windows does not invoke mobile notification channels', () async {
    SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.windows;
    expect(await SystemMediaNotificationGate.holdPlaying(), isTrue);
    expect(await SystemMediaNotificationGate.conceal(), isTrue);
    expect(await SystemMediaNotificationGate.suppress(), isTrue);
    expect(await SystemMediaNotificationGate.armShow(), isTrue);
    expect(calls, isEmpty);
  });

  test(
    'ordinary notification denial does not block an Android media channel',
    () async {
      SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
      messenger.setMockMethodCallHandler(SystemMediaNotificationGate.channel, (
        call,
      ) async {
        expect(call.method, 'readAvailability');
        return {'channelBlocked': false, 'ordinaryNotificationsAllowed': false};
      });
      final availability = await SystemMediaNotificationGate.readAvailability();
      expect(availability.isKnown, isTrue);
      expect(availability.channelBlocked, isFalse);
      expect(availability.ordinaryNotificationsAllowed, isFalse);
      expect(availability.canOpenSystemSettings, isTrue);
    },
  );

  test('an explicitly blocked media channel is reported separately', () async {
    SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
    messenger.setMockMethodCallHandler(
      SystemMediaNotificationGate.channel,
      (_) async => {
        'channelBlocked': true,
        'ordinaryNotificationsAllowed': true,
      },
    );
    expect(
      (await SystemMediaNotificationGate.readAvailability()).channelBlocked,
      isTrue,
    );
  });

  test(
    'an old Android host cannot be mistaken for a denied media channel',
    () async {
      SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
      messenger.setMockMethodCallHandler(SystemMediaNotificationGate.channel, (
        _,
      ) async {
        throw MissingPluginException();
      });
      final availability = await SystemMediaNotificationGate.readAvailability();
      expect(availability.isKnown, isFalse);
      expect(availability.channelBlocked, isFalse);
      expect(await SystemMediaNotificationGate.openSystemSettings(), isFalse);
    },
  );

  test(
    'iOS Now Playing does not query ordinary notification permission',
    () async {
      final availability = await SystemMediaNotificationGate.readAvailability();
      expect(availability.isKnown, isTrue);
      expect(availability.channelBlocked, isFalse);
      expect(availability.ordinaryNotificationsAllowed, isNull);
      expect(availability.canOpenSystemSettings, isFalse);
      expect(calls, isEmpty);
    },
  );

  test('Android notification settings require native acknowledgment', () async {
    SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
    expect(await SystemMediaNotificationGate.openSystemSettings(), isTrue);
    expect(calls, ['app:openSystemSettings']);
    messenger.setMockMethodCallHandler(
      SystemMediaNotificationGate.channel,
      (_) async => null,
    );
    expect(await SystemMediaNotificationGate.openSystemSettings(), isFalse);
  });
}
