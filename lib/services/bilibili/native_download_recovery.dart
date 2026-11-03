import 'package:dio/dio.dart';

import 'download_route_policy.dart';

/// Native resume data is opaque and tied to its original URL. Recover a slow
/// URLSession request by reconnecting it once; an actual failure can still try
/// backup URLs. Never mutate opaque resume data to force a different host.
Future<T> runBilibiliNativeDownload<T>({
  required Iterable<String> urls,
  required String track,
  required CancelToken cancel,
  required Future<T> Function(
    String url,
    CancelToken requestCancel,
    void Function(int bytes, int? total) progress,
  )
  download,
  required void Function(int bytes, int? total) onProgress,
  BilibiliDownloadRoutePolicy policy = const BilibiliDownloadRoutePolicy(),
  BilibiliDownloadDiagnostic? onDiagnostic,
  bool Function()? allowRecovery,
}) async {
  final trace = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  Object? lastError;
  StackTrace? lastStack;
  for (final address in urls.where((value) => value.isNotEmpty).toSet()) {
    final budget = BilibiliDownloadRouteBudget(
      [address],
      policy,
      reconnectSameSource: true,
    );
    while (true) {
      _checkCancelled(cancel);
      final requestCancel = CancelToken();
      CancelToken? linked = requestCancel;
      cancel.whenCancel.then((error) => linked?.cancel(error));
      final diagnostic = BilibiliDownloadAttempt(
        url: address,
        track: track,
        transport: 'urlsession',
        requestedConnections: 1,
        budget: budget,
        onDiagnostic: onDiagnostic,
        trace: trace,
      );
      BilibiliSlowRouteException? slow;
      int? previousBytes;
      var outcome = 'failed';
      try {
        final result = await download(address, requestCancel, (bytes, total) {
          if (cancel.isCancelled || requestCancel.isCancelled) return;
          final previous = previousBytes;
          previousBytes = bytes;
          diagnostic.start(
            resumedBytes: bytes,
            expectedBytes: total == null ? null : total - bytes,
            resumeSupported: true,
          );
          onProgress(bytes, total);
          if (cancel.isCancelled) return;
          if (previous == null || bytes <= previous) return;
          try {
            diagnostic.addBytes(
              bytes - previous,
              allowRecovery: allowRecovery?.call() ?? true,
            );
          } on BilibiliSlowRouteException catch (error) {
            slow = error;
            requestCancel.cancel('保留系统断点后重新连接');
          }
        });
        _checkCancelled(cancel);
        if (slow != null) throw slow!;
        outcome = 'completed';
        return result;
      } catch (error, stack) {
        _checkCancelled(cancel);
        if (slow != null) {
          outcome = 'reconnecting';
          // The native pause result is awaited by download() before this loop
          // starts again, so the saved resume data and callback cannot race.
          continue;
        }
        lastError = error;
        lastStack = stack;
        break;
      } finally {
        linked = null;
        diagnostic.finish(cancel.isCancelled ? 'cancelled' : outcome);
      }
    }
  }
  if (lastError != null) Error.throwWithStackTrace(lastError, lastStack!);
  throw StateError('No Bilibili media URL is available');
}

void _checkCancelled(CancelToken token) {
  if (token.isCancelled) throw token.cancelError!;
}
