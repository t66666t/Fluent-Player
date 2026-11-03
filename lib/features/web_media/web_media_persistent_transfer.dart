// Community edition: executable downloader implementation removed.
part of 'web_media_download_service.dart';

class _StoredMediaAsset {
  _StoredMediaAsset(this.id, this.url, this.track)
    : end = null,
      start = null,
      seconds = 0,
      extension = '.ts';
  final String id, track;
  final String extension;
  String get fileName => '$id$extension';
  final Uri url;
  final int? start, end;
  final double seconds;
}

extension _PersistentMediaTransfer on WebMediaDownloadService {
  Future<void> _saveResume(WebMediaResumeState state) async {}

  Future<T> _merging<T>(Future<T> Function() operation) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<File> _downloadRetainedMedia(
    WebMediaResource video,
    WebMediaResource? audio,
    Directory outputDirectory,
    String base,
    WebMediaResumeState state,
    void Function(double?)? onProgress,
    void Function(int, int?)? onBytes,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<void> _validateMuxedAudio(File output, Duration expected) async {}

  Future<({File file, Duration duration})> _retainedPlaylist(
    WebMediaResource resource,
    String track,
    WebMediaResumeState state,
    Future<void> Function() save,
    void Function(double?)? onProgress,
    void Function(int, int?)? onBytes,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<void> _fetchStoredAsset(
    _StoredMediaAsset asset,
    WebMediaResource resource,
    WebMediaResumeState state,
    _HlsResourceRecovery recovery,
    Future<void> Function() save,
    void Function(bool force) publish,
    _MediaReadJob<_StoredMediaAsset> job,
  ) async {}
}
