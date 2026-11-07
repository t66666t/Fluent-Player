import '../../models/library_activity.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import '../../services/community_media_input.dart';
import '../../services/library_service.dart';

/// Old downloader receipts remain useful evidence even though this edition no
/// longer offers those downloaders. This never changes the saved local file.
bool omitLegacyWebDownload(VideoItem item, LibraryService library) {
  if (!communityMediaIsLocal(item.path)) return false;
  final source = item.sourceRef;
  if (source?.podcast != null ||
      source?.kind == MediaSourceKind.podcastEpisode ||
      source?.cloudDrive != null ||
      source?.kind == MediaSourceKind.cloudDrive) {
    return false;
  }

  final context = library.mediaActivity(item.id)?.downloadImport;
  final origins = library.importBatches
      .where(
        (batch) =>
            batch.id == context?.batchId ||
            batch.createdMediaIds.contains(item.id) ||
            batch.downloadReceipts.containsValue(item.id),
      )
      .map((batch) => batch.sourceKind)
      .toSet();
  if (origins.contains(LibraryImportSourceKind.ytDlp)) return true;
  if (context != null &&
      origins.contains(LibraryImportSourceKind.localFile) &&
      !origins.contains(LibraryImportSourceKind.bilibili)) {
    return true;
  }

  // A generic web source on an older local card identifies a web download.
  // Explicit Bilibili history retains its existing local export behavior.
  if (source?.kind != MediaSourceKind.url ||
      item.isBilibiliExported ||
      item.bilibiliDownloadPath != null ||
      source?.bvid != null ||
      source?.aid != null ||
      source?.cid != null ||
      origins.contains(LibraryImportSourceKind.bilibili)) {
    return false;
  }
  return [source!.value, source.originalValue].whereType<String>().any((value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  });
}
