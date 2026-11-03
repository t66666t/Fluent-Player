import 'dart:async';
import 'dart:math';

import 'podcast_store.dart';
import 'podcast_transfer.dart';

/// Database leases also bound the independent foreground/background isolates.
/// A rate limited host cools down as a whole, then recovers with one request.
class PodcastDownloadGate {
  PodcastDownloadGate(this.store);
  final PodcastStore store;
  final _active = <String, Timer>{};
  bool _closed = false;

  void observe(Uri source, int status, String? retryAfter) {
    if (status != 429 && status != 503) return;
    store.transaction(() {
      final now = DateTime.now();
      final old = store.read('downloadHost', source.host);
      final previousFailures =
          (old?['serialUntil'] as int? ?? 0) > now.millisecondsSinceEpoch
          ? (old?['failures'] as int? ?? 0)
          : 0;
      final failures = min(6, previousFailures + 1);
      final delay =
          parseRetryAfter(retryAfter, now: now) ??
          Duration(seconds: 5 * (1 << (failures - 1)));
      final until =
          now.millisecondsSinceEpoch + max(1000, delay.inMilliseconds);
      store.write('downloadHost', source.host, {
        'failures': failures,
        'until': max(until, old?['until'] as int? ?? 0),
        'serialUntil':
            max(until, old?['until'] as int? ?? 0) +
            PodcastTransferPolicy.hostRecovery.inMilliseconds,
      });
    });
  }

  Future<T> run<T>(
    Uri source,
    Future<T> Function() action, {
    required bool Function() shouldContinue,
    Future<void>? cancelSignal,
    void Function(String message, bool rateLimited)? onWaiting,
  }) async {
    var cancelled = false;
    cancelSignal?.then((_) => cancelled = true);
    final owner =
        '${DateTime.now().microsecondsSinceEpoch}:${Random.secure().nextDouble()}';
    void check() {
      if (_closed || cancelled || !shouldContinue()) {
        throw PodcastTransferException(
          '播客下载已暂停，已下载的数据会保留',
          kind: PodcastTransferFailureKind.cancelled,
        );
      }
    }

    while (true) {
      check();
      final acquired = store.transaction(() {
        final now = DateTime.now().millisecondsSinceEpoch;
        final leases = store.list('downloadConnection');
        for (final lease in leases.where((v) => (v['until'] as int) <= now)) {
          store.remove('downloadConnection', lease['id'] as String);
        }
        final active = leases.where((v) => (v['until'] as int) > now).toList();
        final host = store.read('downloadHost', source.host);
        if ((host?['until'] as int? ?? 0) > now) return false;
        final limit = (host?['serialUntil'] as int? ?? 0) > now
            ? 1
            : PodcastTransferPolicy.maxHostBulkWindows;
        if (active.length >= PodcastTransferPolicy.maxGlobalWindows ||
            active.where((v) => v['host'] == source.host).length >= limit) {
          return false;
        }
        store.write('downloadConnection', owner, {
          'id': owner,
          'host': source.host,
          'until': now + PodcastTransferPolicy.leaseTtl.inMilliseconds,
        });
        return true;
      });
      if (acquired) break;
      final host = store.read('downloadHost', source.host);
      final remaining =
          (host?['until'] as int? ?? 0) - DateTime.now().millisecondsSinceEpoch;
      onWaiting?.call(
        remaining > 0
            ? '来源要求等待 ${(remaining / 1000).ceil()} 秒，已保存下载进度'
            : '正在等待下载连接名额，已保存下载进度',
        remaining > 0,
      );
      await Future.any<void>([
        Future<void>.delayed(const Duration(milliseconds: 200)),
        ?cancelSignal,
      ]);
    }
    _active[owner] = Timer.periodic(PodcastTransferPolicy.leaseRenew, (_) {
      final lease = store.read('downloadConnection', owner);
      if (lease != null) {
        lease['until'] =
            DateTime.now().millisecondsSinceEpoch +
            PodcastTransferPolicy.leaseTtl.inMilliseconds;
        store.write('downloadConnection', owner, lease);
      }
    });
    try {
      check();
      return await action();
    } finally {
      _active.remove(owner)?.cancel();
      store.remove('downloadConnection', owner);
    }
  }

  void close() {
    _closed = true;
    for (final entry in _active.entries) {
      entry.value.cancel();
      store.remove('downloadConnection', entry.key);
    }
    _active.clear();
  }
}
