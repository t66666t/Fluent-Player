import 'dart:async';

import 'package:flutter/foundation.dart';
import '../debug/developer_log.dart' as developer;

enum PlaybackStartupPhase {
  resolving,
  connecting,
  positioning,
  waitingForFrame,
  starting,
  ready,
  failed,
  cancelled,
}

class PlaybackStartupCancelled implements Exception {
  const PlaybackStartupCancelled();
}

/// One tap's monotonic deadline. Shared by the loading route, gateway and
/// native output; successful playback is not subject to this startup deadline.
class PlaybackStartupContext extends ChangeNotifier {
  PlaybackStartupContext({
    this.limit = const Duration(seconds: 30),
    Duration Function()? elapsed,
    this.onMark,
    this.coverUrl,
    this.logName = 'PlaybackStartup',
  }) {
    final watch = Stopwatch()..start();
    _elapsed = elapsed ?? (() => watch.elapsed);
  }

  static const indicatorDelay = Duration(milliseconds: 300);
  static const coverFadeDuration = Duration(milliseconds: 120);
  static const positionTolerance = Duration(milliseconds: 450);
  static const resumeFrameRecoveryDelay = Duration(milliseconds: 750);

  final String logName;
  String get mediaLabel => '媒体';
  final Duration limit;
  final void Function(String)? onMark;
  late final Duration Function() _elapsed;
  final Completer<void> _cancelled = Completer<void>();
  final Set<VoidCallback> _aborts = {};
  final List<({String step, int ms})> _marks = [];
  List<({String step, int ms})> get marks => List.unmodifiable(_marks);
  PlaybackStartupPhase _phase = PlaybackStartupPhase.resolving;
  Duration target = Duration.zero;
  bool hasUserTarget = false;
  int? qualityId;
  String? coverUrl;
  String? failure;
  bool desiredPlaying = true;
  bool _correctedPosition = false;
  bool _recoveredFrame = false;
  bool _recoveredClock = false;
  bool _prepared = false;
  bool _refreshedAddress = false;

  PlaybackStartupPhase get phase => _phase;
  Duration get elapsed => _elapsed();
  Duration get remaining {
    final value = limit - elapsed;
    return value > Duration.zero ? value : Duration.zero;
  }

  bool get isPending => !isReady && !isCancelled && !hasFailed;
  bool get isPrepared => _prepared;
  bool get isReady => _phase == PlaybackStartupPhase.ready;
  bool get isCancelled => _phase == PlaybackStartupPhase.cancelled;
  bool get hasFailed => _phase == PlaybackStartupPhase.failed;
  Future<void> get cancelled => _cancelled.future;

  void check() {
    if (isCancelled) throw const PlaybackStartupCancelled();
    if (hasFailed) throw StateError(failure ?? '$mediaLabel加载失败');
    if (!isReady && remaining == Duration.zero) {
      throw TimeoutException('$mediaLabel加载超时，请重试', limit);
    }
  }

  Duration bounded(Duration cap) {
    check();
    return isReady || remaining > cap ? cap : remaining;
  }

  Future<T> run<T>(Future<T> work, {Duration? cap}) {
    // Always observe work, including a native creation that finishes after a
    // cancellation. The caller still owns and disposes that controller.
    final cancelledWork = cancelled.then<T>((_) {
      if (hasFailed) throw StateError(failure ?? '$mediaLabel加载失败');
      throw const PlaybackStartupCancelled();
    });
    final raced = Future.any<T>([work, cancelledWork]);
    try {
      check();
      return isReady
          ? (cap == null ? raced : raced.timeout(cap))
          : raced.timeout(bounded(cap ?? limit));
    } catch (error, stack) {
      unawaited(raced.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
      return Future<T>.error(error, stack);
    }
  }

  /// A paused native open may acknowledge start= without producing its frame.
  /// Recover that parked decoder once, then verify a fresh readiness sample.
  /// Never reveal a frame merely because this recovery timer has expired.
  Future<void> waitForFrame(
    Future<void> frame, {
    required Future<void> Function() recheckFrame,
    required Future<void> Function(Duration) recoverResume,
    Duration recoveryDelay = resumeFrameRecoveryDelay,
    bool playbackClock = false,
  }) async {
    final recovery = Completer<void>();
    var recovering = false;
    final result = Future.any<void>([frame, recovery.future]);
    final timer = Timer(recoveryDelay, () async {
      if (!isPending ||
          hasUserTarget ||
          target < Duration.zero ||
          !(playbackClock ? claimClockRecovery() : claimFrameRecovery())) {
        return;
      }
      recovering = true;
      record(
        playbackClock
            ? 'startup clock recovery seek'
            : 'resume frame recovery seek',
      );
      try {
        await recoverResume(target);
        recovery.complete();
      } catch (error, stack) {
        recovery.completeError(error, stack);
      }
    });
    try {
      await run(result);
      timer.cancel();
      if (recovering) {
        // An old frame can arrive while the correction command is still in
        // flight. Finish that command and recheck before opening the cover.
        await run(recovery.future);
        await run(Future<void>.sync(recheckFrame));
      }
    } finally {
      timer.cancel();
    }
  }

  void mark(PlaybackStartupPhase next) {
    if (!isPending || next == _phase) return;
    _phase = next;
    record('startup ${next.name}');
    notifyListeners();
  }

  void record(String step) {
    if (_marks.length == 256) _marks.removeAt(0);
    _marks.add((step: step, ms: elapsed.inMilliseconds));
    onMark?.call(step);
    if (onMark == null && kDebugMode) {
      developer.log('+${elapsed.inMilliseconds}ms $step', name: logName);
    }
  }

  bool claimPositionCorrection() {
    if (_correctedPosition) return false;
    _correctedPosition = true;
    return true;
  }

  bool claimFrameRecovery() {
    if (_recoveredFrame) return false;
    _recoveredFrame = true;
    return true;
  }

  bool claimClockRecovery() {
    if (_recoveredClock) return false;
    _recoveredClock = true;
    return true;
  }

  /// Safe to start the transport, but do not advertise successful playback
  /// until the native clock advances (or the latest intent is paused).
  void prepared() {
    if (!isPending) return;
    _prepared = true;
    mark(PlaybackStartupPhase.starting);
  }

  bool claimAddressRefresh() {
    if (_refreshedAddress) return false;
    _refreshedAddress = true;
    return true;
  }

  PlaybackStartupContext.continuation(
    PlaybackStartupContext previous, {
    this.logName = 'PlaybackStartup',
  }) : limit = previous.limit,
       _elapsed = (() => previous.elapsed),
       onMark = previous.onMark,
       coverUrl = previous.coverUrl {
    target = previous.target;
    hasUserTarget = previous.hasUserTarget;
    qualityId = previous.qualityId;
    desiredPlaying = previous.desiredPlaying;
    _refreshedAddress = previous._refreshedAddress;
  }

  /// Recreating a transport must not restart the operation's deadline.
  PlaybackStartupContext continueOnNewNetwork() =>
      PlaybackStartupContext.continuation(this);

  VoidCallback bindAbort(VoidCallback abort) {
    if (isCancelled || hasFailed) {
      abort();
      return () {};
    }
    _aborts.add(abort);
    return () => _aborts.remove(abort);
  }

  void _abort() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    final aborts = _aborts.toList(growable: false);
    _aborts.clear();
    for (final abort in aborts) {
      try {
        abort();
      } catch (_) {
        // A closing socket must not prevent other resources from cancelling.
      }
    }
  }

  void cancel() {
    if (!isPending) return;
    _phase = PlaybackStartupPhase.cancelled;
    _abort();
    notifyListeners();
  }

  void fail(Object error) {
    if (!isPending) return;
    failure = error is TimeoutException
        ? '$mediaLabel加载超时，请重试'
        : '暂时无法加载$mediaLabel，请重试';
    if (error is StateError) {
      final message = error.message;
      if (const [
        '当前账号没有可播放',
        '当前账号需要登录',
        '当前账号没有该视频',
        '当前视频受地区限制',
        '当前视频需要大会员',
        'Bilibili 未返回可用',
        '视频未能定位',
        '音视频解码失败',
        '播放地址刷新后仍不可用',
      ].any(message.startsWith)) {
        failure = message;
      }
    }
    _phase = PlaybackStartupPhase.failed;
    record('startup failed (${error.runtimeType})');
    _abort();
    notifyListeners();
  }

  void ready() {
    if (!isPending) return;
    _prepared = true;
    mark(PlaybackStartupPhase.ready);
    _aborts.clear();
  }
}
