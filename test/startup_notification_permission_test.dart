import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/startup_notification_permission.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('first startup requests once and a denial survives a restart', () async {
    var requests = 0;
    StartupNotificationPermission makePermission() =>
        StartupNotificationPermission(
          isAndroid: true,
          readStatus: () async => PermissionStatus.denied,
          shouldShowRationale: () async => false,
          request: () async {
            requests++;
            return PermissionStatus.denied;
          },
        );
    await makePermission().requestOnce();
    await makePermission().requestOnce();
    expect(requests, 1);
  });

  test('concurrent startup calls share one system prompt', () async {
    final response = Completer<PermissionStatus>();
    var requests = 0;
    final permission = StartupNotificationPermission(
      isAndroid: true,
      readStatus: () async => PermissionStatus.denied,
      shouldShowRationale: () async => false,
      request: () {
        requests++;
        return response.future;
      },
    );
    final first = permission.requestOnce();
    final second = permission.requestOnce();
    response.complete(PermissionStatus.granted);
    await Future.wait([first, second]);
    expect(requests, 1);
  });

  for (final status in [
    PermissionStatus.granted,
    PermissionStatus.permanentlyDenied,
    PermissionStatus.restricted,
  ]) {
    test('$status never causes another system request', () async {
      var requests = 0;
      final permission = StartupNotificationPermission(
        isAndroid: true,
        readStatus: () async => status,
        request: () async {
          requests++;
          return PermissionStatus.granted;
        },
      );
      await permission.requestOnce();
      expect(requests, 0);
    });
  }

  test('an existing denial before this update is respected', () async {
    var requests = 0;
    final permission = StartupNotificationPermission(
      isAndroid: true,
      readStatus: () async => PermissionStatus.denied,
      shouldShowRationale: () async => true,
      request: () async {
        requests++;
        return PermissionStatus.granted;
      },
    );
    await permission.requestOnce();
    expect(requests, 0);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        StartupNotificationPermission.handledKey,
      ),
      isTrue,
    );
  });

  test('non-Android startup does not touch notification permission', () async {
    final permission = StartupNotificationPermission(
      isAndroid: false,
      readStatus: () => throw StateError('unexpected platform request'),
    );
    await permission.requestOnce();
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test(
    'an unavailable plugin does not interrupt startup or mark handled',
    () async {
      final permission = StartupNotificationPermission(
        isAndroid: true,
        readStatus: () => throw StateError('plugin unavailable'),
      );
      await permission.requestOnce();
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );
}
