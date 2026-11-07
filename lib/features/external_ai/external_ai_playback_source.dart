import '../../services/media_playback_service.dart';
import 'external_ai_context.dart';

/// Reads the live session. It does not mount a playback page, restore a queue,
/// change the current selection or initialize a native controller.
ExternalAiPlaybackSnapshot externalAiPlaybackSnapshot(
  MediaPlaybackService service,
) => ExternalAiPlaybackSnapshot(
  current: service.currentItem,
  preview: service.currentItem == null ? service.queuedPreviewItem : null,
  queue: List.unmodifiable(service.playlistManager?.playbackQueue ?? const []),
  state: service.state.name,
  isPlaying: service.isPlaying,
  transportPlaying: service.isTransportPlaying,
  positionMs: service.position.inMilliseconds,
  durationMs: service.duration.inMilliseconds,
  queueRevision: service.playlistManager?.snapshot.revision ?? 0,
  mode: service.playbackMode.name,
);
