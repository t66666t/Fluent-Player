import 'media_artwork_ref.dart';

/// What a shared card or row needs to draw one library entry.
///
/// This is not a [VideoItem]. Browsing a large podcast channel must not insert
/// a media-library record for every episode.
class MediaLibraryEntryPresentation {
  const MediaLibraryEntryPresentation({
    required this.stableId,
    required this.entryKind,
    required this.title,
    this.subtitle = '',
    this.artwork,
    this.durationMs,
    this.progress,
    this.badges = const [],
    this.selected = false,
  });

  final String stableId;
  final String entryKind;
  final String title;
  final String subtitle;
  final ArtworkRef? artwork;
  final int? durationMs;
  final double? progress;
  final List<String> badges;
  final bool selected;
}
