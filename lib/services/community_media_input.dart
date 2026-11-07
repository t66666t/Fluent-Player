import '../models/media_source_ref.dart';

/// Low-level file consumers accept local media only. Podcast identities pass
/// through a separate guard and the RSS runtime before becoming local files.
void requireCommunityLocalMedia(String path) {
  final value = path.trim();
  if (value.isEmpty) throw const FormatException('请选择本地媒体文件');
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return;
  final uri = Uri.tryParse(value);
  if (uri?.scheme == 'file' && (uri!.host.isEmpty || uri.host == 'localhost')) {
    return;
  }
  if (value.contains('://') || (uri != null && uri.scheme.isNotEmpty)) {
    throw UnsupportedError('社区版支持本地文件与 RSS 播客；其他远程媒体已停用');
  }
}

bool communityMediaIsLocal(String path) {
  try {
    requireCommunityLocalMedia(path);
    return true;
  } on FormatException {
    return false;
  } on UnsupportedError {
    return false;
  }
}

/// Converts a local file URI before passing it to a filesystem or player API.
String communityLocalMediaPath(String path) {
  requireCommunityLocalMedia(path);
  final value = path.trim();
  final uri = Uri.tryParse(value);
  return uri?.scheme == 'file' ? uri!.toFilePath() : value;
}

/// This validates a podcast identity, not its enclosure provenance. The podcast
/// runtime additionally checks the episode against its parsed RSS catalog before
/// requesting media. Raw URLs never become a general remote-input exception.
bool communityMediaIsPodcast(String path, {MediaSourceRef? source}) {
  final ref = source?.podcast;
  if (source?.kind != MediaSourceKind.podcastEpisode ||
      ref == null ||
      ref.channelId.isEmpty ||
      ref.episodeId.isEmpty ||
      path != 'podcast:${ref.episodeId}') {
    return false;
  }
  for (final address in [ref.feedUrl, ref.mediaUrl]) {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
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
  return true;
}

bool communityMediaIsPlayable(String path, {MediaSourceRef? source}) =>
    communityMediaIsLocal(path) ||
    communityMediaIsPodcast(path, source: source);

void requireCommunityPlaybackSource(String path, {MediaSourceRef? source}) {
  if (communityMediaIsPodcast(path, source: source)) return;
  requireCommunityLocalMedia(path);
}

/// Podcast references may enter preparation, which must resolve them through
/// the RSS runtime. Decoders and upload clients still require an actual file.
void requireCommunityProcessingSource(String path, {MediaSourceRef? source}) {
  requireCommunityPlaybackSource(path, source: source);
}

/// Cookie/client endpoints are not an authorized cloud-drive API integration.
void requireCommunityAuthorizedCloudDrive() {
  throw UnsupportedError('开源版仅支持本地媒体，网盘浏览、播放和下载已停用');
}

/// The compatibility API cannot reactivate platform media playback.
void requireCommunityOfficialBilibili() {
  throw UnsupportedError('开源版仅支持本地媒体，哔哩哔哩在线播放和媒体提取已停用');
}
