import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player_app/services/video_compose/android_compose_storage_access.dart';

void main() {
  const owned = [
    '/storage/emulated/0/Android/data/com.example.video_player_app.sidebar_profile/files',
    '/storage/emulated/0/Android/data/com.example.video_player_app.sidebar_profile/cache',
    '/storage/ABCD-1234/Android/data/com.example.video_player_app.sidebar_profile/files',
  ];

  for (final path in [
    owned.first,
    '${owned.first}/Exports/中文 空格',
    '${owned[1]}/compose',
    '${owned[2]}/output',
    '/data/user/0/com.example.video_player_app.sidebar_profile/app_flutter/exports',
  ]) {
    test(
      'application-owned directory does not require all-files permission: $path',
      () {
        expect(
          composeOutputRequiresAllFilesPermission(
            path,
            appOwnedDirectories: owned,
          ),
          isFalse,
        );
      },
    );
  }

  for (final path in [
    '/storage/emulated/0/Download/ComposedVideos',
    '/storage/emulated/0/Movies',
    '${owned.first}/../../../../../Download',
    '${owned.first}-other/exports',
    '/storage/emulated/0/Android/data/another.app/files',
    '/storage/ABCD-1234/Movies',
  ]) {
    test('public/sibling destination keeps its permission gate: $path', () {
      expect(
        composeOutputRequiresAllFilesPermission(
          path,
          appOwnedDirectories: owned,
        ),
        isTrue,
      );
    });
  }

  test('a missing ownership lookup never grants the whole shared volume', () {
    expect(
      composeOutputRequiresAllFilesPermission('/storage/emulated/0/Download'),
      isTrue,
    );
  });

  test(
    'Android 7–10 restricted all-files API uses legacy storage permission',
    () {
      expect(
        composeSharedStoragePermission(PermissionStatus.restricted),
        Permission.storage,
      );
    },
  );

  test('modern Android retains all-files permission for public raw paths', () {
    for (final status in [
      PermissionStatus.granted,
      PermissionStatus.denied,
      PermissionStatus.permanentlyDenied,
    ]) {
      expect(
        composeSharedStoragePermission(status),
        Permission.manageExternalStorage,
      );
    }
  });
}
