import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/ui_interaction_budget.dart';
import 'package:video_player_app/widgets/player_sidebar_motion.dart';
import 'package:video_player_app/widgets/sidebar_activity.dart';

void main() {
  testWidgets(
    'pointer and inertial scrolling keep headroom until hidden or settled',
    (tester) async {
      var active = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) {
                update = set;
                return SidebarActivity(
                  active: active,
                  child: SidebarInteractionRegion(
                    child: ListView.builder(
                      itemCount: 200,
                      itemBuilder: (_, index) =>
                          SizedBox(height: 48, child: Text('row $index')),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final pointer = await tester.startGesture(const Offset(100, 200));
      await tester.pump();
      expect(UiInteractionBudget.instance.isActive, isTrue);
      update(() => active = false);
      await tester.pump();
      expect(UiInteractionBudget.instance.isActive, isFalse);
      await pointer.cancel();
      update(() => active = true);
      await tester.pump();
      await tester.fling(find.byType(ListView), const Offset(0, -250), 1200);
      await tester.pump();
      expect(UiInteractionBudget.instance.isActive, isTrue);
      await tester.pumpAndSettle();
      expect(UiInteractionBudget.instance.isActive, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'shared clock retargets displayed geometry and releases its budget',
    (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(MaterialApp(home: _Host(key: key)));
      final host = key.currentState!;
      host.open('a', 300);
      await tester.pump();
      expect(UiInteractionBudget.instance.isActive, isTrue);
      await tester.pump(const Duration(milliseconds: 60));
      final extent = host.motion.extent.value;
      final opacity = host.motion.opacityFor('a').value;
      expect(extent / 300, closeTo(opacity, 1e-8));
      host.open('b', 420);
      await tester.pump();
      expect(host.motion.extent.value, extent);
      expect(host.motion.opacityFor('a').value, opacity);
      var settled = false;
      host.motion.whenSettled().then((_) => settled = true);
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 8));
        final before = host.motion.extent.value;
        host.open(i.isEven ? 'a' : 'b', i.isEven ? 300 : 420);
        await tester.pump();
        expect(host.motion.extent.value, closeTo(before, 1e-8));
      }
      await tester.pumpAndSettle();
      expect(host.motion.extent.value, 420);
      expect(host.motion.opacityFor('b').value, 1);
      expect(host.motion.opacityFor('a').value, 0);
      expect(settled, isTrue);
      expect(UiInteractionBudget.instance.isActive, isFalse);
      host.open(null, 0);
      await tester.pump();
      // configure starts during build; present the first vsync before
      // advancing the rest of the transition in one test step.
      await tester.pump(const Duration(milliseconds: 8));
      await tester.pump(const Duration(milliseconds: 160));
      expect(host.motion.extent.value, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'backgrounding and disposal release pending work and interaction',
    (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(MaterialApp(home: _Host(key: key)));
      final host = key.currentState!;
      host.open('a', 300);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(host.motion.extent.value, 300);
      expect(UiInteractionBudget.instance.isActive, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      host.open('b', 400);
      await tester.pump();
      final waiting = host.motion.whenSettled();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(await waiting, isFalse);
      await tester.pump();
      expect(UiInteractionBudget.instance.isActive, isFalse);
    },
  );

  testWidgets('hidden visual selectors detach and catch up once on entry', (
    tester,
  ) async {
    final value = ValueNotifier((form: 0, progress: 0));
    addTearDown(value.dispose);
    var active = true, reads = 0, builds = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, set) {
            update = set;
            return SidebarActivity(
              active: active,
              child: SidebarValueBuilder<int>(
                listenable: value,
                select: () {
                  reads++;
                  return value.value.form;
                },
                builder: (_, form, _) {
                  builds++;
                  return Text('$form');
                },
              ),
            );
          },
        ),
      ),
    );
    final initial = builds;
    for (var i = 0; i < 120; i++) {
      value.value = (form: 0, progress: i);
    }
    await tester.pump();
    expect(builds, initial);
    update(() => active = false);
    await tester.pump();
    reads = 0;
    for (var i = 0; i < 120; i++) {
      value.value = (form: i, progress: i);
    }
    await tester.pump();
    expect(reads, 0);
    update(() => active = true);
    await tester.pump();
    expect(find.text('119'), findsOneWidget);
    expect(reads, 1);
  });
}

class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final motion = PlayerSidebarMotion(vsync: this);
  String? panel;
  double extent = 0;
  void open(String? id, double width) => setState(() {
    panel = id;
    extent = width;
  });
  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    motion.configure(
      target: panel,
      dockExtent: extent,
      visibleSurfaces: {?panel},
    );
    motion.opacityFor('a');
    motion.opacityFor('b');
    return AnimatedBuilder(
      animation: motion.extent,
      builder: (_, _) => SizedBox(width: motion.extent.value),
    );
  }
}
