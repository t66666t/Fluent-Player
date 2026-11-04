import '../cloud_drive/models/cloud_drive_models.dart';
import '../cloud_drive/providers/cloud_drive_provider.dart';

int? cloudCacheQualityHeight(String id, String label) {
  final match = RegExp(r'(\d{3,4})\s*[pP]').firstMatch('$id $label');
  if (match != null) return int.tryParse(match[1]!);
  final text = '$id $label'.toLowerCase();
  if (text.contains('8k')) return 4320;
  if (text.contains('4k')) return 2160;
  if (text.contains('2k')) return 1440;
  return switch (id.toLowerCase()) {
    'low' => 360,
    'normal' => 480,
    'high' => 720,
    'super' => 1080,
    _ => null,
  };
}

/// Original files outrank every transcode, regardless of their pixel count.
/// A download must not inherit playback's faster, lower-quality auto choice.
Future<CloudDrivePlaybackDescriptor> resolveCloudCacheQuality(
  CloudDriveProvider provider,
  CloudDrivePlaybackRequest request, {
  int? maxHeight,
  Object? cancelToken,
}) async {
  Future<CloudDrivePlaybackDescriptor> resolve(String id) async {
    final descriptor = await provider.resolvePlayback(
      CloudDrivePlaybackRequest(
        credential: request.credential,
        accountLocalId: request.accountLocalId,
        remoteAccountId: request.remoteAccountId,
        driveId: request.driveId,
        fileId: request.fileId,
        pathHint: request.pathHint,
        name: request.name,
        durationMs: request.durationMs,
        size: request.size,
        preferredQualityId: id,
        revision: request.revision,
        playbackSessionId: request.playbackSessionId,
      ),
      cancelToken: cancelToken,
    );
    if (descriptor.quality.id != id ||
        !descriptor.complete ||
        !descriptor.quality.selectable) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '来源没有返回所选画质的完整媒体',
      );
    }
    return descriptor;
  }

  final explicit = request.preferredQualityId;
  if (explicit != null) return resolve(explicit);
  CloudDriveFailure? originalFailure;
  if (maxHeight == null) {
    try {
      final original = await resolve('original');
      if (original.quality.id == 'original' &&
          original.complete &&
          original.quality.selectable) {
        return original;
      }
    } on CloudDriveFailure catch (error) {
      // Only a confirmed refusal may fall back. Network/login failures must
      // keep their recoverable state instead of silently lowering quality.
      if (!const {
        CloudDriveFailureKind.unavailable,
        CloudDriveFailureKind.unsupported,
        CloudDriveFailureKind.entitlement,
      }.contains(error.kind)) {
        rethrow;
      }
      originalFailure = error;
    }
  }
  final choices = await provider.discoverQualities(
    request,
    cancelToken: cancelToken,
  );
  final allowed =
      choices.where((q) {
        if (!q.selectable) return false;
        if (q.id == 'original' && originalFailure != null) return false;
        if (maxHeight == null) return true;
        final height = cloudCacheQualityHeight(q.id, q.label);
        return q.id != 'original' && height != null && height <= maxHeight;
      }).toList()..sort(
        (a, b) =>
            (b.id == 'original'
                    ? 100000
                    : cloudCacheQualityHeight(b.id, b.label) ?? 0)
                .compareTo(
                  a.id == 'original'
                      ? 100000
                      : cloudCacheQualityHeight(a.id, a.label) ?? 0,
                ),
      );
  if (allowed.isEmpty) {
    throw originalFailure ?? const FormatException('网盘没有符合分辨率上限的可用完整画质');
  }
  return resolve(allowed.first.id);
}
