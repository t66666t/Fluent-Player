import 'dart:io';

import '../../models/video_item.dart';
import '../../services/library_service.dart';
import '../media_cache/media_cache_models.dart';
import '../media_cache/media_cache_service.dart';
import 'portable_media_selection.dart';
import 'sync_media_origin.dart';

/// Checks actual complete files, never queued downloads or isolated tracks.
/// The exporter must still acquire its own lease before reading the result.
Future<List<VideoItem>> uncachedCloudExportItems(
  LibraryService library,
  Iterable<String> rootIds, {
  MediaCacheService? cache,
}) async {
  final inclusion = PortableMediaSelection(
    rootIds,
  ).resolveAgainstLibrary(library);
  final missing = <VideoItem>[];
  final service = cache ?? MediaCacheService.instance;
  var initialized = false;
  for (final id in inclusion.videoIds) {
    final item = library.getVideo(id);
    if (item == null || item.sourceRef?.cloudDrive == null) continue;
    // A deliberately imported local download already carries the media bytes.
    // A transient playbackPath is not proof of a completed download.
    final origin = await classifySyncMediaOrigin(path: item.path);
    if (origin.placement == SyncMediaPlacement.localFile) {
      try {
        final stat = await File(origin.localPath!).stat();
        if (stat.type == FileSystemEntityType.file && stat.size > 0) continue;
      } on FileSystemException {
        // A removed or disconnected local file still gets the cache prompt.
      }
    }
    final source = CacheSource.fromItem(item);
    if (service == null || source == null) {
      missing.add(item);
      continue;
    }
    if (!initialized) {
      await service.initialize();
      initialized = true;
    }
    await service.discoverMaterial(source);
    await service.refreshAvailability(mediaKey: source.key);
    if (service.completeExportVariant(item) == null) missing.add(item);
  }
  return missing;
}
