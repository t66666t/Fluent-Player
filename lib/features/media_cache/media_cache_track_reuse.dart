import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../models/bilibili_models.dart';
import '../../models/bilibili_download_task.dart';
import '../../services/media_materialization_service.dart';
import 'media_cache_backend.dart';
import 'media_cache_hooks.dart';
import 'media_cache_models.dart';

/// Seed only an exact isolated track into the task's existing resume pipeline.
/// The source stays in place and leased until its local copy has been sealed.
Future<DownloadPartResumeState?> reuseCacheTrack({
  required CacheSource source,
  required StreamItem stream,
  required bool video,
  required Directory directory,
  required CancelToken cancel,
}) async {
  final acquire = MediaCacheHooks.acquireMaterial;
  if (acquire == null) return null;
  final lease = await acquire(
    source.toItem(),
    video
        ? MediaMaterializationRequirement.videoFrames
        : MediaMaterializationRequirement.audioOnly,
    qualityId: '${stream.id}',
    codec: stream.codecs,
    isolatedTrack: true,
  );
  if (lease == null) return null;
  try {
    // A muxed file is not a byte-for-byte copy of a DASH track.
    if (lease.completePath != null) return null;
    final path = video ? lease.videoPath : lease.audioPath;
    if (path == null) return null;
    cancel.throwIfCancellationRequested();
    final original = File(path);
    final bytes = await original.length();
    if (bytes <= 0) return null;
    await directory.create(recursive: true);
    final target = File(
      p.join(
        directory.path,
        'reused_${video ? 'video' : 'audio'}_${stream.id}_${cacheDigest(stream.codecs).substring(0, 12)}.m4s',
      ),
    );
    final staging = File('${target.path}.copying');
    try {
      await original.copy(staging.path);
      cancel.throwIfCancellationRequested();
      if (await staging.length() != bytes) {
        throw const FileSystemException('本地轨道复制不完整');
      }
      if (await target.exists()) await target.delete();
      await staging.rename(target.path);
      return DownloadPartResumeState(
        tempPath: target.path,
        downloadedBytes: bytes,
        totalBytes: bytes,
        streamId: stream.id,
        codecid: stream.codecid,
        codecs: stream.codecs,
        mimeType: stream.mimeType,
        supportsRange: true,
      );
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  } finally {
    await lease.release();
  }
}
