import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A cancellable interest in a decode. Disposing an active request does not
/// pretend that the engine has stopped decoding; its slot stays occupied until
/// the image, an error, or the fault deadline arrives.
class ThumbnailDecodeRequest {
  ThumbnailDecodeRequest._(this.ready, this._cancel);

  final Future<bool> ready;
  final VoidCallback _cancel;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancel();
  }
}

class _DecodeDemand {
  _DecodeDemand(this.priority, this.shouldDefer);

  final int priority;
  final bool Function()? shouldDefer;
  final result = Completer<bool>();
  _DecodeJob? job;
  bool cancelled = false;
}

class _DecodeJob {
  _DecodeJob(this.key, this.provider, this.configuration, this.sequence);

  final Object key;
  final ImageProvider provider;
  final ImageConfiguration configuration;
  final int sequence;
  final demands = <_DecodeDemand>[];
  bool active = false;
}

/// Bounds actual image decoding, including work requested by the preloader.
/// Visible requests take precedence over optional prefetches. The image cache
/// remains Flutter's bounded cache; this class does not retain image pixels.
class ThumbnailDecodeScheduler {
  ThumbnailDecodeScheduler({this.maxConcurrent = 3})
    : assert(maxConcurrent > 0);

  static final ThumbnailDecodeScheduler instance = ThumbnailDecodeScheduler();
  static const int prefetchPriority = 1 << 30;

  final int maxConcurrent;
  final Map<Object, _DecodeJob> _jobs = {};
  int _active = 0;
  int _sequence = 0;
  bool _pumpScheduled = false;
  Timer? _retry;

  @visibleForTesting
  int get activeCount => _active;

  @visibleForTesting
  int get pendingCount => _jobs.values.where((job) => !job.active).length;

  ThumbnailDecodeRequest request(
    ImageProvider provider,
    ImageConfiguration configuration, {
    int priority = 0,
    bool Function()? shouldDefer,
  }) {
    final demand = _DecodeDemand(priority, shouldDefer);
    final request = ThumbnailDecodeRequest._(demand.result.future, () {
      if (demand.cancelled) return;
      demand.cancelled = true;
      if (!demand.result.isCompleted) demand.result.complete(false);
      final job = demand.job;
      job?.demands.remove(demand);
      if (job != null && !job.active && job.demands.isEmpty) {
        _jobs.remove(job.key);
      }
      _schedulePump();
    });

    // Obtaining a cache key does not decode the image. Cached images bypass
    // the queue so returning to a previously visited card is instantaneous.
    Future.sync(() => provider.obtainKey(configuration)).then(
      (key) {
        if (demand.cancelled) return;
        final status = PaintingBinding.instance.imageCache.statusForKey(key);
        if (status.keepAlive && !status.pending) {
          demand.result.complete(true);
          return;
        }
        final job = _jobs.putIfAbsent(
          key,
          () => _DecodeJob(key, provider, configuration, _sequence++),
        );
        demand.job = job;
        job.demands.add(demand);
        _schedulePump();
      },
      onError: (Object _, StackTrace _) {
        if (!demand.result.isCompleted) demand.result.complete(false);
      },
    );
    return request;
  }

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      _pump();
    });
  }

  void _pump() {
    _retry?.cancel();
    _retry = null;
    while (_active < maxConcurrent) {
      _DecodeJob? best;
      var bestPriority = prefetchPriority + 1;
      var hasDeferred = false;
      for (final job in _jobs.values) {
        if (job.active) continue;
        var priority = prefetchPriority + 1;
        for (final demand in job.demands) {
          if (demand.cancelled) continue;
          if (demand.shouldDefer?.call() ?? false) {
            hasDeferred = true;
            continue;
          }
          if (demand.priority < priority) priority = demand.priority;
        }
        if (priority < bestPriority ||
            (priority == bestPriority &&
                best != null &&
                job.sequence < best.sequence)) {
          best = job;
          bestPriority = priority;
        }
      }
      if (best == null || bestPriority > prefetchPriority) {
        if (hasDeferred) {
          _retry = Timer(const Duration(milliseconds: 40), _schedulePump);
        }
        return;
      }
      _start(best);
    }
  }

  void _start(_DecodeJob job) {
    job.active = true;
    _active++;
    ImageStream? stream;
    ImageStreamListener? listener;
    Timer? deadline;
    var finished = false;

    void finish(bool success) {
      if (finished) return;
      finished = true;
      deadline?.cancel();
      if (listener != null) stream?.removeListener(listener);
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      _active--;
      for (final demand in job.demands) {
        if (!demand.result.isCompleted) demand.result.complete(success);
      }
      job.demands.clear();
      _schedulePump();
    }

    try {
      stream = job.provider.resolve(job.configuration);
      listener = ImageStreamListener((image, _) {
        image.dispose();
        // A cached stream can call back inside addListener.
        scheduleMicrotask(() => finish(true));
      }, onError: (Object _, StackTrace? _) => finish(false));
      // A broken provider must not permanently stall every later cover.
      deadline = Timer(const Duration(seconds: 10), () => finish(false));
      stream.addListener(listener);
    } catch (_) {
      finish(false);
    }
  }
}
