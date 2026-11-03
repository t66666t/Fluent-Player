import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/playback_source_viewport.dart';

/// Compare the same lazy grid with and without return protection, on the same
/// native surface. Run in profile mode; no media or thumbnail IO is involved.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native scroll and navigation frame comparison', (tester) async {
    final reports = <Map<String, Object>>[];
    for (var round = 0; round < 3; round++) {
      for (final protected in round.isEven ? [false, true] : [true, false]) {
        final controller = protected
            ? PlaybackScrollController()
            : ScrollController();
        final navigator = GlobalKey<NavigatorState>();
        final gridDelegate = const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisExtent: 160,
        );
        Widget item(BuildContext context, int i) => ColoredBox(
          color: i.isEven ? Colors.blueGrey : Colors.indigo,
          child: Center(child: Text('item $i')),
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [PlaybackRouteObserver()],
            theme: ThemeData(
              pageTransitionsTheme: protected
                  ? appPageTransitionsTheme
                  : const PageTransitionsTheme(
                      builders: {
                        TargetPlatform.windows: ZoomPageTransitionsBuilder(
                          allowEnterRouteSnapshotting: false,
                        ),
                        TargetPlatform.linux: ZoomPageTransitionsBuilder(
                          allowEnterRouteSnapshotting: false,
                        ),
                        TargetPlatform.macOS: ZoomPageTransitionsBuilder(
                          allowEnterRouteSnapshotting: false,
                        ),
                        TargetPlatform.android: ZoomPageTransitionsBuilder(
                          allowEnterRouteSnapshotting: false,
                        ),
                        TargetPlatform.iOS: ZoomPageTransitionsBuilder(
                          allowEnterRouteSnapshotting: false,
                        ),
                      },
                    ),
            ),
            home: Scaffold(
              body: protected
                  ? PlaybackGridView.builder(
                      controller: controller,
                      gridDelegate: gridDelegate,
                      itemCount: 10000,
                      itemKey: (i) => i,
                      itemBuilder: item,
                    )
                  : GridView.builder(
                      controller: controller,
                      gridDelegate: gridDelegate,
                      itemCount: 10000,
                      itemBuilder: item,
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (var frame = 0; frame < 20; frame++) {
          controller.jumpTo(frame * 80.0);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 700)),
        );
        final timings = <FrameTiming>[];
        void collect(List<FrameTiming> batch) => timings.addAll(batch);
        tester.binding.addTimingsCallback(collect);
        for (var frame = 0; frame < 120; frame++) {
          controller.jumpTo((frame % 80) * 110.0);
          await tester.pump(const Duration(milliseconds: 16));
        }
        final navigationMicros = <int>[];
        for (var visit = 0; visit < 6; visit++) {
          var clock = Stopwatch()..start();
          navigator.currentState!.push(
            AppMaterialPageRoute<void>(
              settings: const RouteSettings(name: '/playback/landscape'),
              builder: (_) => const Scaffold(body: Text('player')),
            ),
          );
          await tester.pump();
          navigationMicros.add(clock.elapsedMicroseconds);
          await tester.pumpAndSettle();
          clock = Stopwatch()..start();
          navigator.currentState!.pop();
          await tester.pump();
          navigationMicros.add(clock.elapsedMicroseconds);
          await tester.pumpAndSettle();
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 700)),
        );
        tester.binding.removeTimingsCallback(collect);
        expect(timings, isNotEmpty);
        reports.add({
          'protected': protected,
          'round': round,
          'frames': timings.length,
          'build': _summarize(
            timings.map((t) => t.buildDuration.inMicroseconds),
          ),
          'raster': _summarize(
            timings.map((t) => t.rasterDuration.inMicroseconds),
          ),
          'navigationFirstPump': _summarize(navigationMicros),
          'rssBytes': ProcessInfo.currentRss,
          'retainedSnapshots': PlaybackViewportRegistry.retainedSnapshotCount,
        });
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        expect(PlaybackViewportRegistry.registeredSourceCount, 0);
        expect(tester.takeException(), isNull);
      }
    }
    // The native test log is the report artifact; it includes raw per-round
    // summaries so noisy runs are visible instead of hidden behind an average.
    debugPrint('PLAYBACK_VIEWPORT_PROFILE ${jsonEncode(reports)}');
  });
}

Map<String, int> _summarize(Iterable<int> samples) {
  final sorted = samples.toList()..sort();
  int at(double fraction) => sorted[((sorted.length - 1) * fraction).round()];
  return {'p50Micros': at(.5), 'p95Micros': at(.95), 'p99Micros': at(.99)};
}
