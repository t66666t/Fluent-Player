import '../models/youtube_download_models.dart';

/// Shared video-format selection policy used by metadata recommendations,
/// task defaults, and the final request fallback.
class YtDlpVideoFormatSelector {
  const YtDlpVideoFormatSelector._();

  static String? pickFormatId(
    Iterable<VideoFormat> formats, {
    String preferredQuality = 'best',
  }) {
    final candidates = formats
        .where((format) => format.formatId.trim().isNotEmpty)
        .toList();
    if (candidates.isEmpty) return null;

    final targetHeight = _targetHeight(preferredQuality);
    final qualityPool = targetHeight == null
        ? _bestCompatiblePool(candidates)
        : _closestQualityPool(candidates, targetHeight);
    qualityPool.sort(_compareWithinQuality);
    return qualityPool.first.formatId;
  }

  static List<VideoFormat> sortForDisplay(Iterable<VideoFormat> formats) {
    final sorted = formats.toList();
    sorted.sort((a, b) {
      final height = (b.height ?? -1).compareTo(a.height ?? -1);
      if (height != 0) return height;

      final width = (b.width ?? -1).compareTo(a.width ?? -1);
      if (width != 0) return width;

      final audio = (b.hasAudio ? 1 : 0).compareTo(a.hasAudio ? 1 : 0);
      if (audio != 0) return audio;

      final bitrate = (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
      if (bitrate != 0) return bitrate;

      final fps = (b.fps ?? 0).compareTo(a.fps ?? 0);
      if (fps != 0) return fps;

      final compatibility = _broadCompatibilityRank(
        b,
      ).compareTo(_broadCompatibilityRank(a));
      if (compatibility != 0) return compatibility;

      final container = _containerRank(b).compareTo(_containerRank(a));
      if (container != 0) return container;

      final codec = _codecRank(b).compareTo(_codecRank(a));
      if (codec != 0) return codec;
      return a.formatId.compareTo(b.formatId);
    });
    return sorted;
  }

  static List<VideoFormat> _bestCompatiblePool(List<VideoFormat> candidates) {
    final broadlyCompatible = candidates
        .where((format) => _broadCompatibilityRank(format) > 0)
        .toList();
    final bestOverallHeight = _maxKnownHeight(candidates);
    final bestCompatibleHeight = _maxKnownHeight(broadlyCompatible);
    // Prefer broad compatibility unless it would discard more than one third
    // of the available vertical resolution.
    final compatibilityKeepsReasonableQuality =
        bestCompatibleHeight != null &&
        (bestOverallHeight == null ||
            bestCompatibleHeight * 3 >= bestOverallHeight * 2);
    final pool = compatibilityKeepsReasonableQuality
        ? broadlyCompatible
        : List<VideoFormat>.from(candidates);
    final knownHeights = pool
        .map((format) => format.height)
        .whereType<int>()
        .where((height) => height > 0)
        .toList();
    if (knownHeights.isEmpty) return pool;
    final bestHeight = knownHeights.reduce((a, b) => a > b ? a : b);
    return pool.where((format) => format.height == bestHeight).toList();
  }

  static int? _maxKnownHeight(Iterable<VideoFormat> formats) {
    final heights = formats
        .map((format) => format.height)
        .whereType<int>()
        .where((height) => height > 0)
        .toList();
    if (heights.isEmpty) return null;
    return heights.reduce((a, b) => a > b ? a : b);
  }

  static List<VideoFormat> _closestQualityPool(
    List<VideoFormat> candidates,
    int targetHeight,
  ) {
    final known = candidates
        .where((format) => (format.height ?? 0) > 0)
        .toList();
    if (known.isEmpty) return List<VideoFormat>.from(candidates);

    final exact = known
        .where((format) => format.height == targetHeight)
        .toList();
    if (exact.isNotEmpty) return exact;

    final below = known
        .where((format) => format.height! < targetHeight)
        .toList();
    if (below.isNotEmpty) {
      final closestBelow = below
          .map((format) => format.height!)
          .reduce((a, b) => a > b ? a : b);
      return below.where((format) => format.height == closestBelow).toList();
    }

    final closestAbove = known
        .map((format) => format.height!)
        .reduce((a, b) => a < b ? a : b);
    return known.where((format) => format.height == closestAbove).toList();
  }

  /// X/Twitter `http-*` variants are one progressive MP4. yt-dlp leaves
  /// `acodec` empty, but the file already contains AAC. Pairing them with
  /// `hls-audio-*` re-downloads that sound as hundreds or thousands of tiny
  /// HLS fragments.
  static bool isTwitterProgressiveVideo(VideoFormat? video, {String? source}) {
    final normalizedSource = (source ?? '').trim().toLowerCase();
    if (video == null || !normalizedSource.startsWith('twitter')) {
      return false;
    }
    final formatId = video.formatId.trim().toLowerCase();
    final ext = video.ext.trim().toLowerCase();
    if (ext == 'm3u8' ||
        formatId.startsWith('hls') ||
        formatId.contains('dash')) {
      return false;
    }
    return formatId == 'http' || formatId.startsWith('http-');
  }

  /// Adaptive streams such as HLS often advertise an audio codec while the
  /// selected rendition itself is video-only. Those need a separate audio merge.
  /// A progressive file that already contains audio does not.
  static bool needsSeparateAudioTrack(VideoFormat? video, {String? source}) {
    if (isTwitterProgressiveVideo(video, source: source)) {
      return false;
    }
    if (video == null || !video.hasAudio) {
      return true;
    }
    final codec = (video.audioCodec ?? '').trim().toLowerCase();
    if (codec.isEmpty || codec == 'none') {
      return true;
    }
    final ext = video.ext.trim().toLowerCase();
    final formatId = video.formatId.trim().toLowerCase();
    return ext == 'm3u8' ||
        formatId.startsWith('hls') ||
        formatId.contains('dash');
  }

  /// A requested audio merge must fail if unavailable. Falling back to the
  /// video alone silently produces a successful download with no sound.
  static String downloadFormatSelector({
    required String videoId,
    required String? audioId,
    required bool mergeAudio,
  }) {
    if (!mergeAudio || audioId == null || audioId.isEmpty) {
      return videoId;
    }
    final merged = '$videoId+$audioId';
    if (videoId.contains('/') ||
        audioId.contains('/') ||
        videoId.contains('+') ||
        audioId.contains('+')) {
      return merged;
    }
    return merged;
  }

  /// Android staged post-process (no yt-dlp ffmpeg CLI): never request a
  /// `video+audio` merge. Download a progressive stream when it already has
  /// audio, otherwise download video and audio as **separate** files
  /// (`id,id`) so FFmpegKit can mux them in finalize.
  static String androidStagedFormatSelector({
    required String? videoId,
    required String? audioId,
    required bool audioOnly,
    required bool removeAudio,
    required bool videoHasEmbeddedAudio,
  }) {
    if (audioOnly) {
      final id = audioId?.trim();
      return (id != null && id.isNotEmpty) ? id : 'bestaudio';
    }
    final resolvedVideo = videoId?.trim();
    if (removeAudio) {
      return (resolvedVideo != null && resolvedVideo.isNotEmpty)
          ? resolvedVideo
          : 'bestvideo/best';
    }
    if (resolvedVideo == null || resolvedVideo.isEmpty) {
      return 'best[acodec!=none]/best';
    }
    if (videoHasEmbeddedAudio) {
      return resolvedVideo;
    }
    final resolvedAudio = audioId?.trim();
    final audioSpec = (resolvedAudio != null && resolvedAudio.isNotEmpty)
        ? resolvedAudio
        : 'bestaudio';
    return '$resolvedVideo,$audioSpec';
  }

  static int _compareWithinQuality(VideoFormat a, VideoFormat b) {
    final compatibility = _broadCompatibilityRank(
      b,
    ).compareTo(_broadCompatibilityRank(a));
    if (compatibility != 0) return compatibility;

    final audio = (b.hasAudio ? 1 : 0).compareTo(a.hasAudio ? 1 : 0);
    if (audio != 0) return audio;

    final container = _containerRank(b).compareTo(_containerRank(a));
    if (container != 0) return container;

    final codec = _codecRank(b).compareTo(_codecRank(a));
    if (codec != 0) return codec;

    final fps = (b.fps ?? 0).compareTo(a.fps ?? 0);
    if (fps != 0) return fps;

    final bitrate = (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
    if (bitrate != 0) return bitrate;
    return a.formatId.compareTo(b.formatId);
  }

  static int _broadCompatibilityRank(VideoFormat format) {
    final ext = format.ext.trim().toLowerCase();
    final codec = (format.videoCodec ?? '').trim().toLowerCase();
    final isMp4 =
        ext == 'mp4' ||
        (format.container ?? '').trim().toLowerCase().contains('mp4');
    final isH264 = codec.contains('avc') || codec.contains('h264');
    return isMp4 && isH264 ? 1 : 0;
  }

  static int _containerRank(VideoFormat format) {
    switch (format.ext.trim().toLowerCase()) {
      case 'mp4':
        return 3;
      case 'webm':
        return 2;
      case 'mkv':
        return 1;
      default:
        return 0;
    }
  }

  static int _codecRank(VideoFormat format) {
    final codec = (format.videoCodec ?? '').trim().toLowerCase();
    if (codec.contains('avc') || codec.contains('h264')) return 5;
    if (codec.contains('hevc') ||
        codec.contains('h265') ||
        codec.contains('hev1') ||
        codec.contains('hvc1')) {
      return 4;
    }
    if (codec.contains('vp9')) return 3;
    if (codec.contains('av01') || codec.contains('av1')) return 2;
    return 1;
  }

  static int? _targetHeight(String rawPreference) {
    switch (rawPreference.trim().toLowerCase()) {
      case '2160p':
        return 2160;
      case '1440p':
        return 1440;
      case '1080p':
        return 1080;
      case '720p':
        return 720;
      case '480p':
        return 480;
      case '360p':
        return 360;
      default:
        return null;
    }
  }
}
