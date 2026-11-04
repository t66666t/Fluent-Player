import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A child token closes only this response when its consumer stops reading.
/// Dio's response stream does not itself forward consumer cancellation to the
/// adapter. The child also stops its idle timer without cancelling sibling reads.
Future<Response<ResponseBody>> openCancellableDioStream(
  Future<Response<ResponseBody>> Function(CancelToken token) open, {
  CancelToken? cancelToken,
}) async {
  if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
  final cancellation = _DioStreamCancellation(cancelToken);
  final Response<ResponseBody> response;
  try {
    response = await open(cancellation.child!);
  } catch (_) {
    cancellation.finish(cancel: true);
    rethrow;
  }
  final body = response.data;
  if (body == null) {
    cancellation.finish(cancel: true);
    return response;
  }
  final source = body.stream;
  StreamSubscription<Uint8List>? subscription;
  late StreamController<Uint8List> forwarded;
  forwarded = StreamController<Uint8List>(
    onListen: () {
      subscription = source.listen(
        forwarded.add,
        onError: (Object error, StackTrace stack) {
          cancellation.finish();
          forwarded.addError(error, stack);
          unawaited(forwarded.close());
        },
        onDone: () {
          cancellation.finish();
          unawaited(forwarded.close());
        },
        cancelOnError: true,
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () async {
      cancellation.finish(cancel: true);
      await subscription?.cancel();
    },
  );
  body.stream = forwarded.stream;
  return response;
}

class _DioStreamCancellation {
  _DioStreamCancellation(CancelToken? parent) {
    if (parent != null) {
      unawaited(
        parent.whenCancel.then((error) {
          child?.cancel(error.error ?? error.message);
        }),
      );
    }
  }

  CancelToken? child = CancelToken();

  void finish({bool cancel = false}) {
    final token = child;
    // A long download's parent token must not retain every completed response.
    // Clearing the link also prevents late cancellation of a reused connection.
    child = null;
    if (cancel) token?.cancel('响应读取已结束');
  }
}
