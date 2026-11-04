import 'dart:convert';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/debug/music_lyric_frame_probe.dart';

FrameTiming _frame(int uiUs, int rasterUs) => FrameTiming(
  vsyncStart: 0,
  buildStart: 0,
  buildFinish: uiUs,
  rasterStart: uiUs,
  rasterFinish: uiUs + rasterUs,
  rasterFinishWallTime: uiUs + rasterUs,
);

FrameTiming _atFrame(
  int vsync, {
  int uiUs = 1000,
  int rasterUs = 1000,
  int waitUs = 0,
}) => FrameTiming(
  vsyncStart: vsync,
  buildStart: vsync + waitUs,
  buildFinish: vsync + waitUs + uiUs,
  rasterStart: vsync + waitUs + uiUs,
  rasterFinish: vsync + waitUs + uiUs + rasterUs,
  rasterFinishWallTime: vsync + waitUs + uiUs + rasterUs,
);

void main() {
  test('long Android frame reports survive bounded log messages', () {
    final report = <String, Object>{
      'build': List.filled(300, '帧').join(),
      'phases': {
        for (var i = 0; i < 12; i++)
          'phase-$i': {'uiP99Ms': 6.5, 'rasterP99Ms': 9.25, 'frames': 700},
      },
    };
    final lines = musicLyricFrameReportLines(report, id: 'test:1');
    expect(lines.length, greaterThan(1));
    for (var i = 0; i < lines.length; i++) {
      expect(utf8.encode(lines[i]).length, lessThan(900));
      expect(
        lines[i],
        startsWith('[lyric-perf-part] test:1 ${i + 1}/${lines.length} '),
      );
    }
    final payload = lines
        .map((line) => line.split(' ').skip(3).join(' '))
        .join();
    expect(jsonDecode(payload), report);
    expect(musicLyricFrameReportLines({'frames': 10}, id: 'test:2'), [
      '[lyric-perf] {"frames":10}',
    ]);
  });

  testWidgets('probe excludes covered routes and detaches on exit', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final mode = ValueNotifier(
      const TickerModeData(enabled: false, forceFrames: false),
    );
    addTearDown(mode.dispose);
    final probe = MusicLyricFrameProbe();
    var disposed = false;
    addTearDown(() {
      if (!disposed) probe.dispose();
    });
    probe.attach(tester.view, mode);
    final callback = tester.binding.platformDispatcher.onReportTimings!;
    final base =
        tester.binding.currentSystemFrameTimeStamp.inMicroseconds + 1000000;
    final frame = FrameTiming(
      vsyncStart: base,
      buildStart: base + 1000,
      buildFinish: base + 2000,
      rasterStart: base + 2000,
      rasterFinish: base + 4000,
      rasterFinishWallTime: base + 4000,
    );
    callback([frame]);
    expect(probe.samples.sessionFrames, 0);
    mode.value = const TickerModeData(enabled: true, forceFrames: false);
    callback([frame]);
    expect(probe.samples.sessionFrames, 1);
    probe.dispose();
    disposed = true;
    expect(probe.samples.isEmpty, isTrue);
    tester.binding.platformDispatcher.onReportTimings?.call([frame]);
    expect(probe.samples.sessionFrames, 1);
  });

  test('frame budgets follow the refresh rate for each sample', () {
    final samples = MusicLyricFrameSamples();
    samples.add(_frame(1000, 10000), refreshRate: 120);
    samples.add(_frame(1000, 10000), refreshRate: 60);
    samples.add(_frame(5000, 5000), refreshRate: 120);
    final report = samples.snapshot();
    expect(report['overBudgetFrames'], 1);
    expect(report['latencyOverBudgetFrames'], 2);
    expect(report['rasterP95Ms'], 10);
    expect(report['sessionFrames'], 3);
  });

  test(
    'samples are bounded while session worst frames survive window resets',
    () {
      final samples = MusicLyricFrameSamples(capacity: 2);
      samples.add(_frame(2000, 40000), refreshRate: 120);
      samples.add(_frame(1000, 2000), refreshRate: 120);
      samples.add(_frame(1000, 3000), refreshRate: 120);
      expect(samples.snapshot()['sampledFrames'], 2);
      expect(samples.snapshot()['rasterP95Ms'], 3);
      expect(samples.snapshot()['sessionWorstRasterMs'], 40);
      samples.clearWindow();
      expect(samples.isEmpty, isTrue);
      samples.add(_frame(1000, 2000), refreshRate: 60);
      expect(samples.snapshot()['sessionFrames'], 4);
      expect(samples.snapshot()['sessionOverBudgetFrames'], 1);
      expect(samples.snapshot()['sessionWorstRasterMs'], 40);
    },
  );

  test('late scheduling and motion gaps are separate from render cost', () {
    final samples = MusicLyricFrameSamples();
    samples.add(
      _atFrame(0),
      refreshRate: 120,
      motion: true,
      phase: 'autoFollow',
    );
    samples.add(
      _atFrame(8333, waitUs: 10000),
      refreshRate: 120,
      motion: true,
      phase: 'autoFollow',
    );
    samples.add(
      _atFrame(25000),
      refreshRate: 120,
      motion: true,
      phase: 'autoFollow',
      append: true,
    );
    final report = samples.snapshot();
    expect(report['overBudgetFrames'], 0);
    expect(report['lateStartFrames'], 1);
    expect(report['motionGapFrames'], 1);
    expect(report['longestSlowStreak'], 2);
    expect(report['sessionEstimatedMissedMotionFrames'], 1);
    expect(report['vsyncOverheadP99Ms'], 10);
    expect(report['motionIntervalP99Ms'], closeTo(16.667, 0.001));
    final phases = report['phases']! as Map;
    expect((phases['autoFollow'] as Map)['frames'], 3);
    expect((phases['append'] as Map)['frames'], 1);
    samples.clearWindow();
    samples.add(
      _atFrame(41667, rasterUs: 12000),
      refreshRate: 120,
      motion: true,
    );
    expect(samples.snapshot()['sessionLongestSlowStreak'], 3);
  });

  test('idle, covered routes and rate changes do not create motion gaps', () {
    final samples = MusicLyricFrameSamples();
    samples.add(_atFrame(0), refreshRate: 120, motion: true);
    samples.add(_atFrame(1000000), refreshRate: 120);
    samples.add(_atFrame(2000000), refreshRate: 120, motion: true);
    samples.add(_atFrame(2011111), refreshRate: 90, motion: true);
    samples.breakMotionSequence();
    samples.add(_atFrame(3000000), refreshRate: 90, motion: true);
    expect(samples.snapshot()['motionGapFrames'], 0);
    expect(samples.snapshot()['sessionEstimatedMissedMotionFrames'], 0);
  });

  test('P99 and worst frames expose tails hidden by P95 at 90 Hz', () {
    final samples = MusicLyricFrameSamples();
    for (var index = 0; index < 100; index++) {
      samples.add(
        _atFrame(
          index * 11111,
          uiUs: index < 98 ? 1000 : 12000 + (index - 98) * 1000,
        ),
        refreshRate: 90,
      );
    }
    final report = samples.snapshot();
    expect(report['uiP95Ms'], 1);
    expect(report['uiP99Ms'], 12);
    expect(report['uiMaxMs'], 13);
    expect(report['longestSlowStreak'], 2);
  });

  testWidgets('batched timings retain the activity at frame production', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final mode = ValueNotifier(
      const TickerModeData(enabled: true, forceFrames: false),
    );
    addTearDown(mode.dispose);
    var nowUs = 1000000;
    final probe = MusicLyricFrameProbe(timestampUs: () => nowUs);
    addTearDown(probe.dispose);
    probe.attach(tester.view, mode);
    probe.markPhase(MusicLyricFramePhase.autoFollow);
    final first = nowUs;
    nowUs += 30000;
    probe.markPhase(MusicLyricFramePhase.tap);
    final second = nowUs;
    tester.binding.platformDispatcher.onReportTimings!([
      _atFrame(first),
      _atFrame(second),
    ]);
    final phases = probe.samples.snapshot()['phases']! as Map;
    expect((phases['autoFollow'] as Map)['frames'], 1);
    expect((phases['tap'] as Map)['frames'], 1);
  });

  testWidgets(
    'a short covered route is excluded even within one timing batch',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      var nowUs = 1000000;
      final mode = ValueNotifier(
        const TickerModeData(enabled: true, forceFrames: false),
      );
      addTearDown(mode.dispose);
      final probe = MusicLyricFrameProbe(timestampUs: () => nowUs);
      addTearDown(probe.dispose);
      probe.attach(tester.view, mode);
      probe.markPhase(MusicLyricFramePhase.autoFollow);
      final first = nowUs;
      nowUs += 30000;
      mode.value = const TickerModeData(enabled: false, forceFrames: false);
      final hidden = nowUs;
      nowUs += 300000;
      mode.value = const TickerModeData(enabled: true, forceFrames: false);
      tester.binding.platformDispatcher.onReportTimings!([
        _atFrame(first),
        _atFrame(hidden),
        _atFrame(nowUs),
      ]);
      expect(probe.samples.sessionFrames, 2);
      expect(probe.samples.snapshot()['motionGapFrames'], 0);
    },
  );

  testWidgets('an idle pause without engine frames is not reported as jank', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var nowUs = 1000000;
    final mode = ValueNotifier(
      const TickerModeData(enabled: true, forceFrames: false),
    );
    addTearDown(mode.dispose);
    final probe = MusicLyricFrameProbe(timestampUs: () => nowUs);
    addTearDown(probe.dispose);
    probe.attach(tester.view, mode);
    probe.markPhase(MusicLyricFramePhase.autoFollow);
    final first = nowUs;
    nowUs += 30000;
    probe.markPhase(MusicLyricFramePhase.idle);
    nowUs += 1000000;
    probe.markPhase(MusicLyricFramePhase.autoFollow);
    tester.binding.platformDispatcher.onReportTimings!([
      _atFrame(first),
      _atFrame(nowUs),
    ]);
    expect(probe.samples.sessionFrames, 2);
    expect(probe.samples.snapshot()['motionGapFrames'], 0);
  });
}
