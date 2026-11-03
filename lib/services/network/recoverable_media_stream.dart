import 'dart:async';
import 'dart:io';

import 'network_recovery.dart';

class NetworkMediaResponse {
  const NetworkMediaResponse({
    required this.status,
    required this.headers,
    required this.body,
    required this.close,
  });

  /// Keep access to the underlying subscription so close() interrupts a pending
  /// read, including when another async* transformer is waiting for more bytes.
  factory NetworkMediaResponse.fromStream({
    required int status,
    required Map<String, String> headers,
    required Stream<List<int>> body,
  }) {
    final iterator = StreamIterator<List<int>>(body);
    Future<void>? closing;
    Future<void> close() => closing ??= iterator.cancel();
    Stream<List<int>> forwarded() async* {
      try {
        while (await iterator.moveNext()) {
          yield iterator.current;
        }
      } finally {
        await close();
      }
    }

    return NetworkMediaResponse(
      status: status,
      headers: headers,
      body: forwarded(),
      close: close,
    );
  }
  final int status;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final Future<void> Function() close;
}

/// Keeps the player's local response open across a transient upstream failure.
/// Already delivered bytes may only be followed by a validated 206 suffix.
Stream<List<int>> recoverableMediaStream({
  required NetworkMediaResponse initial,
  required Future<NetworkMediaResponse> Function(
    int start,
    int? end,
    String? validator,
  )
  reopen,
  required void Function() checkCancelled,
  bool Function()? isCancelled,
  List<Duration> retryDelays = NetworkRecovery.retryDelays,
  Duration idleTimeout = const Duration(seconds: 30),
}) async* {
  final match = RegExp(
    r'^bytes (\d+)-(\d+)/(\d+|\*)$',
  ).firstMatch(initial.headers['content-range'] ?? '');
  final start = match == null ? 0 : int.parse(match[1]!);
  final expected = initial.status == 206 && match != null
      ? int.parse(match[2]!) - start + 1
      : int.tryParse(initial.headers['content-length'] ?? '');
  final end = expected == null ? null : start + expected - 1;
  final total = match == null ? expected : int.tryParse(match[3]!);
  final etag = initial.headers['etag'];
  final validator = etag != null && !etag.startsWith('W/')
      ? etag
      : initial.headers['last-modified'];
  var active = initial;
  var activeClosed = false;
  var delivered = 0, retries = 0;
  try {
    while (true) {
      checkCancelled();
      try {
        await for (final bytes in active.body.timeout(idleTimeout)) {
          checkCancelled();
          if (expected != null && delivered + bytes.length > expected) {
            throw const FormatException('媒体线路返回了超出范围的数据');
          }
          delivered += bytes.length;
          yield bytes;
        }
        if (expected != null && delivered < expected) {
          throw const HttpException('媒体线路提前结束传输');
        }
        return;
      } catch (error) {
        if (!NetworkRecovery.isTransient(error) ||
            initial.status != 200 && initial.status != 206 ||
            delivered > 0 && validator == null) {
          rethrow;
        }
        await active.close();
        activeClosed = true;
        Object failure = error;
        while (true) {
          if (retries >= retryDelays.length) throw failure;
          await NetworkRecovery.wait(
            retryDelays[retries++],
            checkCancelled: checkCancelled,
          );
          try {
            active = await reopen(start + delivered, end, validator);
            activeClosed = false;
            if (NetworkRecovery.transientStatus(active.status)) {
              final status = active.status;
              await active.close();
              activeClosed = true;
              throw HttpException('HTTP $status');
            }
            final next = RegExp(
              r'^bytes (\d+)-(\d+)/(\d+|\*)$',
            ).firstMatch(active.headers['content-range'] ?? '');
            final sameValidator =
                validator == null ||
                active.headers['etag'] == validator ||
                active.headers['last-modified'] == validator;
            final validSuffix =
                active.status == 206 &&
                next != null &&
                int.parse(next[1]!) == start + delivered &&
                (end == null || int.parse(next[2]!) == end) &&
                (total == null || int.tryParse(next[3]!) == total);
            final validFull =
                delivered == 0 &&
                start == 0 &&
                active.status == 200 &&
                (expected == null ||
                    int.tryParse(active.headers['content-length'] ?? '') ==
                        expected);
            if (!sameValidator || (!validSuffix && !validFull)) {
              await active.close();
              activeClosed = true;
              throw const FormatException('重连后的媒体身份或范围不匹配，停止拼接');
            }
            break;
          } catch (nextError) {
            checkCancelled();
            if (!NetworkRecovery.isTransient(nextError)) rethrow;
            failure = nextError;
          }
        }
      }
    }
  } catch (_) {
    // An abandoned player's async generator can still be awaiting a read or
    // retry delay. Finish its deliberate cancellation inside the generator,
    // before an error can outlive the already-cancelled downstream listener.
    if (isCancelled?.call() != true) rethrow;
  } finally {
    if (!activeClosed) await active.close();
  }
}
