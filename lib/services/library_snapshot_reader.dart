import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/library_activity.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import 'app_storage_service.dart';

/// Parsed data only. Applying migrations, recovering backups and publishing
/// library state remain the foreground service's responsibility.
class LoadedLibrarySnapshot {
  const LoadedLibrarySnapshot({
    required this.collections,
    required this.videos,
    required this.rootChildrenIds,
    required this.activity,
    required this.recycleBin,
    required this.schemaVersion,
  });

  final Map<String, VideoCollection>? collections;
  final Map<String, VideoItem>? videos;
  final List<String>? rootChildrenIds;
  final LibraryActivityParseResult activity;
  final List<VideoCollection>? recycleBin;
  final int schemaVersion;
}

/// Passing a path avoids copying a large JSON string into the worker. The
/// snapshot contains path metadata, never a live service or plugin callback.
Future<LoadedLibrarySnapshot> readLibrarySnapshot(
  String path, {
  required StoragePathEncodingSnapshot pathEncoding,
  required int maximumSchemaVersion,
}) => compute(_readLibrarySnapshot, (
  path,
  pathEncoding,
  maximumSchemaVersion,
), debugLabel: 'library-snapshot-read');

Future<LoadedLibrarySnapshot> _readLibrarySnapshot(
  (String, StoragePathEncodingSnapshot, int) request,
) async {
  final raw = await File(request.$1).readAsString();
  if (raw.isEmpty) throw const FormatException('Empty JSON file');
  final data = jsonDecode(raw);
  if (data is! Map || (data['schemaVersion'] as int? ?? 0) > request.$3) {
    throw const StorageUnavailableException('媒体库格式来自更新版本，请使用对应版本打开；原数据已保留');
  }

  // Let parsed JSON rows die as their models are built. Keeping every raw row
  // alive until the final map is returned increases peak memory and worker GC.
  final collections = data.remove('collections') as List?;
  final videos = data.remove('videos') as List?;
  final recycleBin = data.remove('recycleBin') as List?;
  request.$2.decodeOwnedJsonPaths(data);

  return LoadedLibrarySnapshot(
    collections: collections == null
        ? null
        : {
            for (final collection in _parseModels(
              collections,
              request.$2,
              VideoCollection.fromJson,
            ))
              collection.id: collection,
          },
    videos: videos == null
        ? null
        : {
            for (final item in _parseModels(
              videos,
              request.$2,
              VideoItem.fromJson,
            ))
              item.id: item,
          },
    rootChildrenIds: (data['rootChildrenIds'] as List?)
        ?.map((id) => id.toString())
        .toList(),
    activity: LibraryActivityStore.parse(
      data[LibraryActivityStore.snapshotKey],
    ),
    recycleBin: recycleBin == null
        ? null
        : _parseModels(
            recycleBin,
            request.$2,
            VideoCollection.fromJson,
          ).toList(),
    schemaVersion: data['schemaVersion'] as int? ?? 0,
  );
}

Iterable<T> _parseModels<T>(
  List rows,
  StoragePathEncodingSnapshot paths,
  T Function(Map<String, dynamic>) parse,
) sync* {
  const batchSize = 256;
  for (var start = 0; start < rows.length; start += batchSize) {
    final end = (start + batchSize).clamp(0, rows.length);
    final batch = rows.sublist(start, end);
    paths.decodeOwnedJsonPaths(batch);
    for (var i = 0; i < batch.length; i++) {
      final model = parse(batch[i] as Map<String, dynamic>);
      rows[start + i] = null;
      batch[i] = null;
      yield model;
    }
  }
}
