import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class RecoverableMediaHttpException extends HttpException {
  RecoverableMediaHttpException(int status, {this.retryAfter})
    : super('HTTP $status');
  final String? retryAfter;
}

/// Safe reads may resume after a route handover. Account writes are never
/// automatically replayed by this policy.
abstract final class NetworkRecovery {
  static bool _mobileBackground = false;

  /// A native user-initiated transfer lease permits its shared engine to keep
  /// reconnecting while Android is in the background.
  static bool backgroundTransferActive = false;

  /// Losing focus (notification shade/control center) is not suspension. On
  /// mobile, don't burn all retries while the OS cannot run the foreground
  /// transfer. Existing sockets may continue; an interrupted transfer waits
  /// for resume, with pause/cancel still checked throughout.
  static void handleLifecycle(AppLifecycleState? state) {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    _mobileBackground =
        mobile &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached);
  }

  static const retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  static bool transientStatus(int status) =>
      status == 408 || status == 429 || status >= 500 && status <= 504;

  static Duration retryDelay(Object error, Duration fallback, {DateTime? now}) {
    final value = error is RecoverableMediaHttpException
        ? error.retryAfter
        : error is DioException
        ? error.response?.headers.value(HttpHeaders.retryAfterHeader)
        : null;
    if (value == null) return fallback;
    final seconds = int.tryParse(value.trim());
    Duration? requested;
    if (seconds != null && seconds >= 0) {
      requested = Duration(seconds: seconds);
    } else {
      try {
        requested = HttpDate.parse(value).difference(now ?? DateTime.now());
      } on FormatException {
        /* malformed server hint uses the normal backoff */
      } on HttpException {
        /* HttpDate reports malformed dates as HttpException */
      }
    }
    return requested != null && requested > fallback ? requested : fallback;
  }

  static bool isTransient(Object error) {
    if (error is SocketException || error is TimeoutException) return true;
    if (error is DioException) {
      if (CancelToken.isCancel(error)) return false;
      final status = error.response?.statusCode;
      if (status != null) return transientStatus(status);
      return error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.error != null && isTransient(error.error!);
    }
    if (error is HttpException) {
      final status = RegExp(
        r'(?:返回|returned|HTTP|失败（)\s*(\d{3})',
      ).firstMatch(error.message);
      if (status != null) return transientStatus(int.parse(status[1]!));
      return true;
    }
    return false;
  }

  static Future<void> wait(
    Duration delay, {
    required void Function() checkCancelled,
    Future<void>? cancelSignal,
  }) async {
    var remaining = delay;
    while (remaining > Duration.zero) {
      checkCancelled();
      if (_mobileBackground && !backgroundTransferActive) {
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 200)),
          ?cancelSignal,
        ]);
        continue;
      }
      final step = remaining < const Duration(milliseconds: 200)
          ? remaining
          : const Duration(milliseconds: 200);
      await Future.any<void>([Future<void>.delayed(step), ?cancelSignal]);
      checkCancelled();
      remaining -= step;
    }
    checkCancelled();
  }
}
