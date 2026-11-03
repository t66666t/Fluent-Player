import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_continue_policy.dart';
import 'package:video_player_app/services/library_watch_meter.dart';

void main() {
  late int now;
  late LibraryWatchMeter meter;

  setUp(() {
    now = 0;
    meter = LibraryWatchMeter(clockMs: () => now);
  });

  void transport({
    bool playing = true,
    bool buffering = false,
    bool seeking = false,
    bool missing = false,
  }) {
    meter.setTransport(
      playing: playing,
      buffering: buffering,
      seeking: seeking,
      missingSource: missing,
    );
  }

  void start({
    String id = 'a',
    bool userInitiated = true,
    bool hidden = false,
    bool completed = false,
    int? durationMs,
  }) {
    meter.startCycle(
      mediaId: id,
      userInitiated: userInitiated,
      hidden: hidden,
      completed: completed,
      durationMs: durationMs,
      nowMs: now,
    );
  }

  void advance({required int clockMs, required int positionMs}) {
    now += clockMs;
    meter.sample(
      mediaId: meter.mediaId!,
      cycleId: meter.cycleId,
      positionMs: positionMs,
      nowMs: now,
    );
  }

  test('29s stays below the unknown-duration threshold, 30s enrolls', () {
    start();
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    var position = 0;
    for (var i = 0; i < 29; i++) {
      position += 1000;
      advance(clockMs: 1000, positionMs: position);
    }
    expect(meter.cycleWatchMs, 29000);
    expect(meter.isEnrolled, isFalse);
    advance(clockMs: 1000, positionMs: position + 1000);
    expect(meter.cycleWatchMs, 30000);
    expect(meter.isEnrolled, isTrue);
  });

  test('unknown duration flush stamps lastPlayedAt after enrollment', () {
    start();
    transport();
    var position = 0;
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    for (var i = 0; i < 30; i++) {
      position += 1000;
      advance(clockMs: 1000, positionMs: position);
    }
    expect(meter.cycleWatchMs, 30000);
    expect(meter.isEnrolled, isTrue);
    final flush = meter.flush(nowMs: now);
    expect(flush.lastPlayedAtMs, now);
    expect(flush.deltaWatchMs, 30000);
  });

  test('playing transport stamps history before any counted delta', () {
    start();
    expect(meter.flush(nowMs: now).lastPlayedAtMs, isNull);
    transport();
    expect(meter.hasStartedPlaying, isTrue);
    final flush = meter.flush(nowMs: now);
    expect(flush.lastPlayedAtMs, now);
    expect(flush.deltaWatchMs, 0);
    expect(flush.enrolled, isFalse);
  });

  test('a few counted seconds stamp history before enrollment', () {
    start();
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    advance(clockMs: 1000, positionMs: 1000);
    advance(clockMs: 1000, positionMs: 2000);
    expect(meter.isEnrolled, isFalse);
    final flush = meter.flush(nowMs: now);
    expect(flush.enrolled, isFalse);
    expect(flush.lastPlayedAtMs, now);
    expect(flush.deltaWatchMs, 2000);
  });

  test('short clip uses 20 percent threshold', () {
    start(durationMs: 10000);
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    advance(clockMs: 1000, positionMs: 1000);
    expect(meter.isEnrolled, isFalse);
    advance(clockMs: 1000, positionMs: 2000);
    expect(meter.isEnrolled, isTrue);
    expect(LibraryWatchMeter.enrollmentThresholdMs(10000), 2000);
  });

  test('raising the policy mid-cycle delays enrollment', () {
    start(durationMs: 200000);
    meter.setPolicy(
      ContinueWatchPolicy.defaults.copyWith(
        combineMode: ContinueWatchCombineMode.both,
        minWatchMs: 60000,
      ),
    );
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    var position = 0;
    for (var i = 0; i < 40; i++) {
      position += 1000;
      advance(clockMs: 1000, positionMs: position);
    }
    expect(meter.isEnrolled, isFalse);
    for (var i = 0; i < 20; i++) {
      position += 1000;
      advance(clockMs: 1000, positionMs: position);
    }
    expect(meter.isEnrolled, isTrue);
  });

  test('2x playback still counts wall-clock seconds', () {
    start();
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    advance(clockMs: 10000, positionMs: 20000);
    expect(meter.cycleWatchMs, 0); // 10s > 6s jump cap
    var position = 0;
    now = 0;
    start();
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    for (var i = 0; i < 10; i++) {
      position += 2000;
      advance(clockMs: 1000, positionMs: position);
    }
    expect(meter.cycleWatchMs, 10000);
  });

  test('pause buffering and seek do not count', () {
    start();
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    advance(clockMs: 1000, positionMs: 1000);
    transport(playing: false);
    advance(clockMs: 5000, positionMs: 1000);
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 1000, nowMs: now);
    transport(buffering: true);
    advance(clockMs: 4000, positionMs: 5000);
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 5000, nowMs: now);
    meter.beginSeek();
    now += 1000;
    meter.endSeek(positionMs: 20000, nowMs: now);
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 20000, nowMs: now);
    advance(clockMs: 1000, positionMs: 21000);
    expect(meter.cycleWatchMs, 2000);
  });

  test('clock jumps are discarded', () {
    start();
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    advance(clockMs: 60000, positionMs: 1000);
    expect(meter.cycleWatchMs, 0);
  });

  test('stale A callbacks are ignored after switching to B', () {
    start(id: 'a');
    transport();
    final aCycle = meter.cycleId;
    meter.sample(mediaId: 'a', cycleId: aCycle, positionMs: 0, nowMs: now);
    advance(clockMs: 1000, positionMs: 1000);
    start(id: 'b');
    transport();
    meter.sample(mediaId: 'a', cycleId: aCycle, positionMs: 5000, nowMs: now + 1000);
    expect(meter.mediaId, 'b');
    expect(meter.cycleWatchMs, 0);
  });

  test('confirmed complete is separate from a seek near the end', () {
    start(durationMs: 60000);
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    meter.beginSeek();
    now += 50;
    meter.endSeek(positionMs: 59900, nowMs: now);
    expect(meter.completedThisCycle, isFalse);
    final flush = meter.onConfirmedComplete(nowMs: now);
    expect(flush.completed, isTrue);
    expect(meter.completedThisCycle, isTrue);
  });

  test('rewatch clears completed only after the threshold', () {
    start(completed: true, durationMs: 200000);
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    var position = 0;
    for (var i = 0; i < 29; i++) {
      position += 1000;
      advance(clockMs: 1000, positionMs: position);
    }
    expect(meter.flush(nowMs: now).uncomplete, isFalse);
    advance(clockMs: 1000, positionMs: position + 1000);
    expect(meter.flush(nowMs: now).uncomplete, isTrue);
  });

  test('hide in the same cycle stays hidden; a new user cycle can unhide', () {
    start(hidden: false, userInitiated: true);
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    meter.noteHidden();
    var position = 0;
    for (var i = 0; i < 30; i++) {
      position += 1000;
      advance(clockMs: 1000, positionMs: position);
    }
    expect(meter.flush(nowMs: now).unhide, isFalse);

    start(hidden: true, userInitiated: true);
    transport();
    meter.sample(mediaId: 'a', cycleId: meter.cycleId, positionMs: 0, nowMs: now);
    position = 0;
    for (var i = 0; i < 30; i++) {
      position += 1000;
      advance(clockMs: 1000, positionMs: position);
    }
    expect(meter.flush(nowMs: now).unhide, isTrue);
  });
}
