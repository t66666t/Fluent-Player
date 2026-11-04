class PodcastChannelRef {
  const PodcastChannelRef({required this.channelId, required this.feedUrl});
  final String channelId;
  final String feedUrl;
  Map<String, dynamic> toJson() => {'channelId': channelId, 'feedUrl': feedUrl};
  static PodcastChannelRef? fromJsonOrNull(Object? value) {
    if (value is! Map ||
        value['channelId'] is! String ||
        value['feedUrl'] is! String) {
      return null;
    }
    return PodcastChannelRef(
      channelId: value['channelId'] as String,
      feedUrl: value['feedUrl'] as String,
    );
  }
}

class PodcastEpisodeRef {
  const PodcastEpisodeRef({
    required this.channelId,
    required this.episodeId,
    required this.feedUrl,
    required this.mediaUrl,
  });
  final String channelId, episodeId, feedUrl, mediaUrl;
  Map<String, dynamic> toJson() => {
    'channelId': channelId,
    'episodeId': episodeId,
    'feedUrl': feedUrl,
    'mediaUrl': mediaUrl,
  };
  static PodcastEpisodeRef? fromJsonOrNull(Object? value) {
    if (value is! Map ||
        [
          'channelId',
          'episodeId',
          'feedUrl',
          'mediaUrl',
        ].any((key) => value[key] is! String)) {
      return null;
    }
    return PodcastEpisodeRef(
      channelId: value['channelId'],
      episodeId: value['episodeId'],
      feedUrl: value['feedUrl'],
      mediaUrl: value['mediaUrl'],
    );
  }
}
