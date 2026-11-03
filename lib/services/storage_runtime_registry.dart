import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/app_data_paths.dart';
import 'storage_audit_service.dart';

/// Remembers exact temporary directories created by this app.
///
/// System temp is shared. A matching prefix is not enough to delete a folder;
/// the audit only trusts paths written here that also carry an ownership marker.
class StorageRuntimeRegistry {
  static const fileName = 'storage_runtime_registry.json';
  static const markerName = '.fluent_player_owned';
  static const leaseName = '.fluent_player_lease';

  /// In-process paths whose owner has not finished disposing them.
  static final Set<String> activePaths = <String>{};

  static void activate(String path) => activePaths.add(storagePathKey(path));

  static void deactivate(String path) =>
      activePaths.remove(storagePathKey(path));

  static bool isActive(String path) => activePaths.contains(storagePathKey(path));

  /// Best-effort. A failed registry write must not block login or playback.
  static Future<void> remember({
    required String kind,
    required String path,
  }) async {
    try {
      final root = await resolveAppDataDirectory();
      final file = File(p.join(root.path, fileName));
      final entries = readFile(file);
      final key = storagePathKey(path);
      entries.removeWhere((entry) => storagePathKey(entry.path) == key);
      entries.add(StorageRuntimeEntry(kind: kind, path: path));
      await _write(file, entries);
    } catch (_) {
      /* The in-memory lease still protects the directory for this process. */
    }
  }

  static Future<void> forget(String path) async {
    try {
      final root = await resolveAppDataDirectory();
      final file = File(p.join(root.path, fileName));
      final entries = readFile(file);
      final key = storagePathKey(path);
      final next = entries
          .where((entry) => storagePathKey(entry.path) != key)
          .toList();
      if (next.length == entries.length) return;
      await _write(file, next);
    } catch (_) {}
  }

  static List<StorageRuntimeEntry> readFile(File file) {
    if (!file.existsSync()) return <StorageRuntimeEntry>[];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      final raw = decoded is Map ? decoded['entries'] : null;
      if (raw is! List) return <StorageRuntimeEntry>[];
      return [
        for (final item in raw)
          if (item is Map &&
              item['kind'] is String &&
              item['path'] is String &&
              (item['path'] as String).isNotEmpty)
            StorageRuntimeEntry(
              kind: item['kind'] as String,
              path: item['path'] as String,
            ),
      ];
    } catch (_) {
      return <StorageRuntimeEntry>[];
    }
  }

  static Future<void> _write(
    File file,
    List<StorageRuntimeEntry> entries,
  ) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'entries': [
          for (final entry in entries)
            {'kind': entry.kind, 'path': entry.path},
        ],
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}

class StorageRuntimeEntry {
  const StorageRuntimeEntry({required this.kind, required this.path});
  final String kind;
  final String path;
}

/// Writes the marker and a short lease. The lease expiry lets a crashed
/// process's directory become eligible later without scanning every temp folder.
Future<void> markOwnedTemporaryDirectory(
  Directory directory, {
  required String marker,
  Duration lease = const Duration(hours: 2),
}) async {
  await File(
    p.join(directory.path, StorageRuntimeRegistry.markerName),
  ).writeAsString(marker, flush: true);
  final until = DateTime.now().add(lease).millisecondsSinceEpoch;
  await File(
    p.join(directory.path, StorageRuntimeRegistry.leaseName),
  ).writeAsString('$until', flush: true);
}

bool ownedTemporaryMarker(Directory directory, String prefix) {
  final file = File(p.join(directory.path, StorageRuntimeRegistry.markerName));
  if (!file.existsSync()) return false;
  try {
    return file.readAsStringSync().startsWith(prefix);
  } catch (_) {
    return false;
  }
}

bool temporaryLeaseActive(Directory directory) {
  final file = File(p.join(directory.path, StorageRuntimeRegistry.leaseName));
  if (!file.existsSync()) return false;
  try {
    final until = int.tryParse(file.readAsStringSync().trim());
    return until != null && until > DateTime.now().millisecondsSinceEpoch;
  } catch (_) {
    return true;
  }
}
