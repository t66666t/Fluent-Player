import 'dart:async';
import 'model_background_tasks.dart';
import 'device_resource_monitor.dart';
import 'inference_resource_governor.dart';

class InferenceReservation {
  InferenceReservation._(this.owner, this.resources);
  final InferenceScheduler owner;
  final InferenceResourceSession resources;
  bool _active = true;
}

/// Serializes heavy native work across ASR, translation and OCR. A cancelled
/// waiter never releases the running owner's reservation.
class InferenceScheduler {
  InferenceScheduler({
    Future<InferenceResourceSession> Function()? openResources,
  }) : _openResources =
           openResources ?? DeviceResourceMonitor.instance.openSession;
  final Future<InferenceResourceSession> Function() _openResources;
  static final instance = InferenceScheduler();
  static final _reservationKey = Object();
  InferenceReservation? get currentReservation =>
      Zone.current[_reservationKey] as InferenceReservation?;
  Future<void> _tail = Future<void>.value();
  int waiting = 0;
  bool busy = false;

  Future<void Function()> acquire({
    Future<void>? cancelSignal,
    bool Function()? isCancelled,
  }) async {
    final previous = _tail;
    final released = Completer<void>();
    _tail = released.future;
    waiting++;
    final cancelled = Completer<void>();
    var settled = false;
    cancelSignal?.then((_) {
      if (!settled && !cancelled.isCompleted) cancelled.complete();
    });
    await Future.any<void>([previous, cancelled.future]);
    if (cancelled.isCompleted || isCancelled?.call() == true) {
      settled = true;
      waiting--;
      unawaited(previous.then((_) => released.complete()));
      throw StateError('任务已取消');
    }
    settled = true;
    busy = true;
    ModelBackgroundTasks.inference(1);
    var done = false;
    return () {
      if (done) return;
      done = true;
      busy = false;
      ModelBackgroundTasks.inference(-1);
      waiting--;
      released.complete();
    };
  }

  Future<T> run<T>(
    Future<T> Function() work, {
    Future<void>? cancelSignal,
    InferenceReservation? reservation,
    InferenceResourceSession? resources,
  }) async {
    if (reservation != null) {
      if (!identical(reservation.owner, this) || !reservation._active) {
        throw StateError('本地推理资源预约已失效');
      }
      return runZoned(
        work,
        zoneValues: {
          _reservationKey: reservation,
          InferenceResourceSession.zoneKey: reservation.resources,
        },
      );
    }
    final release = await acquire(cancelSignal: cancelSignal);
    InferenceResourceSession? acquired;
    InferenceReservation? owned;
    try {
      acquired = resources ?? await _openResources();
      owned = InferenceReservation._(this, acquired);
      return await runZoned(
        work,
        zoneValues: {
          _reservationKey: owned,
          InferenceResourceSession.zoneKey: acquired,
        },
      );
    } finally {
      owned?._active = false;
      try {
        await acquired?.close();
      } finally {
        release();
      }
    }
  }
}
