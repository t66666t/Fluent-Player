// Community edition: executable downloader implementation removed.
part of 'web_media_download_service.dart';

/// Refresh signed URLs together. New URLs are accepted only when every
/// playlist still describes the same VOD segments in the same order.
class _HlsResourceRecovery {
  _HlsResourceRecovery(this.owner, this.current, this.original);
  final WebMediaDownloadService owner;
  WebMediaResource current;
  final _ValidatedHls original;
  Future<bool>? refreshing;
  final Map<String, Uri> targets = {};
  int refreshes = 0;
  int revision = 0;

  Future<Response<ResponseBody>> open(
    Uri target, {
    String? byteRange,
    CancelToken? cancelToken,
    bool retry = true,
  }) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<bool> _refresh() async {
    return false;
  }

  Map<String, String> _canonical(_ValidatedHls manifests) {
    return {};
  }
}

/// A sliding disk cache for VOD playlists. At most the selected connection
/// count of segments is fetched ahead per playlist, then released after use.
/// Keys and byte-range playlists keep the original scoped relay behavior.
class _HlsPrefetch {
  _HlsPrefetch(this.owner, this.recovery, this.directory) : onBytes = null;
  final WebMediaDownloadService owner;
  final _HlsResourceRecovery recovery;
  final Directory directory;
  final void Function(int, int?)? onBytes;
  int receivedBytes = 0;
  final Map<String, Object> failures = {};
  final CancelToken cancel = CancelToken();
  final Map<String, Future<File?>> files = {};
  final Map<String, List<Uri>> playlists = {};
  final Map<String, int> cursors = {};
  final Set<String> used = {};

  void prime(String text, Uri base) {}

  void _schedule(String playlist) {}

  Future<File?> _fetch(Uri target) async {
    return null;
  }

  Future<File?> take(Uri uri) async {
    return null;
  }

  Future<void> release(Uri uri) async {}

  Future<void> close() async {}
}
