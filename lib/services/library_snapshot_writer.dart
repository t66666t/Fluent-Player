import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/library_activity.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import 'app_storage_service.dart';

/// compute copies these models before the worker starts, so mutations made
/// during a disk write belong to the next queued save.
class LibrarySnapshot {
  const LibrarySnapshot({
    required this.directory,
    required this.schemaVersion,
    required this.collections,
    required this.videos,
    required this.rootChildrenIds,
    required this.activity,
    required this.pathEncoding,
    this.preservedActivity,
  });

  final String directory;
  final int schemaVersion;
  final List<VideoCollection> collections;
  final List<VideoItem> videos;
  final List<String> rootChildrenIds;
  final LibraryActivityStore activity;
  final StoragePathEncodingSnapshot pathEncoding;
  final Object? preservedActivity;

  Object _activitySnapshot() {
    if (preservedActivity != null) return preservedActivity!;
    final snapshot = activity.toJson();
    final watchOnlyIds = <String>{
      for (final item in videos)
        if (item.isTransient) item.id,
    };
    if (watchOnlyIds.isEmpty) return snapshot;
    snapshot['media'] = <Object?>[
      for (final record in snapshot['media'] as List<dynamic>)
        if (record is! Map || !watchOnlyIds.contains(record['id'])) record,
    ];
    return snapshot;
  }
}

/// Serialization, path mapping and backup validation can all take longer than
/// a frame for a large library. Keep the entire write off the UI isolate.
Future<void> writeLibrarySnapshot(LibrarySnapshot snapshot) =>
    compute(_writeLibrarySnapshot, snapshot);

Future<void> _writeLibrarySnapshot(LibrarySnapshot snapshot) async {
  final file = File(p.join(snapshot.directory, 'library.json'));
  final tempFile = File('${file.path}.tmp');
  final backupFile = File('${file.path}.bak');
  final data = {
    'collections': snapshot.collections.map((e) => e.toJson()).toList(),
    'videos': snapshot.videos
        .where((e) => !e.isTransient)
        .map((e) => e.toJson())
        .toList(),
    'rootChildrenIds': snapshot.rootChildrenIds,
    'schemaVersion': snapshot.schemaVersion,
    LibraryActivityStore.snapshotKey: snapshot._activitySnapshot(),
  };

  await tempFile.writeAsString(
    jsonEncode(snapshot.pathEncoding.encodePaths(data)),
    flush: true,
  );

  if (await file.exists()) {
    try {
      jsonDecode(await file.readAsString());
      await file.copy(backupFile.path);
    } on FormatException {
      /* preserve the last readable backup */
    }
  }

  // Windows rename-overwrite is unreliable. Retain the existing fallback and
  // the previous complete generation if the replacement fails.
  try {
    if (await file.exists()) await file.delete();
    await tempFile.rename(file.path);
  } catch (_) {
    await tempFile.copy(file.path);
    await tempFile.delete();
  }
}
