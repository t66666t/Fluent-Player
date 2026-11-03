import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_menu.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_scrollbar.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

import 'podcast_channel_scrolling_test.dart' show thumbCenter;

/// Count work at the store boundary without adding instrumentation to the UI.
class _CountingStore extends PodcastStore {
  _CountingStore() : super(sqlite3.openInMemory());

  final reads = <String, int>{};
  final presented = <String>{};

  @override
  Map<String, dynamic>? read(String kind, String id) {
    reads.update(kind, (count) => count + 1, ifAbsent: () => 1);
    if (kind == 'episodeUserPresentation') presented.add(id);
    return super.read(kind, id);
  }

  void resetReads() {
    reads.clear();
    presented.clear();
  }
}

void _actionTests() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'episode action keeps keyboard activation and target size: ${platform.name}',
      (tester) async {
        var presses = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PodcastIconButton(
                tooltip: '节目操作测试',
                onPressed: () => presses++,
                icon: const Icon(Icons.more_horiz),
              ),
            ),
          ),
        );
        final action = find.byType(PodcastIconButton);
        expect(
          tester.getSize(action),
          Size.square(platform == TargetPlatform.android ? 48 : 44),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(presses, 1);
        await tester.tap(find.byTooltip('节目操作测试'));
        expect(presses, 2);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}

void main({bool profile = false}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  const baseline = bool.fromEnvironment('PODCAST_SCROLL_BASELINE');
  if (!profile) _actionTests();

  for (final count in [500, 2000, 10000]) {
    for (final viewport in [
      (TargetPlatform.android, const Size(390, 844)),
      (TargetPlatform.iOS, const Size(390, 844)),
      (TargetPlatform.windows, const Size(1440, 900)),
      (TargetPlatform.macOS, const Size(1280, 800)),
      (TargetPlatform.linux, const Size(1280, 800)),
    ]) {
      if (profile &&
          (count !=
                  const int.fromEnvironment(
                    'PODCAST_SCROLL_EPISODES',
                    defaultValue: 2000,
                  ) ||
              viewport.$1 != defaultTargetPlatform)) {
        continue;
      }
      testWidgets(
        '$count episodes ${viewport.$1.name}: distant scrollbar drag builds only the viewport',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = viewport.$2;
          final root = Directory.systemTemp.createTempSync('podcast-perf-');
          final store = _CountingStore();
          final client = PodcastClient();
          final controller = PodcastController(
            store: store,
            client: client,
            mediaStore: PodcastMediaStore(
              root: root,
              store: store,
              http: client.http,
            ),
          );
          final channel = PodcastChannel(
            id: 'perf-channel',
            feedUrl: 'https://example.com/feed',
            title: '长列表测试',
          );
          store.write('channel', channel.id, channel.toJson());
          store.setSetting(channel.id, 'autoRefresh', false);
          store.setSetting(channel.id, 'groupSeasons', true);
          store.transaction(() {
            for (var i = 0; i < count; i++) {
              final episode = PodcastEpisode(
                id: 'perf-$i',
                channelId: channel.id,
                title: i % 3 == 0 ? '第 $i 集：${'长标题' * 20}' : '第 $i 集',
                description: i % 5 == 0
                    ? ''
                    : List.filled(
                        2 + i % 12,
                        '<p>节目简介与时间轴 01:30 继续收听</p>',
                      ).join(),
                publishedMs: count - i,
                durationMs: 3600000,
                season: i ~/ 40,
                media: [PodcastMedia(url: 'https://example.com/$i.mp3')],
              );
              store.write(
                'episode',
                episode.id,
                episode.toJson(),
                channel: channel.id,
              );
            }
          });
          // A real queue contains a full snapshot; eager per-row JSON reads
          // should not make scrollbar cost grow with the size of this snapshot.
          store.write('queue', 'current', {
            'version': 2,
            'ids': [for (var i = 0; i < count; i++) 'perf-$i'],
            'entries': [
              for (var i = 0; i < count; i++)
                {
                  'kind': 'podcast',
                  'episodeId': 'perf-$i',
                  'mediaId': 'perf-$i',
                },
            ],
          });
          final runtime = PodcastRuntime.forTesting(controller);
          PodcastRuntime.debugOverride = runtime;
          addTearDown(() async {
            PodcastRuntime.debugOverride = null;
            runtime.dispose();
            await controller.close();
            store.close();
            root.deleteSync(recursive: true);
            tester.view.reset();
          });

          Widget app({double textScale = 1}) => MaterialApp(
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: PodcastChannelPage(channelId: channel.id),
          );
          await tester.pumpWidget(app());
          await tester.pumpAndSettle();
          final scrollbar = find.byKey(
            const ValueKey('podcast-channel-episodes-scrollbar'),
          );
          final scroll = tester.widget<PodcastScrollbar>(scrollbar).controller;
          final rect = tester.getRect(scrollbar);
          final catalogQueries = store.catalogQueries;
          store.resetReads();
          final elapsed = Stopwatch()..start();
          final drag = await tester.startGesture(
            thumbCenter(tester, scrollbar),
          );
          await drag.moveBy(const Offset(0, 2));
          await tester.pump();
          await drag.moveTo(Offset(rect.right - 7, rect.bottom - 8));
          await tester.pump();
          await drag.up();
          await tester.pumpAndSettle();
          elapsed.stop();
          final dragRows = store.presented.length;
          final dragQueueReads = store.reads['queue'] ?? 0;
          final dragSettingsReads = store.reads['settings'] ?? 0;

          // Repeated distant jumps cover reverse travel and estimated extents.
          var maxJumpRows = 0;
          final jumpTimes = <int>[];
          for (final fraction in [.1, .9, .25, .75, 1.0, 0.0]) {
            store.resetReads();
            final watch = Stopwatch()..start();
            scroll.jumpTo(scroll.position.maxScrollExtent * fraction);
            await tester.pumpAndSettle();
            watch.stop();
            jumpTimes.add(watch.elapsedMicroseconds);
            if (store.presented.length > maxJumpRows) {
              maxJumpRows = store.presented.length;
            }
            expect(tester.takeException(), isNull);
            if (!baseline) {
              expect(store.reads['queue'] ?? 0, 0);
              expect(store.presented.length, lessThan(80));
            }
          }
          // ignore: avoid_print
          print(
            'PODCAST_SCROLL ${jsonEncode({'episodes': count, 'platform': viewport.$1.name, 'dragRows': dragRows, 'dragQueueReads': dragQueueReads, 'dragSettingsReads': dragSettingsReads, 'dragMicros': elapsed.elapsedMicroseconds, 'maxJumpRows': maxJumpRows, 'jumpMicros': jumpTimes})}',
          );
          if (!baseline) {
            expect(dragRows, lessThan(80));
            expect(dragQueueReads, 0);
            expect(dragSettingsReads, 0);
          }
          expect(store.catalogQueries, catalogQueries);
          if (profile) {
            await _profileDragging(tester, scrollbar, count);
          }
          if (!baseline && !profile && count == 2000) {
            // Changes at a distant offset must keep layout lazy even when
            // the header moves between the list and the desktop sidebar.
            scroll.jumpTo(scroll.position.maxScrollExtent * .85);
            await tester.pumpAndSettle();
            store.resetReads();
            tester.view.physicalSize = viewport.$2.width < 600
                ? const Size(1440, 900)
                : const Size(390, 844);
            await tester.pumpWidget(app(textScale: 1.7));
            await tester.pumpAndSettle();
            expect(store.presented.length, lessThan(80));
            expect(tester.takeException(), isNull);

            store.setSetting(channel.id, 'density', 'compact');
            store.setSetting(channel.id, 'groupSeasons', false);
            controller.publish();
            await tester.pumpAndSettle();
            // The new end must be reachable immediately after shrinking rows.
            scroll.jumpTo(scroll.position.maxScrollExtent);
            await tester.pumpAndSettle();
            expect(
              find.byKey(ValueKey('podcast-episode-surface-perf-${count - 1}')),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          }
          if (!baseline &&
              !profile &&
              count == 500 &&
              viewport.$1 == TargetPlatform.windows) {
            final row = find.byType(PodcastEpisodeTile).hitTestable().first;
            final id = tester.widget<PodcastEpisodeTile>(row).episode.id;
            final menu = find.descendant(
              of: row,
              matching: find.byTooltip('节目操作'),
            );
            store.resetReads();
            store.write('queue', 'current', {'ids': <String>[]});
            await tester.tap(menu);
            await tester.pumpAndSettle();
            expect(find.text('从队列移除'), findsNothing);
            expect(store.reads['queue'], 1);
            await tester.tapAt(const Offset(10, 10));
            await tester.pumpAndSettle();
            // Queue and listen state can change without rebuilding this row.
            store.write('queue', 'current', {
              'ids': [id],
            });
            controller.state(id).favorite = true;
            await tester.tap(menu);
            await tester.pumpAndSettle();
            expect(find.text('从队列移除'), findsOneWidget);
            expect(find.text('取消收藏'), findsOneWidget);
            expect(store.reads['queue'], 2);
            await tester.tapAt(const Offset(10, 10));
            await tester.pumpAndSettle();
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: profile
            ? const DefaultTestVariant()
            : TargetPlatformVariant.only(viewport.$1),
      );
    }
  }
}

/// Run 1,800 drag updates through the real scrollbar in a native profile
/// build. Widget-test wall times above measure work, not native frame rate.
Future<void> _profileDragging(
  WidgetTester tester,
  Finder scrollbar,
  int count,
) async {
  final timings = <ui.FrameTiming>[];
  void collect(List<ui.FrameTiming> batch) => timings.addAll(batch);
  final binding = WidgetsBinding.instance;
  binding.addTimingsCallback(collect);
  final rect = tester.getRect(scrollbar);
  final drag = await tester.startGesture(
    thumbCenter(tester, scrollbar),
    kind: PointerDeviceKind.mouse,
  );
  try {
    await drag.moveBy(const Offset(0, 2));
    await tester.pump();
    for (var frame = 0; frame < 1800; frame++) {
      // Cross most of the catalog once a second, in both directions.
      final phase = frame % 120;
      final fraction =
          .05 + .9 * (phase < 60 ? phase / 60 : (120 - phase) / 60);
      await drag.moveTo(
        Offset(rect.right - 7, rect.top + rect.height * fraction),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  } finally {
    binding.removeTimingsCallback(collect);
  }
  expect(timings, isNotEmpty, reason: 'Run with -d windows --profile');
  final refreshRate =
      ui.PlatformDispatcher.instance.views.first.display.refreshRate;
  final budgetMicros = 1000000 / refreshRate;
  Map<String, Object> summarize(List<int> values) {
    values.sort();
    int percentile(double fraction) =>
        values[((values.length - 1) * fraction).round()];
    return {
      'p50Micros': percentile(.5),
      'p95Micros': percentile(.95),
      'p99Micros': percentile(.99),
      'overBudgetFrames': values.where((value) => value > budgetMicros).length,
    };
  }

  final report = {
    'episodes': count,
    'frames': timings.length,
    'refreshRate': refreshRate,
    'build': summarize([
      for (final timing in timings) timing.buildDuration.inMicroseconds,
    ]),
    'raster': summarize([
      for (final timing in timings) timing.rasterDuration.inMicroseconds,
    ]),
  };
  // ignore: avoid_print
  print('PODCAST_SCROLL_PROFILE ${jsonEncode(report)}');
  const output = String.fromEnvironment('PODCAST_SCROLL_PROFILE_OUTPUT');
  if (output.isNotEmpty) {
    await tester.runAsync(
      () => File(output).writeAsString(
        jsonEncode({
          ...report,
          'frameTimings': [
            for (final timing in timings)
              {
                'buildMicros': timing.buildDuration.inMicroseconds,
                'rasterMicros': timing.rasterDuration.inMicroseconds,
              },
          ],
        }),
      ),
    );
  }
}
