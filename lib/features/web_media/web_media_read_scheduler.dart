// Community edition: executable downloader implementation removed.
part of 'web_media_download_service.dart';

class _MediaReadJob<T> {
  _MediaReadJob(this.value, this.highWater);
  final T value;
  int failures = 0;
  int highWater;
  int? attemptedLimit;
  int? attemptedGeneration;
  DateTime? readyAt;
  Object? lastFailure;

  void started(_TransferLimiter limiter) {}
}

extension _MediaReadScheduling on WebMediaDownloadService {
  /// A retry waits outside a worker. Healthy reads continue filling available
  /// connections, and completed windows return their worker to the shared queue.
  Future<void> _runReadJobs<T>(
    Iterable<T> values,
    Future<bool> Function(_MediaReadJob<T>) read, {
    required int Function() retainedProgress,
  }) async {}
}
