import '../services/app_storage_service.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app_branding.dart';

/// Folder name under XDG data home for Linux fallbacks.
///
/// Matches the GTK application ID; legacy directories are adopted by storage.
const String kAppDataFolderName = kApplicationId;

/// Resolves a writable directory for app-owned data (library, batch cache, …).
///
/// **Linux:** prefers [getApplicationSupportDirectory] (stable XDG data home),
/// then [getApplicationDocumentsDirectory]. Documents often throws
/// [MissingPlatformDirectoryException] when XDG user-dirs `DOCUMENTS` is unset.
///
/// **Other platforms:** prefers documents first so existing `library.json` and
/// related files keep their historical location, then support.
///
/// If both path_provider calls fail with [MissingPlatformDirectoryException]
/// (or similar), falls back to `$XDG_DATA_HOME/<app>` or `~/.local/share/<app>`,
/// creating the directory recursively.
Future<Directory> resolveAppDataDirectory() async {
  if (AppStorageService.instance.isReady) {
    return AppStorageService.instance.metadataDirectory;
  }
  final preferred = Platform.isLinux
      ? <Future<Directory> Function()>[
          getApplicationSupportDirectory,
          getApplicationDocumentsDirectory,
        ]
      : <Future<Directory> Function()>[
          getApplicationDocumentsDirectory,
          getApplicationSupportDirectory,
        ];

  Object? lastError;
  for (final getter in preferred) {
    try {
      final dir = await getter();
      return dir;
    } on MissingPlatformDirectoryException catch (e, st) {
      lastError = e;
      debugPrint('resolveAppDataDirectory: path_provider unavailable: $e');
      debugPrint('$st');
    } catch (e, st) {
      // Catch-all for platform channel / plugin failures with similar effect.
      lastError = e;
      debugPrint('resolveAppDataDirectory: path_provider failed: $e');
      debugPrint('$st');
    }
  }

  debugPrint(
    'resolveAppDataDirectory: using XDG data-home fallback '
    '(lastError=$lastError)',
  );
  return createXdgDataHomeFallback();
}

/// `$XDG_DATA_HOME/<app>` or `~/.local/share/<app>`, created if missing.
@visibleForTesting
Future<Directory> createXdgDataHomeFallback({
  String appFolderName = kAppDataFolderName,
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final xdgDataHome = env['XDG_DATA_HOME'];
  final String base;
  if (xdgDataHome != null && p.isAbsolute(xdgDataHome.trim())) {
    base = xdgDataHome.trim();
  } else {
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      base = p.join(home, '.local', 'share');
    } else {
      throw const StorageUnavailableException(
        '无法确定持久数据目录，请检查 HOME 或 XDG_DATA_HOME',
      );
    }
  }

  final dir = Directory(p.join(base, appFolderName));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}
