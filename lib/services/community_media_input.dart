import '../models/media_source_ref.dart';

/// Playback and processing accept local media only. Historical provenance is
/// metadata and never authorizes acquiring a remote media source.
void requireCommunityLocalMedia(String path) {
  final value = path.trim();
  if (value.isEmpty) throw const FormatException('请选择本地媒体文件');
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return;
  final uri = Uri.tryParse(value);
  if (uri?.scheme == 'file' && (uri!.host.isEmpty || uri.host == 'localhost')) {
    return;
  }
  if (value.contains('://') || (uri != null && uri.scheme.isNotEmpty)) {
    throw UnsupportedError('开源版仅支持本地媒体文件；在线播放、下载及远程媒体处理已停用');
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

/// The source reference is retained for old records, never as a remote-input
/// exception. Already downloaded files work independently of that reference.
void requireCommunityProcessingSource(String path, {MediaSourceRef? source}) {
  requireCommunityLocalMedia(path);
}

/// Cookie/client endpoints are not an authorized cloud-drive API integration.
void requireCommunityAuthorizedCloudDrive() {
  throw UnsupportedError('开源版仅支持本地媒体，网盘浏览、播放和下载已停用');
}

/// The compatibility API cannot reactivate platform media playback.
void requireCommunityOfficialBilibili() {
  throw UnsupportedError('开源版仅支持本地媒体，哔哩哔哩在线播放和媒体提取已停用');
}

/// Retained podcast data is local history; subscription and media transports
/// cannot be reactivated by old callbacks, jobs or compatibility callers.
void requireCommunityPodcastOnline() {
  throw UnsupportedError('开源版仅支持本地媒体，播客订阅、更新、在线播放和下载已停用');
}
