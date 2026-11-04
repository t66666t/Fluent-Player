import 'podcast_models.dart';

const podcastRssSourceMessage =
    '该节目尚未确认来自发布者 RSS。请刷新频道或导入发布者提供的 RSS；已有本地文件和收听进度会保留。';

/// Playback and offline tasks may only request enclosures supplied by a feed.
/// This is source evidence, not a grant to redistribute or export the audio.
bool podcastHasRssMedia(PodcastEpisode episode, PodcastMedia media) {
  final feed = Uri.tryParse(episode.sourceFeedUrl);
  final enclosure = Uri.tryParse(media.url);
  bool web(Uri? uri) =>
      uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
  if (!web(feed) || !web(enclosure)) return false;
  // Official video pages/player URLs never become podcast material simply
  // because they were written into an enclosure or an imported backup.
  for (final uri in [feed!, enclosure!]) {
    final host = uri.host.toLowerCase();
    if (const [
      'youtube.com',
      'youtube-nocookie.com',
      'googlevideo.com',
      'youtu.be',
      'bilibili.com',
      'bilivideo.com',
      'bilivideo.cn',
      'b23.tv',
    ].any((domain) => host == domain || host.endsWith('.$domain'))) {
      return false;
    }
  }
  return episode.media.any((candidate) => candidate.url == media.url);
}

void requirePodcastRssMedia(PodcastEpisode episode, PodcastMedia media) {
  if (!podcastHasRssMedia(episode, media)) {
    throw const FormatException(podcastRssSourceMessage);
  }
}
