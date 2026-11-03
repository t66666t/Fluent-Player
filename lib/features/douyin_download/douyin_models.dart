/// Metadata captured from an official Douyin page. Unknown fields stay null.
class DouyinVideo {
  const DouyinVideo({
    required this.id,
    required this.title,
    this.author = '',
    this.coverUrl = '',
    this.duration = Duration.zero,
    this.variants = const [],
    this.createTime,
    this.likes,
    this.titleQuality = 2,
  });

  final String id;
  final String title;
  final String author;
  final String coverUrl;
  final Duration duration;
  final List<DouyinVideoVariant> variants;

  /// Unix time in seconds, as reported by Douyin.
  final int? createTime;
  final int? likes;
  final int titleQuality;

  Uri get shareUri => Uri.https('www.douyin.com', '/video/$id');
  DouyinVideoVariant? get bestVariant =>
      variants.isEmpty ? null : variants.first;

  DouyinVideo merge(DouyinVideo next) {
    if (next.id != id) return this;
    final merged = <String, DouyinVideoVariant>{
      for (final value in variants) value.id: value,
      for (final value in next.variants) value.id: value,
    }.values.toList()..sort(DouyinVideoVariant.compare);
    return DouyinVideo(
      id: id,
      title: next.titleQuality >= titleQuality ? next.title : title,
      titleQuality: next.titleQuality >= titleQuality
          ? next.titleQuality
          : titleQuality,
      author: next.author.isNotEmpty ? next.author : author,
      coverUrl: next.coverUrl.isNotEmpty ? next.coverUrl : coverUrl,
      duration: next.duration > Duration.zero ? next.duration : duration,
      variants: merged.take(30).toList(growable: false),
      createTime: next.createTime ?? createTime,
      likes: next.likes ?? likes,
    );
  }
}

class DouyinVideoVariant {
  const DouyinVideoVariant({
    required this.id,
    required this.url,
    this.backupUrls = const [],
    this.width,
    this.height,
    this.bitrate,
    this.fps,
    this.codec,
    this.sizeBytes,
    this.qualityLabel = '网页播放源',
    this.audioUrls = const [],
    this.hasAudio,
    this.isSeparateVideo = false,
  });

  final String id;
  final String url;
  final List<String> backupUrls;
  final int? width;
  final int? height;

  /// Bits per second; do not confuse with the downloader's bytes per second.
  final int? bitrate;
  final double? fps;
  final String? codec;
  final int? sizeBytes;
  final String qualityLabel;

  /// Only the matching work's own audio, never music.play_url/background music.
  final List<String> audioUrls;
  final bool? hasAudio;
  final bool isSeparateVideo;

  List<String> get allUrls => [url, ...backupUrls];
  List<String> get requestUrls => [...allUrls.take(6), ...audioUrls.take(6)];

  /// A progressive video may legitimately have no sound. Only a known split
  /// video representation needs its matching audio before it can be selected.
  bool get isCompleteSource => !isSeparateVideo || audioUrls.isNotEmpty;
  static int compare(DouyinVideoVariant a, DouyinVideoVariant b) {
    final complete = (b.isCompleteSource ? 1 : 0).compareTo(
      a.isCompleteSource ? 1 : 0,
    );
    if (complete != 0) return complete;
    final pixels = ((b.width ?? 0) * (b.height ?? 0)).compareTo(
      (a.width ?? 0) * (a.height ?? 0),
    );
    return pixels != 0 ? pixels : (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
  }

  String get resolutionLabel =>
      width != null && height != null ? '$width × $height' : '分辨率未知';
}
