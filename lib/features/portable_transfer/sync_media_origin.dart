import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/media_source_ref.dart';

/// Where the bytes for one library card actually live.
///
/// Source metadata (Bilibili, cloud drive) never decides this by itself.
/// A downloaded file stays a local file even when the card remembers its origin.
enum SyncMediaPlacement {
  localFile,
  localContentUri,
  onlineReference,
  unavailable,
}

class SyncMediaOrigin {
  const SyncMediaOrigin({required this.placement, this.localPath, this.reason});

  final SyncMediaPlacement placement;

  /// Absolute path when [placement] is [SyncMediaPlacement.localFile].
  final String? localPath;

  /// Why a required local file could not be packaged. Empty for online cards.
  final String? reason;
}

bool _remoteLocator(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('bilibili://') ||
      lower.startsWith('podcast:') ||
      lower.startsWith('cloud-drive://') ||
      lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('content://');
}

String? _fileUriPath(String raw) {
  try {
    return p.normalize(Uri.parse(raw).toFilePath());
  } catch (_) {
    return null;
  }
}

/// Classifies a card from its playback locator, not from the origin label.
///
/// [playbackPath] is checked first so a downloaded file is not treated as the
/// remote stream URI still stored in [path]. `content://` is reported as its
/// own placement: callers must stream it or record an explicit failure.
Future<SyncMediaOrigin> classifySyncMediaOrigin({
  required String path,
  String? playbackPath,
  MediaSourceKind? sourceKind,
}) async {
  final candidates = <String>[
    if (playbackPath != null && playbackPath.trim().isNotEmpty)
      playbackPath.trim(),
    path.trim(),
  ];
  for (final raw in candidates) {
    if (raw.toLowerCase().startsWith('content://')) {
      return const SyncMediaOrigin(
        placement: SyncMediaPlacement.localContentUri,
        reason: 'content-uri',
      );
    }
    final String? local;
    if (raw.toLowerCase().startsWith('file://')) {
      local = _fileUriPath(raw);
    } else if (!_remoteLocator(raw)) {
      local = p.normalize(raw);
    } else {
      local = null;
    }
    if (local == null) continue;
    if (await File(local).exists()) {
      return SyncMediaOrigin(
        placement: SyncMediaPlacement.localFile,
        localPath: local,
      );
    }
  }

  final remoteCard =
      (sourceKind == MediaSourceKind.podcastEpisode && path.startsWith('podcast:')) ||
      path.startsWith('bilibili://stream/') ||
      path.startsWith('cloud-drive://') ||
      (sourceKind == MediaSourceKind.bilibiliStream &&
          (path.startsWith('bilibili://') ||
              path.startsWith('http://') ||
              path.startsWith('https://'))) ||
      (sourceKind == MediaSourceKind.cloudDrive && path.contains('://'));
  if (remoteCard) {
    return const SyncMediaOrigin(
      placement: SyncMediaPlacement.onlineReference,
    );
  }
  return const SyncMediaOrigin(
    placement: SyncMediaPlacement.unavailable,
    reason: 'missing-file',
  );
}
