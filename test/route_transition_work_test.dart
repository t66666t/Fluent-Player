import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/playback_page_route.dart';
import 'package:video_player_app/utils/route_transition_work.dart';

class _Page extends StatefulWidget {
  const _Page({required this.work, super.key});

  final VoidCallback work;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final tasks = RouteTransitionWork();

  @override
  void initState() {
    super.initState();
    tasks.schedule('initial', widget.work);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    tasks.bind(ModalRoute.of(context));
  }

  @override
  void dispose() {
    tasks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('player'));
}

Future<GlobalKey<NavigatorState>> _host(WidgetTester tester) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
      home: const Scaffold(body: Text('library')),
    ),
  );
  return navigator;
}

void main() {
  testWidgets('work host resumes after a popup without rebuilding its page', (
    tester,
  ) async {
    final navigator = await _host(tester);
    final work = RouteTransitionWork();
    addTearDown(work.dispose);
    var builds = 0, runs = 0;
    navigator.currentState!.push(
      AppMaterialPageRoute<void>(
        builder: (_) => RouteTransitionWorkHost(
          work: work,
          child: Builder(
            builder: (_) {
              builds++;
              return const Scaffold(body: Text('retained content'));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = builds;
    navigator.currentState!.push(
      DialogRoute<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('popup')),
      ),
    );
    await tester.pumpAndSettle();
    work.schedule('after-popup', () => runs++);
    await tester.pump();
    expect(runs, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(runs, 1);
    expect(
      builds,
      before,
      reason: 'only the small route host may subscribe to navigator changes',
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'work waits for the entry final frame, including a paused player',
    (tester) async {
      final navigator = await _host(tester);
      var runs = 0;
      final route = PlaybackPageRoute<void>(
        builder: (_) => _Page(work: () => runs++),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(runs, 0);
      await tester.pumpAndSettle();
      expect(route.animation!.isCompleted, isTrue);
      expect(runs, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pump(const Duration(seconds: 20));
      expect(runs, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('an exit during entry abandons optional work', (tester) async {
    final navigator = await _host(tester);
    var runs = 0;
    navigator.currentState!.push(
      PlaybackPageRoute<void>(builder: (_) => _Page(work: () => runs++)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(runs, 0);
    expect(find.text('library'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'covered work resumes only when the covering return has finished',
    (tester) async {
      final navigator = await _host(tester);
      var runs = 0;
      final key = GlobalKey<_PageState>();
      navigator.currentState!.push(
        PlaybackPageRoute<void>(
          builder: (_) => _Page(key: key, work: () => runs++),
        ),
      );
      await tester.pumpAndSettle();
      expect(runs, 1);
      navigator.currentState!.push(
        AppMaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('settings')),
        ),
      );
      await tester.pump();
      key.currentState!.tasks.schedule('later', () => runs++);
      await tester.pumpAndSettle();
      expect(runs, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(runs, 1);
      await tester.pumpAndSettle();
      expect(runs, 2);
    },
  );

  testWidgets('only the latest item work for a key runs after entry', (
    tester,
  ) async {
    final navigator = await _host(tester);
    final key = GlobalKey<_PageState>();
    final runs = <int>[];
    navigator.currentState!.push(
      PlaybackPageRoute<void>(
        builder: (_) => _Page(key: key, work: () => runs.add(0)),
      ),
    );
    await tester.pump();
    key.currentState!.tasks.schedule('item', () => runs.add(1));
    key.currentState!.tasks.schedule('item', () => runs.add(2));
    await tester.pumpAndSettle();
    expect(runs, [0, 2]);
  });

  testWidgets(
    'an explicit action can cancel older automatic UI without dropping other work',
    (tester) async {
      final navigator = await _host(tester);
      final key = GlobalKey<_PageState>();
      var runs = 0;
      navigator.currentState!.push(
        PlaybackPageRoute<void>(
          builder: (_) => _Page(key: key, work: () {}),
        ),
      );
      await tester.pump();
      key.currentState!.tasks.schedule('old-navigation', () => runs += 100);
      key.currentState!.tasks.schedule('metadata', () => runs++);
      key.currentState!.tasks.cancel('old-navigation');
      await tester.pumpAndSettle();
      expect(runs, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposal cancels an already scheduled batch', (tester) async {
    await tester.pumpWidget(const SizedBox());
    var runs = 0;
    final tasks = RouteTransitionWork()..schedule('cancelled', () => runs++);
    tasks.dispose();
    tasks.dispose();
    await tester.pump();
    tasks.schedule('disposed', () => runs++);
    tasks.bind(null);
    await tester.pump();
    expect(runs, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a batch stops if a callback removes its page', (tester) async {
    final navigator = await _host(tester);
    final key = GlobalKey<_PageState>();
    var runs = 0;
    navigator.currentState!.push(
      PlaybackPageRoute<void>(
        builder: (_) => _Page(key: key, work: () {}),
      ),
    );
    await tester.pumpAndSettle();
    key.currentState!.tasks.schedule(
      'leave',
      () => navigator.currentState!.pop(),
    );
    key.currentState!.tasks.schedule('obsolete', () => runs++);
    await tester.pumpAndSettle();
    expect(runs, 0);
    expect(find.text('library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
