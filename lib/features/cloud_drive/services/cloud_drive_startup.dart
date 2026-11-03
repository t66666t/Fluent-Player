import 'dart:async';

import '../models/cloud_drive_models.dart';

const cloudDriveInitializationTimeout = Duration(seconds: 12);

/// A slow local disk must not leave a page or playback waiting forever. The
/// shared installation keeps running, so a retry can reuse a late completion.
Future<T> waitForCloudDriveInitialization<T>(
  Future<T> future, {
  Duration timeout = cloudDriveInitializationTimeout,
}) => future.timeout(
  timeout,
  onTimeout: () => throw const CloudDriveFailure(
    CloudDriveFailureKind.unavailable,
    '读取本机网盘账号超时，请重试；若仍失败，请检查数据目录是否可访问。',
    diagnostic: 'startup=timeout',
  ),
);

/// Single wait point for cloud-drive startup.
///
/// The first frame must not block on disk or account loading, but restoring or
/// tapping a cloud file has to await the same future. Rebuilding the player
/// does not clear that race.
class CloudDriveStartup {
  static Future<void>? _pending;
  static Future<void> Function()? _retry;

  static Future<void>? get pending => _pending;

  static void bind({
    required Future<void>? pending,
    required Future<void> Function() retry,
  }) {
    _pending = pending;
    _retry = retry;
    if (pending != null) {
      // Installation may fail before anyone opens a cloud file. Observe that
      // background error now while preserving it for waitUntilReady to retry.
      unawaited(
        pending.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  static void resetForTest() {
    _pending = null;
    _retry = null;
  }

  /// Waits for the in-flight install, then retries once if that attempt failed.
  static Future<void> waitUntilReady() =>
      waitForCloudDriveInitialization(_waitUntilReady());

  static Future<void> _waitUntilReady() async {
    final first = _pending;
    if (first != null) {
      try {
        await first;
        return;
      } catch (_) {
        if (identical(_pending, first)) _pending = null;
      }
    }
    final retry = _retry;
    if (retry == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '网盘播放服务尚未初始化',
      );
    }
    final next = retry();
    _pending = next;
    try {
      await next;
    } catch (_) {
      if (identical(_pending, next)) _pending = null;
      rethrow;
    }
  }
}
