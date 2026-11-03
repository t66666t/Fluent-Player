import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/device_resource_platform.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/inference_tuning.dart';

class _TimedSession extends InferenceResourceSession {
  _TimedSession(super.governor);
  Duration productive = const Duration(seconds: 100);
  @override
  Duration get productiveTime => productive;
}

void main() {
  var time = DateTime.utc(2026, 10, 20);
  DeviceResourceSnapshot sample({
    int cores = 8,
    String platform = 'android',
    int? allowed,
    int? physical,
    bool known = true,
    bool playing = false,
    bool interacting = false,
    bool saving = false,
    ResourceThermalState thermal = ResourceThermalState.normal,
    ResourceMemoryPressure pressure = ResourceMemoryPressure.normal,
    int window = 0,
    double slow = 0,
    bool complete = true,
  }) => DeviceResourceSnapshot(
    platform: platform,
    processors: cores,
    allowedProcessors: allowed,
    physicalProcessors: physical,
    memoryBytes: known ? 16 * 1073741824 : null,
    availableMemoryBytes: known ? 12 * 1073741824 : null,
    capturedAt: time,
    playing: playing,
    interacting: interacting,
    powerSaving: saving,
    thermal: thermal,
    thermalSupported: true,
    memoryPressure: pressure,
    frameCount: 120,
    frameWindow: window,
    slowFrameFraction: slow,
    workerMemoryComplete: complete,
  );
  setUp(() => time = DateTime.utc(2026, 10, 20));
  test(
    'heavy alignment gets bounded CPU threads and excludes ASR/translation',
    () async {
      final session = InferenceResourceSession(
        InferenceResourceGovernor(
          sample(platform: 'windows', cores: 16),
          now: () => time,
        ),
      );
      final asr = await session.acquire(
        InferenceLane.recognition,
        requested: 4,
      );
      var entered = false;
      final waiting = session
          .acquire(InferenceLane.alignment, requested: 6)
          .then((p) {
            entered = true;
            return p;
          });
      await Future<void>.delayed(Duration.zero);
      expect(entered, isFalse);
      asr.release();
      final alignment = await waiting;
      expect(alignment.threads, 6);
      var translated = false;
      final translation = session.acquire(InferenceLane.translation).then((p) {
        translated = true;
        return p;
      });
      await Future<void>.delayed(Duration.zero);
      expect(translated, isFalse);
      alignment.release();
      (await translation).release();
      session.asrMaximum = 2;
      final limited = await session.acquire(
        InferenceLane.alignment,
        requested: 6,
      );
      expect(limited.threads, 2);
      limited.release();
      session.governor.update(
        sample(
          platform: 'windows',
          cores: 16,
          pressure: ResourceMemoryPressure.critical,
        ),
      );
      final protective = await session.acquire(
        InferenceLane.alignment,
        requested: 6,
      );
      expect(protective.threads, 1);
      protective.release();
      await session.close();
    },
  );
  testWidgets('OCR paces rapid frame checks while retaining protective caps', (
    tester,
  ) async {
    final governor = InferenceResourceGovernor(
      sample(pressure: ResourceMemoryPressure.warning),
      now: () => time,
    );
    final session = InferenceResourceSession(governor);
    var launches = 0;
    final permits = <InferenceComputePermit>[];
    Future<void> frame() => session.run(InferenceLane.ocr, (permit) async {
      permits.add(permit);
      launches++;
    }, minimumYieldInterval: const Duration(milliseconds: 250));
    final first = frame();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 149));
    expect(launches, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await first;
    expect(launches, 1);
    for (var i = 0; i < 10; i++) {
      time = time.add(const Duration(milliseconds: 5));
      await frame();
    }
    expect(launches, 11);
    time = time.add(const Duration(milliseconds: 200));
    governor.update(sample(pressure: ResourceMemoryPressure.warning));
    final paced = frame();
    await tester.pump();
    expect(launches, 11);
    await tester.pump(const Duration(milliseconds: 150));
    await paced;
    expect(launches, 12);
    expect(permits.every((permit) => permit.threads == 1), isTrue);
    expect(permits.every((permit) => !permit.decision.pipeline), isTrue);
    expect(session.activeThreads, 0);
    await session.close();
  });

  test('limiter text distinguishes power saving from recovery', () {
    final governor = InferenceResourceGovernor(
      sample(saving: true),
      now: () => time,
    );
    expect(governor.decide().reason, contains('省电模式'));
    governor.update(sample());
    expect(governor.decide().reason, contains('逐步恢复'));
    governor.update(sample(pressure: ResourceMemoryPressure.warning));
    expect(governor.decide().reason, contains('内存余量不足'));
    // A protective cap can remain latched while a weaker pressure is still
    // present. That is not a healthy recovery window yet.
    governor.update(sample(thermal: ResourceThermalState.moderate));
    expect(governor.decide().reason, contains('设备发热'));
    governor.update(sample(saving: true));
    expect(governor.decide().reason, contains('省电模式'));
    governor.update(sample(window: 1, slow: .15));
    governor.update(sample(window: 2, slow: .15));
    expect(governor.decide().reason, contains('持续掉帧'));
  });
  for (final platform in ['android', 'windows']) {
    test(
      'interaction preserves native configurations and manual caps on $platform',
      () {
        final governor = InferenceResourceGovernor(
          sample(cores: 16, platform: platform),
          now: () => time,
        );
        final normal = governor.decide();
        governor.update(
          sample(cores: 16, platform: platform, interacting: true),
        );
        final reading = governor.decide(asrMaximum: 1, translationMaximum: 1);
        expect(reading.totalThreads, normal.totalThreads);
        expect(reading.asrThreads, 1);
        expect(reading.translationThreads, 1);
        expect(reading.translationBatchLimit, 2);
        expect(reading.allowTuning, isFalse);
        final automatic = governor.decide();
        expect(automatic.asrThreads, normal.asrThreads);
        expect(automatic.translationThreads, normal.translationThreads);
        expect(automatic.promptThreads, normal.promptThreads);
        expect(automatic.pipeline, normal.pipeline);
        expect(automatic.yieldDuration, const Duration(milliseconds: 16));
        governor.update(sample(cores: 16, platform: platform));
        expect(governor.decide().totalThreads, normal.totalThreads);
        expect(governor.decide().yieldDuration, Duration.zero);
      },
    );
  }

  test(
    'reading serializes grants without resizing or revoking native work',
    () async {
      final governor = InferenceResourceGovernor(sample(), now: () => time);
      final session = InferenceResourceSession(governor);
      final running = await session.acquire(
        InferenceLane.recognition,
        requested: 4,
      );
      governor.update(sample(interacting: true));
      var admitted = false;
      final queued = session.acquire(InferenceLane.auxiliary).then((value) {
        admitted = true;
        return value;
      });
      await Future<void>.value();
      expect(admitted, isFalse);
      expect(session.activeThreads, running.threads);
      running.release();
      final next = await queued;
      expect(next.threads, 1);
      next.release();
      await session.close();
    },
  );
  testWidgets('reading leaves a frame before launching the next native batch', (
    tester,
  ) async {
    final governor = InferenceResourceGovernor(
      sample(interacting: true),
      now: () => time,
    );
    final session = InferenceResourceSession(governor);
    var launched = false;
    final work = session.run(InferenceLane.recognition, (_) async {
      launched = true;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 15));
    expect(launched, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(launched, isTrue);
    await work;
    expect(session.activeThreads, 0);
    await session.close();
  });

  testWidgets('cancelling a deferred native launch releases its permit', (
    tester,
  ) async {
    final session = InferenceResourceSession(
      InferenceResourceGovernor(sample(interacting: true), now: () => time),
    );
    final cancel = Completer<void>();
    var launched = false;
    final work = session.run(
      InferenceLane.recognition,
      (_) async => launched = true,
      cancelSignal: cancel.future,
    );
    final outcome = expectLater(work, throwsStateError);
    await tester.pump();
    cancel.complete();
    await tester.pump();
    await outcome;
    expect(launched, isFalse);
    expect(session.activeThreads, 0);
    await tester.pump(const Duration(milliseconds: 16));
    expect(launched, isFalse);
    await session.close();
  });
  for (final platform in ['android', 'ios', 'windows', 'macos', 'linux']) {
    test('$platform budgets reserve cores and bound initial threads', () {
      final mobile = platform == 'android' || platform == 'ios';
      for (final cores in [1, 2, 4, 8, 16, 32]) {
        final governor = InferenceResourceGovernor(
          sample(cores: cores, platform: platform),
          now: () => time,
        );
        final d = governor.decide();
        final expected = (cores - (cores / 4).ceil()).clamp(1, mobile ? 6 : 12);
        expect(d.totalThreads, expected);
        expect(d.asrThreads, expected - (d.pipeline ? 1 : 0));
        expect(
          d.asrThreads + (d.pipeline ? d.auxiliaryThreads : 0),
          lessThanOrEqualTo(d.totalThreads),
        );
        final manual = governor.decide(asrMaximum: 2, translationMaximum: 1);
        expect(manual.asrThreads, lessThanOrEqualTo(2));
        expect(manual.promptThreads, 1);
        expect(manual.translationThreads, 1);
      }
    });
  }
  test('physical cores, affinity and quota bound effective CPU', () {
    expect(
      InferenceResourceGovernor(
        sample(cores: 32, physical: 16, allowed: 4),
        now: () => time,
      ).decide().totalThreads,
      3,
    );
    expect(
      InferenceResourceGovernor(
        sample(allowed: 1),
        now: () => time,
      ).decide().totalThreads,
      1,
    );
  });
  test(
    'two threads overlap different owners and no auxiliary stage reserves nothing',
    () async {
      final g = InferenceResourceGovernor(sample(cores: 3), now: () => time);
      final updates = <InferenceBudgetDecision>[];
      final s = InferenceResourceSession(g, onBudget: updates.add);
      expect(s.decision.pipelineCapacity, 2);
      final primary = await s.acquire(InferenceLane.recognition);
      final helper = await s.acquire(InferenceLane.auxiliary);
      expect(primary.threads, 1);
      expect(helper.threads, 1);
      expect(s.activeThreads, 2);
      expect(updates.last.activeAsrThreads, 1);
      expect(updates.last.activeAuxiliaryThreads, 1);
      primary.release();
      helper.release();
      expect(updates.last.activeAsrThreads, 0);
      await s.close();
      final full = InferenceResourceGovernor(sample(), now: () => time);
      expect(full.decide(pipelineRequested: false).asrThreads, 6);
      expect(full.decide(pipelineRequested: false).allowAudioPrefetch, isTrue);
      expect(
        InferenceResourceGovernor(
          sample(known: false),
          now: () => time,
        ).decide().allowAudioPrefetch,
        isFalse,
      );
      expect(
        InferenceResourceGovernor(
          sample(saving: true),
          now: () => time,
        ).decide().pipeline,
        isTrue,
      );
    },
  );
  test(
    'a memory handoff narrows the live pipeline and recovers without recreating the session',
    () async {
      final g = InferenceResourceGovernor(sample(), now: () => time);
      final s = InferenceResourceSession(g);
      final active = await s.acquire(InferenceLane.recognition);
      s.limitPipelineForMemory();
      expect(s.decision.reasonCode, InferenceLimitReason.memory);
      expect(s.decision.pipelineRequested, isTrue);
      expect(s.decision.pipelineCapacity, 1);
      expect(s.activeThreads, active.threads);
      var helperStarted = false;
      final helper = s.run(InferenceLane.auxiliary, (_) async {
        helperStarted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(helperStarted, isFalse);
      active.release();
      await helper;
      for (var i = 0; i < 14; i++) {
        time = time.add(const Duration(seconds: 2));
        g.update(sample());
      }
      expect(s.decision.pipelineCapacity, 1);
      time = time.add(const Duration(seconds: 2));
      g.update(sample());
      expect(s.decision.pipelineCapacity, 2);
      expect(s.decision.reasonCode, InferenceLimitReason.none);
      await s.close();
    },
  );
  test(
    'alternate model residency is scoped to its phase and does not lock the workflow serial',
    () async {
      final g = InferenceResourceGovernor(sample(), now: () => time);
      final s = InferenceResourceSession(g);
      await s.memoryHandoff(() async {
        expect(s.decision.pipelineCapacity, 1);
        expect(s.decision.reasonCode, InferenceLimitReason.memory);
        await s.run(InferenceLane.auxiliary, (_) async {});
      });
      expect(s.decision.pipelineCapacity, 2);
      final active = await s.acquire(InferenceLane.recognition);
      await expectLater(s.memoryHandoff(() async {}), throwsStateError);
      active.release();
      await expectLater(
        s.memoryHandoff(() async {
          throw StateError('native failed');
        }),
        throwsStateError,
      );
      expect(s.decision.pipelineCapacity, 2);
      s.limitPipelineForMemory();
      time = time.add(const Duration(seconds: 31));
      g.update(sample());
      expect(
        s.decision.pipelineCapacity,
        1,
        reason: 'a gap in samples is not thirty seconds of health',
      );
      for (var i = 0; i < 15; i++) {
        time = time.add(const Duration(seconds: 2));
        g.update(sample());
      }
      expect(s.decision.pipelineCapacity, 2);
      await s.close();
    },
  );
  test('lost signals reset a partially completed recovery window', () {
    final g = InferenceResourceGovernor(sample(playing: true), now: () => time);
    expect(g.decide().totalThreads, 4);
    time = time.add(const Duration(seconds: 2));
    g.update(sample());
    time = time.add(const Duration(seconds: 18));
    g.update(sample(known: false));
    time = time.add(const Duration(seconds: 20));
    g.update(sample());
    expect(g.decide().totalThreads, 2);
    for (var i = 0; i < 15; i++) {
      time = time.add(const Duration(seconds: 2));
      g.update(sample());
    }
    expect(g.decide().totalThreads, 6);
  });
  test('unknown/stale signals serialize and disable exploration', () {
    final g = InferenceResourceGovernor(sample(known: false), now: () => time);
    expect(g.decide().totalThreads, 2);
    expect(g.decide().pipeline, isFalse);
    expect(g.decide().allowTuning, isFalse);
    g.update(sample());
    expect(g.decide().totalThreads, 2);
    for (var i = 0; i < 15; i++) {
      time = time.add(const Duration(seconds: 2));
      g.update(sample());
    }
    expect(g.decide().totalThreads, 6);
    time = time.add(const Duration(seconds: 9));
    expect(g.decide().allowTuning, isFalse);
    expect(g.decide().totalThreads, 2);
  });
  test('two frame windows, immediate pressure and staged 30s recovery', () {
    final g = InferenceResourceGovernor(sample(), now: () => time);
    g.update(sample(window: 1, slow: .15));
    expect(g.decide().level, InferencePressureLevel.normal);
    g.update(sample(window: 1, slow: .15));
    expect(g.decide().level, InferencePressureLevel.normal);
    g.update(sample(window: 2, slow: .15));
    expect(g.decide().totalThreads, 3);
    expect(g.decide().translationBatchLimit, 4);
    g.update(sample(window: 3, slow: .3));
    g.update(sample(window: 4, slow: .3));
    expect(g.decide().totalThreads, 1);
    expect(g.decide().translationBatchLimit, 1);
    for (var i = 0; i < 31; i++) {
      time = time.add(const Duration(seconds: 2));
      g.update(sample(window: 5 + i));
    }
    expect(g.decide().level, InferencePressureLevel.normal);
    g.update(sample(pressure: ResourceMemoryPressure.warning));
    expect(g.decide().totalThreads, 1);
    expect(g.decide().retainModels, isFalse);
  });
  test(
    'playing intent, warmth, powersave and missing child metrics prevent tuning',
    () {
      for (final s in [
        sample(playing: true),
        sample(saving: true),
        sample(thermal: ResourceThermalState.warm),
        sample(complete: false),
      ]) {
        expect(
          InferenceResourceGovernor(s, now: () => time).decide().allowTuning,
          isFalse,
        );
      }
      expect(
        InferenceResourceGovernor(
          sample(playing: true),
          now: () => time,
        ).decide().totalThreads,
        4,
      );
      expect(
        InferenceResourceGovernor(
          sample(saving: true),
          now: () => time,
        ).decide().totalThreads,
        3,
      );
    },
  );
  test(
    'one budget is shared; translation drains both lanes and cancellation owns no permit',
    () async {
      final s = InferenceResourceSession(
        InferenceResourceGovernor(sample(), now: () => time),
      );
      final asr = await s.acquire(InferenceLane.recognition);
      final aux = await s.acquire(InferenceLane.auxiliary);
      expect(s.activeThreads, 6);
      var translated = false;
      final translate = s.run(InferenceLane.translation, (_) async {
        translated = true;
        expect(s.activeThreads, 6);
      });
      final cancel = Completer<void>();
      final waiting = s.acquire(
        InferenceLane.recognition,
        cancelSignal: cancel.future,
      );
      final failed = expectLater(waiting, throwsStateError);
      cancel.complete();
      await failed;
      expect(translated, isFalse);
      asr.release();
      asr.release();
      await Future<void>.delayed(Duration.zero);
      expect(translated, isFalse);
      aux.release();
      await translate;
      expect(s.activeThreads, 0);
      await s.close();
    },
  );
  test(
    'pressure changes wait for native boundary, never revoke an active owner',
    () async {
      final g = InferenceResourceGovernor(sample(), now: () => time);
      final s = InferenceResourceSession(g);
      final asr = await s.acquire(InferenceLane.recognition);
      g.update(sample(thermal: ResourceThermalState.severe));
      var ran = false;
      final next = s.run(InferenceLane.auxiliary, (p) async {
        ran = true;
        expect(p.threads, 1);
      });
      await Future<void>.delayed(Duration.zero);
      expect(ran, isFalse);
      expect(s.activeThreads, asr.threads);
      asr.release();
      await next;
      await s.close();
    },
  );
  test(
    'allocation tickets prevent parallel peak oversubscription and release idempotently',
    () async {
      final s = InferenceResourceSession(
        InferenceResourceGovernor(sample(), now: () => time),
      );
      final p = await s.acquire(InferenceLane.auxiliary);
      await s.checkAllocation(8 * 1073741824, permit: p);
      await expectLater(s.checkAllocation(4 * 1073741824), throwsStateError);
      p.release();
      p.release();
      await s.checkAllocation(8 * 1073741824);
      await s.close();
    },
  );
  test(
    'tuning requires two valid pairs, 10% net gain and persists no samples',
    () async {
      final s = InferenceResourceSession(
        InferenceResourceGovernor(sample(), now: () => time),
      );
      final records = <String, Map<String, dynamic>>{};
      final tuner = InferenceTuner(
        session: s,
        records: records,
        modelId: 'm',
        signature: 'k',
        save: () async {},
        now: () => time,
      );
      var probes = 0;
      Future<InferenceProbeResult> probe(int threads) async {
        probes++;
        return const InferenceProbeResult(
          baselineMs: 1000,
          candidateMs: 700,
          costMs: 1700,
          valid: true,
        );
      }

      expect(
        await tuner.explore(
          baseline: 2,
          maximum: 6,
          estimatedCostMs: 1700,
          remainingProductiveMs: 20000,
          probe: probe,
        ),
        isNull,
      );
      expect(probes, 0);
      expect(
        await tuner.explore(
          baseline: 2,
          maximum: 6,
          estimatedCostMs: 1700,
          remainingProductiveMs: 20000,
          probe: probe,
          manual: true,
        ),
        isNull,
      );
      expect(
        await tuner.explore(
          baseline: 2,
          maximum: 6,
          estimatedCostMs: 1700,
          remainingProductiveMs: 20000,
          probe: probe,
          manual: true,
        ),
        4,
      );
      expect(tuner.preferredThreads, 4);
      expect(tuner.dailySpentMs, 0);
      time = time.add(const Duration(days: 15));
      expect(tuner.preferredThreads, isNull);
      await s.close();
    },
  );
  test('CPU lists and fractional quotas are parsed defensively', () {
    expect(countCpuList('0-3,6,8-9'), 7);
    expect(countCpuList('0-3,2-4'), 5);
    expect(countCpuList('invalid'), 0);
    expect(cpuQuota('150000 100000'), 2);
    expect(cpuQuota('max 100000'), isNull);
    expect(countProcessorMask(-1), 64);
    expect(countProcessorMask(1 << 63), 1);
  });

  test(
    'automatic experiments share the five percent allowance and account failures',
    () async {
      final g = InferenceResourceGovernor(sample(), now: () => time);
      final s = _TimedSession(g);
      final records = <String, Map<String, dynamic>>{};
      final tuner = InferenceTuner(
        session: s,
        records: records,
        modelId: 'm',
        signature: 'a',
        save: () async {},
        now: () => time,
      );
      var attempts = 0;
      Future<InferenceProbeResult> probe(int _) async {
        attempts++;
        throw StateError('cancelled probe');
      }

      expect(
        await tuner.explore(
          baseline: 2,
          maximum: 6,
          estimatedCostMs: 5001,
          remainingProductiveMs: 100000,
          probe: probe,
        ),
        isNull,
      );
      expect(attempts, 0);
      await expectLater(
        tuner.explore(
          baseline: 2,
          maximum: 6,
          estimatedCostMs: 5000,
          remainingProductiveMs: 100000,
          probe: probe,
        ),
        throwsStateError,
      );
      expect(tuner.dailySpentMs, 5000);
      final other = InferenceTuner(
        session: s,
        records: records,
        modelId: 'other',
        signature: 'b',
        save: () async {},
        now: () => time,
      );
      expect(other.automaticCreditMs, 0);
      s.productive = const Duration(hours: 1);
      records['m:earlier'] = {
        'model': 'm',
        'day': '2026-10-20',
        'spentMs': 25000,
      };
      expect(tuner.automaticCreditMs, 0);
      await s.close();
    },
  );

  test(
    'Linux honors SMT affinity, ancestor quotas, pressure and child accounting',
    () async {
      final temp = await Directory.systemTemp.createTemp('resource-proc-');
      Future<void> write(String path, String value) async {
        final file = File('${temp.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsString(value);
      }

      try {
        await write(
          'proc/meminfo',
          'MemTotal: 16777216 kB\nMemAvailable: 8388608 kB\n',
        );
        await write(
          'proc/self/status',
          'Cpus_allowed_list: 0-3\nVmRSS: 1024 kB\n',
        );
        await write('proc/self/cgroup', '0::/parent/leaf\n');
        await write(
          'proc/cpuinfo',
          [
            for (var i = 0; i < 8; i++)
              'processor: $i\nphysical id: 0\ncore id: ${i ~/ 2}',
          ].join('\n\n'),
        );
        await write('cgroup/parent/leaf/cpu.max', 'max 100000');
        await write('cgroup/parent/cpu.max', '150000 100000');
        await write('cgroup/parent/memory.max', '${4 * 1073741824}');
        await write('cgroup/parent/memory.current', '${1073741824}');
        await write(
          'cgroup/parent/memory.pressure',
          'full avg10=11.50 avg60=3.00 total=10',
        );
        await write('proc/77/status', 'VmRSS: 2048 kB\n');
        final snapshot = await LinuxResourceProbe(
          procRoot: '${temp.path}/proc',
          cgroupRoot: '${temp.path}/cgroup',
        ).read([77, 88]);
        expect(snapshot.allowedProcessors, 2);
        expect(snapshot.physicalProcessors, 2);
        expect(snapshot.availableMemoryBytes, 3 * 1073741824);
        expect(snapshot.memoryBytes, 4 * 1073741824);
        expect(snapshot.workerBytes, 2048 * 1024);
        expect(snapshot.workerMemoryComplete, isFalse);
        expect(snapshot.memoryPressure, ResourceMemoryPressure.warning);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
  test(
    'Windows reads its own memory/topology and releases notification handle',
    () async {
      if (!Platform.isWindows) return;
      final probe = WindowsResourceProbe();
      await probe.start();
      try {
        final s = await probe.read([]);
        expect(s.memoryKnown, isTrue);
        expect(s.processBytes, greaterThan(0));
        expect(
          s.effectiveProcessors,
          inInclusiveRange(1, Platform.numberOfProcessors),
        );
      } finally {
        await probe.close();
      }
    },
  );
}
