import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

/// Whether an Android raw output path needs broad shared-storage access.
bool composeOutputRequiresAllFilesPermission(
  String path, {
  Iterable<String> appOwnedDirectories = const [],
}) {
  final normalized = p.posix.normalize(path);
  for (final directory in appOwnedDirectories) {
    if (directory.trim().isEmpty) continue;
    final owned = p.posix.normalize(directory);
    if (p.posix.equals(owned, normalized) ||
        p.posix.isWithin(owned, normalized)) {
      return false;
    }
  }
  return p.posix.equals('/storage', normalized) ||
      p.posix.isWithin('/storage', normalized) ||
      p.posix.equals('/sdcard', normalized) ||
      p.posix.isWithin('/sdcard', normalized);
}

/// permission_handler reports MANAGE_EXTERNAL_STORAGE as restricted below
/// Android 11. Those supported devices use the existing storage permission.
Permission composeSharedStoragePermission(PermissionStatus allFilesStatus) =>
    allFilesStatus.isRestricted
    ? Permission.storage
    : Permission.manageExternalStorage;
