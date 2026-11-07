import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// App-owned persistent output, used without a shared-storage permission.
Future<String> androidPrivateComposeOutputDirectory({
  Future<Directory> Function()? documentsDirectory,
}) async {
  final documents =
      await (documentsDirectory ?? getApplicationDocumentsDirectory)();
  return p.join(documents.path, 'exports', 'composed');
}

/// Keeps a chosen directory when permitted. A denied public directory only
/// falls back to app storage after the user explicitly accepts that choice.
Future<String?> resolveAndroidComposeOutputDirectory({
  required String? selectedDirectory,
  required Future<bool> Function(String path) requiresPermission,
  required Future<bool> Function() requestPermission,
  required Future<bool> Function() useAppDirectory,
  required Future<String> Function() appDirectory,
}) async {
  if (selectedDirectory == null || selectedDirectory.isEmpty) {
    return appDirectory();
  }
  if (!await requiresPermission(selectedDirectory) ||
      await requestPermission()) {
    return selectedDirectory;
  }
  return await useAppDirectory() ? appDirectory() : null;
}

/// Verify a task can create its staging directory before adding it to the queue.
Future<void> prepareComposeOutputDirectory(String path) async {
  final directory = Directory(path);
  await directory.create(recursive: true);
  final probe = await directory.createTemp('.compose_write_probe_');
  await probe.delete();
}

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
