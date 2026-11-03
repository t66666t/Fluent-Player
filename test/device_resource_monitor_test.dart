import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/device_resource_monitor.dart';
import 'package:video_player_app/features/model_center/device_resource_platform.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/utils/ui_interaction_budget.dart';

class _Probe extends ResourcePlatformProbe {
  final events = StreamController<Map<dynamic, dynamic>>.broadcast(sync: true);
  int starts = 0, reads = 0, closes = 0;
  bool fail = false;
  @override
  Stream<Map<dynamic, dynamic>> get urgent => events.stream;
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<DeviceResourceSnapshot> read(List<int> workerPids) async {
    reads++;
    if (fail) throw StateError('old host');
    return DeviceResourceSnapshot(
      platform: 'ios',
      processors: 8,
      memoryBytes: 8 * 1073741824,
      availableMemoryBytes: 6 * 1073741824,
      capturedAt: DateTime.now(),
    );
  }

  @override
  Future<void> close() async {
    closes++;
    await events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'interaction during layout safely updates a sibling budget view',
    (tester) async {
      final monitor = DeviceResourceMonitor(createProbe: _Probe.new);
      final session = (await tester.runAsync(monitor.openSession))!;
      VoidCallback? release;
      try {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                ValueListenableBuilder(
                  valueListenable: monitor.budget,
                  builder: (context, value, _) => Text(value?.reason ?? 'idle'),
                ),
                Builder(
                  builder: (context) {
                    release ??= UiInteractionBudget.instance.acquire();
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
        );
        expect(session.governor.snapshot.interacting, isTrue);
        await tester.pump(Duration.zero);
        expect(tester.takeException(), isNull);
        expect(monitor.budget.value, isNotNull);
        expect(find.text(monitor.budget.value!.reason), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        release?.call();
        await tester.runAsync(session.close);
      }
    },
  );

  test(
    'reading motion reserves headroom immediately and releases without polling',
    () async {
      final probe = _Probe();
      final monitor = DeviceResourceMonitor(createProbe: () => probe);
      final session = await monitor.openSession();
      final normal = session.decision.totalThreads;
      final release = UiInteractionBudget.instance.acquire();
      expect(session.governor.snapshot.interacting, isTrue);
      expect(session.decision.totalThreads, normal);
      expect(session.decision.yieldDuration, const Duration(milliseconds: 16));
      expect(session.decision.translationBatchLimit, 2);
      expect(session.decision.allowTuning, isFalse);
      expect(probe.reads, 1);
      release();
      await Future<void>.value();
      expect(session.governor.snapshot.interacting, isFalse);
      expect(session.decision.totalThreads, normal);
      expect(session.decision.yieldDuration, Duration.zero);
      expect(probe.reads, 1);
      await session.close();
    },
  );
  test(
    'idle recommendations read once without subscribing or keeping a monitor alive',
    () async {
      final probe = _Probe();
      final monitor = DeviceResourceMonitor(createProbe: () => probe);
      final snapshot = await monitor.readOnce();
      expect(snapshot.effectiveProcessors, 8);
      expect(snapshot.memoryKnown, isTrue);
      expect(probe.reads, 1);
      expect(probe.starts, 0);
      expect(probe.closes, 1);
      expect(monitor.activeLeases, 0);
      expect(monitor.budget.value, isNull);
    },
  );
  test(
    'monitor is reference counted and route independent; warnings only reduce resources',
    () async {
      final probe = _Probe();
      final monitor = DeviceResourceMonitor(createProbe: () => probe);
      final first = await monitor.openSession();
      final second = await monitor.openSession();
      expect(probe.starts, 1);
      expect(monitor.activeLeases, 2);
      expect(identical(first.governor, second.governor), isTrue);
      probe.events.add({'memoryPressure': 'critical'});
      expect(first.decision.totalThreads, 1);
      expect(second.decision.translationBatchLimit, 1);
      expect(first.activeThreads, 0);
      await first.close();
      expect(probe.closes, 0);
      await second.close();
      await second.close();
      expect(monitor.activeLeases, 0);
      expect(probe.closes, 1);
      expect(monitor.budget.value, isNull);
    },
  );
  test(
    'older or failing host starts with conservative policy and can be reopened',
    () async {
      final probes = <_Probe>[];
      final monitor = DeviceResourceMonitor(
        createProbe: () {
          final probe = _Probe()..fail = probes.isEmpty;
          probes.add(probe);
          return probe;
        },
      );
      final first = await monitor.openSession();
      expect(first.decision.allowTuning, isFalse);
      expect(first.decision.pipeline, isFalse);
      expect(first.decision.totalThreads, lessThanOrEqualTo(2));
      await first.close();
      final next = await monitor.openSession();
      expect(probes.length, 2);
      expect(next.governor.snapshot.memoryKnown, isTrue);
      monitor.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(next.decision.allowTuning, isFalse);
      await next.close();
    },
  );
}
