import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:video_player_app/utils/import_gallery_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  final requests = <int>[];
  final checks = <int>[];
  var video = PermissionState.denied;
  var audio = PermissionState.denied;
  var combined = PermissionState.denied;

  setUp(() {
    requests.clear();
    checks.clear();
    video = PermissionState.denied;
    audio = PermissionState.denied;
    combined = PermissionState.denied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, (call) async {
          final args = call.arguments as Map<dynamic, dynamic>;
          final permission = args['androidPermission'] as Map<dynamic, dynamic>;
          expect(permission['mediaLocation'], isFalse);
          final type = permission['type'] as int;
          if (call.method == 'requestPermissionExtend') {
            requests.add(type);
            return combined.index;
          }
          if (call.method == 'getPermissionState') {
            checks.add(type);
            return (type == RequestType.video.value ? video : audio).index;
          }
          throw StateError('Unexpected photo manager method ${call.method}');
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, null);
  });

  test('Android 13 keeps allowed videos when audio was denied', () async {
    video = PermissionState.authorized;
    // The Android 13 plugin reports the combined request denied in this case.
    expect(
      await requestImportGalleryAccess(platform: TargetPlatform.android),
      RequestType.video,
    );
    expect(requests, [(RequestType.video | RequestType.audio).value]);
    expect(checks, [RequestType.video.value, RequestType.audio.value]);
  });

  test('Android keeps allowed audio when visual access was denied', () async {
    audio = PermissionState.authorized;
    expect(
      await requestImportGalleryAccess(platform: TargetPlatform.android),
      RequestType.audio,
    );
  });

  test('Android 14 selected videos work without audio access', () async {
    combined = PermissionState.limited;
    video = PermissionState.limited;
    expect(
      await requestImportGalleryAccess(platform: TargetPlatform.android),
      RequestType.video,
    );
  });

  test(
    'Android 14 selected videos can coexist with full audio access',
    () async {
      combined = PermissionState.limited;
      video = PermissionState.limited;
      audio = PermissionState.authorized;
      expect(
        await requestImportGalleryAccess(platform: TargetPlatform.android),
        RequestType.video | RequestType.audio,
      );
    },
  );

  test(
    'revocation before picker creation leaves no readable media type',
    () async {
      combined = PermissionState.authorized;
      expect(
        await requestImportGalleryAccess(platform: TargetPlatform.android),
        isNull,
      );
    },
  );

  for (final status in [PermissionState.authorized, PermissionState.limited]) {
    test(
      'iOS $status uses Photos access without Android permission queries',
      () async {
        combined = status;
        expect(
          await requestImportGalleryAccess(platform: TargetPlatform.iOS),
          RequestType.video | RequestType.audio,
        );
        expect(checks, isEmpty);
        expect(requests, [(RequestType.video | RequestType.audio).value]);
      },
    );
  }

  test('denied iOS Photos access never opens the gallery picker', () async {
    expect(
      await requestImportGalleryAccess(platform: TargetPlatform.iOS),
      isNull,
    );
    expect(checks, isEmpty);
  });
}
