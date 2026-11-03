import 'package:flutter/material.dart';
import '../../models/video_item.dart';
import 'podcast_models.dart';
import '../media_cache/media_cache_models.dart';

/// Installed after the library is ready; no second player or playback clock.
class PodcastPlaybackHooks {
  /// Recover legacy task sources from the podcast catalog without registering
  /// an entire playback queue in the media library.
  static VideoItem? Function(String path, String? itemId)? restoreSource;
  static Future<Uri> Function(VideoItem)? resolve;

  /// Mini's local bookmark can precede podcast initialization. An early play
  /// joins startup, then uses the real resolver installed by the runtime.
  /// Registering this hook performs no I/O and does not initialize a player.
  static void deferResolveUntil(Future<void> ready) {
    if (resolve != null) return;
    late final Future<Uri> Function(VideoItem) deferred;
    deferred = (item) async {
      await ready;
      final installed = resolve;
      if (installed == null || identical(installed, deferred)) {
        throw StateError('播客服务尚未就绪');
      }
      return installed(item);
    };
    resolve = deferred;
  }

  static void Function(VideoItem)? prepareSeek;
  static double Function(VideoItem)? speed;
  static bool Function(VideoItem)? speedOverridden;
  static Future<void> Function(VideoItem, double, bool)? setSpeedDefault;
  static bool Function(VideoItem)? continuous;
  static void Function(VideoItem)? completed;

  /// A null completion value saves a local bookmark without changing whether
  /// the episode has been heard. Remote checkpoints can explicitly set either
  /// completion value.
  static void Function(VideoItem, int, bool?, int?)? syncedProgress;
  static Future<String> Function(
    VideoItem, {
    bool Function()? isCancelled,
    Future<void>? cancelSignal,
    void Function(PodcastTransferProgress)? onProgress,
  })?
  materialize;
  static Future<String> Function(
    VideoItem, {
    bool Function()? isCancelled,
    Future<void>? cancelSignal,
    void Function(PodcastTransferProgress)? onProgress,
  })?
  materializeVideo;
  static Future<List<CacheVariant>> Function(VideoItem)? cachedVariants;
  static bool Function(String path)? isStoragePathInUse;
  static Future<void> Function(List<String> paths)? forgetDeletedStorage;
  static void Function(VideoItem)? releaseMaterialized;
  static String? Function(String path)? sourceIdentity;
  static Route<void> Function(VideoItem)? route;
  static Route<void> Function(VideoItem)? musicRoute;
}
