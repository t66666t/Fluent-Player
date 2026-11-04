import 'package:flutter/material.dart';

import '../../models/media_artwork_ref.dart';
import '../../models/video_item.dart';
import '../../services/media_artwork_repository.dart';
import '../../widgets/cached_thumbnail_widget.dart';
import '../../widgets/media_artwork_view.dart';
import 'podcast_runtime.dart';

/// Queue entries may have no local thumbnail yet. Resolve their source art
/// through the same repository as the channel and episode pages, without
/// downloading another file for each lightweight playback projection.
class PodcastQueueArtwork extends StatelessWidget {
  const PodcastQueueArtwork({
    super.key,
    required this.item,
    required this.size,
    required this.placeholder,
  });

  final VideoItem item;
  final double size;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    final runtime = PodcastRuntime.instance;
    // Catalog reloads change the image URL. Download byte ticks do not notify
    // this runtime, so a visible row is not rebuilt for every progress event.
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) {
        final local = item.thumbnailPath?.isNotEmpty == true
            ? CachedThumbnailWidget(
                videoId: item.id,
                thumbnailPath: item.thumbnailPath,
                fit: BoxFit.cover,
                cacheWidth: artworkSizeBucket(
                  size,
                  MediaQuery.devicePixelRatioOf(context),
                ),
                placeholder: placeholder,
                errorWidget: placeholder,
              )
            : placeholder;
        final source = item.sourceRef?.podcast;
        final repository = MediaArtworkRepository.active;
        if (source == null || !runtime.ready || repository == null) {
          return local;
        }
        final episode = runtime.store.episode(source.episodeId);
        final channel = runtime.store.channel(
          episode?.channelId ?? source.channelId,
        );
        final episodeImage = episode?.imageUrl.trim() ?? '';
        final channelImage = channel?.imageUrl.trim() ?? '';
        final reference = podcastArtworkRef(
          ownerKind: 'episode',
          ownerId: source.episodeId,
          primaryUrl: episodeImage.isNotEmpty ? episodeImage : channelImage,
          fallbackUrl: episodeImage.isNotEmpty ? channelImage : '',
        );
        if (reference.chain.isEmpty) return local;
        return MediaArtworkView(
          key: ValueKey((
            repository,
            source.episodeId,
            reference.chain.map((request) => request.requestKey).join('|'),
          )),
          reference: reference,
          size: size,
          priority: ArtworkPriority.visible,
          fit: BoxFit.cover,
          placeholder: local,
        );
      },
    );
  }
}
