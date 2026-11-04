import '../../models/video_collection.dart';
import '../../models/video_item.dart';

/// Only descriptive fields cross the provider boundary. Provider URLs, account
/// identifiers and playback credentials must never be serialized by MCP.
class ExternalAiItemDetails {
  const ExternalAiItemDetails({
    this.originalTitle,
    String? description,
    this.descriptionReader,
    this.author,
    this.publishedMs,
    this.channelTitle,
    this.season,
    this.episodeNumber,
    this.listenBucket,
    this.played,
    this.favorite,
    this.positionMs,
    this.episodeCounts,
  }) : _description = description;
  final String? originalTitle, author, channelTitle;
  final String? _description;
  final String Function()? descriptionReader;
  String? get description => descriptionReader?.call() ?? _description;
  final int? publishedMs, season, episodeNumber;
  final String? listenBucket;
  final bool? played, favorite;
  final int? positionMs;
  final Map<String, int>? episodeCounts;
}

class ExternalAiCatalogRequest {
  const ExternalAiCatalogRequest({
    required this.tool,
    required this.arguments,
    required this.folders,
    required this.media,
    this.playback = const ExternalAiPlaybackSnapshot(),
  });
  final String tool;
  final Map<String, dynamic> arguments;
  final List<VideoCollection> folders;
  final List<VideoItem> media;
  final ExternalAiPlaybackSnapshot playback;
}

class ExternalAiCatalogSnapshot {
  const ExternalAiCatalogSnapshot({
    this.media = const [],
    this.children = const {},
    this.details = const {},
    this.excludedMediaIds = const {},
    this.status = const {},
  });
  final List<VideoItem> media;
  final Map<String, List<String>> children;
  final Map<String, ExternalAiItemDetails> details;
  final Set<String> excludedMediaIds;
  final Map<String, String> status;
}

class ExternalAiPlaybackSnapshot {
  const ExternalAiPlaybackSnapshot({
    this.current,
    this.preview,
    this.queue = const [],
    this.state = 'idle',
    this.isPlaying = false,
    this.transportPlaying = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.queueRevision = 0,
    this.mode = 'sequential',
  });
  final VideoItem? current, preview;

  /// Exactly the order shown by the mini player's playlist, including shuffle.
  final List<VideoItem> queue;
  final String state, mode;
  final bool isPlaying, transportPlaying;
  final int positionMs, durationMs, queueRevision;
}
