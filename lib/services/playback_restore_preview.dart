import '../models/video_item.dart';
import 'library_service.dart';
import 'media_playback_service.dart';
import 'playlist_manager.dart';
import 'progress_tracker.dart';
import 'community_media_input.dart';

/// The local bookmark published before the home page's first frame. The native
/// player can restore it later, provided it is still the current local session.
class PlaybackRestorePreview {
  const PlaybackRestorePreview({
    required this.item,
    required this.snapshot,
    required this.generation,
    required this.queueRevision,
  });

  final VideoItem item;
  final PlaybackStateSnapshot snapshot;
  final int generation;
  final int queueRevision;

  bool isCurrent(MediaPlaybackService playback, PlaylistManager playlist) =>
      playback.sessionGeneration == generation &&
      playback.currentItem?.id == item.id &&
      playlist.revision == queueRevision;
}

/// Reads only persisted metadata. Never resolves a media URL, creates a player,
/// or copies a cover. The library must already be loaded so deleted cards are
/// not resurrected from an older snapshot.
Future<PlaybackRestorePreview?> restorePlaybackPreview({
  required MediaPlaybackService playback,
  required ProgressTracker progress,
  required PlaylistManager playlist,
  required LibraryService library,
}) async {
  final generation = playback.sessionGeneration;
  final queueEpoch = playlist.queueEpoch;
  // These independent local reads can overlap. A saved mixed queue must still
  // take precedence over an older source-specific playback snapshot.
  final snapshotFuture = progress.restorePlaybackState();
  await playlist.initializePlaybackModes();
  await playlist.ensureManualQueueLibraryEntries();
  final snapshot = await snapshotFuture;
  if (snapshot?.currentItemId == null ||
      playback.currentItem != null ||
      playback.sessionGeneration != generation ||
      playlist.queueEpoch != queueEpoch ||
      (playlist.hasManualQueue &&
          playlist.anchoredItemId != snapshot!.currentItemId)) {
    return null;
  }

  final item = library.getVideo(snapshot!.currentItemId!);
  if (item == null ||
      !communityMediaIsPlayable(item.path, source: item.sourceRef)) {
    return null;
  }
  final positionMs =
      item.lastPositionMs > 0 && item.lastUpdated > snapshot.timestamp
      ? item.lastPositionMs
      : snapshot.positionMs;
  playback.publishRestoredSessionPreview(
    item,
    Duration(milliseconds: positionMs),
  );
  return PlaybackRestorePreview(
    item: item,
    snapshot: snapshot,
    generation: playback.sessionGeneration,
    queueRevision: playlist.revision,
  );
}
