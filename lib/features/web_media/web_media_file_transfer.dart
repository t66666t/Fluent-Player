// Community edition: executable downloader implementation removed.
part of 'web_media_download_service.dart';

class _MediaByteRange {
  _MediaByteRange(this.start, this.end) : received = 0;
  final int start;
  final int end;
  int received;
}

class _MediaRangeUnsupported implements Exception {}

/// RandomAccessFile rejects overlapping async operations. Checkpoint flushes
/// must use the same fence as seek/write, and close must drain that fence too.
class _MediaFileWriter {
  _MediaFileWriter(this.file);

  final RandomAccessFile file;
  Future<void> _pending = Future.value();

  Future<void> _enqueue(Future<void> Function() operation) async {}

  Future<void> write(List<int> bytes, {int? position}) async {}

  Future<void> flush() async {}

  Future<void> close() async {}
}

({int start, int end, int total})? _mediaRange(
  Response<ResponseBody> response,
) {
  final match = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  ).firstMatch(response.headers.value('content-range') ?? '');
  if (match == null) return null;
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  final total = int.parse(match.group(3)!);
  return start >= 0 && end >= start && end < total
      ? (start: start, end: end, total: total)
      : null;
}

extension _WebMediaFileTransfer on WebMediaDownloadService {
  String? _validator(Response<ResponseBody> response) {
    return null;
  }

  Future<File> _downloadFile(
    WebMediaResource initial,
    Directory directory,
    String base,
    WebMediaResumeState? retained,
    void Function(double?)? onProgress,
    void Function(int, int?)? onBytes,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<void> _writeSequential(
    Response<ResponseBody> response,
    File file,
    _MediaByteRange range,
    void Function() progress,
  ) async {}
}
