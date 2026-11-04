import 'dart:io';

import '../../models/video_item.dart';
import '../../services/library_service.dart';
import '../media_cache/media_cache_service.dart';
import 'portable_media_selection.dart';
import 'sync_media_origin.dart';

/// Legacy name retained for export/sync callers. Only actual local files can
/// satisfy readiness; this helper never discovers or acquires online caches.
Future<List<VideoItem>> uncachedCloudExportItems(
  LibraryService library,
  Iterable<String> rootIds, {
  MediaCacheService? cache,
}) async {
  final inclusion = PortableMediaSelection(
    rootIds,
  ).resolveAgainstLibrary(library);
  final missing = <VideoItem>[];
  for (final id in inclusion.videoIds) {
    final item = library.getVideo(id);
    if (item == null) continue;
    final origin = await classifySyncMediaOrigin(path: item.path);
    // Android provider files need their existing local URI grant. The exporter
    // validates/streams that grant; no network cache can satisfy it.
    if (origin.placement == SyncMediaPlacement.localContentUri) continue;
    if (origin.placement == SyncMediaPlacement.localFile) {
      try {
        final stat = await File(origin.localPath!).stat();
        if (stat.type == FileSystemEntityType.file && stat.size > 0) continue;
      } on FileSystemException {
        // A removed or disconnected local file requires user relocation.
      }
    }
    missing.add(item);
  }
  return missing;
}
