/// Podcast-only transport hints. The native adapter removes these before HTTP.
class PodcastPlaybackPolicy {
  static const streamHeader = 'x-fluent-player-podcast-stream';

  static Map<String, String> nativeOptions({required bool audioOnly}) => {
    'cache': 'yes',
    'cache-pause': 'yes',
    'cache-pause-initial': 'no',
    'cache-pause-wait': '0.15',
    'cache-secs': audioOnly ? '8' : '15',
    'demuxer-readahead-secs': audioOnly ? '4' : '10',
    'demuxer-max-bytes': '${(audioOnly ? 4 : 16) * 1024 * 1024}',
    'demuxer-max-back-bytes': '${(audioOnly ? 2 : 8) * 1024 * 1024}',
    'demuxer-lavf-analyzeduration': audioOnly ? '0.25' : '0.5',
    'demuxer-lavf-probesize': audioOnly ? '131072' : '262144',
    // Use Xing/VBRI/bitrate seeking rather than indexing all preceding MP3
    // frames. Containers with an exact index still use that index.
    if (audioOnly) 'demuxer-lavf-o': 'fflags=+fastseek',
    // Respect actual random-access capability reported by the gateway.
    'force-seekable': 'no',
  };
}
