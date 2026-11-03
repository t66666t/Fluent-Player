import '../../models/video_item.dart';
import '../../services/media_materialization_service.dart';
import '../cloud_drive/services/cloud_drive_playback_service.dart';
import 'media_cache_models.dart';

/// Optional hooks keep playback independent of queue initialization and permit
/// existing player tests to run without constructing a download service.
abstract final class MediaCacheHooks {
  static Future<MaterializedMediaLease?> Function(
    VideoItem item, {
    String? qualityId,
  })?
  acquire;
  static Future<CloudDrivePreparedPlayback?> Function(
    VideoItem item, {
    String? qualityId,
  })?
  openCloud;
  static List<CacheQuality> Function(VideoItem item)? qualities;

  /// Producers publish only sealed originals, never derived OCR/ASR outputs.
  static Future<void> Function(List<CacheVariant> variants)? publish;
  static Future<List<CacheVariant>> Function(CacheSource source)? discover;
  static bool Function(String path)? pathInUse;
  static Future<MaterializedMediaLease?> Function(
    VideoItem item,
    MediaMaterializationRequirement requirement, {
    int? targetHeight,
    String? qualityId,
    String? codec,
    bool isolatedTrack,
  })?
  acquireMaterial;
}
